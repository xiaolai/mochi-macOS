import XCTest
import MochiCore
@testable import MochiApp
final class HistoryModelTests: XCTestCase {
    @MainActor func testDraftSelectionAndRenameSurviveRelaunch() throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at:root) }
        let model = AppModel(libraryRoot:root)
        let first = try XCTUnwrap(model.selectedID)
        model.draft = "An unfinished thought"
        model.renameChat(first,title:" My custom title ")
        model.newChat()
        let second = try XCTUnwrap(model.selectedID)
        XCTAssertNotEqual(first,second)
        model.draft = "Second draft"
        model.select(first)
        XCTAssertEqual(model.draft,"An unfinished thought")
        model.append(Message(role:"user",text:"A first real message"),to:first)
        XCTAssertEqual(model.conversation?.title,"My custom title")
        model.save()
        let reopened = AppModel(libraryRoot:root)
        XCTAssertEqual(reopened.selectedID,first)
        XCTAssertEqual(reopened.draft,"An unfinished thought")
        reopened.select(second)
        XCTAssertEqual(reopened.draft,"Second draft")
    }
    @MainActor func testDeleteCancelsLateReplyAndReadOnlyGuards() throws {
        let model = AppModel(demo:true)
        model.resume()
        let id = try XCTUnwrap(model.selectedID)
        let token = model.turn.begin(.generating)
        model.deleteChats([id])
        XCTAssertNotEqual(model.turn.epoch,token)
        model.showHistory(.deleted)
        XCTAssertFalse(model.writableConversation)
        model.draft = "Do not send"
        let count = model.conversation?.messages.count
        model.send(); model.startHelp(); model.toggleRecord()
        XCTAssertEqual(model.conversation?.messages.count,count)
        XCTAssertFalse(model.practice)
        XCTAssertFalse(model.busy)
        model.restoreChats([id])
        model.select(id)
        XCTAssertTrue(model.writableConversation)
    }
    @MainActor func testFailedMutationDoesNotChangeSelectionOrAudio() throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at:root) }
        let model = AppModel(libraryRoot:root)
        let id = try XCTUnwrap(model.selectedID)
        model.save()
        let wav = root.appendingPathComponent("test.wav")
        try Data([1,2]).write(to:wav)
        model.append(Message(role:"user",text:"Audio",audio:"test.wav"),to:id)
        try Data("broken".utf8).write(to:model.store.file)
        model.deleteChats([id])
        XCTAssertEqual(model.selectedID,id)
        XCTAssertFalse(model.conversation!.isDeleted)
        XCTAssertTrue(FileManager.default.fileExists(atPath:wav.path))
        XCTAssertNotNil(model.error)
    }
    @MainActor func testPermanentDeletionKeepsExpressionAudioAndCreatesFreshSource() throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at:root) }
        let model = AppModel(libraryRoot:root)
        let id = try XCTUnwrap(model.selectedID)
        var item = PracticeExpression(conversationID:id,meaning:"",english:"A useful sentence")
        item.reference = "shared.wav"
        model.library.expressions = [item]
        try Data([1]).write(to:root.appendingPathComponent("shared.wav"))
        try Data([2]).write(to:root.appendingPathComponent("chat-only.wav"))
        model.append(Message(role:"user",text:"Hello",audio:"chat-only.wav"),to:id)
        model.deleteChats([id]); model.permanentDeleteIDs = [id]; model.permanentlyDeleteChats()
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("chat-only.wav").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath:root.appendingPathComponent("shared.wav").path))
        XCTAssertEqual(model.library.expressions.count,1)
        // Use an expression without audio to avoid decoding the synthetic fixture.
        item.reference = nil
        model.openExpression(item)
        XCTAssertNotEqual(model.selectedID,id)
        XCTAssertTrue(model.writableConversation)
        XCTAssertTrue(model.conversation?.messages.isEmpty == true)
        model.stop()
    }
    @MainActor func testEmptyNewChatIsReusedAndArchiveRestoreStopsActivity() throws {
        let model = AppModel(libraryRoot:temporary())
        defer { try? FileManager.default.removeItem(at:model.store.root) }
        let first = model.selectedID
        model.newChat(); model.newChat()
        XCTAssertEqual(model.selectedID,first)
        XCTAssertEqual(model.library.conversations.count,1)
        model.draft = "Keep draft"
        model.archiveChats([try XCTUnwrap(first)])
        XCTAssertNil(model.selectedID)
        model.showHistory(.archived)
        XCTAssertEqual(model.draft,"Keep draft")
        XCTAssertFalse(model.writableConversation)
        model.restoreChats([try XCTUnwrap(first)])
        model.showHistory(.active)
        XCTAssertEqual(model.selectedID,first)
        XCTAssertTrue(model.writableConversation)
    }
    @MainActor func testBulkActionsKeepOriginalArchiveStateAndPracticeExpression() throws {
        let model = AppModel(demo:true)
        let source = try XCTUnwrap(model.selectedID)
        let ids = Set(model.library.conversations.map(\.id))
        let other = try XCTUnwrap(ids.first(where:{ $0 != source }))
        model.archiveChats([other])
        // Deleting while practising must preserve the in-progress expression.
        model.deleteChats(ids)
        XCTAssertTrue(model.library.conversations.allSatisfy(\.isDeleted))
        XCTAssertEqual(model.library.expressions.count,1)
        XCTAssertFalse(model.practice)
        model.restoreChats(ids)
        XCTAssertTrue(model.library.conversations.allSatisfy { !$0.isDeleted })
        XCTAssertTrue(model.library.conversations.first(where:{ $0.id == other })!.archived)
        XCTAssertFalse(model.library.conversations.first(where:{ $0.id == source })!.archived)
    }
    private func temporary() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
}
