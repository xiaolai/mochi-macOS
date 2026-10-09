import XCTest
import MochiCore
@testable import MochiApp
private final class AutomationPlayer: PlaybackPlayer {
    var duration: TimeInterval = 5
    var currentTime: TimeInterval = 0
    var enableRate = false
    var rate: Float = 1
    func play() -> Bool { true }
    func pause() {}
    func stop() {}
}
final class AutomationTests: XCTestCase {
    @MainActor func testConversationSettingsPersistAndRejectArchivedChanges() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at:root) }
        let app = AppModel(libraryRoot:root,preferences:UserDefaults(suiteName:"automation-tests-" + root.lastPathComponent)!), id = try XCTUnwrap(app.selectedID)
        var preferences = ConversationPreferences(); preferences.speed = 0.7
        XCTAssertTrue(app.setConversationInstructions(id,instructions:"Interview me",preferences:preferences))
        XCTAssertEqual(AppModel(libraryRoot:root,preferences:UserDefaults(suiteName:"automation-tests-" + root.lastPathComponent)!).conversation?.instructions,"Interview me")
        app.archiveChats([id]); XCTAssertFalse(app.setConversationInstructions(id,instructions:"No",preferences:preferences))
    }
    @MainActor func testRevisionAndScopeGuardAndExpressionPersistence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at:root) }
        let app = AppModel(libraryRoot:root,preferences:UserDefaults(suiteName:"automation-tests-" + root.lastPathComponent)!), id = try XCTUnwrap(app.selectedID)
        app.externalControlEnabled = true
        let args: [String:Any] = ["conversation_id":id.uuidString,"expected_revision":app.controlRevision,"english":"Could you give me a moment?"]
        let result = try app.executeTool("save_expression",arguments:args,origin:.external)
        XCTAssertEqual(result["ok"] as? Bool,true); XCTAssertEqual(AppModel(libraryRoot:root,preferences:UserDefaults(suiteName:"automation-tests-" + root.lastPathComponent)!).library.expressions.count,1)
        XCTAssertThrowsError(try app.executeTool("save_expression",arguments:args,origin:.external))
        XCTAssertThrowsError(try app.executeTool("set_conversation_instructions",arguments:["conversation_id":id.uuidString,"instructions":"No","expected_revision":app.controlRevision],origin:.voice))
        app.externalControlEnabled = false
        XCTAssertThrowsError(try app.executeTool("get_session",arguments:[:],origin:.external))
    }
    @MainActor func testVoiceNavigationIsDeferredAndCancelledWithTurn() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at:root) }
        let app = AppModel(libraryRoot:root,preferences:UserDefaults(suiteName:"automation-tests-" + root.lastPathComponent)!), id = try XCTUnwrap(app.selectedID)
        _ = app.turn.begin(.generating)
        _ = try app.executeTool("prepare_expression",arguments:["conversation_id":id.uuidString,"english":"Let me think."],origin:.voice)
        XCTAssertFalse(app.practice); XCTAssertNotNil(app.deferredToolAction)
        XCTAssertThrowsError(try app.executeTool("prepare_expression",arguments:["conversation_id":id.uuidString,"english":"Overwrite this"],origin:.voice))
        XCTAssertNil(app.conversation?.helpDraft)
        app.stop(); XCTAssertNil(app.deferredToolAction); XCTAssertFalse(app.practice)
    }
    @MainActor func testAtomicFailureDoesNotChangeInstructionsOrExpressions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at:root) }
        let app = AppModel(libraryRoot:root,preferences:UserDefaults(suiteName:"automation-tests-" + root.lastPathComponent)!), id = try XCTUnwrap(app.selectedID)
        try Data("broken".utf8).write(to:app.store.file)
        XCTAssertFalse(app.setConversationInstructions(id,instructions:"New",preferences:ConversationPreferences()))
        XCTAssertEqual(app.conversation?.instructions,"")
        XCTAssertThrowsError(try app.executeTool("save_expression",arguments:["conversation_id":id.uuidString,"english":"Hello"],origin:.voice))
        XCTAssertTrue(app.library.expressions.isEmpty)
    }
    @MainActor func testRequestUsesConversationInstructionsAndCustomizedEmptyChatIsNotReused() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at:root) }
        let app = AppModel(libraryRoot:root,preferences:UserDefaults(suiteName:"automation-"+UUID().uuidString)!)
        let id = try XCTUnwrap(app.selectedID)
        var prefs = ConversationPreferences(); prefs.coaching = .direct; prefs.speed = 0.8
        XCTAssertTrue(app.setConversationInstructions(id,instructions:"Interview me",preferences:prefs))
        var captured: ConversationRequest?
        app.conversationReply = { request,callbacks in
            captured = request
            var reply = RealtimeAccumulator(); reply.text = "Hello."
            try callbacks.response(reply)
        }
        app.draft = "Hello"; app.send()
        for _ in 0..<100 { if captured != nil { break }; await Task.yield() }
        XCTAssertEqual(captured?.instructions,"Interview me"); XCTAssertEqual(captured?.preferences.speed,0.8)
        app.newChat(); let second = try XCTUnwrap(app.selectedID)
        XCTAssertNotEqual(second,id); XCTAssertEqual(app.conversation?.instructions,"")
        XCTAssertTrue(app.setConversationInstructions(second,instructions:"Travel roleplay",preferences:ConversationPreferences()))
        app.newChat(); XCTAssertNotEqual(app.selectedID,second)
        app.stop()
    }
    @MainActor func testExternalBusyAndModalWritesAreRejected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at:root) }
        let app = AppModel(libraryRoot:root,preferences:UserDefaults(suiteName:"automation-"+UUID().uuidString)!)
        app.externalControlEnabled = true
        let id = try XCTUnwrap(app.selectedID)
        for activity in [Activity.recording,.requestingPermission,.generating] {
            _ = app.turn.begin(activity)
            XCTAssertThrowsError(try app.executeTool("save_expression",arguments:["conversation_id":id.uuidString,"expected_revision":app.controlRevision,"english":"Hello"],origin:.external))
        }
        app.stop(); app.instructionsID = id
        XCTAssertThrowsError(try app.executeTool("save_expression",arguments:["conversation_id":id.uuidString,"expected_revision":app.controlRevision,"english":"Hello"],origin:.external))
        app.instructionsID = nil; app.startHelp()
        XCTAssertThrowsError(try app.executeTool("prepare_expression",arguments:["conversation_id":id.uuidString,"expected_revision":app.controlRevision,"english":"Hello"],origin:.external))
        XCTAssertTrue(app.library.expressions.isEmpty)
        app.externalControlEnabled = false; app.stop()
    }
    @MainActor func testControlReplayCacheAndChangedArguments() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at:root) }
        let app = AppModel(libraryRoot:root,preferences:UserDefaults(suiteName:"automation-"+UUID().uuidString)!)
        app.externalControlEnabled = true
        var revealed = 0; app.revealWorkspace = { revealed += 1 }
        var payload: [String:Any] = ["name":"create_conversation","arguments":["title":"Practice","expected_revision":app.controlRevision],"request_id":"same"]
        let data = try JSONSerialization.data(withJSONObject:payload)
        let first = app.handleControlRequest(data), count = app.library.conversations.count
        XCTAssertEqual(first,app.handleControlRequest(data)); XCTAssertEqual(count,app.library.conversations.count); XCTAssertEqual(revealed,1)
        payload["arguments"] = ["title":"Other","expected_revision":app.controlRevision]
        let changed = try JSONSerialization.jsonObject(with:app.handleControlRequest(JSONSerialization.data(withJSONObject:payload))) as! [String:Any]
        XCTAssertEqual(changed["ok"] as? Bool,false); XCTAssertEqual(count,app.library.conversations.count)
        app.externalControlEnabled = false
        let disabled = try JSONSerialization.jsonObject(with:app.handleControlRequest(data)) as! [String:Any]
        XCTAssertEqual(disabled["ok"] as? Bool,false)
    }
    @MainActor func testReadsAreBoundedAndWrongConversationCannotBeRead() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at:root) }
        let app = AppModel(libraryRoot:root,preferences:UserDefaults(suiteName:"automation-"+UUID().uuidString)!), id = try XCTUnwrap(app.selectedID)
        var chat = app.conversation!
        chat.messages = (0..<110).map { _ in Message(role:"user",text:String(repeating:"x",count:10000)) }
        app.library.conversations = [chat,Conversation()]
        let result = try app.executeTool("get_messages",arguments:["conversation_id":id.uuidString,"limit":100],origin:.voice)
        let messages = result["messages"] as! [[String:Any]]
        XCTAssertGreaterThan(messages.count,0); XCTAssertLessThanOrEqual(messages.count,100); XCTAssertEqual(result["has_more"] as? Bool,true); XCTAssertEqual((messages[0]["text"] as! String).count,2000)
        XCTAssertLessThan(try JSONSerialization.data(withJSONObject:result).count,LocalControl.maxFrame)
        XCTAssertThrowsError(try app.executeTool("get_messages",arguments:["conversation_id":app.library.conversations[1].id.uuidString],origin:.voice))
        XCTAssertThrowsError(try app.executeTool("play_audio",arguments:["conversation_id":id.uuidString,"message_id":chat.messages[0].id.uuidString],origin:.voice))
    }
    @MainActor func testDeferredPracticeOnlyRunsAfterReplyAndRejectsSecondNavigation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at:root) }
        let app = AppModel(libraryRoot:root,preferences:UserDefaults(suiteName:"automation-"+UUID().uuidString)!), id = try XCTUnwrap(app.selectedID)
        let saved = try app.executeTool("save_expression",arguments:["conversation_id":id.uuidString,"english":"Let me think."],origin:.voice)
        let token = app.turn.begin(.generating)
        let args: [String:Any] = ["conversation_id":id.uuidString,"expression_id":saved["expression_id"]!]
        let result = try app.executeTool("start_practice",arguments:args,origin:.voice)
        XCTAssertEqual(result["status"] as? String,"scheduled_after_reply"); XCTAssertFalse(app.practice)
        XCTAssertThrowsError(try app.executeTool("start_practice",arguments:args,origin:.voice))
        let action = app.deferredToolAction; app.deferredToolAction = nil; _ = app.turn.finish(token); action?()
        XCTAssertTrue(app.practice); XCTAssertEqual(app.expression?.english,"Let me think."); app.stop()
    }

    @MainActor func testVoiceAcknowledgmentPlaysBeforePracticeAndStopCancelsNavigation() async throws {
        for cancel in [false,true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at:root) }
            let app = AppModel(libraryRoot:root,preferences:UserDefaults(suiteName:"automation-"+UUID().uuidString)!), id = try XCTUnwrap(app.selectedID)
            let player = AutomationPlayer(); app.audio.makePlayer = { _ in player }
            app.conversationReply = { _,callbacks in
                _ = try app.executeTool("prepare_expression",arguments:["conversation_id":id.uuidString,"english":"Let me think."],origin:.voice)
                var response = RealtimeAccumulator(); response.text = "Let's practise."; response.audio = Data(repeating:0,count:4800)
                try callbacks.response(response)
            }
            app.draft = "Let's practise"; app.send()
            for _ in 0..<100 { if app.turn.activity != .generating { break }; await Task.yield() }
            XCTAssertEqual(app.turn.activity,.playing); XCTAssertFalse(app.practice)
            if cancel { app.stop() }
            app.audio.finishPlayback(player,successfully:true)
            XCTAssertEqual(app.practice,!cancel); app.stop()
        }
    }

}
