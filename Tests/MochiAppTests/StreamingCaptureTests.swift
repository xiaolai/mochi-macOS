import AVFoundation
import PCM16
import XCTest

@testable import MochiApp

/// Hands-free listening falls back to capture without voice processing where voice processing cannot start (issue #1).
final class StreamingCaptureTests: XCTestCase {
    private struct Refused: Error, Equatable { let mode: Bool }

    /// Runs the fallback with an attempt that fails in the modes given, recording the modes it was tried in.
    private func attempts(skipped: Bool = false, failing: Set<Bool>) -> (tried: [Bool], result: Result<Error?, Error>) {
        var tried: [Bool] = []
        let result = Result {
            try StreamingCapture.preferVoiceProcessing(unless: skipped) { voiceProcessing in
                tried.append(voiceProcessing)
                if failing.contains(voiceProcessing) { throw Refused(mode: voiceProcessing) }
            }
        }
        return (tried, result)
    }

    func testVoiceProcessingThatStartsIsUsedAlone() throws {
        let (tried, result) = attempts(failing: [])
        XCTAssertEqual(tried, [true])
        XCTAssertNil(try result.get())
    }

    func testVoiceProcessingThatFailsFallsBackToPlainCaptureAndReportsWhy() throws {
        let (tried, result) = attempts(failing: [true])
        XCTAssertEqual(tried, [true, false])
        XCTAssertEqual(try result.get() as? Refused, Refused(mode: true))
    }

    func testDevicesItFailedOnGoStraightToPlainCapture() throws {
        let (tried, result) = attempts(skipped: true, failing: [true])
        XCTAssertEqual(tried, [false])
        XCTAssertNil(try result.get())
    }

    /// When plain capture fails too, the microphone itself failed: its error surfaces, and nothing tells the caller
    /// to stop trying voice processing on these devices.
    func testPlainCaptureFailureSurfacesItsOwnError() {
        let (tried, result) = attempts(failing: [true, false])
        XCTAssertEqual(tried, [true, false])
        XCTAssertThrowsError(try result.get()) { XCTAssertEqual($0 as? Refused, Refused(mode: false)) }
    }

    func testPlainCaptureFailureSurfacesWhenSkipped() {
        let (tried, result) = attempts(skipped: true, failing: [false])
        XCTAssertEqual(tried, [false])
        XCTAssertThrowsError(try result.get()) { XCTAssertEqual($0 as? Refused, Refused(mode: false)) }
    }
}

/// Engines that render offline: they run, take a tap and players, and never open a device, so the capture's engine
/// lifecycle can be tested on any Mac. Voice processing is reported, not performed.
@MainActor private final class OfflineEngines {
    struct Refused: Error {}
    static let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
    /// Every engine made, and whether it was asked for voice processing.
    private(set) var made: [(engine: AVAudioEngine, voiceProcessing: Bool)] = []
    /// Every request, including refused ones: true asked for voice processing.
    private(set) var requested: [Bool] = []
    var refuseVoiceProcessing = false
    var devices = AudioDevicePair(input: 1, output: 2)
    /// A tone the input supplies whenever the engine renders.
    private let tone: AVAudioPCMBuffer = {
        let buffer = AVAudioPCMBuffer(pcmFormat: OfflineEngines.format, frameCapacity: 4800)!
        buffer.frameLength = 4800
        for i in 0..<4800 { buffer.floatChannelData![0][i] = 0.3 * sin(Float(i) * 0.05) }
        return buffer
    }()

    func capture() -> StreamingCapture {
        StreamingCapture(
            makeEngine: { [unowned self] voiceProcessing in try make(voiceProcessing) },
            devices: { [unowned self] in devices })
    }

    var engine: AVAudioEngine? { made.last?.engine }

