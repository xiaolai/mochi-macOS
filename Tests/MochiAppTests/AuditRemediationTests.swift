import XCTest
import MochiCore
@testable import MochiApp
final class AuditRemediationTests: XCTestCase {
    @MainActor private func app() -> AppModel { AppModel(libraryRoot:URL(fileURLWithPath:"/tmp/mochi-audit-\(UUID())"),preferences:UserDefaults(suiteName:"mochi-audit-\(UUID())")!) }
    @MainActor func testDraftProtectedAndCancelledPreparationNeverWrites() throws {
        let app = app(); defer { app.stop(); try? FileManager.default.removeItem(at:app.store.root) }
        let id = try XCTUnwrap(app.selectedID), args: [String:Any] = ["conversation_id":id.uuidString,"english":"New sentence"]
        app.library.conversations[0].helpDraft = HelpDraft(meaning:"My thought",english:"My draft",recording:"recording.wav")
        XCTAssertThrowsError(try app.executeTool("prepare_expression",arguments:args,origin:.voice))
        XCTAssertEqual(app.conversation?.helpDraft?.english,"My draft")
        app.library.conversations[0].helpDraft = nil
        _ = app.turn.begin(.generating)
        _ = try app.executeTool("prepare_expression",arguments:args,origin:.voice)
        XCTAssertNil(app.conversation?.helpDraft)
        app.stop(); XCTAssertNil(app.conversation?.helpDraft)
    }
    @MainActor func testBlankConversationReused() throws {
        let app = app(); defer { app.externalControlEnabled = false; app.stop(); try? FileManager.default.removeItem(at:app.store.root) }
        app.externalControlEnabled = true
        let id = try XCTUnwrap(app.selectedID), count = app.library.conversations.count
        XCTAssertFalse(app.automationModal)
        let result = try app.executeTool("create_conversation",arguments:["title":"   ","expected_revision":app.controlRevision],origin:.external)
        XCTAssertEqual(result["conversation_id"] as? String,id.uuidString); XCTAssertEqual(app.library.conversations.count,count); XCTAssertFalse(app.conversation!.customTitle)
    }
    @MainActor func testProductionControlAndReplayCacheBound() async throws {
        let app = app(); defer { app.externalControlEnabled = false; app.stop(); try? FileManager.default.removeItem(at:app.store.root) }
        app.externalControlEnabled = true
        XCTAssertNotNil(app.controlServer)
        let request = try JSONSerialization.data(withJSONObject:["name":"get_session","arguments":[:],"request_id":"ipc"])
        let path = app.controlSocketPath
        let result = try await Task.detached { try LocalControl.request(request,path:path) }.value
        XCTAssertEqual((try JSONSerialization.jsonObject(with:result) as! [String:Any])["ok"] as? Bool,true)
        for i in 0..<140 { _ = app.handleControlRequest(try JSONSerialization.data(withJSONObject:["name":"get_session","arguments":[:],"request_id":"r\(i)"])) }
        XCTAssertEqual(app.toolResultCache.count,128); XCTAssertNil(app.toolResultCache["r0"])
        app.externalControlEnabled = false; XCTAssertFalse(FileManager.default.fileExists(atPath:path))
    }
}

