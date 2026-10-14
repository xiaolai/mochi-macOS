import AVFoundation
import Foundation
import MochiCore
import MochiKernel

protocol PlaybackPlayer: AnyObject {
    var duration: TimeInterval { get }
    var currentTime: TimeInterval { get set }
    var enableRate: Bool { get set }
    var rate: Float { get set }
    func play() -> Bool
    func pause()
    func stop()
}
extension AVAudioPlayer: PlaybackPlayer {}

@MainActor @Observable final class AudioController: NSObject, AVAudioPlayerDelegate, AVAudioRecorderDelegate {
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    private(set) var paused = false
    @ObservationIgnored private var playbackClock: Task<Void, Never>?
    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var player: (any PlaybackPlayer)?
    @ObservationIgnored var makePlayer: (URL) throws -> any PlaybackPlayer = { try AVAudioPlayer(contentsOf: $0) }
    /// Consulted first: a player for audio that must play somewhere other than `makePlayer`'s, or nil.
    @ObservationIgnored var routedPlayer: ((URL) throws -> (any PlaybackPlayer)?)?
    /// True while the audio playing came from `routedPlayer`.
    @ObservationIgnored private(set) var playingRouted = false
    @ObservationIgnored private var playingURL: URL?
    @ObservationIgnored private var completion: (() -> Void)?
    @ObservationIgnored private var failure: (() -> Void)?
    /// Set when the recorder reports an error or the microphone it started on disconnects.
    @ObservationIgnored private(set) var recordingInterrupted = false
    /// Set when the recorder reports that it stopped successfully at its time limit.
    @ObservationIgnored private(set) var recordingFinished = false
    @ObservationIgnored private var recordingDevice: String?
    @ObservationIgnored private var disconnectObserver: NSObjectProtocol?
    /// False once recording ends for any reason other than `stopRecording()`.
    var isRecording: Bool { recorder?.isRecording == true && !recordingInterrupted }
    var meter: Float {
        recorder?.updateMeters()
        return recorder?.averagePower(forChannel: 0) ?? -80
    }
    func permission() async -> Bool {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized { return true }
        return await AVCaptureDevice.requestAccess(for: .audio)
    }
    func record(to url: URL, maxDuration: Double = 60) throws {
        stop()
        let r = try AVAudioRecorder(
            url: url,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 24000, AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            ])
        r.isMeteringEnabled = true
        r.delegate = self
        guard r.record(forDuration: maxDuration) else {
            throw AppFailure("Could not start the microphone. Check Sound settings and retry.")
        }
        recorder = r
        recordingInterrupted = false
        recordingFinished = false
        recordingDevice = AVCaptureDevice.default(for: .audio)?.uniqueID
        disconnectObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: .main
        ) { [weak self] note in
            let id = (note.object as? AVCaptureDevice)?.uniqueID
            MainActor.assumeIsolated { self?.deviceDisconnected(id) }
        }
    }
    private func deviceDisconnected(_ id: String?) {
        // Only the microphone this recording started on matters; unplugging another device does not.
        guard recorder != nil, let id, id == recordingDevice else { return }
        MochiLog.audio.notice("The recording microphone disconnected")
        recordingInterrupted = true
    }
    func stopRecording() -> URL? {
        let url = recorder?.url
        recorder?.stop()
        recorder = nil
        if let disconnectObserver { NotificationCenter.default.removeObserver(disconnectObserver) }
        disconnectObserver = nil
        recordingDevice = nil
        return url
    }
    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor in
            guard self.recorder === recorder else { return }
            if let error { MochiLog.failure(MochiLog.audio, "Recording encode error", error) }
            self.recordingInterrupted = true
        }
    }
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in
            // `stopRecording()` releases the recorder first, so only a stop the recorder chose itself arrives here.
            guard self.recorder === recorder else { return }
            guard flag else {
                MochiLog.audio.notice("The recorder stopped unsuccessfully")
                self.recordingInterrupted = true
                return
            }
            self.recordingFinished = true
        }
    }
    func play(url: URL, rate: Float = 1, failed: (() -> Void)? = nil, completed: @escaping () -> Void) throws {
        stop()
        let routed = try routedPlayer?(url)
        let p = try routed ?? makePlayer(url)
        playingRouted = routed != nil
        playingURL = url
        (p as? AVAudioPlayer)?.delegate = self
        p.enableRate = true
        p.rate = rate
        completion = completed
        failure = failed
        player = p
        guard p.play() else {
            stop()
            throw AppFailure("This audio file could not be played.")
        }
        duration = p.duration
        paused = false
        playbackClock = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let player = self.player else { return }
                self.position = player.currentTime
                do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
            }
        }
    }
    /// The playing position now, read from the player rather than the 100 ms clock.
    var elapsed: Double { player?.currentTime ?? position }
    func togglePause() {
        guard let player else { return }
        if paused {
            guard player.play() else {
                let callback = failure ?? completion
                stop()
                callback?()
                return
            }
            paused = false
        } else {
            player.pause()
            position = player.currentTime
            paused = true
        }
    }
    func seek(to seconds: Double) {
        guard let player, seconds.isFinite else { return }
        player.currentTime = min(max(0, seconds), player.duration)
        position = player.currentTime
    }
    /// Moves routed audio to `makePlayer`'s player at the same position, paused if it was, with the same completion,
    /// so whatever the routed player held (the listening microphone's engine) can be let go.
    func moveToOrdinaryPlayer() {
        guard playingRouted, let routed = player, let url = playingURL else { return }
        let time = routed.currentTime
        playingRouted = false
        do {
            let ordinary = try makePlayer(url)
            (ordinary as? AVAudioPlayer)?.delegate = self
            ordinary.enableRate = true
            ordinary.rate = routed.rate
            ordinary.currentTime = time
            // Swapped before the routed player stops, so nothing it reports late is taken for this playback.
            player = ordinary
            routed.stop()
            guard paused || ordinary.play() else { throw AppFailure("This audio file could not be played.") }
        } catch {
            MochiLog.failure(MochiLog.audio, "Move playback off the listening engine", error)
            routed.stop()
            let callback = failure ?? completion
            stop()
            callback?()
        }
    }
    private func resetPlayback() {
        playingRouted = false
        playingURL = nil
        playbackClock?.cancel()
        playbackClock = nil
        position = 0
        duration = 0
        paused = false
    }
    func stop() {
        resetPlayback()
        _ = stopRecording()
        player?.stop()
        player = nil
        completion = nil
        failure = nil
    }
    func finishPlayback(_ player: any PlaybackPlayer, successfully flag: Bool) {
        guard self.player === player else { return }
        let callback = flag ? completion : (failure ?? completion)
        completion = nil
        failure = nil
        self.player = nil
        resetPlayback()
        callback?()
    }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.finishPlayback(player, successfully: flag) }
    }
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in self.finishPlayback(player, successfully: false) }
    }
}
enum AudioFile {
    /// Decodes a whole file to mono samples. One `read(into:)` can stop short of the end, so reading
    /// continues until the file is exhausted; for uncompressed audio the decoded length must match exactly.
    /// Cancelling the calling task stops decoding with `CancellationError`.
    static func samples(_ url: URL, maxDuration: Double = 65, isCancelled: () -> Bool = { Task.isCancelled }) throws
        -> (
            samples: [Float], rate: Double
        )
    {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard file.length > 0, Double(file.length) / format.sampleRate <= maxDuration else {
            throw AppFailure("Choose a shorter audio clip for this operation.")
        }
        guard let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65536) else {
            throw AppFailure("Cannot decode this recording.")
        }
        let channelCount = Int(format.channelCount)
        var samples = [Float]()
        samples.reserveCapacity(Int(file.length))
        while file.framePosition < file.length {
            if isCancelled() { throw CancellationError() }
            try file.read(into: chunk)
            let count = Int(chunk.frameLength)
            guard count > 0 else { break }
            guard let channels = chunk.floatChannelData else { throw AppFailure("Unsupported recording format.") }
            for i in 0..<count {
                var sum: Float = 0
                for c in 0..<channelCount { sum += channels[c][i] }
                samples.append(sum / Float(channelCount))
            }
        }
        if file.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatLinearPCM,
            samples.count != Int(file.length)
        {
            throw AppFailure("This recording could not be read completely. Record it again.")
        }
        if isCancelled() { throw CancellationError() }
        return (samples, format.sampleRate)
    }
    /// Mono little-endian 16-bit PCM at 24 kHz. Cancelling the calling task stops with `CancellationError`.
    static func pcm(_ url: URL) throws -> Data {
        let (samples, rate) = try samples(url)
        let count = Int(Double(samples.count) * 24000 / rate)
        guard count >= 2400 else {
            throw AppFailure("That recording was too short. Speak for at least a moment, then finish.")
        }
        let resampled = rate == 24000 ? samples : try resample(samples, from: rate, frames: count)
        try Task.checkCancellation()
        var data = Data(capacity: count * 2)
        for i in 0..<count {
            let mixed = i < resampled.count ? resampled[i] : 0
            // Clamp before scaling: a huge finite sample would overflow the integer conversion.
            let sample = mixed.isFinite ? max(-1, min(1, mixed)) : 0
            var value = Int16(sample * 32767).littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        return data
    }
    /// Band-limited conversion to 24 kHz. Recordings restored from a backup can have any rate; the converter
    /// filters out what 24 kHz cannot carry instead of folding it back into the audible band.
    private static func resample(_ samples: [Float], from rate: Double, frames: Int) throws -> [Float] {
        let failure = AppFailure("This recording could not be converted. Record it again.")
        guard
            let input = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
            let output = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false),
            let converter = AVAudioConverter(from: input, to: output),
            let source = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: AVAudioFrameCount(samples.count)),
            let target = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: AVAudioFrameCount(frames + 4096)),
            let sourceData = source.floatChannelData, let targetData = target.floatChannelData
        else { throw failure }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
        source.frameLength = AVAudioFrameCount(samples.count)
        for i in samples.indices { sourceData[0][i] = samples[i].isFinite ? samples[i] : 0 }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: target, error: &error) { _, state in
            guard !supplied else {
                state.pointee = .endOfStream
                return nil
            }
            supplied = true
            state.pointee = .haveData
            return source
        }
        guard status != .error, error == nil else { throw AppFailure(verbatim: failure.message, underlying: error) }
        return Array(UnsafeBufferPointer(start: targetData[0], count: Int(target.frameLength)))
    }
    /// Cancelling the calling task stops with `CancellationError`, never a partial or empty contour.
    static func pitch(_ url: URL) throws -> [PitchPoint] {
        let (samples, rate) = try samples(url)
        let points = PitchAnalyzer.analyze(samples: samples, sampleRate: rate)
        // The analyzer stops early on cancellation; its partial result must not look like a finished one.
        try Task.checkCancellation()
        return points
    }
    /// Analyses off the main actor; cancelling the caller stops the analysis instead of letting it run on.
    static func pitchInBackground(_ url: URL) async throws -> [PitchPoint] {
        let work = Task.detached(priority: .userInitiated) { try AudioFile.pitch(url) }
        let points = try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
        // The detached work can finish just before the caller is cancelled; that result is no longer wanted.
        try Task.checkCancellation()
        return points
    }
}
