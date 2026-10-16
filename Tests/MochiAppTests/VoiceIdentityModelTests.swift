import MochiCore
import MochiKernel
import MochiTestSupport
import PCM16
import XCTest

@testable import MochiApp

private final class GreetingPlayer: PlaybackPlayer {
    var duration: TimeInterval = 5
    var currentTime: TimeInterval = 0
    var enableRate = false
    var rate: Float = 1
    var succeeds = true
    func play() -> Bool { succeeds }
    func pause() {}
    func stop() {}
}

final class VoiceIdentityModelTests: XCTestCase {
    @MainActor private func app() -> AppModel {
        let app = makeApp(demo: true)
        app.resume()
        let chat = Conversation()
        app.library.conversations = [chat]
        app.select(chat.id)
        app.media.permission = { true }
        app.media.record = { _ in }
        app.speech.referenceAudio = { _, _, _, root, _ in root.appendingPathComponent("greeting.wav") }
        return app
    }
    @MainActor func testGreetingSavesThenListensAndNeverRepeatsOrListensOnReplay() async {
        let app = app()
        let player = GreetingPlayer()
        app.audio.makePlayer = { _ in player }
        var renderCount = 0
        var recordCount = 0
        app.speech.referenceAudio = { text, _, service, root, _ in
            renderCount += 1
            XCTAssertTrue(VoiceIdentity.greetings.contains(text))
            XCTAssertEqual(service.voice, app.settings.conversationVoice)
            return root.appendingPathComponent("greeting.wav")
        }
        app.media.record = { _ in recordCount += 1 }
        XCTAssertEqual(app.microphoneLabel, "Start Voice Conversation")
        app.toggleConversationVoice()
        await waitUntil { app.turn.activity == .playing }
        XCTAssertEqual(app.conversation?.messages.count, 1)
        XCTAssertTrue(app.conversation?.voiceIntroduced == true)
        XCTAssertEqual(app.conversation?.messages.first?.role, "assistant")
        XCTAssertEqual(recordCount, 0)
        app.togglePlayback("greeting.wav")
        XCTAssertTrue(app.audio.paused)
        app.togglePlayback("greeting.wav")
        XCTAssertFalse(app.audio.paused)
        app.audio.finishPlayback(player, successfully: true)
        await waitUntil { app.turn.activity == .recording }
        XCTAssertEqual(recordCount, 1)
        app.stop()
        app.toggleConversationVoice()
        await waitUntil { app.turn.activity == .recording }
        XCTAssertEqual(renderCount, 1)
        XCTAssertEqual(recordCount, 2)
        app.stop()
        app.play("greeting.wav", mochi: true)
        app.audio.finishPlayback(player, successfully: true)
        await Task.yield()
        XCTAssertEqual(recordCount, 2)
        XCTAssertEqual(app.turn.activity, .idle)
        app.append(Message(role: "user", text: "The first real thought"), to: app.selectedID!)
        XCTAssertEqual(app.conversation?.title, "The first real thought")
        app.stop()
    }
    @MainActor func testPermissionDenialAndRenderFailureLeaveMicrophoneOff() async {
        let app = app()
        var renders = 0
        var records = 0
        app.media.record = { _ in records += 1 }
        app.speech.referenceAudio = { _, _, _, _, _ in
            renders += 1
            throw AppFailure("Greeting failed")
        }
        app.media.permission = { false }
        app.toggleConversationVoice()
        await waitUntil { app.turn.activity == .idle }
        XCTAssertEqual(renders, 0)
        XCTAssertEqual(records, 0)
        XCTAssertNotNil(app.error)
        XCTAssertFalse(app.greetingActive)
        app.media.permission = { true }
        app.toggleConversationVoice()
        await waitUntil { app.turn.activity == .idle }
        XCTAssertEqual(renders, 1)
        XCTAssertEqual(records, 0)
        XCTAssertFalse(app.conversation?.voiceIntroduced == true)
        XCTAssertTrue(app.conversation?.messages.isEmpty == true)
        app.stop()
    }
    @MainActor func testSkipDuringGenerationIgnoresLateResult() async {
        let app = app()
        let gate = TestGate()
        var records = 0
        app.speech.referenceAudio = { _, _, _, root, _ in
            await gate.wait()
            return root.appendingPathComponent("late.wav")
        }
        app.media.record = { _ in records += 1 }
        app.toggleConversationVoice()
        await waitUntil { app.turn.activity == .generating }
        let greeting = app.currentTask
        app.toggleConversationVoice()
        await waitUntil { app.turn.activity == .recording }
        await gate.release()
        await greeting?.value
        XCTAssertEqual(records, 1)
        XCTAssertTrue(app.conversation?.messages.isEmpty == true)
        XCTAssertTrue(app.conversation?.voiceIntroduced == true)
        app.stop()
    }
    @MainActor func testStopNavigationPracticeAndReplacementCancelAutomaticMicrophone() async {
        for action in 0..<4 {
            let app = app()
            let player = GreetingPlayer()
            var records = 0
            app.audio.makePlayer = { _ in player }
            app.media.record = { _ in records += 1 }
            app.toggleConversationVoice()
            await waitUntil { app.turn.activity == .playing }
            switch action {
            case 0: app.stop()
            case 1:
                let next = Conversation()
                app.library.conversations.append(next)
                app.select(next.id)
            case 2: app.startHelp()
            default: app.play("other.wav")
            }
            app.audio.finishPlayback(player, successfully: true)
            await app.currentTask?.value
            XCTAssertEqual(records, 0)
            XCTAssertFalse(app.greetingActive)
            app.stop()
        }
    }
    @MainActor func testFailedPlaybackDoesNotListen() async {
        for failsAtStart in [false, true] {
            let app = app()
            let player = GreetingPlayer()
            var records = 0
            player.succeeds = !failsAtStart
            app.audio.makePlayer = { _ in player }
            app.media.record = { _ in records += 1 }
            app.toggleConversationVoice()
            await waitUntil { app.turn.activity == (failsAtStart ? .idle : .playing) }
            if !failsAtStart { app.audio.finishPlayback(player, successfully: false) }
            await app.currentTask?.value
            XCTAssertEqual(records, 0)
            XCTAssertFalse(app.greetingActive)
            XCTAssertNotNil(app.error)
            app.stop()
        }
    }
    @MainActor func testStopWhilePermissionOrRenderingPendingNeverStartsAudioOrRecording() async {
        for waitingForPermission in [true, false] {
            let app = app()
            let gate = TestGate()
            var renders = 0
            var records = 0
            app.media.permission = {
                if waitingForPermission { await gate.wait() }
                return true
            }
            app.speech.referenceAudio = { _, _, _, root, _ in
                renders += 1
                if !waitingForPermission { await gate.wait() }
                return root.appendingPathComponent("late.wav")
            }
            app.media.record = { _ in records += 1 }
            app.toggleConversationVoice()
            await waitUntil { waitingForPermission ? app.turn.activity == .requestingPermission : renders == 1 }
            let pending = app.currentTask
            app.stop()
            await gate.release()
            await pending?.value
            XCTAssertEqual(renders, waitingForPermission ? 0 : 1)
            XCTAssertEqual(records, 0)
            XCTAssertNil(app.playbackFile)
            XCTAssertTrue(app.conversation?.messages.isEmpty == true)
            XCTAssertFalse(app.greetingActive)
        }
    }
    @MainActor func testIntroductionAndRecentGreetingsSurviveRelaunch() async throws {
        let root = TestScratch.folder()
        let suite = "mochi-greeting-persistence-\(UUID())"
        let prefs = TestScratch.preferences(named: suite)
        defer {
            try? FileManager.default.removeItem(at: root)
            prefs.removePersistentDomain(forName: suite)
        }
        let app = makeApp(root: root, preferences: prefs)
        app.media.permission = { true }
        app.speech.referenceAudio = { _, _, _, root, _ in
            let url = root.appendingPathComponent("greeting.wav")
            try PCM.wav(Data(repeating: 0, count: 24000), rate: PCM.sampleRate).write(to: url)
            return url
        }
        app.audio.makePlayer = { _ in GreetingPlayer() }
        var greetings: [String] = []
        for _ in 0..<4 {
            app.newChat()
            app.toggleConversationVoice()
            await waitUntil { app.turn.activity == .playing }
            let text = try XCTUnwrap(app.conversation?.messages.first?.text)
            XCTAssertFalse(greetings.suffix(3).contains(text))
            greetings.append(text)
            app.stop()
        }
        let reopened = makeApp(root: root, preferences: prefs)
        XCTAssertEqual(reopened.selectedID, app.selectedID)
        XCTAssertTrue(reopened.conversation?.voiceIntroduced == true)
        XCTAssertEqual(
            prefs.stringArray(forKey: "voiceGreetingHistory"),
            Array(greetings.suffix(3)).map { $0.replacingOccurrences(of: "Mochi", with: "{name}") })
        var rendered = false
        reopened.speech.referenceAudio = { _, _, _, root, _ in
            rendered = true
            return root.appendingPathComponent("unexpected.wav")
        }
        reopened.media.permission = { true }
        reopened.media.record = { _ in }
        reopened.toggleConversationVoice()
        await waitUntil { reopened.turn.activity == .recording }
        XCTAssertFalse(rendered)
        reopened.stop()
    }
    /// The greeting name is captured before the permission wait and survives a rename.
    @MainActor func testGreetingUsesNameCapturedBeforePermissionAfterRename() async throws {
        let app = app()
        let gate = TestGate()
        let id = try XCTUnwrap(app.selectedID)
        XCTAssertTrue(
            app.setConversationInstructions(
                id, instructions: "", preferences: ConversationPreferences(), characterName: "Loki"))
        var rendered: String?
        app.media.permission = {
            await gate.wait()
            return true
        }
        app.speech.referenceAudio = { text, _, _, root, _ in
            rendered = text
            return root.appendingPathComponent("greeting.wav")
        }
        app.audio.makePlayer = { _ in GreetingPlayer() }
        app.toggleConversationVoice()
        await waitUntil { app.turn.activity == .requestingPermission }
        let index = try XCTUnwrap(app.library.conversations.firstIndex(where: { $0.id == id }))
        app.library.conversations[index].characterName = "Sam"
        await gate.release()
        await waitUntil { app.conversation?.messages.first != nil }
        let greeting = try XCTUnwrap(app.conversation?.messages.first)
        XCTAssertEqual(greeting.speakerName, "Loki")
        XCTAssertEqual(rendered, greeting.text)
        XCTAssertTrue(greeting.text.contains("Loki"))
        XCTAssertFalse(greeting.text.contains("Mochi"))
        app.stop()
    }
}

extension VoiceIdentityModelTests {
    @MainActor func testGreetingUsesTheConversationSpeechSpeed() async throws {
        let app = makeApp(root: makeTemporaryFolder())
        let id = try XCTUnwrap(app.selectedID)
        let index = try XCTUnwrap(app.library.conversations.firstIndex { $0.id == id })
        app.library.conversations[index].preferences.speed = 0.8
        app.media.permission = { true }
        var speed: Double?
        app.speech.referenceAudio = { _, _, service, _, _ in
            speed = service.options.speed
            throw AppFailure("Stop after capturing the service.")
        }
        app.toggleConversationVoice()
        await waitUntil { speed != nil && !app.busy }
        XCTAssertEqual(speed, 0.8)
    }
}
