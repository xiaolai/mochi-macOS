import MochiCore
import MochiTestSupport
import XCTest

@testable import MochiApp

final class HistoryModelTests: XCTestCase {
    @MainActor func testDraftSelectionAndRenameSurviveRelaunch() throws {
        let root = temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeApp(root: root)
        let first = try XCTUnwrap(model.selectedID)
        model.draft = "An unfinished thought"
        model.renameChat(first, title: " My custom title ")
        model.newChat()
        let second = try XCTUnwrap(model.selectedID)
        XCTAssertNotEqual(first, second)
        model.draft = "Second draft"
        model.select(first)
        XCTAssertEqual(model.draft, "An unfinished thought")
        model.append(Message(role: "user", text: "A first real message"), to: first)
        XCTAssertEqual(model.conversation?.title, "My custom title")
        model.save()
        let reopened = makeApp(root: root)
        XCTAssertEqual(reopened.selectedID, first)
        XCTAssertEqual(reopened.draft, "An unfinished thought")
        reopened.select(second)
        XCTAssertEqual(reopened.draft, "Second draft")
    }
    @MainActor func testDeleteCancelsLateReplyAndReadOnlyGuards() throws {
        let model = makeApp(demo: true)
        model.resume()
        let id = try XCTUnwrap(model.selectedID)
        let token = model.turn.begin(.generating)
        model.deleteChats([id])
        XCTAssertNotEqual(model.turn.epoch, token)
        model.showHistory(.deleted)
        XCTAssertFalse(model.writableConversation)
        model.draft = "Do not send"
        let count = model.conversation?.messages.count
        model.send()
        model.startHelp()
        model.toggleRecord()
        XCTAssertEqual(model.conversation?.messages.count, count)
        XCTAssertFalse(model.practice)
        XCTAssertFalse(model.busy)
        model.restoreChats([id])
        model.select(id)
        XCTAssertTrue(model.writableConversation)
    }
    @MainActor func testFailedMutationDoesNotChangeSelectionOrAudio() throws {
        let root = temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeApp(root: root)
        let id = try XCTUnwrap(model.selectedID)
        model.save()
        let wav = root.appendingPathComponent("test.wav")
        try Data([1, 2]).write(to: wav)
        model.append(Message(role: "user", text: "Audio", audio: "test.wav"), to: id)
        try Data("broken".utf8).write(to: model.store.file)
        model.deleteChats([id])
        XCTAssertEqual(model.selectedID, id)
        XCTAssertFalse(model.conversation!.isDeleted)
        XCTAssertTrue(FileManager.default.fileExists(atPath: wav.path))
        XCTAssertNotNil(model.error)
    }
    @MainActor func testPermanentDeletionKeepsExpressionAudioAndCreatesFreshSource() throws {
        let root = temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeApp(root: root)
        let id = try XCTUnwrap(model.selectedID)
        var item = PracticeExpression(conversationID: id, meaning: "", english: "A useful sentence", language: .english)
        item.reference = "shared.wav"
        model.library.expressions = [item]
        try Data([1]).write(to: root.appendingPathComponent("shared.wav"))
        try Data([2]).write(to: root.appendingPathComponent("chat-only.wav"))
        model.append(Message(role: "user", text: "Hello", audio: "chat-only.wav"), to: id)
        model.deleteChats([id])
        model.history.permanentDeleteIDs = [id]
        model.permanentlyDeleteChats()
        // The earlier copy still names the chat's recording, so the launch sweep removes it, not this deletion.
        XCTAssertFalse(model.library.referencedAudio.contains("chat-only.wav"))
        XCTAssertTrue(model.store.previousReferencedAudio().contains("chat-only.wav"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("chat-only.wav").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("shared.wav").path))
        XCTAssertEqual(model.library.expressions.count, 1)
        // Use an expression without audio to avoid decoding the synthetic fixture.
        item.reference = nil
        model.openExpression(item)
        XCTAssertNotEqual(model.selectedID, id)
        XCTAssertTrue(model.writableConversation)
        XCTAssertTrue(model.conversation?.messages.isEmpty == true)
        model.stop()
    }
    @MainActor func testEmptyNewChatIsReusedAndArchiveRestoreStopsActivity() throws {
        let model = makeApp(root: temporary())
        defer { try? FileManager.default.removeItem(at: model.store.root) }
        let first = model.selectedID
        model.newChat()
        model.newChat()
        XCTAssertEqual(model.selectedID, first)
        XCTAssertEqual(model.library.conversations.count, 1)
        model.draft = "Keep draft"
        model.archiveChats([try XCTUnwrap(first)])
        XCTAssertNil(model.selectedID)
        model.showHistory(.archived)
        XCTAssertEqual(model.draft, "Keep draft")
        XCTAssertFalse(model.writableConversation)
        model.restoreChats([try XCTUnwrap(first)])
        model.showHistory(.active)
        XCTAssertEqual(model.selectedID, first)
        XCTAssertTrue(model.writableConversation)
    }
    @MainActor func testBulkActionsKeepOriginalArchiveStateAndPracticeExpression() throws {
        let model = makeApp(demo: true)
        let source = try XCTUnwrap(model.selectedID)
        let ids = Set(model.library.conversations.map(\.id))
        let other = try XCTUnwrap(ids.first(where: { $0 != source }))
        model.archiveChats([other])
        // Deleting while practising must preserve the in-progress expression.
        model.deleteChats(ids)
        XCTAssertTrue(model.library.conversations.allSatisfy(\.isDeleted))
        XCTAssertEqual(model.library.expressions.count, 1)
        XCTAssertFalse(model.practice)
        model.restoreChats(ids)
        XCTAssertTrue(model.library.conversations.allSatisfy { !$0.isDeleted })
        XCTAssertTrue(model.library.conversations.first(where: { $0.id == other })!.archived)
        XCTAssertFalse(model.library.conversations.first(where: { $0.id == source })!.archived)
    }
    private func temporary() -> URL { TestScratch.folder() }
}

