import Carbon.HIToolbox
import MochiCore
import MochiKernel
import MochiTestSupport
import PCM16
import SwiftUI
import XCTest

@testable import MochiApp
@testable import MochiProviders

/// A listening session the test drives: it records the audio sent and reports what the test tells it to.
private final class FakeLine: ListeningLine, @unchecked Sendable {
    let signals: AsyncThrowingStream<ListeningSignal, Error>
    private let sink: AsyncThrowingStream<ListeningSignal, Error>.Continuation
    private(set) var sent = Data()
    private(set) var closed = false
    /// While true, appended audio waits unsent, as behind a slow connection.
    var stalled = false
    var sentBytes: Int { stalled ? 0 : sent.count }
    init() { (signals, sink) = AsyncThrowingStream.makeStream(of: ListeningSignal.self) }
    func append(_ pcm: Data) { sent.append(pcm) }
    func close() {
        closed = true
        sink.finish()
    }
    func emit(_ signal: ListeningSignal) { sink.yield(signal) }
    func fail(_ error: Error) { sink.finish(throwing: error) }
}

/// The microphone and the connections, as the test feeds and inspects them.
@MainActor private final class FakeListening {
    var deliver: (@MainActor (Data) -> Void)?
    var interrupted: (@MainActor () -> Void)?
    var lines: [FakeLine] = []
    var detections: [TurnDetection] = []
    var captureStarts = 0
    var refuseSession: Error?
    var refuseCapture: Error?
    var capturing: Bool { deliver != nil }
    /// Players made for speech routed through listening; nil makes none, so speech plays the ordinary way.
    var routedPlayer: TestPlayer?
    var routedURLs: [URL] = []
    var routedFinish: (@MainActor (any PlaybackPlayer, Bool) -> Void)?
    var services: ListeningServices {
        ListeningServices(
            startCapture: { deliver, interrupted in
                if let refuseCapture = self.refuseCapture { throw refuseCapture }
                self.captureStarts += 1
                self.deliver = deliver
                self.interrupted = interrupted
            },
            stopCapture: {
                self.deliver = nil
                self.interrupted = nil
            },
            capturing: { self.capturing },
            openSession: { detection, _ in
                try await MainActor.run {
                    self.detections.append(detection)
                    if let refuseSession = self.refuseSession { throw refuseSession }
                    let line = FakeLine()
                    self.lines.append(line)
                    return line
                }
            },
            makePlayer: { url, finished in
                guard let player = self.routedPlayer else { return nil }
                self.routedURLs.append(url)
                self.routedFinish = finished
                return player
            })
    }
    /// Feeds `pcm` as capture would, in 100 ms pieces.
    func feed(_ pcm: Data) {
        for offset in stride(from: 0, to: pcm.count, by: 4800) {
            deliver?(pcm.subdata(in: offset..<min(offset + 4800, pcm.count)))
        }
    }
}

/// `seconds` of a tone at `decibels` dBFS, or of low noise when `decibels` is nil.
private func audio(_ seconds: Double, decibels: Float? = nil) -> Data {
    let count = Int(seconds * 24000)
    var data = Data(capacity: count * 2)
    var seed: UInt32 = 7
    for i in 0..<count {
        let value: Double
        if let decibels {
            value = pow(10, Double(decibels) / 20) * 32767 * 2.0.squareRoot() * sin(2 * .pi * 220 * Double(i) / 24000)
        } else {
            seed = seed &* 1_103_515_245 &+ 12345
            value = Double(Int(seed >> 16) % 61 - 30)
        }
        var sample = Int16(max(-32767, min(32767, value))).littleEndian
        withUnsafeBytes(of: &sample) { data.append(contentsOf: $0) }
    }
    return data
}

/// Equal length, and no sample more than one step apart.
private func assertSameAudio(_ a: Data, _ b: Data, _ message: String, line: UInt = #line) {
    XCTAssertEqual(a.count, b.count, message, line: line)
    let left = a.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
    let right = b.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
    let worst = zip(left, right).map { abs(Int($0) - Int($1)) }.max() ?? 0
    XCTAssertLessThanOrEqual(worst, 1, message, line: line)
}

final class HandsFreeTests: XCTestCase {
    /// A conversation in hands-free mode with fake listening, ready to start; the greeting is already done.
    @MainActor private func handsFreeApp(_ listening: FakeListening) -> AppModel {
        let app = makeApp(demo: true, listeningServices: listening.services)
        app.resume()
        app.newChat()
        if let index = app.library.conversations.firstIndex(where: { $0.id == app.selectedID }) {
            app.library.conversations[index].voiceIntroduced = true
        }
        app.settings.talkingMode = .handsFree
        app.media.permission = { true }
        return app
    }

    /// Starts listening and waits until the microphone and its connection are open.
    @MainActor private func startListening(_ app: AppModel, _ listening: FakeListening) async -> FakeLine? {
        app.toggleConversationVoice()
        await waitUntil { app.listening.phase == .listening && listening.capturing && !listening.lines.isEmpty }
        await waitUntil { app.listeningRuntime.line != nil }
        return listening.lines.last
    }

    /// Starts listening and returns the open connection; fails the test when none opened.
    @MainActor private func startedLine(_ app: AppModel, _ listening: FakeListening) async -> FakeLine {
        let line = await startListening(app, listening)
        XCTAssertNotNil(line, "No listening connection opened")
        return line ?? FakeLine()
    }

    /// Room noise, then speech the Mac hears start.
    @MainActor private func speak(_ listening: FakeListening, seconds: Double = 1) {
        listening.feed(audio(0.5))
        listening.feed(audio(seconds, decibels: -25))
    }

    // MARK: Settings

    @MainActor func testTalkingSettingsDefaultToPressToSendTwoMinutesAndPatient() {
        let preferences = makePreferences()
        let settings = PreferencesStore(preferences, importLegacy: false, allowExternalControl: false)
        XCTAssertEqual(settings.talkingMode, .pressToSend, "Hands-free is off by default")
        XCTAssertFalse(settings.listenAfterReply)
        XCTAssertEqual(settings.listeningPatience, .patient)
        XCTAssertEqual(settings.listeningSilenceLimit, .twoMinutes)
        settings.talkingMode = .handsFree
        settings.listenAfterReply = true
        settings.listeningPatience = .quick
        settings.listeningSilenceLimit = .tenMinutes
        let reloaded = PreferencesStore(preferences, importLegacy: false, allowExternalControl: false)
        XCTAssertEqual(reloaded.talkingMode, .handsFree)
        XCTAssertTrue(reloaded.listenAfterReply)
        XCTAssertEqual(reloaded.listeningPatience, .quick)
        XCTAssertEqual(reloaded.listeningSilenceLimit, .tenMinutes)
        preferences.set("shouting", forKey: "talkingMode")
        preferences.set(7, forKey: "listeningSilenceMinutes")
        preferences.set("impatient", forKey: "listeningPatience")
        let rejected = PreferencesStore(preferences, importLegacy: false, allowExternalControl: false)
        XCTAssertEqual(rejected.talkingMode, .pressToSend, "An unknown stored value falls back to the default")
        XCTAssertEqual(rejected.listeningSilenceLimit, .twoMinutes, "There is no seven-minute or never choice")
        XCTAssertEqual(rejected.listeningPatience, .patient)
    }

    // MARK: Turns

    @MainActor func testSessionUsesSemanticDetectionAtTheChosenEagerness() async throws {
        for (patience, eagerness) in [(ListeningPatience.patient, "low"), (.balanced, "medium"), (.quick, "high")] {
            let listening = FakeListening()
            let app = handsFreeApp(listening)
            app.settings.listeningPatience = patience
            _ = await startListening(app, listening)
            XCTAssertEqual(listening.detections, [.semantic(eagerness: eagerness)])
            app.stopListening()
            XCTAssertFalse(listening.capturing)
        }
    }

    @MainActor func testNothingIsSentUntilTheMacHearsSpeechThenItStartsWithPreRoll() async throws {
        let listening = FakeListening()
        let app = handsFreeApp(listening)
        let line = await startedLine(app, listening)
        listening.feed(audio(2))
        XCTAssertTrue(line.sent.isEmpty, "Silence is never streamed")
        XCTAssertEqual(app.listening.phase, .listening)
        listening.feed(audio(0.5, decibels: -25))
        XCTAssertEqual(app.listening.phase, .hearingSpeech)
        // The turn begins 300 ms before the detected start, and everything heard since is streamed.
        XCTAssertEqual(app.listeningRuntime.turnAudio.count, (300 + 500) * 48)
        XCTAssertEqual(line.sent, app.listeningRuntime.turnAudio)
        app.stop()
    }

