import AVFoundation
import CoreAudio
import Foundation
import MochiKernel

/// Live microphone audio for hands-free listening, and Mochi's own speech while it listens through it. One
/// `AVAudioEngine` with voice processing on carries both: the microphone tap, converted to 24 kHz mono 16-bit PCM and
/// delivered in order on the main actor, and replies played through the same engine, so the echo canceller has
/// exactly what the speakers play as its reference and the learner can interrupt Mochi without Mochi hearing itself
/// (plan H4). Press to send keeps using `AVAudioRecorder` and `AVAudioPlayer`.
///
/// On some Macs the voice-processing unit cannot initialize for a pair of devices (issue #1: error -10875 on an M1 Pro
/// MacBook Pro's built-in microphone and speakers). Listening then captures without voice processing, and replies
/// play the ordinary way with the microphone closed (plan D4): the learner cannot interrupt, but hands-free works.
@MainActor final class StreamingCapture {
    private var engine: AVAudioEngine?
    /// Whether `engine` runs voice processing. Replies play through the engine only when it does.
    private var engineProcessesVoice = false
    /// Default device pairs voice processing failed to start on, while plain capture started there. Listening on
    /// them goes straight to plain capture rather than failing again, which can stall audio for seconds each time.
    private var voiceProcessingFailed: Set<AudioDevicePair> = []
    private var configurationObserver: NSObjectProtocol?
    private var tapInstalled = false
    private var interrupted: (@MainActor () -> Void)?
    /// The reply playing through the engine, if any. The engine, and with it the microphone, stops once neither the
    /// tap nor a player needs it.
    private weak var player: EnginePlayer?
    /// Changes on every start and stop, so audio or an interruption queued by an earlier capture is dropped.
    private var generation = UUID()
    /// True while the microphone tap delivers audio.
    var isRunning: Bool { tapInstalled && engine?.isRunning == true }
    /// True while the engine runs at all; the microphone is in use whenever it does.
    var engineRunning: Bool { engine?.isRunning == true }
    /// Makes a new engine, with voice processing on when asked; tests make engines that never open a device.
    private let makeEngine: @MainActor (_ voiceProcessing: Bool) throws -> AVAudioEngine
    /// The default devices now, which a voice-processing failure is remembered for.
    private let currentDevices: @MainActor () -> AudioDevicePair

    init(
        makeEngine: @escaping @MainActor (_ voiceProcessing: Bool) throws -> AVAudioEngine = StreamingCapture
            .deviceEngine,
        devices: @escaping @MainActor () -> AudioDevicePair = AudioDevicePair.current
    ) {
        self.makeEngine = makeEngine
        currentDevices = devices
    }

    /// An engine on the default devices. Voice processing ducks other apps' audio by default; Mochi needs only its
    /// own echo removed.
    static func deviceEngine(voiceProcessing: Bool) throws -> AVAudioEngine {
        let engine = AVAudioEngine()
        guard voiceProcessing else { return engine }
        do { try engine.inputNode.setVoiceProcessingEnabled(true) } catch {
            throw AppFailure("Could not start the microphone. Check Sound settings and retry.", underlying: error)
        }
        engine.inputNode.voiceProcessingOtherAudioDuckingConfiguration = .init(
            enableAdvancedDucking: false, duckingLevel: .min)
        return engine
    }

    /// Starts capturing. `deliver` receives each converted piece; `interrupted` is called once when the input
    /// device changes or stops underneath the capture, after which the capture has stopped.
    func start(
        deliver: @escaping @MainActor (Data) -> Void, interrupted: @escaping @MainActor () -> Void
    ) throws {
        stop()
        let devices = currentDevices()
        let failure = try Self.preferVoiceProcessing(unless: voiceProcessingFailed.contains(devices)) {
            voiceProcessing in
            let engine = try prepareEngine(voiceProcessing: voiceProcessing)
            try installTap(on: engine, deliver: deliver, interrupted: interrupted)
            self.interrupted = interrupted
            do { try run(engine) } catch {
                stop()
                throw AppFailure("Could not start the microphone. Check Sound settings and retry.", underlying: error)
            }
        }
        if let failure {
            voiceProcessingFailed.insert(devices)
            MochiLog.failure(
                MochiLog.audio, "Start voice processing; listening without it, so Mochi cannot be interrupted", failure)
        }
    }

    /// Runs `attempt` with voice processing (`true`) unless `skipped`, and again without it (`false`) when that throws.
    /// Returns the voice-processing error when the plain attempt then succeeded, so the caller can remember the
    /// devices; when the plain attempt fails too, its error is thrown and nothing is to be remembered, since the
    /// microphone itself, not voice processing, is what failed.
    nonisolated static func preferVoiceProcessing(unless skipped: Bool, _ attempt: (Bool) throws -> Void) throws
        -> Error?
    {
        guard !skipped else {
            try attempt(false)
            return nil
        }
        do {
            try attempt(true)
            return nil
        } catch {
            try attempt(false)
            return error
        }
    }