private final class AuditPlayer: PlaybackPlayer {
    var duration: TimeInterval = 5
    var currentTime: TimeInterval = 0
    var enableRate = false
    var rate: Float = 1
    var starts = 0, pauses = 0
    func play() -> Bool { starts += 1; return true }
    func pause() { pauses += 1 }
    func stop() {}
}
extension AuditRemediationTests {
    @MainActor func testVoiceRetryCachesCompletedMutationButNotCancelledNavigation() throws {
        let app = app(); defer { app.stop(); try? FileManager.default.removeItem(at:app.store.root) }
        let id = try XCTUnwrap(app.selectedID), operation = UUID()
        let args: [String:Any] = ["conversation_id":id.uuidString,"speed":0.8]
        _ = try app.executeVoiceTool("set_conversation_preferences",arguments:args,operationID:operation)
        app.library.conversations[0].preferences.speed = 1.0
        let replay = try app.executeVoiceTool("set_conversation_preferences",arguments:args,operationID:operation)
        XCTAssertEqual(replay["status"] as? String,"previously_completed"); XCTAssertEqual(app.conversation?.preferences.speed,1.0)
        _ = app.turn.begin(.generating)
        let prepare: [String:Any] = ["conversation_id":id.uuidString,"english":"Let me think."]
        _ = try app.executeVoiceTool("prepare_expression",arguments:prepare,operationID:operation)
        app.stop(); XCTAssertNil(app.conversation?.helpDraft)
        let token = app.turn.begin(.generating)
        _ = try app.executeVoiceTool("prepare_expression",arguments:prepare,operationID:operation)
        let action = app.deferredToolAction; app.deferredToolAction = nil; _ = app.turn.finish(token); action?()
        XCTAssertTrue(app.practice); XCTAssertEqual(app.conversation?.helpDraft?.english,"Let me think.")
        app.leavePractice()
        for _ in 0..<140 { _ = try app.executeVoiceTool("set_conversation_preferences",arguments:args,operationID:UUID()) }
        XCTAssertEqual(app.voiceToolResults.count,128)
    }
    @MainActor func testFailedAcknowledgmentStillOpensPreparedExpression() async throws {
        let app = app(); defer { app.stop(); try? FileManager.default.removeItem(at:app.store.root) }
        let id = try XCTUnwrap(app.selectedID), player = AuditPlayer(); app.audio.makePlayer = { _ in player }
        app.conversationReply = { _,callbacks in
            _ = try app.executeTool("prepare_expression",arguments:["conversation_id":id.uuidString,"english":"A sentence."],origin:.voice)
            var reply = RealtimeAccumulator(); reply.text = "Ready."; reply.audio = Data(repeating:0,count:4800)
            try callbacks.response(reply)
        }
        app.draft = "Prepare a sentence"; app.send()
        for _ in 0..<100 { if app.turn.activity != .generating { break }; await Task.yield() }
        XCTAssertEqual(app.turn.activity,.playing); XCTAssertFalse(app.practice)
        app.audio.finishPlayback(player,successfully:false)
        XCTAssertTrue(app.practice); XCTAssertEqual(app.conversation?.helpDraft?.english,"A sentence.")
    }
    @MainActor func testPauseResumeAndRecentExpressionOrdering() throws {
        let app = app(); defer { app.stop(); try? FileManager.default.removeItem(at:app.store.root) }
        let id = try XCTUnwrap(app.selectedID)
        let first = try app.executeTool("save_expression",arguments:["conversation_id":id.uuidString,"english":"First"],origin:.voice)
        let last = try app.executeTool("save_expression",arguments:["conversation_id":id.uuidString,"english":"Last"],origin:.voice)
        let search = try app.executeTool("search_expressions",arguments:["conversation_id":id.uuidString,"query":"","limit":1],origin:.voice)
        let found = try XCTUnwrap((search["expressions"] as? [[String:Any]])?.first)
        XCTAssertEqual(found["id"] as? String,last["expression_id"] as? String); XCTAssertNotEqual(first["expression_id"] as? String,last["expression_id"] as? String)
        app.externalControlEnabled = true
        let player = AuditPlayer(); app.audio.makePlayer = { _ in player }; app.play("fixture.wav")
        _ = try app.executeTool("pause_audio",arguments:["conversation_id":id.uuidString,"expected_revision":app.controlRevision],origin:.external)
        XCTAssertTrue(app.audio.paused)
        _ = try app.executeTool("resume_audio",arguments:["conversation_id":id.uuidString,"expected_revision":app.controlRevision],origin:.external)
        XCTAssertFalse(app.audio.paused); XCTAssertEqual(player.starts,2); app.externalControlEnabled = false
    }
}
extension AuditRemediationTests {
    @MainActor func testBlankChatReusePreservesPinDateAndIntroduction() throws {
        let app = app(); defer { app.externalControlEnabled = false; app.stop(); try? FileManager.default.removeItem(at:app.store.root) }
        app.externalControlEnabled = true
        let id = try XCTUnwrap(app.selectedID), date = Date(timeIntervalSince1970:1234)
        app.library.conversations[0].pinned = true; app.library.conversations[0].date = date; app.library.conversations[0].voiceIntroduced = true
        _ = try app.executeTool("create_conversation",arguments:["title":"Practice","expected_revision":app.controlRevision],origin:.external)
        XCTAssertEqual(app.selectedID,id); XCTAssertTrue(app.conversation!.pinned); XCTAssertEqual(app.conversation!.date,date); XCTAssertTrue(app.conversation!.voiceIntroduced)
    }
    @MainActor func testDeferredNavigationAndPlaybackRejectNewModal() throws {
        for name in ["start_practice","play_audio","seek_audio"] {
            let app = app(); defer { app.stop(); try? FileManager.default.removeItem(at:app.store.root) }
            let id = try XCTUnwrap(app.selectedID)
            var item = PracticeExpression(conversationID:id,meaning:"",english:"Hello")
            item.reference = "fixture.wav"; app.library.expressions = [item]
            try PCM.wav(Data(repeating:0,count:4800)).write(to:app.store.root.appendingPathComponent("fixture.wav"))
            var args: [String:Any] = ["conversation_id":id.uuidString,"expression_id":item.id.uuidString]
            if name == "seek_audio" { args["seconds"] = 1 }
            let token = app.turn.begin(.generating)
            _ = try app.executeVoiceTool(name,arguments:args,operationID:UUID())
            let action = app.deferredToolAction; app.deferredToolAction = nil; _ = app.turn.finish(token)
            app.managerOpen = true; action?()
            XCTAssertFalse(app.practice); XCTAssertNil(app.playbackFile); XCTAssertNotNil(app.error); XCTAssertTrue(app.voiceToolResults.isEmpty)
        }
    }
}
extension AuditRemediationTests {
    @MainActor func testForeignOversizedInstructionsRetainedButRequestAndToolsBounded() async throws {
        let app = app(); defer { app.stop(); try? FileManager.default.removeItem(at:app.store.root) }
        let original = String(repeating:"文",count:9000)
        app.library.conversations[0].instructions = original
        try app.store.save(app.library)
        XCTAssertEqual(try app.store.load().conversations[0].instructions,original)
        let session = try app.executeTool("get_session",arguments:[:],origin:.voice)
        XCTAssertEqual((session["instructions"] as? String)?.count,1000); XCTAssertEqual(session["instructions_truncated"] as? Bool,true)
        var captured: ConversationRequest?
        app.conversationReply = { request,callbacks in captured = request; var reply = RealtimeAccumulator(); reply.text = "Hello."; try callbacks.response(reply) }
        app.draft = "Hello"; app.send()
        for _ in 0..<100 { if captured != nil { break }; await Task.yield() }
        XCTAssertEqual(captured?.instructions.count,8000)
        XCTAssertEqual(app.conversation?.instructions,original)
    }
}
extension AuditRemediationTests {
    @MainActor func testLostSocketRebindsWithoutDroppingReplayCache() async throws {
        let app = app(); defer { app.externalControlEnabled = false; app.stop(); try? FileManager.default.removeItem(at:app.store.root) }
        app.externalControlEnabled = true
        let old = try XCTUnwrap(app.controlServer), path = app.controlSocketPath
        let request = try JSONSerialization.data(withJSONObject:["name":"get_session","arguments":[:],"request_id":"retained"])
        _ = app.handleControlRequest(request)
        try FileManager.default.removeItem(atPath:path)
        XCTAssertFalse(old.endpointAvailable)
        app.configureAutomation()
        XCTAssertTrue(app.controlServer?.endpointAvailable == true); XCTAssertFalse(app.controlServer === old); XCTAssertNotNil(app.toolResultCache["retained"])
        let reply = try await Task.detached { try LocalControl.request(request,path:path) }.value
        XCTAssertEqual((try JSONSerialization.jsonObject(with:reply) as? [String:Any])?["ok"] as? Bool,true)
        app.externalControlEnabled = false; XCTAssertNil(app.controlHealthTask)
    }
}