    @MainActor func testAHandsFreeTurnSavesTheSameMessageAsAPressedOne() async throws {
        let listening = FakeListening()
        let app = handsFreeApp(listening)
        var requests: [ConversationRequest] = []
        app.speech.conversationReply = { _, request, _ in requests.append(request) }
        let line = await startedLine(app, listening)
        speak(listening)
        line.emit(.speechStarted(audioMilliseconds: 300))
        await waitUntil { app.listeningRuntime.apiHeardSpeech }
        listening.feed(audio(0.6))
        line.emit(.speechStopped(audioMilliseconds: 1300))
        await waitUntil { requests.count == 1 }
        XCTAssertTrue(line.closed, "The turn's connection closes when it ends")
        XCTAssertFalse(listening.capturing, "The microphone closes while Mochi works on the reply")
        let handsFree = try XCTUnwrap(app.conversation?.messages.last)
        let turnAudio = try XCTUnwrap(requests.first?.pcm)

        // The same audio, recorded with a press.
        let pressed = makeApp(demo: true)
        pressed.resume()
        pressed.newChat()
        var pressedRequests: [ConversationRequest] = []
        pressed.speech.conversationReply = { _, request, _ in pressedRequests.append(request) }
        if let index = pressed.library.conversations.firstIndex(where: { $0.id == pressed.selectedID }) {
            pressed.library.conversations[index].voiceIntroduced = true
        }
        var recorded: URL?
        pressed.media.permission = { true }
        pressed.media.record = { url in
            recorded = url
            try PCM.wav(turnAudio, rate: PCM.sampleRate).write(to: url)
        }
        pressed.media.stopRecording = { recorded }
        pressed.toggleRecord()
        await waitUntil { pressed.turn.activity == .recording }
        pressed.finishRecording()
        await waitUntil { pressedRequests.count == 1 }
        let pressedMessage = try XCTUnwrap(pressed.conversation?.messages.last)

        for message in [handsFree, pressedMessage] {
            XCTAssertEqual(message.role, "user")
            XCTAssertEqual(message.text, "")
            XCTAssertEqual(message.recording, RecordingMetadata(model: RealtimeService.transcriptionModel))
            XCTAssertNotNil(message.audio)
        }
        XCTAssertEqual(handsFree.transcriptionState, pressedMessage.transcriptionState)
        XCTAssertEqual(handsFree.transcriptionError, pressedMessage.transcriptionError)
        XCTAssertEqual(requests.first?.spoken, pressedRequests.first?.spoken)
        XCTAssertEqual(requests.first?.text, pressedRequests.first?.text)
        // The pressed path decodes its file through floating point, which can move a sample by one step.
        assertSameAudio(try XCTUnwrap(pressedRequests.first?.pcm), turnAudio, "Both paths send the same audio")
        let saved = try AudioFile.pcm(app.store.root.appendingPathComponent(try XCTUnwrap(handsFree.audio)))
        assertSameAudio(saved, turnAudio, "The saved recording is the turn")
        XCTAssertEqual(app.conversation?.voiceIntroduced, true)
        app.stop()
        pressed.stop()
    }

