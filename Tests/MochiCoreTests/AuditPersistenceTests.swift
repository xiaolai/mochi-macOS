import XCTest
@testable import MochiCore
final class AuditPersistenceTests: XCTestCase {
    func testPartialAndUnknownPreferencesDecodeSafely() throws {
        for json in ["{}","{\"coaching\":\"future\"}","{\"speed\":10}","{\"speed\":\"bad\"}"] {
            let preferences = try JSONDecoder().decode(ConversationPreferences.self,from:Data(json.utf8))
            XCTAssertEqual(preferences.coaching,.natural); XCTAssertNil(preferences.speed)
        }
    }
    func testOversizedInstructionsPreservedOnLoadSaveAndImport() throws {
        var library = Library(); var chat = Conversation(); chat.instructions = String(repeating:"x",count:8001); library.conversations = [chat]
        try library.validate()
        let root = URL(fileURLWithPath:"/tmp/mochi-invalid-\(UUID())"); defer { try? FileManager.default.removeItem(at:root) }
        let store = LibraryStore(root:root); try store.prepare(); try JSONEncoder().encode(library).write(to:store.file)
        XCTAssertEqual(try store.load().conversations[0].instructions,chat.instructions)
        try store.save(library)
        let package = root.appendingPathComponent("backup.mochilibrary")
        try LibraryBackup.write(library,from:root,to:package)
        XCTAssertEqual(try LibraryBackup.read(package).conversations[0].instructions,chat.instructions)
        XCTAssertThrowsError(try MochiTools.validateInstructions(chat.instructions))
    }
    func testPreInstructionsBackupAndConservativeOrphanSweep() throws {
        let root = URL(fileURLWithPath:"/tmp/mochi-library-\(UUID())"); defer { try? FileManager.default.removeItem(at:root) }
        let store = LibraryStore(root:root); try store.prepare()
        var library = Library(); library.conversations = [Conversation()]
        let data = try JSONEncoder().encode(library); var object = try JSONSerialization.jsonObject(with:data) as! [String:Any]
        var chats = object["conversations"] as! [[String:Any]]; chats[0].removeValue(forKey:"instructions"); chats[0].removeValue(forKey:"preferences"); object["conversations"] = chats
        let legacy = try JSONSerialization.data(withJSONObject:object); try legacy.write(to:store.file)
        library.conversations[0].instructions = "Interview me"; try store.save(library)
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent("library-before-conversation-instructions.json")),legacy)
        let orphan = "reply-\(UUID()).wav", referenced = "recording-\(UUID()).wav", unknown = "recording-manual.wav"
        for name in [orphan,referenced,unknown] { try Data([1]).write(to:root.appendingPathComponent(name)) }
        library.conversations[0].messages = [Message(role:"user",text:"Keep",audio:referenced)]
        try store.cleanupOrphanedAudio(library)
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent(orphan).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath:root.appendingPathComponent(referenced).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath:root.appendingPathComponent(unknown).path))
    }
}
