import XCTest
@testable import MochiCore
final class HistoryTests: XCTestCase {
    func testLegacyDefaultsAndMigrationBackup() throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at:root) }
        let store = LibraryStore(root:root); try store.prepare()
        let id = UUID()
        let legacy = Data("{\"version\":1,\"conversations\":[{\"id\":\"\(id)\",\"title\":\"Old\",\"messages\":[],\"date\":0}],\"expressions\":[]}".utf8)
        try legacy.write(to:store.file)
        var library = try store.load()
        XCTAssertEqual(library.version,3)
        XCTAssertFalse(library.conversations[0].pinned)
        XCTAssertEqual(library.conversations[0].draft,"")
        library.conversations[0].draft = "Unsaved thought"
        library.selectedConversationID = id
        try store.save(library)
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent("library-v1-backup.json")),legacy)
        XCTAssertEqual(try store.load().conversations[0].draft,"Unsaved thought")
        XCTAssertEqual(try store.load().selectedConversationID,id)
    }
    func testSearchScopeAndOrdering() {
        var older = Conversation(title:"Café"); older.date = Date(timeIntervalSince1970:0); older.pinned = true
        var newest = Conversation(title:"Latest"); newest.messages = [Message(role:"user",text:"你好 coffee")]
        var archive = Conversation(title:"Archive"); archive.archived = true; archive.messages = [Message(role:"user",text:"COFFEE")]
        var deleted = Conversation(title:"Deleted coffee"); deleted.deletedAt = Date()
        var library = Library(); library.conversations = [newest,archive,deleted,older]
        XCTAssertEqual(library.history(in:.active).map(\.id),[older.id,newest.id])
        XCTAssertEqual(library.history(in:.active,query:"coffee").count,2)
        XCTAssertEqual(library.history(in:.active,query:"cafe").first?.id,older.id)
        XCTAssertEqual(library.history(in:.active,query:"你好").first?.id,newest.id)
        XCTAssertEqual(library.history(in:.deleted,query:"coffee").first?.id,deleted.id)
    }
    func testLifecycleAndSharedAudio() {
        var chat = Conversation(title:"Keep"); chat.archived = true; chat.messages = [Message(role:"user",text:"Hello",audio:"shared.wav"), Message(role:"assistant",text:"Hi",audio:"only.wav")]
        var item = PracticeExpression(conversationID:chat.id,meaning:"",english:"Hello"); item.reference = "shared.wav"
        var library = Library(); library.conversations = [chat]; library.expressions = [item]
        library.moveToDeleted([chat.id]); XCTAssertTrue(library.conversations[0].isDeleted)
        library.restore([chat.id]); XCTAssertTrue(library.conversations[0].archived)
        library.moveToDeleted([chat.id])
        XCTAssertEqual(library.removePermanently([chat.id]),Set(["only.wav"]))
        XCTAssertEqual(library.expressions.count,1)
        XCTAssertEqual(library.conversations.count,0)
    }
    func testBackupRoundTripAndConflictMerge() throws {
        let root = temporary(), target = temporary(), package = temporary()
        defer { for p in [root,target,package] { try? FileManager.default.removeItem(at:p) } }
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        var chat = Conversation(title:"Original"); chat.messages = [Message(role:"user",text:"Hello",audio:"voice.wav")]
        var library = Library(); library.conversations = [chat]
        try Data([1,2,3]).write(to:root.appendingPathComponent("voice.wav"))
        try LibraryBackup.write(library,from:root,to:package)
        let imported = try LibraryBackup.read(package)
        XCTAssertEqual(imported.conversations[0].messages[0].text,"Hello")
        var local = Library(); var localChat = chat; localChat.title = "Local version"; local.conversations = [localChat]
        XCTAssertEqual(try LibraryBackup.merge(imported,from:package,into:&local,root:target),0)
        XCTAssertEqual(local.conversations[0].title,"Local version")
        var fresh = Library()
        XCTAssertEqual(try LibraryBackup.merge(imported,from:package,into:&fresh,root:target),1)
        XCTAssertEqual(try Data(contentsOf:target.appendingPathComponent(fresh.conversations[0].messages[0].audio!)),Data([1,2,3]))
    }
    func testRejectUnsafeMissingAndDuplicateBackup() throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at:root) }
        var chat = Conversation(); chat.messages = [Message(role:"user",text:"Bad",audio:"../secret")]
        var library = Library(); library.conversations = [chat]
        XCTAssertThrowsError(try library.validate())
        chat.messages[0].audio = "missing.wav"; library.conversations = [chat]
        XCTAssertThrowsError(try LibraryBackup.write(library,from:root,to:root.appendingPathComponent("backup")))
        library.conversations.append(chat)
        XCTAssertThrowsError(try library.validate())
    }
    func testMarkdownAndSearchPerformance() throws {
        var chat = Conversation(title:"A title"); chat.messages = [Message(role:"user",text:"Find needle here")]
        XCTAssertTrue(HistoryExport.markdown([chat]).contains("Find needle here"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with:HistoryExport.json([chat])) as? [String:Any])
        XCTAssertEqual(json["format"] as? String,"mochi-transcript")
        XCTAssertEqual(json["version"] as? Int,1)
        var library = Library(); library.conversations = (0..<1000).map { n in var c = Conversation(title:"\(n)"); c.messages = [Message(role:"assistant",text:"A paragraph about needle")]; return c }
        // Thread CPU time measures the search's own work; wall time also counts scheduler waits on a loaded host.
        func cpu() -> Double { var t = timespec(); clock_gettime(CLOCK_THREAD_CPUTIME_ID,&t); return Double(t.tv_sec) + Double(t.tv_nsec) / 1e9 }
        let start = cpu(); XCTAssertEqual(library.history(in:.active,query:"needle").count,1000)
        XCTAssertLessThan(cpu() - start,0.1)
    }
    func testFailedSaveKeepsOriginalAndDoesNotCleanAudio() throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at:root) }
        let store = LibraryStore(root:root); try store.prepare()
        try Data("block".utf8).write(to:store.file)
        var library = Library(); library.conversations = [Conversation()]
        XCTAssertThrowsError(try store.save(library))
        XCTAssertEqual(try String(contentsOf:store.file),"block")
    }
    func testImportSharesRemappedAudioAndRejectsSymlinksBeforeCopying() throws {
        let source = temporary(), package = temporary(), target = temporary()
        defer { for p in [source,package,target] { try? FileManager.default.removeItem(at:p) } }
        try FileManager.default.createDirectory(at:source,withIntermediateDirectories:true)
        try Data([1]).write(to:source.appendingPathComponent("shared.wav"))
        var a = Conversation(); a.messages = [Message(role:"user",text:"One",audio:"shared.wav")]
        var b = Conversation(); b.messages = [Message(role:"assistant",text:"Two",audio:"shared.wav")]
        var expression = PracticeExpression(conversationID:a.id,meaning:"",english:"One"); expression.reference = "shared.wav"
        var imported = Library(); imported.conversations = [a,b]; imported.expressions = [expression]
        try LibraryBackup.write(imported,from:source,to:package)
        var local = Library()
        XCTAssertEqual(try LibraryBackup.merge(imported,from:package,into:&local,root:target),2)
        XCTAssertEqual(local.referencedAudio.count,1)
        XCTAssertEqual(local.expressions[0].reference,local.conversations[0].messages[0].audio)
        try FileManager.default.removeItem(at:package.appendingPathComponent("shared.wav"))
        try FileManager.default.createSymbolicLink(at:package.appendingPathComponent("shared.wav"),withDestinationURL:source.appendingPathComponent("shared.wav"))
        XCTAssertThrowsError(try LibraryBackup.read(package))
    }
    private func temporary() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
}