    /// Installs the tap that converts the input to 24 kHz mono 16-bit PCM for `deliver`.
    private func installTap(
        on engine: AVAudioEngine, deliver: @escaping @MainActor (Data) -> Void,
        interrupted: @escaping @MainActor () -> Void
    ) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
            let target = AVAudioFormat(
                commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: true),
            let converter = AVAudioConverter(from: format, to: target)
        else {
            releaseIfIdle()
            throw AppFailure("No microphone is available. Check Sound settings and retry.")
        }
        converter.downmix = true
        let ratio = 24000 / format.sampleRate
        let current = UUID()
        generation = current
        /// Runs `body` on the main actor only while this capture is still the current one.
        let onMain: @Sendable (@escaping @MainActor (StreamingCapture) -> Void) -> Void = { [weak self] body in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.generation == current else { return }
                    body(self)
                }
            }
        }
        // About 100 ms per piece at the device's rate.
        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(format.sampleRate / 10), format: format) {
            buffer, _ in
            guard
                let output = AVAudioPCMBuffer(
                    pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64)
            else { return }
            var supplied = false
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, state in
                guard !supplied else {
                    state.pointee = .noDataNow
                    return nil
                }
                supplied = true
                state.pointee = .haveData
                return buffer
            }
            guard status != .error, error == nil else {
                // Audio that cannot be converted would leave the microphone open while nothing is heard.
                onMain { capture in
                    MochiLog.failure(
                        MochiLog.audio, "Convert listening audio", error ?? AppFailure(verbatim: "Conversion failed."))
                    capture.stop()
                    interrupted()
                }
                return
            }
            guard let samples = output.int16ChannelData, output.frameLength > 0 else { return }
            let data = Data(bytes: samples[0], count: Int(output.frameLength) * 2)
            // The main queue keeps pieces in the order the tap produced them.
            onMain { _ in deliver(data) }
        }
        tapInstalled = true
    }

    /// Stops the microphone tap. The engine keeps running only for a reply still playing through it.
    func stop() {
        generation = UUID()
        interrupted = nil
        if tapInstalled { engine?.inputNode.removeTap(onBus: 0) }
        tapInstalled = false
        releaseIfIdle()
    }

    /// A player for a reply, played through the engine the microphone listens through. `finished` is called once
    /// when playback reaches the end (`true`) or the engine stopped underneath it (`false`); never after `stop()`.
    /// Nil when voice processing is unavailable here, so the reply plays the ordinary way with the microphone closed.
    func player(_ url: URL, finished: @escaping @MainActor (any PlaybackPlayer, Bool) -> Void) throws
        -> (any PlaybackPlayer)?
    {
        let file = try AVAudioFile(forReading: url)
        player?.stop()
        let engine: AVAudioEngine
        if let current = self.engine {
            guard engineProcessesVoice else { return nil }
            engine = current
        } else {
            guard !voiceProcessingFailed.contains(currentDevices()) else { return nil }
            // Started here rather than on play, so a voice-processing failure leaves the reply to an ordinary player.
            // It is not remembered: only a plain capture that then starts proves the microphone itself works.
            do {
                engine = try prepareEngine(voiceProcessing: true)
                try run(engine)
            } catch {
                MochiLog.failure(
                    MochiLog.audio, "Start voice processing for a reply; playing it the ordinary way", error)
                releaseIfIdle()
                return nil
            }
        }
        let player = EnginePlayer(file: file, engine: engine, capture: self, finished: finished)
        self.player = player
        return player
    }

    /// Starts the engine for a player.
    fileprivate func runForPlayback() throws {
        guard let engine else { throw AppFailure("This audio file could not be played.") }
        try run(engine)
    }

    /// A player let go of the engine.
    fileprivate func playerReleased(_ released: EnginePlayer) {
        if player === released { player = nil }
        releaseIfIdle()
    }

    /// The engine in use, or a new one, with voice processing on when `voiceProcessing`. An engine in use is kept
    /// either way: one exists here only while a reply plays through it, which needs voice processing.
    private func prepareEngine(voiceProcessing: Bool) throws -> AVAudioEngine {
        if let engine { return engine }
        let engine = try makeEngine(voiceProcessing)
        _ = engine.mainMixerNode
        self.engine = engine
        engineProcessesVoice = voiceProcessing
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.engineChanged(engine) }
        }
        return engine
    }

    private func run(_ engine: AVAudioEngine) throws {
        guard !engine.isRunning else { return }
        engine.prepare()
        try engine.start()
    }

    /// The device changed or stopped: the engine stopped underneath both the tap and any player.
    private func engineChanged(_ changed: AVAudioEngine) {
        guard engine === changed else { return }
        MochiLog.audio.notice("The listening audio device changed or stopped")
        let interrupted = tapInstalled ? self.interrupted : nil
        let player = self.player
        tapInstalled = false
        self.interrupted = nil
        self.player = nil
        generation = UUID()
        changed.inputNode.removeTap(onBus: 0)
        teardown()
        player?.engineStopped()
        interrupted?()
    }

    private func releaseIfIdle() {
        guard !tapInstalled, player == nil else { return }
        teardown()
    }

    private func teardown() {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        engine?.stop()
        engine = nil
        engineProcessesVoice = false
    }
}

