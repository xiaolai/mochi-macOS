import AVFoundation
import MochiCore
import MochiTestSupport
import PCM16
import XCTest

@testable import MochiApp

final class RecordingTests: XCTestCase {
    @MainActor func testMicrophoneThatStopsMidTakeEndsTheRecordingWithAnExplanation() async throws {
        let root = makeTemporaryFolder()
        let app = makeApp(root: root)
        var recorded: URL?
        var active = true
        app.media.permission = { true }
        app.media.record = { url in
            recorded = url
            try Data([1, 2, 3]).write(to: url)
        }
        app.media.stopRecording = {
            defer { recorded = nil }
            return recorded
        }
        app.media.recordingActive = { active }
        app.recordingSleep = { _ in await Task.yield() }
        app.toggleRecord()
        await waitUntil { app.turn.activity == .recording }
        let file = try XCTUnwrap(recorded)
        active = false
        await waitUntil { app.turn.activity == .idle }
        XCTAssertTrue(app.error?.contains("microphone disconnected") == true, app.error ?? "no error")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(app.conversation?.messages.isEmpty == true)
    }

    @MainActor func testTakeThatReachedTheTimeLimitIsKeptNotTreatedAsInterrupted() async throws {
        let root = makeTemporaryFolder()
        var active = true
        let (app, file) = recordingApp(root: root, content: tone(), active: { active })
        // The recorder confirms a successful stop at its limit; elapsed time alone no longer decides.
        app.media.recordingFinished = { !active }
        var now = Date()
        app.recordingNow = { now }
        app.startHelp()
        app.recordMeaning()
        await waitUntil { app.turn.activity == .recording }
        now = now.addingTimeInterval(59.8)
        active = false
        app.finishRecording()
        await waitUntil { app.help.thoughtRecording != nil && !app.busy }
        XCTAssertNil(app.error)
        let name = try XCTUnwrap(file()?.lastPathComponent)
        XCTAssertEqual(app.help.thoughtRecording, name)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path))
        app.stop()
    }

    @MainActor func testFailedTakeAtTheTimeLimitIsDiscardedNotKept() async throws {
        let root = makeTemporaryFolder()
        var active = true
        let (app, file) = recordingApp(root: root, content: tone(), active: { active })
        app.media.recordingInterrupted = { !active }
        var now = Date()
        app.recordingNow = { now }
        app.startHelp()
        app.recordMeaning()
        await waitUntil { app.turn.activity == .recording }
        now = now.addingTimeInterval(59.8)
        active = false
        app.finishRecording()
        XCTAssertTrue(app.error?.contains("microphone disconnected") == true, app.error ?? "no error")
        XCTAssertNil(app.help.thoughtRecording)
        let url = try XCTUnwrap(file())
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    @MainActor func testFinishingAfterTheMicrophoneStoppedDiscardsThePartialTake() async throws {
        let root = makeTemporaryFolder()
        var active = true
        let (app, file) = recordingApp(root: root, content: tone(), active: { active })
        app.startHelp()
        app.recordMeaning()
        await waitUntil { app.turn.activity == .recording }
        active = false
        app.finishRecording()
        // With no confirmed outcome the decision waits briefly for the recorder's report, then discards.
        await waitUntil { app.error != nil }
        XCTAssertTrue(app.error?.contains("microphone disconnected") == true, app.error ?? "no error")
        XCTAssertNil(app.help.thoughtRecording)
        let url = try XCTUnwrap(file())
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    @MainActor func testStoppedTakeIsKeptOnceTheRecorderConfirmsSuccess() async throws {
        var finished = false
        let (app, url) = await stoppedTake(finished: { finished })
        app.finishRecording()
        // The outcome has not arrived yet: nothing is decided.
        XCTAssertNil(app.error)
        XCTAssertEqual(app.turn.activity, .recording)
        finished = true
        await waitUntil { app.help.thoughtRecording != nil && !app.busy }
        XCTAssertNil(app.error)
        XCTAssertEqual(app.help.thoughtRecording, url.lastPathComponent)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        app.stop()
    }

    @MainActor func testStoppedTakeIsDiscardedWhenAFailureArrivesLate() async throws {
        var interrupted = false
        let (app, url) = await stoppedTake(finished: { false }, interrupted: { interrupted })
        app.finishRecording()
        XCTAssertNil(app.error)
        interrupted = true
        await waitUntil { app.error != nil }
        XCTAssertTrue(app.error?.contains("microphone disconnected") == true, app.error ?? "no error")
        XCTAssertNil(app.help.thoughtRecording)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    @MainActor func testStoppedTakeWithoutAConfirmedOutcomeIsDiscardedEvenNearTheLimit() async throws {
        var now = Date()
        let (app, url) = await stoppedTake(finished: { false })
        app.recordingNow = { now }
        now = now.addingTimeInterval(59.9)
        app.finishRecording()
        await waitUntil { app.error != nil }
        XCTAssertTrue(app.error?.contains("microphone disconnected") == true, app.error ?? "no error")
        XCTAssertNil(app.help.thoughtRecording)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    @MainActor func testUnreadableThoughtRecordingIsRemovedAndReported() async throws {
        let root = makeTemporaryFolder()
        let (app, file) = recordingApp(root: root, content: Data([1, 2, 3]), active: { true })
        app.startHelp()
        app.recordMeaning()
        await waitUntil { app.turn.activity == .recording }
        app.finishRecording()
        await waitUntil { !app.busy }
        XCTAssertNotNil(app.error)
        XCTAssertNil(app.help.thoughtRecording)
        XCTAssertNotEqual(app.notice, "Your thought is recorded locally. Listen, then choose Transcribe.")
        let url = try XCTUnwrap(file())
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    @MainActor func testUnreadableVoiceMessageIsRemovedAndNothingIsSent() async throws {
        let root = makeTemporaryFolder()
        let (app, file) = recordingApp(root: root, content: Data([1, 2, 3]), active: { true })
        app.toggleRecord()
        await waitUntil { app.turn.activity == .recording }
        app.finishRecording()
        await waitUntil { !app.busy }
        XCTAssertNotNil(app.error)
        XCTAssertTrue(app.conversation?.messages.isEmpty == true)
        let url = try XCTUnwrap(file())
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    @MainActor func testRecordingClockUpdatesAndStopsWithoutMicrophone() async throws {
        let app = makeApp(demo: true)
        var now = Date()
        app.recordingNow = { now }
        app.media.meter = { -60 }
        let gate = TestGate()
        let ticked = expectation(description: "Feedback updated")
        var ticks = 0
        app.recordingSleep = { _ in
            ticks += 1
            if ticks == 1 {
                now = now.addingTimeInterval(2)
            } else {
                ticked.fulfill()
                await gate.wait()
            }
        }
        let token = app.turn.begin(.recording)
        app.startRecordingFeedback(token: token)
        let clock = try XCTUnwrap(app.recordingClock)
        await fulfillment(of: [ticked], timeout: 2)
        XCTAssertEqual(app.recordingSeconds, 2)
        XCTAssertNotNil(app.recordingWarning)
        app.stop()
        await gate.release()
        await clock.value
        XCTAssertEqual(app.recordingSeconds, 2)
        XCTAssertEqual(app.recordingLevel, -80)
    }

    @MainActor func testRecordingFeedbackUsesElapsedTimeAndSanitizesMeter() {
        let app = makeApp(demo: true)
        app.updateRecordingFeedback(elapsed: 3.4, level: -60)
        XCTAssertEqual(app.recordingSeconds, 3)
        XCTAssertNotNil(app.recordingWarning)
        app.updateRecordingFeedback(elapsed: 3.5, level: -12)
        XCTAssertNil(app.recordingWarning)
        // A pause between words is not a quiet microphone: the warning would otherwise blink in and out mid-sentence.
        app.updateRecordingFeedback(elapsed: 4.0, level: -60)
        XCTAssertNil(app.recordingWarning)
        app.updateRecordingFeedback(elapsed: 5.4, level: -60)
        XCTAssertNil(app.recordingWarning)
        app.updateRecordingFeedback(elapsed: 5.5, level: -60)
        XCTAssertNotNil(app.recordingWarning)
        app.updateRecordingFeedback(elapsed: 4.1, level: -12)
        XCTAssertEqual(app.recordingSeconds, 4)
        XCTAssertNil(app.recordingWarning)
        app.updateRecordingFeedback(elapsed: 0.4, level: .nan)
        XCTAssertEqual(app.recordingLevel, -80)
        XCTAssertNil(app.recordingWarning)
    }

    private func tone(seconds: Double = 0.5) -> Data {
        var pcm = Data()
        for i in 0..<Int(24000 * seconds) {
            var value = Int16(sin(2 * Double.pi * 180 * Double(i) / 24000) * 12000).littleEndian
            withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) }
        }
        // Half a second of 24 kHz audio is far inside the header's range, so writing it cannot fail.
        return try! PCM.wav(pcm, rate: PCM.sampleRate)
    }

    /// A fake microphone whose take is written by `content`; the clock never ticks on its own.
    @MainActor private func recordingApp(root: URL, content: Data, active: @escaping () -> Bool) -> (
        AppModel, () -> URL?
    ) {
        let app = makeApp(root: root)
        var recorded: URL?
        var last: URL?
        app.media.permission = { true }
        app.media.record = { url in
            recorded = url
            last = url
            try content.write(to: url)
        }
        app.media.stopRecording = {
            defer { recorded = nil }
            return recorded
        }
        app.media.recordingActive = active
        app.recordingSleep = { _ in try await Task.sleep(nanoseconds: 60_000_000_000) }
        return (app, { last })
    }

    /// A take whose recorder stopped on its own; `finished` and `interrupted` model the recorder's late report.
    @MainActor private func stoppedTake(
        finished: @escaping () -> Bool, interrupted: @escaping () -> Bool = { false }
    ) async -> (AppModel, URL) {
        let root = makeTemporaryFolder()
        let app = makeApp(root: root)
        var recorded: URL?
        var active = true
        app.media.permission = { true }
        app.media.record = { url in
            recorded = url
            try self.tone().write(to: url)
        }
        app.media.stopRecording = { recorded }
        app.media.recordingActive = { active }
        app.media.recordingFinished = finished
        app.media.recordingInterrupted = interrupted
        app.recordingSleep = { _ in try await Task.sleep(nanoseconds: 60_000_000_000) }
        app.startHelp()
        app.recordMeaning()
        await waitUntil { app.turn.activity == .recording }
        active = false
        return (app, recorded!)
    }

    private func wav(rate: Double, frames: Int, _ sample: (Int) -> Float) throws -> URL {
        let folder = TestScratch.folder("r2a-audio")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("clip-\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(
            forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        for i in 0..<frames { buffer.floatChannelData![0][i] = sample(i) }
        try file.write(from: buffer)
        return url
    }
}
