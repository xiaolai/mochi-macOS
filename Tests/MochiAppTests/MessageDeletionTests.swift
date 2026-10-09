import XCTest
import MochiCore
@testable import MochiApp

final class MessageDeletionTests: XCTestCase {
    private func temporary() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }

    @MainActor func testDeletePersistsAndRemovesSearchAndContextWithoutDeletingOtherMessages() throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at:root) }
        let app = AppModel(libraryRoot:root), id = try XCTUnwrap(app.selectedID)
        let first = Message(role:"user",text:"Forget this phrase")
        let reply = Message(role:"assistant",text:"A response")
        let last = Message(role:"user",text:"Keep this phrase")
        for message in [first,reply,last] { app.append(message,to:id) }
        app.conversationQuery = "Forget"
        app.deleteMessage(first.id)
        XCTAssertEqual(app.conversation?.messages.map(\.id),[reply.id,last.id])
        XCTAssertTrue(app.conversationMatchIDs.isEmpty)
        XCTAssertEqual(app.conversation?.title,"Keep this phrase")
        XCTAssertTrue(app.library.history(in:.active,query:"Forget").isEmpty)
        let reopened = AppModel(libraryRoot:root)
        XCTAssertEqual(reopened.conversation?.messages.map(\.id),[reply.id,last.id])
        app.undoMessageDeletion()
        XCTAssertEqual(app.conversation?.messages.map(\.id),[first.id,reply.id,last.id])
        XCTAssertEqual(AppModel(libraryRoot:root).conversation?.messages.map(\.id),[first.id,reply.id,last.id])
        app.stop()
    }

    @MainActor func testUndoRetainsAudioAndDismissalRemovesOnlyUnreferencedAudio() throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at:root) }
        let app = AppModel(libraryRoot:root), id = try XCTUnwrap(app.selectedID)
        let url = root.appendingPathComponent("message.wav")
        try Data([1,2]).write(to:url)
        let message = Message(role:"user",text:"Audio",audio:"message.wav")
        app.append(message,to:id)
        app.deleteMessage(message.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath:url.path))
        app.undoMessageDeletion()
        XCTAssertTrue(FileManager.default.fileExists(atPath:url.path))
        app.deleteMessage(message.id)
        app.notice = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath:url.path))
        XCTAssertFalse(app.canUndoMessageDeletion)
    }

    @MainActor func testConsecutiveDeletionOfSharedAudioKeepsLatestUndoAndSavedExpressions() throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at:root) }
        let app = AppModel(libraryRoot:root), id = try XCTUnwrap(app.selectedID)
        let url = root.appendingPathComponent("shared.wav")
        try Data([1]).write(to:url)
        let a = Message(role:"user",text:"First",audio:"shared.wav")
        let b = Message(role:"assistant",text:"Second",audio:"shared.wav")
        app.append(a,to:id); app.append(b,to:id)
        app.deleteMessage(a.id); app.deleteMessage(b.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath:url.path))
        var item = PracticeExpression(conversationID:id,meaning:"",english:"Saved")
        item.reference = "shared.wav"; app.library.expressions = [item]; app.save()
        app.notice = nil
        XCTAssertTrue(FileManager.default.fileExists(atPath:url.path))
        XCTAssertEqual(app.library.expressions.count,1)
    }

    @MainActor func testFailedDeletionKeepsMessageRecordingAndActiveTurn() throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at:root) }
        let app = AppModel(libraryRoot:root), id = try XCTUnwrap(app.selectedID)
        let message = Message(role:"user",text:"Keep",audio:"keep.wav")
        try Data([1]).write(to:root.appendingPathComponent("keep.wav"))
        app.append(message,to:id)
        try Data("broken".utf8).write(to:app.store.file)
        let token = app.turn.begin(.generating)
        app.deleteMessage(message.id)
        XCTAssertEqual(app.conversation?.messages.first?.id,message.id)
        XCTAssertEqual(app.turn.epoch,token)
        XCTAssertTrue(FileManager.default.fileExists(atPath:root.appendingPathComponent("keep.wav").path))
        XCTAssertFalse(app.canUndoMessageDeletion)
        app.stop()
    }

    @MainActor func testDeleteInvalidatesReplyAndUndoInterruptsPendingTranscript() throws {
        let app = AppModel(demo:true); app.resume(); app.newChat()
        let id = try XCTUnwrap(app.selectedID)
        var message = Message(role:"user",text:"",audio:"pending.wav")
        message.transcriptionState = .pending
        app.append(message,to:id)
        let token = app.turn.begin(.generating)
        app.deleteMessage(message.id)
        XCTAssertNotEqual(app.turn.epoch,token)
        XCTAssertFalse(app.busy)
        app.undoMessageDeletion()
        XCTAssertEqual(app.conversation?.messages.first?.transcriptionState,.interrupted)
        app.turn.begin(.recording)
        app.deleteMessage(message.id)
        XCTAssertEqual(app.conversation?.messages.first?.id,message.id)
        app.stop(); app.archiveChats([id]); app.select(id)
        app.deleteMessage(message.id)
        XCTAssertEqual(app.conversation?.messages.first?.id,message.id)
    }

    @MainActor func testExpiryEndsUndoAndCleansTheDeletedRecording() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at:root) }
        let app = AppModel(libraryRoot:root), id = try XCTUnwrap(app.selectedID)
        let file = root.appendingPathComponent("expire.wav")
        try Data([1]).write(to:file)
        let message = Message(role:"user",text:"Delete",audio:"expire.wav")
        app.append(message,to:id)
        let gate = TestGate(), scheduled = expectation(description:"Undo deadline scheduled")
        app.noticeSleep = { duration in
            XCTAssertEqual(duration,10_000_000_000); scheduled.fulfill(); await gate.wait()
        }
        app.deleteMessage(message.id)
        await fulfillment(of:[scheduled],timeout:2)
        XCTAssertTrue(app.canUndoMessageDeletion)
        await gate.release()
        for _ in 0..<100 where app.notice != nil { try await Task.sleep(nanoseconds:1_000_000) }
        XCTAssertNil(app.notice); XCTAssertFalse(app.canUndoMessageDeletion)
        XCTAssertFalse(FileManager.default.fileExists(atPath:file.path))
    }

    @MainActor func testLateTranscriptionCannotRewriteAnUndoneDeletion() async throws {
        let app = AppModel(demo:true); app.resume(); app.newChat()
        let id = try XCTUnwrap(app.selectedID)
        var message = Message(role:"user",text:"",audio:"late.wav")
        message.transcriptionState = .failed; app.append(message,to:id)
        let gate = TestGate(), started = expectation(description:"Transcription started")
        app.transcribeRecording = { _,_,_ in started.fulfill(); await gate.wait(); return "Late text" }
        app.retryTranscription(message.id)
        let job = try XCTUnwrap(app.transcriptTasks[message.id])
        await fulfillment(of:[started],timeout:2)
        app.deleteMessage(message.id); app.undoMessageDeletion()
        await gate.release(); await job.value
        XCTAssertEqual(app.conversation?.messages.first?.text,"")
        XCTAssertEqual(app.conversation?.messages.first?.transcriptionState,.interrupted)
        XCTAssertTrue(app.transcribingMessageIDs.isEmpty)
        app.stop()
    }

    @MainActor func testNextRequestExcludesDeletedMessageAndLateReplyCannotReturn() async throws {
        let app = AppModel(demo:true); app.resume(); app.newChat()
        let id = try XCTUnwrap(app.selectedID)
        let removed = Message(role:"user",text:"Remove from context")
        app.append(removed,to:id); app.deleteMessage(removed.id)
        let gate = TestGate(), started = expectation(description:"Reply started"), returned = expectation(description:"Late reply attempted")
        app.conversationReply = { request,callbacks in
            XCTAssertFalse(request.history.contains { $0.id == removed.id })
            started.fulfill(); await gate.wait()
            var result = RealtimeAccumulator(); result.text = "Late reply"; result.done = true
            try callbacks.response(result); returned.fulfill()
        }
        app.draft = "New message"; app.send()
        await fulfillment(of:[started],timeout:2)
        app.deleteMessage(try XCTUnwrap(app.conversation?.messages.last?.id))
        await gate.release(); await fulfillment(of:[returned],timeout:2)
        XCTAssertTrue(app.conversation?.messages.isEmpty == true)
        app.notice = nil; app.stop()
    }
}