    @MainActor func testANoiseOnlyTurnCreatesNoMessage() async throws {
        let listening = FakeListening()
        let app = handsFreeApp(listening)
        app.speech.conversationReply = { _, _, _ in XCTFail("Noise must not be sent as a message") }
        let first = await startedLine(app, listening)
        // A loud sound the Mac takes for speech; the API never hears speech in it.
        listening.feed(audio(0.5))
        listening.feed(audio(0.4, decibels: -20))
        XCTAssertEqual(app.listening.phase, .hearingSpeech)
        listening.feed(audio(4))
        XCTAssertEqual(app.listening.phase, .listening)
        XCTAssertTrue(app.conversation?.messages.isEmpty == true)
        XCTAssertTrue(first.closed, "The dropped audio's connection is closed")
        await waitUntil { listening.lines.count == 2 && app.listeningRuntime.line === listening.lines.last }
        XCTAssertTrue(listening.capturing, "Listening goes on")
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(atPath: app.store.root.path).allSatisfy {
                !$0.hasPrefix("recording-")
            }, "No recording is written for noise")
        app.stop()
    }

    @MainActor func testSendNowEndsTheTurnAtOnce() async throws {
        let listening = FakeListening()
        let app = handsFreeApp(listening)
        var requests = 0
        app.speech.conversationReply = { _, _, _ in requests += 1 }
        _ = await startedLine(app, listening)
        XCTAssertFalse(app.canSendNow, "Nothing to send before speech")
        speak(listening)
        XCTAssertTrue(app.canSendNow)
        app.shortcutTriggered(.sendNow, pressed: true)
        await waitUntil { requests == 1 }
        XCTAssertEqual(app.conversation?.messages.count, 1)
        app.stop()
    }

    @MainActor func testATurnEndsAtTheRecordingLimit() async throws {
        let listening = FakeListening()
        let app = handsFreeApp(listening)
        var requests: [ConversationRequest] = []
        app.speech.conversationReply = { _, request, _ in requests.append(request) }
        let line = await startedLine(app, listening)
        listening.feed(audio(0.5))
        listening.feed(audio(1, decibels: -25))
        line.emit(.speechStarted(audioMilliseconds: 0))
        await waitUntil { app.listeningRuntime.apiHeardSpeech }
        listening.feed(audio(60, decibels: -25))
        await waitUntil { requests.count == 1 }
        let seconds = Double(try XCTUnwrap(requests.first?.pcm).count) / 48000
        XCTAssertEqual(seconds, AppModel.recordingLimit, accuracy: 0.11)
        app.stop()
    }

    @MainActor func testMochiNeverListensWhileSpeakingAndListensAgainAfterwards() async throws {
        let listening = FakeListening()
        let app = handsFreeApp(listening)
        let player = TestPlayer()
        app.audio.makePlayer = { _ in player }
        app.speech.conversationReply = { _, _, callbacks in
            var reply = RealtimeAccumulator()
            reply.text = "Tell me more."
            reply.audio = Data(repeating: 1, count: 4800)
            reply.done = true
            try callbacks.response(reply)
        }
        var now = Date(timeIntervalSinceReferenceDate: 5000)
        app.listeningNow = { now }
        app.listeningSleep = { _ in try await Task.sleep(nanoseconds: 60_000_000_000) }
        let line = await startedLine(app, listening)
        speak(listening)
        line.emit(.speechStarted(audioMilliseconds: 300))
        await waitUntil { app.listeningRuntime.apiHeardSpeech }
        line.emit(.speechStopped(audioMilliseconds: 1300))
        await waitUntil { app.turn.activity == .playing }
        XCTAssertEqual(app.listening.phase, .mochiSpeaking)
        XCTAssertFalse(listening.capturing, "The microphone is closed while Mochi speaks")
        XCTAssertTrue(app.listeningRuntime.line == nil && app.listeningRuntime.opening == nil)
        XCTAssertNil(app.listening.silenceDeadline)
        XCTAssertEqual(listening.captureStarts, 1, "The microphone never opened between the reply and its playback")
        now = now.addingTimeInterval(7)
        app.audio.finishPlayback(player, successfully: true)
        await waitUntil { app.listening.phase == .listening }
        XCTAssertTrue(listening.capturing)
        XCTAssertEqual(app.listening.silenceDeadline, now.addingTimeInterval(120), "Counted from playback's end")
        await waitUntil { listening.lines.count == 2 }
        app.stop()
    }

    @MainActor func testSilenceStopsListeningOnceAndClosesTheMicrophone() async throws {
        let listening = FakeListening()
        let app = handsFreeApp(listening)
        app.settings.listeningSilenceLimit = .oneMinute
        var now = Date(timeIntervalSinceReferenceDate: 5000)
        app.listeningNow = { now }
        let slept = expectation(description: "The timer waited for the deadline")
        app.listeningSleep = { nanoseconds in
            XCTAssertEqual(nanoseconds, 60_000_000_000)
            now = now.addingTimeInterval(60)
            slept.fulfill()
        }
        app.toggleConversationVoice()
        await fulfillment(of: [slept], timeout: 5)
        await waitUntil { app.listening.phase == .stoppedBySilence }
        XCTAssertFalse(listening.capturing, "The microphone is off after silence")
        XCTAssertTrue(listening.lines.allSatisfy(\.closed))
        XCTAssertEqual(
            app.notice, "Stopped listening after 1 min of silence. Start listening again when you’re ready.")
        XCTAssertEqual(app.status, "Stopped listening after silence · microphone off")
        XCTAssertEqual(app.microphoneLabel, "Start Listening")
        app.stop()
    }

    @MainActor func testAFailedSessionFallsBackToPressToSendWithANotice() async throws {
        let listening = FakeListening()
        let app = handsFreeApp(listening)
        let line = await startedLine(app, listening)
        speak(listening)
        line.fail(AppFailure("The listening connection ended. Check your connection; press to send still works."))
        await waitUntil { app.listening.phase == .failed }
        XCTAssertFalse(listening.capturing)
        XCTAssertTrue(app.handsFreeFallback)
        XCTAssertTrue(app.error?.contains("Listening stopped") == true, app.error ?? "no error")
        XCTAssertTrue(app.conversation?.messages.isEmpty == true, "The interrupted turn is not sent")
        // The microphone button now records one message at a time.
        var asked = false
        app.media.permission = {
            asked = true
            return false
        }
        app.toggleConversationVoice()
        await waitUntil { asked }
        XCTAssertEqual(app.listening.phase, .failed, "Press to send does not restart listening")
        // Start Listening tries hands-free again.
        app.media.permission = { true }
        app.toggleListening()
        await waitUntil { app.listening.phase == .listening }
        XCTAssertFalse(app.handsFreeFallback)
        app.stop()
    }

    @MainActor func testAConnectionThatDropsWhileNobodySpeaksIsReopenedQuietly() async throws {
        let listening = FakeListening()
        let app = handsFreeApp(listening)
        let line = await startedLine(app, listening)
        line.fail(AppFailure("Dropped."))
        await waitUntil { listening.lines.count == 2 }
        XCTAssertEqual(app.listening.phase, .listening)
        XCTAssertNil(app.error)
        try XCTUnwrap(listening.lines.dropFirst().first).fail(AppFailure("Dropped again."))
        await waitUntil { app.listening.phase == .failed }
        XCTAssertTrue(app.error?.contains("Dropped again.") == true, app.error ?? "no error")
        app.stop()
    }

    /// The one quiet reopen is per turn: a drop many turns after an earlier one is reopened quietly too.
    @MainActor func testADropAfterADeliveredTurnIsReopenedQuietlyAgain() async throws {
        let listening = FakeListening()
        let app = handsFreeApp(listening)
        let player = TestPlayer()
        app.audio.makePlayer = { _ in player }
        var requests = 0
        app.speech.conversationReply = { _, _, callbacks in
            requests += 1
            var reply = RealtimeAccumulator()
            reply.text = "Go on."
            reply.audio = Data(repeating: 1, count: 4800)
            reply.done = true
            try callbacks.response(reply)
        }
        let first = await startedLine(app, listening)
        first.fail(AppFailure("Dropped."))
        let reopened = await startedLineAfter(app, listening, lines: 2)
        XCTAssertNil(app.error)
        speak(listening)
        reopened.emit(.speechStarted(audioMilliseconds: 300))
        await waitUntil { app.listeningRuntime.apiHeardSpeech }
        reopened.emit(.speechStopped(audioMilliseconds: 1300))
        await waitUntil { requests == 1 && app.turn.activity == .playing }
        app.audio.finishPlayback(player, successfully: true)
        let later = await startedLineAfter(app, listening, lines: 3)
        later.fail(AppFailure("Dropped much later."))
        _ = await startedLineAfter(app, listening, lines: 4)
        XCTAssertEqual(app.listening.phase, .listening)
        XCTAssertFalse(app.handsFreeFallback)
        XCTAssertNil(app.error)
        app.stop()
    }

    @MainActor func testAConnectionThatCannotOpenFallsBack() async throws {
        let listening = FakeListening()
        listening.refuseSession = AppFailure("OpenAI usage limit reached (rate_limit_exceeded).")
        let app = handsFreeApp(listening)
        app.toggleConversationVoice()
        await waitUntil { app.listening.phase == .failed }
        XCTAssertEqual(listening.detections.count, 2, "Opened once, retried once while nobody spoke")
        XCTAssertTrue(app.error?.contains("usage limit") == true, app.error ?? "no error")
        app.stop()
    }

    @MainActor func testTheSecondTurnKeepsItsPreRoll() async throws {
        let listening = FakeListening()
        let app = handsFreeApp(listening)
        let player = TestPlayer()
        app.audio.makePlayer = { _ in player }
        var requests: [ConversationRequest] = []
        app.speech.conversationReply = { _, request, callbacks in
            requests.append(request)
            var reply = RealtimeAccumulator()
            reply.text = "Go on."
            reply.audio = Data(repeating: 1, count: 4800)
            reply.done = true
            try callbacks.response(reply)
        }
        for turn in 1...2 {
            let line = await startedLineAfter(app, listening, lines: turn)
            listening.feed(audio(1))
            listening.feed(audio(0.5, decibels: -25))
            XCTAssertEqual(
                app.listeningRuntime.turnAudio.count, (300 + 500) * 48,
                "Turn \(turn) starts 300 ms before its speech")
            line.emit(.speechStarted(audioMilliseconds: 300))
            await waitUntil { app.listeningRuntime.apiHeardSpeech }
            line.emit(.speechStopped(audioMilliseconds: 800))
            await waitUntil { requests.count == turn && app.turn.activity == .playing }
            app.audio.finishPlayback(player, successfully: true)
        }
        app.stop()
    }

    /// Starts listening the first time; afterwards waits for listening to resume with connection number `lines`.
    @MainActor private func startedLineAfter(_ app: AppModel, _ listening: FakeListening, lines: Int) async -> FakeLine
    {
        if lines == 1 { return await startedLine(app, listening) }
        await waitUntil {
            app.listening.phase == .listening && listening.capturing && listening.lines.count == lines
                && app.listeningRuntime.line === listening.lines.last
        }
        return listening.lines.last ?? FakeLine()
    }

    @MainActor func testAudioFromAStoppedCaptureNeverReachesTheNextOne() async throws {
        let listening = FakeListening()
        let app = handsFreeApp(listening)
        _ = await startedLine(app, listening)
        let stale = try XCTUnwrap(listening.deliver)
        let staleInterrupted = try XCTUnwrap(listening.interrupted)
        app.showExpressions = true
        await waitUntil { app.listening.phase == .paused }
        app.showExpressions = false
        await waitUntil { app.listening.phase == .listening && listening.capturing }
        stale(audio(0.5))
        stale(audio(1, decibels: -20))
        XCTAssertEqual(app.listening.phase, .listening, "The old capture's audio is ignored")
        staleInterrupted()
        XCTAssertEqual(app.listening.phase, .listening, "The old capture's interruption is ignored")
        app.stop()
    }

    @MainActor func testSpeechDuringASlowHandshakeIsNotDiscardedAsNoise() async throws {
        let listening = FakeListening()
        let gate = TestGate()
        let services = listening.services
        var slow = services
        slow.openSession = { detection, model in
            await gate.wait()
            return try await services.openSession(detection, model)
        }
        let app = handsFreeApp(listening)
        app.listeningServices = slow
        app.toggleConversationVoice()
        await waitUntil { app.listening.phase == .listening && listening.capturing }
        listening.feed(audio(0.5))
        listening.feed(audio(6, decibels: -25))
        XCTAssertEqual(app.listening.phase, .hearingSpeech, "Six seconds unheard by the API are not noise")
        await gate.release()
        await waitUntil { app.listeningRuntime.line != nil }
        let line = try XCTUnwrap(listening.lines.last)
        XCTAssertEqual(line.sent, app.listeningRuntime.turnAudio, "The backlog is sent once the connection opens")
        listening.feed(audio(3.9, decibels: -25))
        XCTAssertEqual(app.listening.phase, .hearingSpeech)
        listening.feed(audio(0.2, decibels: -25))
        XCTAssertEqual(app.listening.phase, .listening, "Four seconds heard live without speech is noise")
        app.stop()
    }

    @MainActor func testAStalledSenderIsNotMistakenForNoise() async throws {
        let listening = FakeListening()
        let app = handsFreeApp(listening)
        let line = await startedLine(app, listening)
        line.stalled = true
        listening.feed(audio(0.5))
        listening.feed(audio(6, decibels: -25))
        XCTAssertEqual(app.listening.phase, .hearingSpeech, "Audio the API never received cannot show it was noise")
        line.stalled = false
        listening.feed(audio(0.1, decibels: -25))
        XCTAssertEqual(app.listening.phase, .listening, "Once sent and still unheard as speech, it is noise")
        app.stop()
    }

    // MARK: Interrupting Mochi (H4)

    /// A hands-free conversation whose replies say `text` and play through listening's echo-cancelled player.
    @MainActor private func interruptibleApp(
        _ listening: FakeListening, text: String = "Tell me more about your weekend in the mountains."
    ) -> (AppModel, TestPlayer, () -> [ConversationRequest]) {
        let app = handsFreeApp(listening)
        let routed = TestPlayer()
        listening.routedPlayer = routed
        var requests: [ConversationRequest] = []
        app.speech.conversationReply = { _, request, callbacks in
            requests.append(request)
            var reply = RealtimeAccumulator()
            reply.text = text
            reply.audio = Data(repeating: 1, count: 4800)
            reply.done = true
            try callbacks.response(reply)
        }
        return (app, routed, { requests })
    }

    /// Speaks one turn and waits until Mochi speaks its reply with the microphone open to interrupt it.
    @MainActor private func untilMochiSpeaks(_ app: AppModel, _ listening: FakeListening) async {
        let line = await startedLine(app, listening)
        speak(listening)
        line.emit(.speechStarted(audioMilliseconds: 300))
        await waitUntil { app.listeningRuntime.apiHeardSpeech }
        line.emit(.speechStopped(audioMilliseconds: 1300))
        await waitUntil {
            app.listening.phase == .mochiSpeaking && listening.capturing && app.listeningRuntime.line != nil
        }
    }

    @MainActor func testSpeakingOverMochiStopsItAndKeepsOnlyWhatWasHeard() async throws {
        let listening = FakeListening()
        let (app, routed, requests) = interruptibleApp(listening)
        await untilMochiSpeaks(app, listening)
        XCTAssertEqual(listening.routedURLs.count, 1, "The reply plays through listening's routed player")
        XCTAssertTrue(routed.playing)
        XCTAssertTrue(app.listening.microphoneOpen, "Listening through Mochi's speech")
        await waitUntil { app.listeningRuntime.line != nil }
        let next = try XCTUnwrap(app.listeningRuntime.line as? FakeLine, "The next turn's connection opens")
        routed.currentTime = 2.5  // of 5 seconds
        speak(listening)
        XCTAssertFalse(routed.playing, "Mochi stops as soon as the learner speaks")
        XCTAssertEqual(app.turn.activity, .idle)
        XCTAssertEqual(app.listening.phase, .hearingSpeech)
        let reply = try XCTUnwrap(app.conversation?.messages.last { $0.role == "assistant" })
        XCTAssertEqual(reply.text, "Tell me more about your…", "Only the half that was heard is kept")
        XCTAssertNotNil(reply.audio)
        // The interruption is the next turn, sent the ordinary way with the shortened reply in its history.
        next.emit(.speechStarted(audioMilliseconds: 300))
        await waitUntil { app.listeningRuntime.apiHeardSpeech }
        next.emit(.speechStopped(audioMilliseconds: 1300))
        await waitUntil { requests().count == 2 }
        XCTAssertEqual(try XCTUnwrap(requests().dropFirst().first).history.last?.text, "Tell me more about your…")
        app.stop()
    }

    @MainActor func testAnInterruptionThatTurnsOutToBeNoiseLeavesMochiStoppedAndListening() async throws {
        let listening = FakeListening()
        let (app, routed, _) = interruptibleApp(listening)
        await untilMochiSpeaks(app, listening)
        routed.currentTime = 4
        listening.feed(audio(0.5))
        listening.feed(audio(0.2, decibels: -25))
        XCTAssertEqual(app.listening.phase, .hearingSpeech, "The sound interrupted Mochi")
        // A sound the API never hears as speech, fed until listening judges it noise.
        for _ in 0..<60 where app.listening.phase == .hearingSpeech { listening.feed(audio(0.1, decibels: -25)) }
        XCTAssertFalse(routed.playing)
        XCTAssertEqual(app.listening.phase, .listening, "No speech reached the API: noise, dropped")
        XCTAssertNotNil(app.listening.silenceDeadline)
        XCTAssertEqual(app.conversation?.messages.filter { $0.role == "user" }.count, 1, "No message was created")
        app.stop()
    }

    @MainActor func testAReplayedReplyIsStoppedButNotCutAgain() async throws {
        let listening = FakeListening()
        let (app, routed, _) = interruptibleApp(listening)
        await untilMochiSpeaks(app, listening)
        routed.currentTime = 2.5
        speak(listening)
        let reply = try XCTUnwrap(app.conversation?.messages.last { $0.role == "assistant" })
        XCTAssertEqual(reply.text, "Tell me more about your…")
        app.stopListening()
        // Played again from the message and interrupted again: the text stays as it was cut the first time.
        let replay = TestPlayer()
        listening.routedPlayer = replay
        app.toggleConversationVoice()
        await waitUntil { app.listening.phase == .listening && app.listeningRuntime.line != nil }
        app.play(try XCTUnwrap(reply.audio), mochi: true)
        await waitUntil { app.listening.phase == .mochiSpeaking && listening.capturing }
        replay.currentTime = 2.5
        speak(listening)
        XCTAssertFalse(replay.playing, "The replay stops")
        XCTAssertEqual(app.conversation?.messages.first { $0.id == reply.id }?.text, "Tell me more about your…")
        app.stop()
    }

    @MainActor func testAReplyStoppedWithStopAndReplayedIsNotCut() async throws {
        let listening = FakeListening()
        let (app, _, _) = interruptibleApp(listening)
        await untilMochiSpeaks(app, listening)
        let reply = try XCTUnwrap(app.conversation?.messages.last { $0.role == "assistant" })
        app.stop()
        XCTAssertNil(app.unheardReply)
        let replay = TestPlayer()
        listening.routedPlayer = replay
        app.toggleConversationVoice()
        await waitUntil { app.listening.phase == .listening && app.listeningRuntime.line != nil }
        app.play(try XCTUnwrap(reply.audio), mochi: true)
        await waitUntil { app.listening.phase == .mochiSpeaking && listening.capturing }
        replay.currentTime = 2.5
        speak(listening)
        XCTAssertFalse(replay.playing)
        XCTAssertEqual(app.conversation?.messages.first { $0.id == reply.id }?.text, reply.text)
        app.stop()
    }

    @MainActor func testTheLearnersOwnRecordingIsNeverInterruptible() async throws {
        let listening = FakeListening()
        let app = handsFreeApp(listening)
        listening.routedPlayer = TestPlayer()
        let ordinary = TestPlayer()
        app.audio.makePlayer = { _ in ordinary }
        let recording = app.store.root.appendingPathComponent("mine.wav")
        try PCM.wav(Data(repeating: 0, count: 4800), rate: PCM.sampleRate).write(to: recording)
        _ = await startedLine(app, listening)
        app.play("mine.wav")
        await waitUntil { app.listening.phase == .mochiSpeaking }
        XCTAssertTrue(listening.routedURLs.isEmpty, "Only Mochi's speech goes through the listening engine")
        XCTAssertTrue(ordinary.playing)
        XCTAssertFalse(listening.capturing, "The microphone stays closed while the learner's recording plays")
        app.stop()
    }

    @MainActor func testATurnEndingJustAfterASheetOpensIsNotSent() async throws {
        let listening = FakeListening()
        let app = handsFreeApp(listening)
        var requests = 0
        app.speech.conversationReply = { _, _, _ in requests += 1 }
        _ = await startedLine(app, listening)
        speak(listening)
        XCTAssertEqual(app.listening.phase, .hearingSpeech)
        app.history.managerOpen = true
        app.sendNow()  // before any observer has run
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(requests, 0)
        XCTAssertTrue(app.conversation?.messages.isEmpty == true, "Nothing is saved or sent")
        XCTAssertEqual(app.listening.phase, .paused)
        app.stop()
    }

    @MainActor func testAMicrophoneThatFailsAsMochiSpeaksMovesTheReplyOffTheEngine() async throws {
        let listening = FakeListening()
        let (app, routed, _) = interruptibleApp(listening)
        let ordinary = TestPlayer()
        app.audio.makePlayer = { _ in ordinary }
        let line = await startedLine(app, listening)
        speak(listening)
        line.emit(.speechStarted(audioMilliseconds: 300))
        await waitUntil { app.listeningRuntime.apiHeardSpeech }
        listening.refuseCapture = AppFailure("No microphone.")
        line.emit(.speechStopped(audioMilliseconds: 1300))
        await waitUntil { app.listening.phase == .off }
        XCTAssertFalse(routed.playing, "The listening engine's player is let go")
        XCTAssertTrue(ordinary.playing, "Mochi finishes the reply the ordinary way")
        XCTAssertFalse(app.audio.playingRouted)
        app.stop()
    }

    @MainActor func testStoppingListeningMovesTheReplyOffTheListeningEngine() async throws {
        let listening = FakeListening()
        let (app, routed, _) = interruptibleApp(listening)
        let ordinary = TestPlayer()
        app.audio.makePlayer = { _ in ordinary }
        await untilMochiSpeaks(app, listening)
        routed.currentTime = 1.5
        app.stopListening()
        XCTAssertFalse(routed.playing, "The listening engine's player is let go")
        XCTAssertTrue(ordinary.playing, "Mochi goes on speaking the ordinary way")
        XCTAssertEqual(ordinary.currentTime, 1.5, "From the same point")
        XCTAssertFalse(listening.capturing)
        XCTAssertFalse(app.audio.playingRouted)
        app.stop()
    }

    @MainActor func testPausingTheReplyClosesTheMicrophone() async throws {
        let listening = FakeListening()
        let (app, routed, _) = interruptibleApp(listening)
        let ordinary = TestPlayer()
        app.audio.makePlayer = { _ in ordinary }
        await untilMochiSpeaks(app, listening)
        let file = try XCTUnwrap(app.playbackFile)
        app.togglePlayback(file, mochi: true)
        XCTAssertTrue(app.audio.paused)
        XCTAssertFalse(routed.playing)
        XCTAssertFalse(ordinary.playing, "Moved, still paused")
        XCTAssertFalse(listening.capturing, "A paused reply does not keep the microphone open")
        XCTAssertFalse(app.listening.microphoneOpen)
        app.stop()
    }

    @MainActor func testTheCutReplyIsWhatIsSavedOnDisk() async throws {
        let listening = FakeListening()
        let root = makeTemporaryFolder()
        let app = makeApp(root: root, listeningServices: listening.services)
        await waitUntil { app.libraryReadable }
        app.resume()
        app.newChat()
        let id = try XCTUnwrap(app.selectedID)
        if let index = app.library.conversations.firstIndex(where: { $0.id == id }) {
            app.library.conversations[index].voiceIntroduced = true
        }
        app.settings.talkingMode = .handsFree
        app.media.permission = { true }
        let routed = TestPlayer()
        listening.routedPlayer = routed
        app.speech.conversationReply = { _, _, callbacks in
            var reply = RealtimeAccumulator()
            reply.text = "Tell me more about your weekend in the mountains."
            reply.audio = Data(repeating: 1, count: 4800)
            reply.done = true
            try callbacks.response(reply)
        }
        await untilMochiSpeaks(app, listening)
        routed.currentTime = 2.5
        speak(listening)
        app.stop()
        let reopened = makeApp(root: root)
        await waitUntil { reopened.libraryReadable }
        let saved = reopened.library.conversations.first { $0.id == id }?.messages.last { $0.role == "assistant" }
        XCTAssertEqual(saved?.text, "Tell me more about your…")
    }

    @MainActor func testSpeechPlayedTheOrdinaryWayIsNeverInterrupted() async throws {
        let listening = FakeListening()
        let (app, _, _) = interruptibleApp(listening)
        listening.routedPlayer = nil
        let player = TestPlayer()
        app.audio.makePlayer = { _ in player }
        let line = await startedLine(app, listening)
        speak(listening)
        line.emit(.speechStarted(audioMilliseconds: 300))
        await waitUntil { app.listeningRuntime.apiHeardSpeech }
        line.emit(.speechStopped(audioMilliseconds: 1300))
        await waitUntil { app.listening.phase == .mochiSpeaking }
        XCTAssertFalse(listening.capturing, "Without the echo canceller the microphone stays closed while Mochi speaks")
        XCTAssertTrue(player.playing)
        app.stop()
    }

    @MainActor func testMochiFinishingItsReplyGoesBackToListeningWithoutAnInterruption() async throws {
        let listening = FakeListening()
        let (app, routed, _) = interruptibleApp(listening)
        await untilMochiSpeaks(app, listening)
        let starts = listening.captureStarts
        listening.feed(audio(1))
        listening.routedFinish?(routed, true)
        await waitUntil { app.listening.phase == .listening }
        XCTAssertEqual(listening.captureStarts, starts, "The microphone stays open from Mochi's speech into listening")
        XCTAssertEqual(
            app.conversation?.messages.last?.text, "Tell me more about your weekend in the mountains.",
            "A reply heard to the end is kept whole")
        app.stop()
    }

    @MainActor func testStartingWhileMochiIsBusyKeepsTheMicrophoneClosed() async throws {
        let listening = FakeListening()
        let app = handsFreeApp(listening)
        let player = TestPlayer()
        app.audio.makePlayer = { _ in player }
        let greeting = app.store.root.appendingPathComponent("earlier.wav")
        try PCM.wav(Data(repeating: 0, count: 4800), rate: PCM.sampleRate).write(to: greeting)
        app.play("earlier.wav")
        XCTAssertEqual(app.turn.activity, .playing)
        app.toggleListening()
        await waitUntil { app.listening.isOn }
        XCTAssertEqual(app.listening.phase, .mochiSpeaking)
        XCTAssertFalse(listening.capturing, "Nothing is heard over Mochi's own playback")
        app.audio.finishPlayback(player, successfully: true)
        await waitUntil { app.listening.phase == .listening && listening.capturing }
        // Resuming from a pause while something plays waits for it too.
        app.showExpressions = true
        await waitUntil { app.listening.phase == .paused }
        app.play("earlier.wav")
        app.showExpressions = false
        await waitUntil { app.listening.pauses.isEmpty }
        XCTAssertNotEqual(app.listening.phase, .listening)
        XCTAssertFalse(listening.capturing)
        app.stop()
    }

    @MainActor func testStartingWhileAReplyIsGeneratedKeepsTheMicrophoneClosed() async throws {
        let listening = FakeListening()
        let app = handsFreeApp(listening)
        let gate = TestGate()
        app.speech.conversationReply = { _, _, _ in await gate.wait() }
        app.draft = "Hello"
        app.send()
        await waitUntil { app.turn.activity == .generating }
        app.toggleListening()
        await waitUntil { app.listening.isOn }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNotEqual(app.listening.phase, .listening)
        XCTAssertFalse(listening.capturing, "Nothing is heard while Mochi is working on a reply")
        await gate.release()
        app.stop()
    }

    @MainActor func testStartingDuringAPressToSendRecordingKeepsTheMicrophoneClosed() async throws {
        let listening = FakeListening()
        let app = handsFreeApp(listening)
        app.settings.talkingMode = .pressToSend
        app.media.record = { _ in }
        app.toggleConversationVoice()
        await waitUntil { app.turn.activity == .recording }
        app.toggleListening()
        await waitUntil { app.listening.isOn }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNotEqual(app.listening.phase, .listening)
        XCTAssertFalse(listening.capturing, "The recording keeps the microphone; listening does not open it again")
        app.stop()
    }

    @MainActor func testChoosingPressToSendCancelsAStartWaitingForPermission() async throws {
        let listening = FakeListening()
        let app = handsFreeApp(listening)
        let gate = TestGate()
        app.media.permission = {
            await gate.wait()
            return true
        }
        app.toggleConversationVoice()
        XCTAssertNotNil(app.listeningRequest)
        app.settings.talkingMode = .pressToSend
        await waitUntil { app.listeningRequest == nil }
        await gate.release()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(app.listening.phase, .off)
        XCTAssertFalse(listening.capturing)
        app.stop()
    }

    @MainActor func testAHiddenWorkspaceKeepsListeningPausedEvenWhenStarted() async throws {
        let listening = FakeListening()
        let app = handsFreeApp(listening)
        app.workspaceHidden = true
        app.toggleConversationVoice()
        await waitUntil { app.listening.isOn }
        XCTAssertEqual(app.listening.phase, .paused)
        XCTAssertFalse(listening.capturing)
        app.workspaceHidden = false
        app.refreshListeningConditions()
        XCTAssertEqual(app.listening.phase, .listening)
        app.stop()
    }

    @MainActor func testASecondToggleCancelsAStartWaitingForPermission() async throws {
        let listening = FakeListening()
        let app = handsFreeApp(listening)
        let gate = TestGate()
        app.media.permission = {
            await gate.wait()
            return true
        }
        app.toggleConversationVoice()
        XCTAssertEqual(app.microphoneLabel, "Stop Listening", "A pending start shows as on")
        app.toggleConversationVoice()
        await gate.release()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(app.listening.phase, .off, "The cancelled start never opens the microphone")
        XCTAssertFalse(listening.capturing)
        app.stop()
    }

    @MainActor func testChoosingPressToSendEndsListeningHoweverItStarted() async throws {
        let listening = FakeListening()
        let app = handsFreeApp(listening)
        app.settings.talkingMode = .pressToSend
        app.toggleListening()  // the Listen shortcut works in press to send too
        await waitUntil { app.listening.phase == .listening && listening.capturing }
        app.settings.talkingMode = .handsFree
        app.settings.talkingMode = .pressToSend
        XCTAssertEqual(app.listening.phase, .off, "Stopped at once, before any observer runs")
        XCTAssertFalse(listening.capturing)
        app.stop()
    }

    @MainActor func testAudioArrivingAfterASheetOpensIsNeverHeard() async throws {
        let listening = FakeListening()
        let app = handsFreeApp(listening)
        let line = await startedLine(app, listening)
        let deliver = try XCTUnwrap(listening.deliver)
        app.history.managerOpen = true
        // No yield: the observer has not run, but the piece already queued arrives.
        deliver(audio(0.5))
        deliver(audio(1, decibels: -20))
        XCTAssertTrue(line.sent.isEmpty)
        XCTAssertEqual(app.listening.phase, .paused)
        app.stop()
    }

    @MainActor func testEndingOnePauseNeverOpensTheMicrophoneBehindAnotherArrivingWithIt() async throws {
        let listening = FakeListening()
        let app = handsFreeApp(listening)
        _ = await startedLine(app, listening)
        app.screenLocked = true
        app.refreshListeningConditions()
        XCTAssertFalse(listening.capturing)
        let starts = listening.captureStarts
        app.screenLocked = false
        app.history.managerOpen = true
        app.refreshListeningConditions()
        XCTAssertEqual(listening.captureStarts, starts, "Unlocking under a sheet that just opened keeps it closed")
        XCTAssertEqual(app.listening.pauses, [.sheetOpen])
        app.stop()
    }

    /// Deleting a message is not a reason to stop listening.
    @MainActor func testDeletingAMessageKeepsListening() async throws {
        let listening = FakeListening()
        let app = handsFreeApp(listening)
        let id = try XCTUnwrap(app.selectedID)
        let message = Message(role: "user", text: "Delete me")
        app.append(message, to: id)
        _ = await startedLine(app, listening)
        app.deleteMessage(message.id)
        XCTAssertTrue(app.listening.isOn)
        XCTAssertTrue(app.settings.talkingMode == .handsFree && app.handsFree)
        XCTAssertTrue(listening.capturing)
        app.notice = nil
        app.stop()
    }

    /// Correcting a transcript is a sheet like any other: what the learner says while editing is never a turn.
    @MainActor func testEditingATranscriptPausesListening() async throws {
        let listening = FakeListening()
        let app = handsFreeApp(listening)
        let id = try XCTUnwrap(app.selectedID)
        var voice = Message(role: "user", text: "Misheard", audio: "saved.wav")
        voice.transcriptionState = .completed
        app.append(voice, to: id)
        let line = await startedLine(app, listening)
        let deliver = try XCTUnwrap(listening.deliver)
        app.transcriptEditID = voice.id
        XCTAssertEqual(app.listeningBlockers, [.sheetOpen])
        deliver(audio(0.5))
        deliver(audio(1, decibels: -20))
        XCTAssertTrue(line.sent.isEmpty, "Speech while the transcript sheet is open is never sent")
        await waitUntil { app.listening.pauses == [.sheetOpen] }
        XCTAssertFalse(listening.capturing)
        app.transcriptEditID = nil
        await waitUntil { app.listening.phase == .listening && listening.capturing }
        // Leaving the conversation closes the sheet with it, so it never holds listening paused.
        app.transcriptEditID = voice.id
        app.newChat()
        XCTAssertNil(app.transcriptEditID)
        app.stop()
    }

    @MainActor func testAudioHeardBeforeABlockerIsNotSentWhenTheConnectionOpensLate() async throws {
        let listening = FakeListening()
        let gate = TestGate()
        let services = listening.services
        var slow = services
        slow.openSession = { detection, model in
            await gate.wait()
            return try await services.openSession(detection, model)
        }
        let app = handsFreeApp(listening)
        app.listeningServices = slow
        app.toggleConversationVoice()
        await waitUntil { app.listening.phase == .listening && listening.capturing }
        speak(listening)
        XCTAssertFalse(app.listeningRuntime.unsent.isEmpty)
        app.workspaceHidden = true
        await gate.release()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(listening.lines.allSatisfy { $0.sent.isEmpty }, "Nothing reaches the API once Mochi is hidden")
        XCTAssertEqual(app.listening.phase, .paused)
        app.stop()
    }

    @MainActor func testTalkHandsFreeDuringPlaybackStartsListeningThatWaitsForMochi() async throws {
        let listening = FakeListening()
        let app = handsFreeApp(listening)
        let player = TestPlayer()
        app.audio.makePlayer = { _ in player }
        let earlier = app.store.root.appendingPathComponent("earlier.wav")
        try PCM.wav(Data(repeating: 0, count: 4800), rate: PCM.sampleRate).write(to: earlier)
        app.play("earlier.wav")
        app.shortcutTriggered(.talk, pressed: true)
        await waitUntil { app.listening.isOn }
        XCTAssertTrue(player.playing, "Talk does not pause Mochi hands-free; it starts listening")
        XCTAssertEqual(app.listening.phase, .mochiSpeaking)
        XCTAssertFalse(listening.capturing)
        app.stop()
    }

    @MainActor func testAnOpenPanelPausesListening() async throws {
        let listening = FakeListening()
        let app = handsFreeApp(listening)
        _ = await startedLine(app, listening)
        var phaseDuringPanel: ListeningMachine.Phase?
        var capturingDuringPanel = true
        app.chooseFile = { _ in
            phaseDuringPanel = app.listening.phase
            capturingDuringPanel = listening.capturing
            return nil
        }
        _ = app.presentPanel(.exportBackup)
        XCTAssertEqual(phaseDuringPanel, .paused)
        XCTAssertFalse(capturingDuringPanel)
        XCTAssertEqual(app.listening.phase, .listening, "Listening resumes once the panel closes")
        app.stop()
    }

    @MainActor func testChoosingPressToSendEndsHandsFreeListening() async throws {
        let listening = FakeListening()
        let app = handsFreeApp(listening)
        _ = await startedLine(app, listening)
        app.settings.talkingMode = .pressToSend
        await waitUntil { app.listening.phase == .off }
        XCTAssertFalse(listening.capturing)
        app.stop()
    }

    @MainActor func testALockedScreenStopsAudioAtOnce() async throws {
        let listening = FakeListening()
        let app = handsFreeApp(listening)
        let line = await startedLine(app, listening)
        app.screenLocked = true
        listening.feed(audio(0.5))
        listening.feed(audio(1, decibels: -20))
        XCTAssertTrue(line.sent.isEmpty, "Audio queued before the pause is not forwarded while locked")
        app.stop()
    }

    // MARK: Pauses

    @MainActor func testExpressionsSheetsAndTheLockPauseAndResume() async throws {
        let listening = FakeListening()
        let app = handsFreeApp(listening)
        _ = await startListening(app, listening)
        app.showExpressions = true
        await waitUntil { app.listening.phase == .paused }
        XCTAssertFalse(listening.capturing)
        app.showExpressions = false
        await waitUntil { app.listening.phase == .listening && listening.capturing }
        app.screenLocked = true
        await waitUntil { app.listening.phase == .paused }
        app.history.managerOpen = true
        app.screenLocked = false
        await waitUntil { app.listening.pauses == [.sheetOpen] }
        XCTAssertEqual(app.listening.phase, .paused)
        app.history.managerOpen = false
        await waitUntil { app.listening.phase == .listening && listening.capturing }
        app.workspaceHidden = true
        await waitUntil { app.listening.phase == .paused }
        app.workspaceHidden = false
        await waitUntil { app.listening.phase == .listening }
        app.stop()
    }

    @MainActor func testSwitchingConversationPausesUntilStartedAgain() async throws {
        let listening = FakeListening()
        let app = handsFreeApp(listening)
        let first = try XCTUnwrap(app.selectedID)
        _ = await startListening(app, listening)
        speak(listening)
        XCTAssertEqual(app.listening.phase, .hearingSpeech)
        app.selectedID = try XCTUnwrap(app.library.conversations.first { $0.id != first && !$0.archived }?.id)
        await waitUntil { app.listening.phase == .paused }
        XCTAssertEqual(app.listening.pauses, [.conversationSwitched])
        XCTAssertFalse(listening.capturing)
        XCTAssertTrue(app.library.conversations.first(where: { $0.id == first })?.messages.isEmpty == true)
        XCTAssertEqual(app.microphoneLabel, "Start Listening")
        if let index = app.library.conversations.firstIndex(where: { $0.id == app.selectedID }) {
            app.library.conversations[index].voiceIntroduced = true
        }
        app.toggleConversationVoice()
        await waitUntil { app.listening.phase == .listening && listening.capturing }
        XCTAssertEqual(app.listeningRuntime.context, .conversation(try XCTUnwrap(app.selectedID)))
        app.stop()
    }

    @MainActor func testStopEndsListening() async throws {
        let listening = FakeListening()
        let app = handsFreeApp(listening)
        _ = await startListening(app, listening)
        speak(listening)
        app.stop()
        XCTAssertEqual(app.listening.phase, .off)
        XCTAssertFalse(listening.capturing)
        XCTAssertTrue(listening.lines.allSatisfy(\.closed))
        XCTAssertTrue(app.conversation?.messages.isEmpty == true)
    }

    // MARK: Practice

    @MainActor func testPracticeAttemptsAreJudgedOnTheMacAndStayThere() async throws {
        let listening = FakeListening()
        let app = makeApp(demo: true, listeningServices: listening.services)
        app.settings.talkingMode = .handsFree
        app.media.permission = { true }
        // The preview opens on the practice sheet with a sentence to practise.
        XCTAssertTrue(app.practice)
        XCTAssertEqual(app.help.stage, .practice)
        let attempts = app.help.expression?.attempts.count ?? 0
        app.toggleRecord()
        await waitUntil { app.listening.phase == .listening && listening.capturing }
        XCTAssertTrue(listening.detections.isEmpty, "Practice audio never goes to the API")
        listening.feed(audio(0.5))
        listening.feed(audio(1.2, decibels: -25))
        XCTAssertEqual(app.listening.phase, .hearingSpeech)
        listening.feed(audio(1))
        XCTAssertEqual(app.listening.phase, .hearingSpeech, "A pause shorter than the end silence keeps the turn")
        listening.feed(audio(0.3))
        await waitUntil { (app.help.expression?.attempts.count ?? 0) == attempts + 1 && !app.busy }
        await waitUntil { app.listening.phase == .listening && listening.capturing }
        XCTAssertEqual(app.listening.phase, .listening, "Listening goes on for the next attempt")
        XCTAssertTrue(listening.detections.isEmpty)
        // A short knock is not an attempt.
        listening.feed(audio(0.25, decibels: -20))
        listening.feed(audio(1.5))
        XCTAssertEqual(app.help.expression?.attempts.count, attempts + 1)
        XCTAssertEqual(app.listening.phase, .listening)
        app.stop()
    }

    @MainActor func testAPracticeAttemptAfterEditingTheSentenceIsKept() async throws {
        let listening = FakeListening()
        let app = makeApp(demo: true, listeningServices: listening.services)
        app.settings.talkingMode = .handsFree
        app.media.permission = { true }
        app.toggleRecord()
        await waitUntil { app.listening.phase == .listening && listening.capturing }
        app.editEnglish("A brand new sentence.")
        XCTAssertNil(app.help.expression, "Editing drops the old sentence's expression")
        await waitUntil { app.listening.phase == .listening && listening.capturing }
        listening.feed(audio(0.5))
        listening.feed(audio(1.2, decibels: -25))
        listening.feed(audio(1.3))
        await waitUntil { app.help.expression?.attempts.count == 1 && !app.busy }
        XCTAssertEqual(app.help.expression?.english, "A brand new sentence.")
        app.stop()
    }

    @MainActor func testAPracticeAttemptStartingWithTheStreamIsNotMistakenForNoise() async throws {
        let listening = FakeListening()
        let app = makeApp(demo: true, listeningServices: listening.services)
        app.settings.talkingMode = .handsFree
        app.media.permission = { true }
        app.toggleRecord()
        await waitUntil { app.listening.phase == .listening && listening.capturing }
        // Speech from the first sample: no pre-roll exists to subtract.
        listening.feed(audio(0.45, decibels: -25))
        listening.feed(audio(1.3))
        await waitUntil { app.help.expression?.attempts.count == 1 && !app.busy }
        app.stop()
    }

    @MainActor func testEditingTheSentenceDuringAnAttemptDropsThatAttempt() async throws {
        let listening = FakeListening()
        let app = makeApp(demo: true, listeningServices: listening.services)
        app.settings.talkingMode = .handsFree
        app.media.permission = { true }
        app.toggleRecord()
        await waitUntil { app.listening.phase == .listening && listening.capturing }
        listening.feed(audio(0.5))
        listening.feed(audio(1.2, decibels: -25))
        app.editEnglish("A different sentence.")
        listening.feed(audio(1.3))
        // Whatever the turn led to has finished once listening is back and nothing is busy.
        await waitUntil { app.listening.phase == .listening && !app.busy }
        try await Task.sleep(nanoseconds: 200_000_000)
        await waitUntil { !app.busy }
        XCTAssertEqual(app.help.expression?.attempts.count ?? 0, 0, "Not scored against the new sentence")
        app.stop()
    }

    @MainActor func testClearingThePracticeSentencePausesListening() async throws {
        let listening = FakeListening()
        let app = makeApp(demo: true, listeningServices: listening.services)
        app.settings.talkingMode = .handsFree
        app.media.permission = { true }
        app.toggleRecord()
        await waitUntil { app.listening.phase == .listening && listening.capturing }
        app.editEnglish("")
        listening.feed(audio(0.5))
        XCTAssertEqual(app.listening.phase, .paused, "No turn has anywhere to go")
        XCTAssertFalse(listening.capturing)
        app.stop()
    }

    // MARK: Shortcuts and press to send

    @MainActor func testTalkStartsListeningHandsFreeAndListenToggles() async throws {
        let listening = FakeListening()
        let app = handsFreeApp(listening)
        app.shortcutTriggered(.talk, pressed: true)
        app.shortcutTriggered(.talk, pressed: false)
        await waitUntil { app.listening.phase == .listening }
        app.shortcutTriggered(.talk, pressed: true)
        XCTAssertEqual(app.listening.phase, .listening, "Talk only starts listening")
        app.shortcutTriggered(.listen, pressed: true)
        XCTAssertEqual(app.listening.phase, .off)
        XCTAssertFalse(listening.capturing)
        app.shortcutTriggered(.listen, pressed: true)
        await waitUntil { app.listening.phase == .listening }
        app.stop()
    }

    @MainActor func testStartListeningWorksInPressToSendAndTheButtonStopsIt() async throws {
        let listening = FakeListening()
        let app = handsFreeApp(listening)
        app.settings.talkingMode = .pressToSend
        XCTAssertEqual(app.microphoneLabel, "Record Voice Message")
        app.toggleListening()
        await waitUntil { app.listening.phase == .listening }
        XCTAssertEqual(app.microphoneLabel, "Stop Listening")
        app.toggleConversationVoice()
        XCTAssertEqual(app.listening.phase, .off)
        app.stop()
    }

    @MainActor func testAnInterruptedGreetingKeepsOnlyWhatWasHeard() async throws {
        let listening = FakeListening()
        let app = handsFreeApp(listening)
        if let index = app.library.conversations.firstIndex(where: { $0.id == app.selectedID }) {
            app.library.conversations[index].voiceIntroduced = false
        }
        let greeting = app.store.root.appendingPathComponent("greeting.wav")
        try PCM.wav(Data(repeating: 0, count: 4800), rate: PCM.sampleRate).write(to: greeting)
        app.speech.referenceAudio = { _, _, _, _, _ in greeting }
        let routed = TestPlayer()
        listening.routedPlayer = routed
        app.toggleConversationVoice()
        await waitUntil {
            app.listening.phase == .mochiSpeaking && listening.capturing && app.listeningRuntime.line != nil
        }
        let said = try XCTUnwrap(app.conversation?.messages.last { $0.role == "assistant" }?.text)
        routed.currentTime = 1  // of 5 seconds
        speak(listening)
        XCTAssertFalse(routed.playing)
        let kept = try XCTUnwrap(app.conversation?.messages.last { $0.role == "assistant" }?.text)
        XCTAssertTrue(kept.hasSuffix("…"), kept)
        XCTAssertLessThan(kept.count, said.count, "Only what was heard of the greeting stays in the conversation")
        app.stop()
    }

    @MainActor func testSeekingInAReplyLeavesItWhole() async throws {
        let listening = FakeListening()
        let (app, routed, _) = interruptibleApp(listening)
        await untilMochiSpeaks(app, listening)
        let file = try XCTUnwrap(app.playbackFile)
        routed.currentTime = 4
        app.seekPlayback(file, to: 1, mochi: true)
        speak(listening)
        XCTAssertFalse(routed.playing)
        XCTAssertEqual(
            app.conversation?.messages.last { $0.role == "assistant" }?.text,
            "Tell me more about your weekend in the mountains.",
            "After a seek the position says nothing of what was heard")
        app.stop()
    }

    @MainActor func testAReplyArrivingJustAfterASheetOpensKeepsTheEngineOff() async throws {
        let listening = FakeListening()
        let (app, _, _) = interruptibleApp(listening)
        let ordinary = TestPlayer()
        app.audio.makePlayer = { _ in ordinary }
        app.speech.conversationReply = { _, _, callbacks in
            app.history.managerOpen = true  // no observer has run when the reply plays
            var reply = RealtimeAccumulator()
            reply.text = "Hello."
            reply.audio = Data(repeating: 1, count: 4800)
            reply.done = true
            try callbacks.response(reply)
        }
        let line = await startedLine(app, listening)
        speak(listening)
        line.emit(.speechStarted(audioMilliseconds: 300))
        await waitUntil { app.listeningRuntime.apiHeardSpeech }
        line.emit(.speechStopped(audioMilliseconds: 1300))
        await waitUntil { app.turn.activity == .playing }
        XCTAssertTrue(listening.routedURLs.isEmpty, "Played the ordinary way behind the sheet")
        XCTAssertTrue(ordinary.playing)
        XCTAssertFalse(listening.capturing)
        app.stop()
    }

    @MainActor func testHandsFreeGreetingPlaysThenListens() async throws {
        let listening = FakeListening()
        let app = handsFreeApp(listening)
        if let index = app.library.conversations.firstIndex(where: { $0.id == app.selectedID }) {
            app.library.conversations[index].voiceIntroduced = false
        }
        let greeting = app.store.root.appendingPathComponent("greeting.wav")
        try PCM.wav(Data(repeating: 0, count: 4800), rate: PCM.sampleRate).write(to: greeting)
        app.speech.referenceAudio = { _, _, _, _, _ in greeting }
        let player = TestPlayer()
        app.audio.makePlayer = { _ in player }
        app.toggleConversationVoice()
        await waitUntil { app.turn.activity == .playing }
        XCTAssertEqual(app.listening.phase, .mochiSpeaking)
        XCTAssertFalse(listening.capturing)
        app.audio.finishPlayback(player, successfully: true)
        await waitUntil { app.listening.phase == .listening }
        XCTAssertFalse(app.greetingActive)
        XCTAssertEqual(app.turn.activity, .idle, "No press to send recording starts after the greeting")
        await waitUntil { listening.capturing }
        app.stop()
    }

    @MainActor func testPressToSendCanStartListeningAfterAReply() async throws {
        for enabled in [false, true] {
            let app = makeApp(demo: true)
            app.resume()
            app.newChat()
            app.settings.listenAfterReply = enabled
            let player = TestPlayer()
            app.audio.makePlayer = { _ in player }
            app.speech.conversationReply = { _, _, callbacks in
                var reply = RealtimeAccumulator()
                reply.text = "Hello."
                reply.audio = Data(repeating: 1, count: 4800)
                reply.done = true
                try callbacks.response(reply)
            }
            var asked = false
            app.media.permission = {
                asked = true
                return false
            }
            app.draft = "Hi"
            app.send()
            await waitUntil { app.turn.activity == .playing }
            app.audio.finishPlayback(player, successfully: true)
            if enabled {
                await waitUntil { asked }
                // Never unattended: a locked screen at the end of the reply keeps the microphone closed.
                asked = false
                app.screenLocked = true
                app.draft = "Again"
                app.send()
                await waitUntil { app.turn.activity == .playing }
                app.audio.finishPlayback(player, successfully: true)
                try await Task.sleep(nanoseconds: 50_000_000)
                XCTAssertFalse(asked, "No recording starts while the screen is locked")
                // Nor when the screen locks while permission is being asked for.
                app.screenLocked = false
                let gate = TestGate()
                var recorded = false
                app.media.record = { _ in recorded = true }
                app.media.permission = {
                    await gate.wait()
                    return true
                }
                app.draft = "Once more"
                app.send()
                await waitUntil { app.turn.activity == .playing }
                app.audio.finishPlayback(player, successfully: true)
                await waitUntil { app.turn.activity == .requestingPermission }
                app.screenLocked = true
                await gate.release()
                await waitUntil { app.turn.activity == .idle }
                XCTAssertFalse(recorded, "A lock during the permission request keeps the microphone closed")
                // Nor when the learner turns the setting off while permission is being asked for.
                app.screenLocked = false
                let second = TestGate()
                app.media.permission = {
                    await second.wait()
                    return true
                }
                app.draft = "One more"
                app.send()
                await waitUntil { app.turn.activity == .playing }
                app.audio.finishPlayback(player, successfully: true)
                await waitUntil { app.turn.activity == .requestingPermission }
                app.settings.listenAfterReply = false
                await second.release()
                await waitUntil { app.turn.activity == .idle }
                XCTAssertFalse(recorded, "Turning the setting off during the permission request keeps it closed")
                app.settings.listenAfterReply = true
                // Nor sent when it finishes just after a sheet opened, before any observer has run. The take is a
                // real one-second recording, so without the guard it would be sent.
                app.media.permission = { true }
                var take: URL?
                app.media.record = { url in
                    try PCM.wav(Data(repeating: 0, count: 48000), rate: PCM.sampleRate).write(to: url)
                    take = url
                }
                app.media.stopRecording = { take }
                var replies = 0
                let reply = app.speech.conversationReply
                app.speech.conversationReply = { service, request, callbacks in
                    replies += 1
                    try await reply(service, request, callbacks)
                }
                app.draft = "Last one"
                app.send()
                await waitUntil { app.turn.activity == .playing }
                app.audio.finishPlayback(player, successfully: true)
                await waitUntil { app.turn.activity == .recording }
                let sentBefore = replies
                app.history.managerOpen = true
                app.finishRecording()
                try await Task.sleep(nanoseconds: 50_000_000)
                XCTAssertEqual(replies, sentBefore, "The unattended take is discarded, not sent")
                XCTAssertEqual(app.turn.activity, .idle)
                app.history.managerOpen = false
                // Nor when Mochi is hidden after the recording started by itself: it is discarded, not sent.
                app.screenLocked = false
                app.media.permission = { true }
                app.draft = "And again"
                app.send()
                await waitUntil { app.turn.activity == .playing }
                app.audio.finishPlayback(player, successfully: true)
                await waitUntil { app.turn.activity == .recording }
                let messages = app.conversation?.messages.count
                app.workspaceHidden = true
                app.refreshListeningConditions()
                XCTAssertEqual(app.turn.activity, .idle, "The unattended recording stops when Mochi is hidden")
                XCTAssertEqual(app.conversation?.messages.count, messages, "Nothing is sent")
            } else {
                try await Task.sleep(nanoseconds: 50_000_000)
                XCTAssertFalse(asked, "Off by default: press to send stays as it is")
            }
        }
    }

    @MainActor func testListenAndSendNowShortcutDefaults() {
        XCTAssertEqual(
            ShortcutAction.listen.defaultShortcut,
            Shortcut(keyCode: UInt16(kVK_ANSI_E), modifiers: [.control, .option, .command]))
        XCTAssertEqual(
            ShortcutAction.sendNow.defaultShortcut,
            Shortcut(keyCode: UInt16(kVK_Return), modifiers: [.option, .command]))
        XCTAssertTrue(ShortcutAction.listen.isGlobal)
        XCTAssertFalse(ShortcutAction.sendNow.isGlobal, "Send Now never fires from another app")
        XCTAssertEqual(ShortcutAction.sendNow.defaultShortcut.keyEquivalent, .return)
        XCTAssertEqual(ShortcutAction.sendNow.defaultShortcut.eventModifiers, [.option, .command])
        // Function keys have no character, but menus still take them.
        let f5 = Shortcut(keyCode: UInt16(kVK_F5), modifiers: [.option, .command])
        XCTAssertEqual(f5.keyEquivalent, KeyEquivalent(Character(UnicodeScalar(NSF5FunctionKey)!)))
        // Existing global shortcuts keep their hot key ids.
        XCTAssertEqual(ShortcutCenter.id(for: .talk), 1)
        XCTAssertEqual(ShortcutCenter.id(for: .togglePet), 2)
    }
}