extension HistoryModelTests {
    @MainActor func testTheReplacementSelectionFollowsTheCharacterFilter() throws {
        let app = makeApp(root: makeTemporaryFolder())
        var ids: [UUID] = []
        for name in ["Ada", "Bea", "Ada"] {
            if !ids.isEmpty { app.newChat() }
            let id = try XCTUnwrap(app.selectedID)
            app.append(Message(role: "user", text: name), to: id)
            let index = try XCTUnwrap(app.library.conversations.firstIndex { $0.id == id })
            app.library.conversations[index].characterName = name
            ids.append(id)
        }
        app.history.character = "Ada"
        app.select(ids[2])
        app.archiveChats([ids[2]])
        XCTAssertEqual(app.selectedID, ids[0], "The next conversation the filtered list shows, not one it hides")
    }
    @MainActor func testDeletingWhilePractisingKeepsTheEditedThought() throws {
        let model = makeApp(demo: true)
        XCTAssertTrue(model.practice)
        let expressionID = try XCTUnwrap(model.help.expression?.id)
        model.help.meaning = "  An edited thought  "
        model.deleteChats(Set(model.library.conversations.map(\.id)))
        XCTAssertEqual(model.library.expressions.first { $0.id == expressionID }?.meaning, "An edited thought")
    }
    @MainActor func testAnAttemptNeedsASentenceToPractise() throws {
        let model = makeApp(demo: true)
        XCTAssertTrue(model.practice)
        model.editEnglish("   ")
        XCTAssertFalse(model.canRecordAttempt)
        model.toggleRecord()
        XCTAssertEqual(model.turn.activity, .idle, "No recording starts without a sentence")
    }
    @MainActor func testArchivingTheSelectedChatSavesTheReplacementSelection() throws {
        let root = makeTemporaryFolder()
        let app = makeApp(root: root)
        let first = try XCTUnwrap(app.selectedID)
        app.append(Message(role: "user", text: "First"), to: first)
        app.newChat()
        let second = try XCTUnwrap(app.selectedID)
        app.append(Message(role: "user", text: "Second"), to: second)
        app.select(first)
        app.archiveChats([first])
        XCTAssertEqual(app.selectedID, second)
        XCTAssertEqual(makeApp(root: root).selectedID, second)
    }

    /// An active-collection search also lists archived conversations, so bulk actions follow each one's state.
    @MainActor func testSelectionActionsSplitArchivedFromActiveConversations() {
        var library = Library()
        let active = Conversation(title: "Active")
        var archived = Conversation(title: "Archived")
        archived.archived = true
        var deleted = Conversation(title: "Deleted")
        deleted.deletedAt = Date()
        library.conversations = [active, archived, deleted]
        XCTAssertEqual(
            library.history(in: .active, query: "e").map(\.id).sorted { $0.uuidString < $1.uuidString },
            [active.id, archived.id].sorted { $0.uuidString < $1.uuidString })

        let mixed = HistorySelectionActions.targets([active.id, archived.id, deleted.id], in: library)
        XCTAssertEqual(mixed.archive, [active.id])
        XCTAssertEqual(mixed.restore, [archived.id])

        let onlyArchived = HistorySelectionActions.targets([archived.id], in: library)
        XCTAssertTrue(onlyArchived.archive.isEmpty)
        XCTAssertEqual(onlyArchived.restore, [archived.id])

        let none = HistorySelectionActions.targets([], in: library)
        XCTAssertTrue(none.archive.isEmpty && none.restore.isEmpty)
    }

    @MainActor func testPermanentDeletionKeepsTheRecordingHeldForUndo() throws {
        let root = makeTemporaryFolder()
        let app = makeApp(root: root)
        let selected = try XCTUnwrap(app.selectedID)
        let other = Conversation(title: "Other")
        app.library.conversations.append(other)
        let url = root.appendingPathComponent("shared.wav")
        try Data([1]).write(to: url)
        let message = Message(role: "user", text: "Mine", audio: "shared.wav")
        app.append(message, to: selected)
        app.append(Message(role: "user", text: "Theirs", audio: "shared.wav"), to: other.id)
        app.deleteMessage(message.id)
        app.deleteChats([other.id])
        app.history.permanentDeleteIDs = [other.id]
        app.permanentlyDeleteChats()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        app.undoMessageDeletion()
        XCTAssertEqual(app.conversation?.messages.first?.audio, "shared.wav")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    @MainActor func testRestoringTheEarlierCopyShowsTheScopeOfTheSelectedChat() throws {
        let root = makeTemporaryFolder()
        let first = makeApp(root: root)
        let id = try XCTUnwrap(first.selectedID)
        first.append(Message(role: "user", text: "Archived words"), to: id)
        first.archiveChats([id])
        first.showHistory(.archived)
        XCTAssertEqual(first.selectedID, id)
        first.save()
        try Data("damaged".utf8).write(to: root.appendingPathComponent("library.json"))
        let app = makeApp(root: root)
        XCTAssertTrue(app.canRestorePreviousLibrary)
        app.restorePreviousLibrary()
        XCTAssertEqual(app.selectedID, id)
        XCTAssertEqual(app.history.scope, .archived)
    }
}
