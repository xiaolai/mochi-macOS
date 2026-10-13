import MochiKernel
import MochiTestSupport
import XCTest

@testable import MochiCore

/// Version 4 adds characters and each setup's personality, greeting, phrases and voice. Older Mochi refuses it, so
/// the bytes from before the upgrade are kept, once, wherever an older library is about to be replaced.
final class LibraryVersionFourTests: XCTestCase {
    private func folder() -> URL { TestScratch.folder() }
    /// A library as Mochi 0.7 wrote it: version 3, none of the version-4 keys.
    private func versionThree(title: String = "Old", audio: String? = nil, pending: Bool = false) -> Data {
        let message =
            audio.map {
                #"{"id":"\#(UUID())","role":"user","text":"","audio":"\#($0)","date":0\#(pending ? #","transcriptionState":"pending""# : "")}"#
            } ?? ""
        return Data(
            #"{"version":3,"conversations":[{"id":"\#(UUID())","title":"\#(title)","messages":[\#(message)],"date":0,"instructions":"Be brief","preferences":{"coaching":"gentle"}}],"expressions":[],"conversationTemplates":[]}"#
                .utf8)
    }
    private func versionTwo() -> Data {
        Data(
            #"{"version":2,"conversations":[{"id":"\#(UUID())","title":"Older","messages":[],"date":0}],"expressions":[]}"#
                .utf8)
    }
    private func backups(_ root: URL, _ prefix: String) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(prefix) }
    }
    private let v4 = LibraryStore.characterLibraryBackupPrefix
    private let v3 = "library-before-character-templates-v3"

    func testVersionThreeKeepsItsBytesOnceBeforeItsFirstVersionFourSave() throws {
        let root = folder()
        let store = LibraryStore(root: root)
        try store.prepare()
        let original = versionThree()
        try original.write(to: store.file)
        let loaded = try store.load()
        XCTAssertEqual(loaded.version, Library.currentVersion)
        XCTAssertEqual(loaded.conversations[0].instructions, "Be brief")
        XCTAssertEqual(loaded.conversations[0].preferences.coaching, .gentle)
        XCTAssertEqual(loaded.conversations[0].personality, "")
        XCTAssertTrue(loaded.characters.isEmpty)
        try store.save(loaded)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("\(v4).json")), original)
        XCTAssertEqual(
            (try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("\(v4).json").path)[
                .posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try backups(root, v3), [], "Version 3 already has templates: no v3 copy")
        XCTAssertEqual(
            try JSONDecoder().decode(Library.self, from: Data(contentsOf: store.file)).version, Library.currentVersion)
        try store.save(try store.load())
        XCTAssertEqual(try backups(root, v4).count, 1, "Later saves add no copies")
    }

    /// Each upgrade's threshold is historical: version 1 and 2 libraries already keep their bytes in the v3 copy.
    func testVersionsOneAndTwoKeepOnlyTheirVersionThreeCopy() throws {
        for original in [
            versionTwo(),
            Data(
                #"{"version":1,"conversations":[{"id":"\#(UUID())","title":"Old","messages":[],"date":0}],"expressions":[]}"#
                    .utf8),
        ] {
            let root = folder()
            let store = LibraryStore(root: root)
            try store.prepare()
            try original.write(to: store.file)
            try store.save(try store.load())
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("\(v3).json")), original)
            XCTAssertEqual(try backups(root, v4), [])
        }
    }

    func testADifferentVersionThreeCopyGetsItsOwnBackup() throws {
        let root = folder()
        let store = LibraryStore(root: root)
        try store.prepare()
        let first = versionThree(title: "First")
        try first.write(to: store.file)
        try store.save(try store.load())
        // An older Mochi, given back the first copy, wrote version 3 again.
        let second = versionThree(title: "Second")
        try second.write(to: store.file)
        try store.save(try store.load())
        let kept = try backups(root, v4)
        XCTAssertEqual(kept.count, 2)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("\(v4).json")), first)
        XCTAssertTrue(try kept.contains { try Data(contentsOf: $0) == second })
    }

    func testAFailedBackupBlocksTheSave() throws {
        let root = folder()
        let store = LibraryStore(root: root)
        try store.prepare()
        let original = versionThree()
        try original.write(to: store.file)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("\(v4).json"), withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.save(try store.load()))
        XCTAssertEqual(try Data(contentsOf: store.file), original)
    }

    func testAFutureVersionIsRefusedAndLeftUntouched() throws {
        let root = folder()
        let store = LibraryStore(root: root)
        try store.prepare()
        let future = Data(#"{"version":\#(Library.currentVersion + 1),"conversations":[],"expressions":[]}"#.utf8)
        try future.write(to: store.file)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.save(Library()))
        XCTAssertEqual(try Data(contentsOf: store.file), future)
    }

    /// Restore Earlier Copy makes the earlier copy the library. Its own bytes get the backup any upgrade keeps, so a
    /// later save, which replaces `library.previous.json`, cannot lose an older format's original.
    func testRestoringAnEarlierCopyKeepsItsOriginalBytes() throws {
        let cases: [(Data, String)] = [
            (versionThree(audio: "recording-\(UUID().uuidString).wav", pending: true), v4),
            (versionTwo(), v3),
        ]
        for (original, prefix) in cases {
            let root = folder()
            let store = LibraryStore(root: root)
            try store.prepare()
            try Data("not a library".utf8).write(to: store.file)
            try original.write(to: store.previousFile)
            let restored = try store.restorePrevious()
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("\(prefix).json")), original, prefix)
            try store.save(restored)
            try store.save(restored)
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("\(prefix).json")), original, prefix)
            XCTAssertNotEqual(try Data(contentsOf: store.previousFile), original)
            XCTAssertEqual(try backups(root, "library-unreadable-").count, 1)
        }
    }

    func testRestoreChangesNothingWhenTheBackupFails() throws {
        let root = folder()
        let store = LibraryStore(root: root)
        try store.prepare()
        let broken = Data("not a library".utf8)
        try broken.write(to: store.file)
        try versionThree().write(to: store.previousFile)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("\(v4).json"), withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.restorePrevious())
        XCTAssertEqual(try Data(contentsOf: store.file), broken)
        XCTAssertEqual(try backups(root, "library-unreadable-"), [])
    }

    /// The v4 backups end in `.json`; a recording never does. An older library that names a recording with the same
    /// prefix still opens and still imports.
    func testOnlyNamesLikeTheBackupsThemselvesAreRefused() throws {
        let root = folder()
        let store = LibraryStore(root: root)
        try store.prepare()
        let name = "\(v4)-example.wav"
        try Data([1, 2, 3]).write(to: root.appendingPathComponent(name))
        try versionThree(audio: name).write(to: store.file)
        let loaded = try store.load()
        XCTAssertEqual(loaded.referencedAudio, [name])
        let package = folder().appendingPathComponent("backup.mochilibrary")
        try LibraryBackup.write(loaded, from: root, to: package)
        var local = Library()
        XCTAssertEqual(
            try LibraryBackup.merge(try LibraryBackup.read(package), from: package, into: &local, root: folder()), 1)

        for unsafe in ["\(v4).json", "\(v4)-1-\(UUID().uuidString).json"] {
            var library = Library()
            var chat = Conversation()
            chat.messages = [Message(role: "user", text: "", audio: unsafe)]
            library.conversations = [chat]
            XCTAssertThrowsError(try library.validate(), unsafe)
        }
    }

    func testCharacterIDsMustBeUniqueAndNeverBuiltin() {
        var library = Library()
        let rose = ConversationCharacter(name: "Rose")
        library.characters = [rose, rose]
        XCTAssertThrowsError(try library.validate())
        library.characters = [ConversationCharacter.builtins[1]]
        XCTAssertThrowsError(try library.validate())
        var blank = rose
        blank.revision = ""
        library.characters = [blank]
        XCTAssertThrowsError(try library.validate())
        library.characters = [rose]
        XCTAssertNoThrow(try library.validate())
    }

    /// Everything version 4 adds survives the library file and a backup, including a voice this version does not
    /// know, which is kept as stored.
    func testEveryNewSettingSurvivesTheFileAndABackup() throws {
        var library = Library()
        library.characters = [
            ConversationCharacter(name: "Rose", description: "Patient", personality: "Kind", voice: "sage"),
            ConversationCharacter(name: "Nova", voice: "future_voice"),
        ]
        var chat = Conversation(title: "Story")
        chat.personality = "Wry"
        chat.greeting = "Where does it begin?"
        chat.phrases = ["Add a twist."]
        chat.preferences.voice = "future_voice"
        library.conversations = [chat]
        var template = ConversationTemplate(title: "Story time", instructions: "Tell stories")
        template.personality = "Bright"
        template.greeting = "Ready?"
        template.phrases = ["Again."]
        template.preferences.voice = "coral"
        library.conversationTemplates = [template]

        let root = folder()
        let store = LibraryStore(root: root)
        try store.save(library)
        func check(_ restored: Library, _ label: String) {
            XCTAssertEqual(restored.characters, library.characters, label)
            XCTAssertEqual(restored.conversationTemplates, library.conversationTemplates, label)
            let c = restored.conversations.first { $0.id == chat.id }
            XCTAssertEqual(c?.personality, "Wry", label)
            XCTAssertEqual(c?.greeting, "Where does it begin?", label)
            XCTAssertEqual(c?.phrases, ["Add a twist."], label)
            XCTAssertEqual(c?.preferences.voice, "future_voice", label)
        }
        check(try store.load(), "library file")
        let package = folder().appendingPathComponent("backup.mochilibrary")
        try LibraryBackup.write(library, from: root, to: package)
        let read = try LibraryBackup.read(package)
        XCTAssertEqual(read.version, Library.currentVersion)
        check(read, "backup")
        var local = Library()
        _ = try LibraryBackup.merge(read, from: package, into: &local, root: folder())
        check(local, "merged")
    }

    func testImportKeepsLocalCharactersAndRefusesBuiltinOnes() throws {
        let root = folder()
        var mine = ConversationCharacter(name: "Rose")
        var imported = Library()
        var theirs = mine
        theirs.name = "Rose from elsewhere"
        imported.characters = [theirs, ConversationCharacter(name: "Nova")]
        let package = folder().appendingPathComponent("backup.mochilibrary")
        try LibraryBackup.write(imported, from: root, to: package)
        var local = Library()
        mine.description = "Mine"
        local.characters = [mine]
        _ = try LibraryBackup.merge(try LibraryBackup.read(package), from: package, into: &local, root: root)
        XCTAssertEqual(local.characters.map(\.name), ["Rose", "Nova"])
        XCTAssertEqual(local.characters[0].description, "Mine")
        var bad = Library()
        bad.characters = [ConversationCharacter.builtins[0]]
        var untouched = Library()
        XCTAssertThrowsError(try LibraryBackup.merge(bad, from: root, into: &untouched, root: root))
        XCTAssertTrue(untouched.characters.isEmpty)
    }
}
