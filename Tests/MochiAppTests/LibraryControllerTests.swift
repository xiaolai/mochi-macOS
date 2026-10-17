import MochiCore
import XCTest

@testable import MochiApp

final class LibraryControllerTests: XCTestCase {
    @MainActor func testControllerOpensSavesAndDebouncesWithoutTheAppModel() async throws {
        let root = makeTemporaryFolder()
        let controller = LibraryController(root: root, demo: false)
        var reports: [String] = []
        controller.report = { reports.append($0) }
        var opened = false
        controller.open(managedIn: nil, isolated: true) { opened = true }
        XCTAssertTrue(opened)
        XCTAssertTrue(controller.readable)
        let chat = Conversation(title: "Saved")
        controller.selection = { chat.id }
        controller.library.conversations = [chat]
        XCTAssertTrue(controller.save())
        XCTAssertEqual(try LibraryStore(root: root).load().selectedConversationID, chat.id)
        controller.saveDelay = 20_000_000
        let revision = controller.revision
        for draft in ["H", "He", "Hel"] {
            controller.updateQuietly { $0.conversations[0].draft = draft }
            controller.scheduleSave()
        }
        XCTAssertEqual(controller.revision, revision)
        await waitUntil { !controller.hasPendingSave }
        XCTAssertEqual(try LibraryStore(root: root).load().conversations[0].draft, "Hel")
        XCTAssertTrue(reports.isEmpty)
    }

    @MainActor func testUnreadableLibraryRefusesCommits() throws {
        let root = makeTemporaryFolder()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("damaged".utf8).write(to: root.appendingPathComponent("library.json"))
        let controller = LibraryController(root: root, demo: false)
        var reports: [String] = []
        controller.report = { reports.append($0) }
        controller.open(managedIn: nil, isolated: true) {}
        XCTAssertFalse(controller.readable)
        XCTAssertEqual(reports.count, 1)
        XCTAssertThrowsError(try controller.commit(Library()))
        XCTAssertFalse(controller.save())
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("library.json")), "damaged")
    }

    @MainActor func testAMissingLibraryWithAnEarlierCopyRefusesWritesUntilItIsRestored() throws {
        let root = makeTemporaryFolder()
        let store = LibraryStore(root: root)
        var kept = Library()
        kept.conversations = [Conversation(title: "Kept")]
        try store.save(kept)
        try store.save(kept)
        try FileManager.default.removeItem(at: store.file)
        let controller = LibraryController(root: root, demo: false)
        var reports: [String] = []
        controller.report = { reports.append($0) }
        controller.open(managedIn: nil, isolated: true) {}
        XCTAssertFalse(controller.readable)
        XCTAssertTrue(controller.canRestorePrevious)
        XCTAssertEqual(reports.count, 1)
        XCTAssertThrowsError(try controller.commit(Library()))
        XCTAssertFalse(controller.save())
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.file.path))
        XCTAssertFalse(try controller.restorePrevious(), "A missing library leaves no file to set aside")
        XCTAssertTrue(controller.readable)
        XCTAssertEqual(controller.library.conversations.map(\.title), ["Kept"])
        XCTAssertEqual(try LibraryStore(root: root).load().conversations.map(\.title), ["Kept"])
    }

    @MainActor func testOnlyOneTransferRunsAndItIsClaimedImmediately() async throws {
        let root = makeTemporaryFolder()
        let controller = LibraryController(root: root, demo: false)
        controller.open(managedIn: nil, isolated: true) {}
        let package = makeTemporaryFolder().appendingPathComponent("Backup.mochilibrary")
        try FileManager.default.createDirectory(
            at: package.deletingLastPathComponent(), withIntermediateDirectories: true)
        let first = try XCTUnwrap(controller.exportBackup(to: package))
        XCTAssertNotNil(controller.transfer)
        XCTAssertNil(controller.exportBackup(to: package.appendingPathExtension("second")))
        XCTAssertNil(controller.importBackup(from: package))
        let omitted = try await first.value
        XCTAssertEqual(omitted, [])
        XCTAssertNil(controller.transfer)
    }
}
