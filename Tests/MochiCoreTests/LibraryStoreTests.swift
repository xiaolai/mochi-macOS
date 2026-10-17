import Darwin
import MochiKernel
import MochiTestSupport
import XCTest

@testable import MochiCore

final class LibraryStoreTests: XCTestCase {
    func testPersistenceRoundTripAndCorruptionDoesNotOverwrite() throws {
        let root = TestScratch.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root)
        var library = Library()
        library.conversations = [Conversation(title: "Test")]
        try store.save(library)
        XCTAssertEqual(try store.load().conversations.first?.title, "Test")
        try Data("broken".utf8).write(to: store.file)
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try String(contentsOf: store.file), "broken")
    }

    func testFutureLibraryVersionIsPreserved() throws {
        let root = TestScratch.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root)
        var library = Library()
        library.version = Library.currentVersion + 1
        try store.prepare()
        try JSONEncoder().encode(library).write(to: store.file)
        let before = try Data(contentsOf: store.file)
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try Data(contentsOf: store.file), before)
    }

    func testUnchangedLibraryIsNotReReadButAnExternalChangeIs() throws {
        let root = temporary()
        let store = LibraryStore(root: root)
        var library = Library()
        library.conversations = [Conversation(title: "First")]
        // A new library settles its one-time upgrade copies on the second save.
        try store.save(library)
        try store.save(library)
        // A file Mochi wrote itself is replaced without being read, even when it is unreadable.
        XCTAssertEqual(chmod(store.file.path, 0), 0)
        library.conversations[0].title = "Second"
        XCTAssertNoThrow(try store.save(library))
        XCTAssertEqual(try store.load().conversations[0].title, "Second")
        // A file changed by someone else is read first, and an unreadable one is never overwritten.
        try Data("not a library".utf8).write(to: store.file)
        XCTAssertThrowsError(try store.save(library))
        XCTAssertEqual(try String(contentsOf: store.file), "not a library")
    }

    func testSaveLeavesNoStagingFilesAndWritesPrivately() throws {
        let root = temporary()
        let store = LibraryStore(root: root)
        var library = Library()
        library.conversations = [Conversation()]
        try store.save(library)
        try store.save(library)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".") })
        XCTAssertEqual(
            (try FileManager.default.attributesOfItem(atPath: store.file.path)[.posixPermissions] as? NSNumber)?
                .intValue, 0o600)
    }

    func testLargeLibrarySaveCost() throws {
        let root = temporary()
        let store = LibraryStore(root: root)
        var library = Library()
        library.conversations = (0..<100).map { n in
            var chat = Conversation(title: "Conversation \(n)")
            chat.messages = (0..<50).map {
                Message(
                    role: $0.isMultiple(of: 2) ? "user" : "assistant",
                    text: "Message \($0) in a realistic sentence of moderate length.")
            }
            return chat
        }
        try store.save(library)
        measure { try? store.save(library) }
    }

    func testInvalidInMemoryLibraryIsReportedAsAnInvariantViolation() throws {
        let root = temporary()
        let store = LibraryStore(root: root)
        let chat = Conversation()
        var library = Library()
        library.conversations = [chat, chat]
        XCTAssertThrowsError(try store.save(library)) { error in
            XCTAssertTrue((error as? AppFailure)?.underlying is LibraryInvariantViolation)
        }
    }

    func testEarlierCopyIsKeptAndRestoreSetsTheUnreadableFileAside() throws {
        let root = temporary()
        let store = LibraryStore(root: root)
        var library = Library()
        library.conversations = [Conversation(title: "Kept")]
        try store.save(library)
        library.conversations[0].title = "Latest"
        try store.save(library)
        XCTAssertEqual(try store.loadPrevious().conversations[0].title, "Kept")
        try Data("damaged".utf8).write(to: store.file)
        XCTAssertThrowsError(try LibraryStore(root: root).load())
        let restored = try LibraryStore(root: root).restorePrevious()
        XCTAssertEqual(restored.conversations[0].title, "Kept")
        XCTAssertEqual(try LibraryStore(root: root).load().conversations[0].title, "Kept")
        let aside = try FileManager.default.contentsOfDirectory(atPath: root.path).filter {
            $0.hasPrefix("library-unreadable-")
        }
        XCTAssertEqual(aside.count, 1)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(aside[0])), "damaged")
    }

    func testRecoveryFileNamesAreNeverRecordingNames() {
        for name in ["library.previous.json", "library-unreadable-1-x.json"] {
            var library = Library()
            var chat = Conversation()
            chat.messages = [Message(role: "user", text: "", audio: name)]
            library.conversations = [chat]
            XCTAssertThrowsError(try library.validate(), name)
        }
    }

    func testReservedNamesAreRefusedInAnyCase() {
        // Volumes are case-insensitive by default: these name the library and its backups.
        let reserved = [
            "LIBRARY.JSON", "Library.Previous.json", "library-before-review-v5.JSON",
            "Library-Before-Character-Library-v4-1.json", "LIBRARY-UNREADABLE-1-x.json",
        ]
        for name in reserved {
            var library = Library()
            var chat = Conversation()
            chat.messages = [Message(role: "user", text: "", audio: name)]
            library.conversations = [chat]
            XCTAssertThrowsError(try library.validate(), name)
        }
        var library = Library()
        var chat = Conversation()
        chat.messages = [Message(role: "user", text: "", audio: "Recording-1.WAV")]
        library.conversations = [chat]
        XCTAssertNoThrow(try library.validate(), "An ordinary capitalised recording name is fine")
    }

    func testEarlierCopyNeverRestoresPendingTranscriptions() throws {
        let root = try folder()
        let store = LibraryStore(root: root)
        try store.save(voiceLibrary("recording-\(UUID()).wav", state: .pending))
        try store.save(Library())
        XCTAssertEqual(try store.loadPrevious().conversations[0].messages[0].transcriptionState, .interrupted)
        try Data("damaged".utf8).write(to: store.file)
        let restored = try LibraryStore(root: root).restorePrevious()
        XCTAssertEqual(restored.conversations[0].messages[0].transcriptionState, .interrupted)
    }

    func testRestoreThatCannotSetTheFileAsideChangesNothing() throws {
        let root = try folder()
        let store = LibraryStore(root: root)
        try store.save(Library())
        try store.save(Library())
        try Data("damaged".utf8).write(to: store.file)
        XCTAssertEqual(chmod(root.path, 0o500), 0)
        defer { chmod(root.path, 0o700) }
        XCTAssertThrowsError(try LibraryStore(root: root).restorePrevious())
        XCTAssertEqual(chmod(root.path, 0o700), 0)
        XCTAssertEqual(try String(contentsOf: store.file), "damaged")
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: root.path).contains {
                $0.hasPrefix("library-unreadable-")
            })
    }

    func testCleanupKeepsRecordingsTheEarlierCopyNeeds() throws {
        let root = try folder()
        let store = LibraryStore(root: root)
        let kept = "recording-\(UUID()).wav"
        try Data([1]).write(to: root.appendingPathComponent(kept))
        try store.save(voiceLibrary(kept))
        try store.save(Library())
        try store.cleanupOrphanedAudio(Library())
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(kept).path))
    }

    func testCleanupKeepsRecordingsAnUnreadableLibraryNames() throws {
        let root = try folder()
        let recording = "recording-\(UUID()).wav"
        let reply = "reply-\(UUID()).wav"
        let imported = LibraryStore.importedAudioName(extension: "mp3")
        let orphan = "recording-\(UUID()).wav"
        for name in [recording, reply, imported, orphan] { try Data([1]).write(to: root.appendingPathComponent(name)) }
        // Set aside by Restore Earlier Copy and kept for recovery; damaged, so it is searched rather than decoded.
        let unreadable =
            #"{"conversations":[{"messages":[{"audio":"\#(recording)"},{"audio" : "\#(reply)"},"#
            + #"{"audio":"\#(imported)"}"#
        try Data(unreadable.utf8).write(to: root.appendingPathComponent("library-unreadable-1-\(UUID()).json"))
        try LibraryStore(root: root).cleanupOrphanedAudio(Library(), now: Date(timeIntervalSinceNow: 30 * 86400))
        for name in [recording, reply, imported] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path), name)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(orphan).path))
    }

    func testCleanupRemovesExportStagingLeftByAForceQuit() throws {
        let root = try folder()
        let staging = root.appendingPathComponent("\(LibraryStore.exportStagingPrefix)\(UUID())")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        try Data([1]).write(to: staging.appendingPathComponent("recording-\(UUID()).wav"))
        try LibraryStore(root: root).cleanupOrphanedAudio(Library())
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
    }

    func testUnusedGeneratedAudioIsRemovedOnlyAfterItsCacheLifetime() throws {
        let root = try folder()
        let store = LibraryStore(root: root)
        let hash = String(repeating: "a", count: 64)
        let other = String(repeating: "b", count: 64)
        // Old and unreferenced caches are removed; a recent cache is kept; an abandoned take goes at once;
        // names Mochi does not generate are never touched.
        let oldCaches = ["builtin-\(hash).wav", "elevenlabs-\(hash).mp3", "import-\(UUID().uuidString).m4a"]
        let recentCache = "builtin-\(other).wav"
        let abandonedTake = "recording-\(UUID().uuidString).wav"
        let foreign = ["builtin-short.wav", "notes.txt", "reference-old.mp3"]
        let files = oldCaches + [recentCache, abandonedTake] + foreign
        for name in files { try Data([1]).write(to: root.appendingPathComponent(name)) }
        for name in oldCaches + foreign { try age(root.appendingPathComponent(name), days: 8) }
        let referenced = "builtin-\(String(repeating:"c",count:64)).wav"
        try Data([1]).write(to: root.appendingPathComponent(referenced))
        try age(root.appendingPathComponent(referenced), days: 30)
        var library = Library()
        var chat = Conversation()
        chat.messages = [Message(role: "assistant", text: "Hi", audio: referenced)]
        library.conversations = [chat]
        try store.cleanupOrphanedAudio(library)
        let remaining = Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
        XCTAssertEqual(
            remaining, Set(["builtin-\(other).wav", "builtin-short.wav", "notes.txt", "reference-old.mp3", referenced]))
    }

    func testPreInstructionsBackupAndConservativeOrphanSweep() throws {
        let root = TestScratch.folder("mochi-library")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root)
        try store.prepare()
        var library = Library()
        library.conversations = [Conversation()]
        let data = try JSONEncoder().encode(library)
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var chats = object["conversations"] as! [[String: Any]]
        chats[0].removeValue(forKey: "instructions")
        chats[0].removeValue(forKey: "preferences")
        object["conversations"] = chats
        let legacy = try JSONSerialization.data(withJSONObject: object)
        try legacy.write(to: store.file)
        library.conversations[0].instructions = "Interview me"
        try store.save(library)
        XCTAssertEqual(
            try Data(contentsOf: root.appendingPathComponent("library-before-conversation-instructions.json")), legacy)
        let orphan = "reply-\(UUID()).wav"
        let referenced = "recording-\(UUID()).wav"
        let unknown = "recording-manual.wav"
        for name in [orphan, referenced, unknown] { try Data([1]).write(to: root.appendingPathComponent(name)) }
        library.conversations[0].messages = [Message(role: "user", text: "Keep", audio: referenced)]
        try store.cleanupOrphanedAudio(library)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(orphan).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(referenced).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(unknown).path))
    }

    private func temporary() -> URL {
        let url = TestScratch.folder("mochi-persistence")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testALinkedLibraryIsNeitherOpenedNorReplaced() throws {
        let root = try folder()
        let elsewhere = try folder().appendingPathComponent("real-library.json")
        let real = LibraryStore(root: elsewhere.deletingLastPathComponent())
        try real.save(voiceLibrary("recording-\(UUID()).wav"))
        try FileManager.default.moveItem(at: real.file, to: elsewhere)
        try FileManager.default.createSymbolicLink(at: LibraryStore(root: root).file, withDestinationURL: elsewhere)
        let before = try Data(contentsOf: elsewhere)
        let store = LibraryStore(root: root)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.save(Library()))
        XCTAssertThrowsError(try store.restorePrevious())
        let kind = try FileManager.default.attributesOfItem(atPath: store.file.path)[.type] as? FileAttributeType
        XCTAssertEqual(kind, .typeSymbolicLink, "The link was not replaced")
        XCTAssertEqual(try Data(contentsOf: elsewhere), before)
    }

    func testImportedRecordingNamesAreClassifiedWithOrWithoutAnExtension() {
        let id = UUID().uuidString
        XCTAssertEqual(LibraryStore.generatedAudio("import-\(id).wav"), .cache)
        XCTAssertEqual(LibraryStore.generatedAudio("import-\(id)"), .cache)
        XCTAssertEqual(LibraryStore.generatedAudio("import-\(id)."), .cache, "the name an older import produced")
        XCTAssertNil(LibraryStore.generatedAudio("import-\(id).a.b"))
        XCTAssertNil(LibraryStore.generatedAudio("import-not-a-uuid.wav"))
        // Every name an import is given is one the classifier recognises, with or without an extension.
        for ext in ["mp3", ""] {
            let name = LibraryStore.importedAudioName(extension: ext)
            XCTAssertFalse(name.hasSuffix("."), name)
            XCTAssertEqual(LibraryStore.generatedAudio(name), .cache, name)
        }
    }

    func testAnEarlierCopyThatBecomesReadableAgainProtectsItsRecordings() throws {
        let root = try folder()
        let store = LibraryStore(root: root)
        let name = "recording-\(UUID()).wav"
        try store.save(voiceLibrary(name))
        try store.save(Library())
        XCTAssertEqual(chmod(store.previousFile.path, 0o000), 0)
        defer { chmod(store.previousFile.path, 0o600) }
        XCTAssertEqual(store.previousReferencedAudio(), [], "An unreadable copy protects nothing")
        XCTAssertEqual(chmod(store.previousFile.path, 0o600), 0)
        XCTAssertEqual(store.previousReferencedAudio(), [name], "Restored permissions leave its identity unchanged")
    }

    private func voiceLibrary(_ audio: String, state: TranscriptionState? = nil) -> Library {
        var message = Message(role: "user", text: "", audio: audio)
        message.transcriptionState = state
        var chat = Conversation()
        chat.messages = [message]
        var library = Library()
        library.conversations = [chat]
        return library
    }

    private func folder() throws -> URL {
        let url = TestScratch.folder("mochi-files")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func age(_ url: URL, days: Double) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -days * 86400)], ofItemAtPath: url.path)
    }
}