/// The system's default input and output devices, which voice processing joins into one aggregate device.
struct AudioDevicePair: Hashable {
    let input: AudioObjectID
    let output: AudioObjectID

    /// The current defaults; a side Core Audio cannot report is `kAudioObjectUnknown`.
    static func current() -> AudioDevicePair {
        func device(_ selector: AudioObjectPropertySelector) -> AudioObjectID {
            var device = AudioObjectID(kAudioObjectUnknown)
            var size = UInt32(MemoryLayout<AudioObjectID>.size)
            var address = AudioObjectPropertyAddress(
                mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            let status = AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
            return status == noErr ? device : AudioObjectID(kAudioObjectUnknown)
        }
        return AudioDevicePair(
            input: device(kAudioHardwarePropertyDefaultInputDevice),
            output: device(kAudioHardwarePropertyDefaultOutputDevice))
    }
}

/// Plays one reply through the listening engine, with the `AVAudioPlayer` surface `AudioController` drives.
@MainActor final class EnginePlayer: @MainActor PlaybackPlayer {
    private let file: AVAudioFile
    private let node = AVAudioPlayerNode()
    private let pitch = AVAudioUnitTimePitch()
    private weak var engine: AVAudioEngine?
    private weak var capture: StreamingCapture?
    private let finished: @MainActor (any PlaybackPlayer, Bool) -> Void
    private let sampleRate: Double
    /// The file frame the current schedule started from.
    private var startFrame: AVAudioFramePosition = 0
    /// Where a paused or not yet started player resumes, in seconds.
    private var resumeAt: TimeInterval? = 0
    /// Changes whenever the schedule is replaced or dropped, so its completion no longer counts.
    private var schedule = UUID()
    private var attached = true
    let duration: TimeInterval
    var enableRate = true
    var rate: Float {
        get { pitch.rate }
        set { pitch.rate = newValue }
    }

    fileprivate init(
        file: AVAudioFile, engine: AVAudioEngine, capture: StreamingCapture,
        finished: @escaping @MainActor (any PlaybackPlayer, Bool) -> Void
    ) {
        self.file = file
        self.engine = engine
        self.capture = capture
        self.finished = finished
        sampleRate = file.processingFormat.sampleRate
        duration = Double(file.length) / sampleRate
        engine.attach(node)
        engine.attach(pitch)
        engine.connect(node, to: pitch, format: file.processingFormat)
        engine.connect(pitch, to: engine.mainMixerNode, format: file.processingFormat)
    }

    var currentTime: TimeInterval {
        get {
            if let resumeAt { return resumeAt }
            guard let render = node.lastRenderTime, let time = node.playerTime(forNodeTime: render) else {
                return Double(startFrame) / sampleRate
            }
            return min(duration, max(0, Double(startFrame + time.sampleTime) / sampleRate))
        }
        set {
            let seconds = min(max(0, newValue), duration)
            if resumeAt != nil {
                resumeAt = seconds
            } else {
                scheduleFrom(seconds)
                node.play()
            }
        }
    }

    func play() -> Bool {
        guard attached, let resume = resumeAt else { return attached }
        do { try capture?.runForPlayback() } catch {
            MochiLog.failure(MochiLog.audio, "Play a reply while listening", error)
            return false
        }
        guard engine?.isRunning == true else { return false }
        scheduleFrom(resume)
        resumeAt = nil
        node.play()
        return true
    }

    func pause() {
        guard attached, resumeAt == nil else { return }
        resumeAt = currentTime
        schedule = UUID()
        node.stop()
    }

    func stop() {
        guard attached else { return }
        release()
    }

    /// The engine stopped underneath the player.
    fileprivate func engineStopped() {
        guard attached else { return }
        release()
        finished(self, false)
    }

    private func scheduleFrom(_ seconds: TimeInterval) {
        let token = UUID()
        schedule = token
        node.stop()
        startFrame = min(file.length, AVAudioFramePosition(seconds * sampleRate))
        let remaining = file.length - startFrame
        guard remaining > 0 else {
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.complete(token) }
            }
            return
        }
        node.scheduleSegment(
            file, startingFrame: startFrame, frameCount: AVAudioFrameCount(remaining), at: nil,
            completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.complete(token) }
            }
        }
    }

    private func complete(_ token: UUID) {
        guard attached, schedule == token else { return }
        // A segment also completes when the engine stops underneath it, as on a device change whose notification
        // may arrive after this callback; that is a failure, reported once, never the reply played to its end.
        guard engine?.isRunning == true else {
            engineStopped()
            return
        }
        release()
        finished(self, true)
    }

    private func release() {
        attached = false
        schedule = UUID()
        node.stop()
        if let engine {
            engine.detach(node)
            engine.detach(pitch)
        }
        capture?.playerReleased(self)
    }
}
