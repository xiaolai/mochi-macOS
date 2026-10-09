import XCTest
import MochiCore
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
        let suite = "mochi-greeting-test-\(UUID())"
        let prefs = UserDefaults(suiteName:suite)!
        prefs.removePersistentDomain(forName:suite)
        let app = AppModel(demo:true,preferences:prefs)
        app.resume()
        let chat = Conversation(); app.library.conversations = [chat]; app.select(chat.id)
        app.microphonePermission = { true }; app.recordAudio = { _ in }
        app.renderGreeting = { _,_,root in root.appendingPathComponent("greeting.wav") }
        return app
    }
    @MainActor private func wait(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline { if predicate() { return }; try? await Task.sleep(nanoseconds:1_000_000) }
        XCTFail("Timed out waiting for voice state",file:file,line:line)
    }
    @MainActor func testGreetingSavesThenListensAndNeverRepeatsOrListensOnReplay() async {
        let app = app(), player = GreetingPlayer()
        app.audio.makePlayer = { _ in player }
        var renderCount = 0, recordCount = 0
        app.renderGreeting = { text,service,root in
            renderCount += 1
            XCTAssertTrue(VoiceIdentity.greetings.contains(text))
            XCTAssertEqual(service.voice,app.conversationVoice)
            return root.appendingPathComponent("greeting.wav")
        }
        app.recordAudio = { _ in recordCount += 1 }
        XCTAssertEqual(app.microphoneLabel,"Start Voice Conversation")
        app.toggleConversationVoice()
        await wait { app.turn.activity == .playing }
        XCTAssertEqual(app.conversation?.messages.count,1)
        XCTAssertTrue(app.conversation?.voiceIntroduced == true)
        XCTAssertEqual(app.conversation?.messages.first?.role,"assistant")
        XCTAssertEqual(recordCount,0)
        app.togglePlayback("greeting.wav"); XCTAssertTrue(app.audio.paused)
        app.togglePlayback("greeting.wav"); XCTAssertFalse(app.audio.paused)
        app.audio.finishPlayback(player,successfully:true)
        await wait { app.turn.activity == .recording }
        XCTAssertEqual(recordCount,1)
        app.stop(); app.toggleConversationVoice()
        await wait { app.turn.activity == .recording }
        XCTAssertEqual(renderCount,1); XCTAssertEqual(recordCount,2)
        app.stop(); app.play("greeting.wav",mochi:true)
        app.audio.finishPlayback(player,successfully:true)
        await Task.yield()
        XCTAssertEqual(recordCount,2); XCTAssertEqual(app.turn.activity,.idle)
        app.append(Message(role:"user",text:"The first real thought"),to:app.selectedID!)
        XCTAssertEqual(app.conversation?.title,"The first real thought")
        app.stop()
    }
    @MainActor func testPermissionDenialAndRenderFailureLeaveMicrophoneOff() async {
        let app = app(); var renders = 0, records = 0
        app.recordAudio = { _ in records += 1 }
        app.renderGreeting = { _,_,_ in renders += 1; throw AppFailure("Greeting failed") }
        app.microphonePermission = { false }
        app.toggleConversationVoice(); await wait { app.turn.activity == .idle }
        XCTAssertEqual(renders,0); XCTAssertEqual(records,0); XCTAssertNotNil(app.error)
        XCTAssertFalse(app.greetingActive)
        app.microphonePermission = { true }
        app.toggleConversationVoice(); await wait { app.turn.activity == .idle }
        XCTAssertEqual(renders,1); XCTAssertEqual(records,0)
        XCTAssertFalse(app.conversation?.voiceIntroduced == true)
        XCTAssertTrue(app.conversation?.messages.isEmpty == true)
        app.stop()
    }
    @MainActor func testSkipDuringGenerationIgnoresLateResult() async {
        let app = app(); let gate = TestGate(); var records = 0
        app.renderGreeting = { _,_,root in await gate.wait(); return root.appendingPathComponent("late.wav") }
        app.recordAudio = { _ in records += 1 }
        app.toggleConversationVoice(); await wait { app.turn.activity == .generating }
        app.toggleConversationVoice(); await wait { app.turn.activity == .recording }
        await gate.release(); for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(records,1); XCTAssertTrue(app.conversation?.messages.isEmpty == true)
        XCTAssertTrue(app.conversation?.voiceIntroduced == true)
        app.stop()
    }
    @MainActor func testStopNavigationPracticeAndReplacementCancelAutomaticMicrophone() async {
        for action in 0..<4 {
            let app = app(), player = GreetingPlayer(); var records = 0
            app.audio.makePlayer = { _ in player }; app.recordAudio = { _ in records += 1 }
            app.toggleConversationVoice(); await wait { app.turn.activity == .playing }
            switch action {
            case 0: app.stop()
            case 1: let next = Conversation(); app.library.conversations.append(next); app.select(next.id)
            case 2: app.startHelp()
            default: app.play("other.wav")
            }
            app.audio.finishPlayback(player,successfully:true)
            for _ in 0..<10 { await Task.yield() }
            XCTAssertEqual(records,0); XCTAssertFalse(app.greetingActive)
            app.stop()
        }
    }
    @MainActor func testFailedPlaybackDoesNotListen() async {
        for failsAtStart in [false,true] {
            let app = app(), player = GreetingPlayer(); var records = 0
            player.succeeds = !failsAtStart
            app.audio.makePlayer = { _ in player }; app.recordAudio = { _ in records += 1 }
            app.toggleConversationVoice()
            await wait { app.turn.activity == (failsAtStart ? .idle : .playing) }
            if !failsAtStart { app.audio.finishPlayback(player,successfully:false) }
            await Task.yield()
            XCTAssertEqual(records,0); XCTAssertFalse(app.greetingActive); XCTAssertNotNil(app.error)
            app.stop()
        }
    }
    @MainActor func testStopWhilePermissionOrRenderingPendingNeverStartsAudioOrRecording() async {
        for waitingForPermission in [true,false] {
            let app = app(), gate = TestGate(); var renders = 0, records = 0
            app.microphonePermission = { if waitingForPermission { await gate.wait() }; return true }
            app.renderGreeting = { _,_,root in renders += 1; if !waitingForPermission { await gate.wait() }; return root.appendingPathComponent("late.wav") }
            app.recordAudio = { _ in records += 1 }
            app.toggleConversationVoice()
            await wait { waitingForPermission ? app.turn.activity == .requestingPermission : renders == 1 }
            app.stop(); await gate.release()
            for _ in 0..<10 { await Task.yield() }
            XCTAssertEqual(renders,waitingForPermission ? 0 : 1)
            XCTAssertEqual(records,0); XCTAssertNil(app.playbackFile)
            XCTAssertTrue(app.conversation?.messages.isEmpty == true)
            XCTAssertFalse(app.greetingActive)
        }
    }
    @MainActor func testIntroductionAndRecentGreetingsSurviveRelaunch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "mochi-greeting-persistence-\(UUID())", prefs = UserDefaults(suiteName:suite)!
        defer { try? FileManager.default.removeItem(at:root); prefs.removePersistentDomain(forName:suite) }
        let app = AppModel(libraryRoot:root,preferences:prefs)
        app.microphonePermission = { true }
        app.renderGreeting = { _,_,root in
            let url = root.appendingPathComponent("greeting.wav")
            try PCM.wav(Data(repeating:0,count:24000)).write(to:url)
            return url
        }
        app.audio.makePlayer = { _ in GreetingPlayer() }
        var greetings: [String] = []
        for _ in 0..<4 {
            app.newChat(); app.toggleConversationVoice()
            await wait { app.turn.activity == .playing }
            let text = try XCTUnwrap(app.conversation?.messages.first?.text)
            XCTAssertFalse(greetings.suffix(3).contains(text))
            greetings.append(text); app.stop()
        }
        let reopened = AppModel(libraryRoot:root,preferences:prefs)
        XCTAssertEqual(reopened.selectedID,app.selectedID)
        XCTAssertTrue(reopened.conversation?.voiceIntroduced == true)
        XCTAssertEqual(prefs.stringArray(forKey:"voiceGreetingHistory"),Array(greetings.suffix(3)))
        var rendered = false
        reopened.renderGreeting = { _,_,root in rendered = true; return root.appendingPathComponent("unexpected.wav") }
        reopened.microphonePermission = { true }; reopened.recordAudio = { _ in }
        reopened.toggleConversationVoice(); await wait { reopened.turn.activity == .recording }
        XCTAssertFalse(rendered)
        reopened.stop()
    }

}
