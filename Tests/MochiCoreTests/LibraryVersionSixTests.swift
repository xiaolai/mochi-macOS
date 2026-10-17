import MochiKernel
import MochiTestSupport
import XCTest

@testable import MochiCore

/// Version 6 adds Recently Deleted for templates: a template an assistant deletes keeps its place in the library with
/// the time it was deleted. Older Mochi refuses it, so the bytes of a version-5 library are kept, once, before its
/// first version-6 save.
final class LibraryVersionSixTests: XCTestCase {
    private func folder() -> URL { TestScratch.folder() }
    private let v6 = LibraryStore.templateRecoveryLibraryBackupPrefix
    /// A library as Mochi 0.9.10 wrote it: version 5, with a user template and none of the version-6 keys.
    private func versionFive(title: String = "Old") -> Data {
        Data(
            #"{"version":5,"conversations":[{"id":"\#(UUID())","title":"\#(title)","messages":[],"date":0}],"expressions":[],"conversationTemplates":[{"id":"\#(UUID())","revision":"\#(UUID())","title":"Mine","description":"","instructions":"Discuss","preferences":{},"createdAt":0,"updatedAt":0}],"characters":[]}"#
                .utf8)
    }
    private func backups(_ root: URL, _ prefix: String) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(prefix) }
    }

    func testVersionFiveKeepsItsBytesOnceBeforeItsFirstVersionSixSave() throws {
        let root = folder()
        let store = LibraryStore(root: root)
        try store.prepare()
        let original = versionFive()
        try original.write(to: store.file)
        let loaded = try store.load()
        XCTAssertNil(loaded.conversationTemplates[0].deletedAt, "Older formats decode the new field as nil")
        try store.save(loaded)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("\(v6).json")), original)
        XCTAssertEqual(
            (try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("\(v6).json").path)[
                .posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try JSONDecoder().decode(Library.self, from: Data(contentsOf: store.file)).version, 6)
        try store.save(try store.load())
        XCTAssertEqual(try backups(root, v6).count, 1, "Later saves add no copies")
        XCTAssertEqual(try backups(root, LibraryStore.reviewLibraryBackupPrefix), [])
    }
    func testOlderVersionsKeepOnlyTheirOwnUpgradeCopy() throws {
        let root = folder()
        let store = LibraryStore(root: root)
        try store.prepare()
        let four = Data(
            #"{"version":4,"conversations":[],"expressions":[],"conversationTemplates":[],"characters":[]}"#.utf8)
        try four.write(to: store.file)
        try store.save(try store.load())
        XCTAssertEqual(
            try Data(contentsOf: root.appendingPathComponent("\(LibraryStore.reviewLibraryBackupPrefix).json")), four)
        XCTAssertEqual(try backups(root, v6), [], "The version-6 threshold is version 5 only")
    }
    func testADifferentVersionFiveCopyGetsItsOwnBackup() throws {
        let root = folder()
        let store = LibraryStore(root: root)
        try store.prepare()
        let first = versionFive(title: "First")
        try first.write(to: store.file)
        try store.save(try store.load())
        let second = versionFive(title: "Second")
        try second.write(to: store.file)
        try store.save(try store.load())
        let kept = try backups(root, v6)
        XCTAssertEqual(kept.count, 2)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("\(v6).json")), first)
        XCTAssertTrue(try kept.contains { try Data(contentsOf: $0) == second })
    }
    func testRestoringAVersionFiveEarlierCopyKeepsItsOriginalBytes() throws {
        let root = folder()
        let store = LibraryStore(root: root)
        try store.prepare()
        try Data("not a library".utf8).write(to: store.file)
        let original = versionFive()
        try original.write(to: store.previousFile)
        try store.save(try store.restorePrevious())
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("\(v6).json")), original)
    }
    func testRecordingsNamedLikeTheBackupAreRefused() {
        for unsafe in ["\(v6).json", "\(v6)-1-\(UUID().uuidString).json", "\(v6.uppercased()).JSON"] {
            var library = Library()
            var chat = Conversation()
            chat.messages = [Message(role: "user", text: "", audio: unsafe)]
            library.conversations = [chat]
            XCTAssertThrowsError(try library.validate(), unsafe)
        }
    }
    func testADeletedTemplateSurvivesTheFileABackupAndAnImport() throws {
        let root = folder()
        let store = LibraryStore(root: root)
        try store.prepare()
        var library = Library()
        var template = ConversationTemplate(title: "Mine", instructions: "Discuss")
        let deleted = Date(timeIntervalSince1970: 1_800_000_000)
        template.deletedAt = deleted
        library.conversationTemplates = [template, ConversationTemplate(title: "Kept", instructions: "Talk")]
        try store.save(library)
        let loaded = try store.load()
        XCTAssertEqual(loaded.conversationTemplates.map(\.deletedAt), [deleted, nil])

        let package = folder().appendingPathComponent("backup.mochilibrary")
        try LibraryBackup.write(loaded, from: root, to: package)
        let read = try LibraryBackup.read(package)
        XCTAssertEqual(read.conversationTemplates.map(\.deletedAt), [deleted, nil])
        var local = Library()
        _ = try LibraryBackup.merge(read, from: package, into: &local, root: folder())
        XCTAssertEqual(local.conversationTemplates.map(\.deletedAt), [deleted, nil])
    }
    /// A built-in's revision hashes its encoding, so the new field is written only when set and no revision moves.
    func testTemplatesInTheCatalogEncodeWithoutTheNewField() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for template in ConversationTemplate.builtins + [ConversationTemplate(title: "Mine", instructions: "Talk")] {
            XCTAssertFalse(String(decoding: try encoder.encode(template), as: UTF8.self).contains("deletedAt"))
        }
        XCTAssertEqual(
            ConversationTemplate.builtins[0].revision.count, 64, "Built-in revisions are still SHA-256 digests")
    }
}