    private func make(_ voiceProcessing: Bool) throws -> AVAudioEngine {
        requested.append(voiceProcessing)
        if voiceProcessing && refuseVoiceProcessing { throw Refused() }
        let engine = AVAudioEngine()
        try engine.enableManualRenderingMode(.offline, format: Self.format, maximumFrameCount: 4800)
        let tone = tone
        _ = engine.inputNode.setManualRenderingInputPCMFormat(Self.format) { frames in
            tone.frameLength = min(frames, tone.frameCapacity)
            return tone.audioBufferList
        }
        // Connected, the input reports the format the tap converts from, and the tap sees what is rendered.
        engine.connect(engine.inputNode, to: engine.mainMixerNode, format: Self.format)
        made.append((engine, voiceProcessing))
        return engine
    }

    /// Pulls `seconds` of audio through the newest engine, as the hardware would.
    func render(_ seconds: Double) throws {
        let engine = try XCTUnwrap(engine)
        let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4800))
        for _ in 0..<Int(seconds * 10) { _ = try engine.renderOffline(4800, to: output) }
    }

    /// What AVAudioEngine posts when its device changes or stops.
    func changeDevice() throws {
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: try XCTUnwrap(engine))
    }
}

/// The capture's engine lifecycle: starting and stopping, a device change, and replies played through the engine.
final class StreamingCaptureLifecycleTests: XCTestCase {
    private func replyFile() throws -> URL {
        let folder = makeTemporaryFolder()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("reply.wav")
        try PCM.wav(Data(repeating: 0, count: 9600), rate: PCM.sampleRate).write(to: url)
        return url
    }

    @MainActor func testCaptureDeliversConvertedAudioAndStopReleasesTheEngine() async throws {
        let engines = OfflineEngines()
        let capture = engines.capture()
        var delivered = Data()
        try capture.start(deliver: { delivered.append($0) }, interrupted: { XCTFail("Nothing interrupted it") })
        XCTAssertEqual(engines.made.map(\.voiceProcessing), [true])
        XCTAssertTrue(capture.isRunning)
        try engines.render(1)
        await waitUntil { delivered.count >= 24000 }
        XCTAssertEqual(delivered.count % 2, 0, "Whole 16-bit samples")
        XCTAssertLessThanOrEqual(delivered.count, 48000 + 4800, "One second at 24 kHz, or nearly")
        capture.stop()
        XCTAssertFalse(capture.isRunning)
        XCTAssertFalse(capture.engineRunning, "With nothing playing, stopping releases the engine and the microphone")
        let after = delivered.count
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(delivered.count, after, "Nothing arrives after stop")
    }

    @MainActor func testADeviceChangeStopsTheCaptureAndReportsItOnce() async throws {
        let engines = OfflineEngines()
        let capture = engines.capture()
        var interruptions = 0
        try capture.start(deliver: { _ in }, interrupted: { interruptions += 1 })
        try engines.changeDevice()
        await waitUntil { interruptions == 1 }
        XCTAssertFalse(capture.isRunning)
        XCTAssertFalse(capture.engineRunning)
        try engines.changeDevice()
        capture.stop()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(interruptions, 1, "Reported once, and never for an engine already let go")
        // The next start makes a new engine.
        try capture.start(deliver: { _ in }, interrupted: {})
        XCTAssertEqual(engines.made.count, 2)
        XCTAssertTrue(capture.isRunning)
        capture.stop()
    }

    @MainActor func testAReplyPlaysThroughTheListeningEngineWhichRunsUntilItEnds() throws {
        let engines = OfflineEngines()
        let capture = engines.capture()
        try capture.start(deliver: { _ in }, interrupted: {})
        let player = try XCTUnwrap(capture.player(try replyFile()) { _, _ in })
        XCTAssertEqual(engines.made.count, 1, "The reply plays through the engine the microphone listens through")
        XCTAssertTrue(player.play())
        capture.stop()
        XCTAssertFalse(capture.isRunning)
        XCTAssertTrue(capture.engineRunning, "The engine keeps running for the reply still playing through it")
        player.stop()
        XCTAssertFalse(capture.engineRunning, "Once the reply is let go nothing needs the engine")
    }