final class HandsFreeVisibleStateTests: XCTestCase {
    func testDesktopMochiListensWhileTheMicrophoneIsOpen() {
        var situation = PetSituation()
        XCTAssertEqual(situation.pose, .idle)
        situation.listening = true
        XCTAssertEqual(situation.pose, .review, "She shows the listening pose, as while recording")
        situation.activity = .playing
        situation.speaking = true
        XCTAssertEqual(situation.pose, .jumping, "Speaking wins over listening")
    }

    @MainActor func testTheMenuBarIconShowsListening() throws {
        let tray = TrayController()
        tray.install()
        defer { tray.statusItem.map { NSStatusBar.system.removeStatusItem($0) } }
        let button = try XCTUnwrap(tray.statusItem?.button)
        XCTAssertFalse(button.image === TrayController.listeningIcon)
        tray.showListening(true)
        XCTAssertTrue(button.image === TrayController.listeningIcon)
        XCTAssertTrue(TrayController.listeningIcon.isTemplate)
        XCTAssertEqual(button.accessibilityLabel(), "Mochi · listening")
        tray.showListening(false)
        XCTAssertFalse(button.image === TrayController.listeningIcon)
        XCTAssertEqual(button.accessibilityLabel(), "Mochi")
    }

    @MainActor func testTheMicrophoneButtonNamesEachPhase() async throws {
        let listening = FakeListening()
        let app = makeApp(demo: true, listeningServices: listening.services)
        app.resume()
        app.newChat()
        XCTAssertNil(app.listeningSymbol, "Press to send keeps its own symbol")
        var expected: [ListeningMachine.Phase: String] = [:]
        var machine = ListeningMachine()
        let now = Date()
        machine.handle(.start(now: now, blockers: []))
        expected[machine.phase] = "ear"
        machine.handle(.speechStarted)
        expected[machine.phase] = "waveform"
        machine.handle(.endOfTurn)
        expected[machine.phase] = "ellipsis.bubble"
        machine.handle(.replyStarted)
        expected[machine.phase] = "ellipsis.bubble"
        machine.handle(.replyEnded)
        expected[machine.phase] = "speaker.wave.2"
        for (phase, symbol) in expected {
            var replay = ListeningMachine()
            replay.handle(.start(now: now, blockers: []))
            for event: ListeningMachine.Event in [.speechStarted, .endOfTurn, .replyStarted, .replyEnded]
            where replay.phase != phase {
                replay.handle(event)
            }
            app.listening = replay
            XCTAssertEqual(app.listeningSymbol, symbol, "\(phase)")
        }
        app.listening = ListeningMachine()
    }

    @MainActor func testThoughtsStayPressToSendWhileListeningIsOn() async throws {
        let listening = FakeListening()
        let app = makeApp(demo: true, listeningServices: listening.services)
        app.resume()
        app.newChat()
        if let index = app.library.conversations.firstIndex(where: { $0.id == app.selectedID }) {
            app.library.conversations[index].voiceIntroduced = true
            app.library.conversations[index].preferences.language = .japanese
        }
        app.settings.talkingMode = .handsFree
        app.media.permission = { true }
        app.toggleConversationVoice()
        await waitUntil { app.listening.phase == .listening && listening.capturing }
        app.startHelp()
        await waitUntil { app.listening.phase == .paused }
        XCTAssertFalse(listening.capturing, "Listening pauses while a thought is worked on")
        var recorded: URL?
        app.media.record = { recorded = $0 }
        app.media.stopRecording = { recorded }
        app.recordMeaning()
        await waitUntil { app.turn.activity == .recording }
        XCTAssertNotNil(recorded, "The thought is recorded with a press, not by listening")
        XCTAssertFalse(listening.capturing)
        app.stop()
    }
}