    @MainActor func testAReplyWithoutCaptureStartsItsOwnEngineAndADeviceChangeEndsItOnce() async throws {
        let engines = OfflineEngines()
        let capture = engines.capture()
        var ends: [Bool] = []
        let player = try XCTUnwrap(capture.player(try replyFile()) { _, reached in ends.append(reached) })
        XCTAssertEqual(engines.made.map(\.voiceProcessing), [true])
        XCTAssertTrue(player.play())
        XCTAssertTrue(capture.engineRunning)
        try engines.changeDevice()
        await waitUntil { !ends.isEmpty }
        XCTAssertEqual(ends, [false], "Cut off, not played to its end")
        XCTAssertFalse(capture.engineRunning)
        player.stop()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(ends, [false], "Reported once")
    }

    /// Listening that starts while Mochi speaks joins the engine the reply plays through, and a device change then
    /// ends both, each reported once.
    @MainActor func testCaptureStartedDuringAReplySharesItsEngine() async throws {
        let engines = OfflineEngines()
        let capture = engines.capture()
        var ends: [Bool] = []
        var interruptions = 0
        let player = try XCTUnwrap(capture.player(try replyFile()) { _, reached in ends.append(reached) })
        XCTAssertTrue(player.play())
        try capture.start(deliver: { _ in }, interrupted: { interruptions += 1 })
        XCTAssertEqual(engines.made.count, 1, "The capture joins the reply's engine")
        XCTAssertTrue(capture.isRunning)
        try engines.changeDevice()
        await waitUntil { interruptions == 1 && ends == [false] }
        XCTAssertFalse(capture.isRunning)
        XCTAssertFalse(capture.engineRunning)
    }

    /// A reply played to its end reports so, and lets the engine go when nothing else needs it.
    @MainActor func testAReplyThatPlaysToItsEndReleasesTheEngine() async throws {
        let engines = OfflineEngines()
        let capture = engines.capture()
        var ends: [Bool] = []
        let player = try XCTUnwrap(capture.player(try replyFile()) { _, reached in ends.append(reached) })
        XCTAssertTrue(player.play())
        // The hardware keeps pulling audio until the reply ends, and when its end is reported after the last sample
        // varies by system, so render on until it is, for at most ten seconds of audio.
        for _ in 0..<100 where ends.isEmpty {
            try engines.render(0.1)
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(ends, [true])
        XCTAssertFalse(capture.engineRunning)
    }

    @MainActor func testWithoutVoiceProcessingRepliesPlayTheOrdinaryWayOnThoseDevices() throws {
        let engines = OfflineEngines()
        engines.refuseVoiceProcessing = true
        let capture = engines.capture()
        // A reply with no capture running tries voice processing, and a failure there is not remembered: only a
        // plain capture that then starts proves the microphone itself works.
        XCTAssertNil(try capture.player(try replyFile()) { _, _ in })
        XCTAssertFalse(capture.engineRunning)
        XCTAssertEqual(engines.requested, [true])
        try capture.start(deliver: { _ in }, interrupted: {})
        XCTAssertEqual(engines.requested, [true, true, false], "Tried with voice processing, then without")
        XCTAssertTrue(capture.isRunning)
        XCTAssertNil(
            try capture.player(try replyFile()) { _, _ in }, "A plain engine cannot cancel the echo of a reply")
        capture.stop()
        XCTAssertFalse(capture.engineRunning)
        // Those devices go straight to plain capture, and replies straight to the ordinary player.
        try capture.start(deliver: { _ in }, interrupted: {})
        XCTAssertEqual(engines.requested, [true, true, false, false])
        capture.stop()
        XCTAssertNil(try capture.player(try replyFile()) { _, _ in })
        XCTAssertEqual(engines.requested.count, 4)
        // Other devices are tried with voice processing again.
        engines.devices = AudioDevicePair(input: 3, output: 4)
        engines.refuseVoiceProcessing = false
        try capture.start(deliver: { _ in }, interrupted: {})
        XCTAssertEqual(engines.made.last?.voiceProcessing, true)
        capture.stop()
    }
}
