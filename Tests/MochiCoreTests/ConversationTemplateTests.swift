import XCTest
@testable import MochiCore

final class ConversationTemplateTests: XCTestCase {
    func testSnapshotAndIdentityRoundtrip() throws {
        var template = ConversationTemplate(title:"Loki",characterName:"Loki")
        try template.validateForWrite()
        var library = Library(); library.conversationTemplates = [template]
        var chat = try template.conversation(); chat.messages = [Message(role:"assistant",text:"Hello",speakerName:"Loki")]
        library.conversations = [chat]
        let data = try JSONEncoder().encode(library)
        let restored = try JSONDecoder().decode(Library.self,from:data)
        XCTAssertEqual(restored.version,3)
        XCTAssertEqual(restored.conversations[0].characterName,"Loki")
        XCTAssertEqual(restored.conversations[0].messages[0].speakerName,"Loki")
        XCTAssertEqual(restored.conversations[0].sourceTemplateRevision,template.revision)
        template.characterName = "Sam"
        XCTAssertEqual(restored.conversations[0].displayCharacterName,"Loki")
    }
    func testLegacyDefaultsAndNilIdentityCopy() throws {
        let data = try JSONEncoder().encode(Library())
        var object = try JSONSerialization.jsonObject(with:data) as! [String:Any]
        object["version"] = 2; object.removeValue(forKey:"conversationTemplates")
        let old = try JSONDecoder().decode(Library.self,from:JSONSerialization.data(withJSONObject:object))
        XCTAssertTrue(old.conversationTemplates.isEmpty)
        let template = ConversationTemplate(title:"Waiter",instructions:"Your name is Sam.")
        XCTAssertNil(try template.conversation().characterName)
        XCTAssertEqual(VoiceIdentity.conversationInstructions(custom:template.instructions,preferences:template.preferences),VoiceIdentity.conversationInstructions(custom:template.instructions,preferences:template.preferences,characterName:nil))
    }
    func testWriteBoundsAndBuiltins() throws {
        XCTAssertEqual(ConversationTemplate.builtins.count,6)
        XCTAssertEqual(Set(ConversationTemplate.builtins.map(\.id)).count,6)
        for t in ConversationTemplate.builtins { try t.validateForWrite() }
        XCTAssertThrowsError(try ConversationTemplate(title:"Empty").validateForWrite())
        XCTAssertThrowsError(try ConversationTemplate(title:"Bad",characterName:"\n").validateForWrite())
        let enormous = "a" + String(repeating:"\u{301}",count:30000)
        XCTAssertLessThan(enormous.count,80)
        XCTAssertThrowsError(try ConversationTemplate(title:"Huge",instructions:enormous).validateForWrite())
        XCTAssertEqual(MochiTools.boundedInstructions(enormous),"")
    }
    func testMigrationBacksUpReupgradeAndStampsVersion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let store = LibraryStore(root:root); try store.prepare()
        var old = Library(); old.version = 2; old.conversations = [Conversation(title:"Before")]
        let original = try JSONEncoder().encode(old); try original.write(to:store.file)
        var loaded = try store.load(); XCTAssertEqual(loaded.version,3)
        loaded.version = 2; try store.save(loaded)
        XCTAssertEqual(try JSONDecoder().decode(Library.self,from:Data(contentsOf:store.file)).version,3)
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent("library-before-character-templates-v3.json")),original)
        old.conversations[0].title = "After downgrade"
        let changed = try JSONEncoder().encode(old); try changed.write(to:store.file)
        try store.save(try store.load())
        let backups = try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil).filter { $0.lastPathComponent.hasPrefix("library-before-character-templates-v3") }
        XCTAssertEqual(backups.count,2)
        XCTAssertTrue(try backups.contains { try Data(contentsOf:$0) == changed })
    }
}

extension ConversationTemplateTests {
    func testRecoveryImportKeepsOverCapTemplatesAndLocalCollisions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let backup = root.appendingPathComponent("backup.mochilibrary")
        defer { try? FileManager.default.removeItem(at:root) }
        var imported = Library()
        imported.conversationTemplates = (0..<205).map { ConversationTemplate(title:"T\($0)",instructions:"Discuss books") }
        imported.conversationTemplates[0].instructions = String(repeating:"x",count:9000)
        try LibraryBackup.write(imported,from:root,to:backup)
        let restored = try LibraryBackup.read(backup)
        var local = Library(); var original = imported.conversationTemplates[1]; original.instructions = "Keep local"
        local.conversationTemplates = [original]
        _ = try LibraryBackup.merge(restored,from:backup,into:&local,root:root)
        XCTAssertEqual(local.conversationTemplates.count,205)
        XCTAssertEqual(local.conversationTemplates.first?.instructions,"Keep local")
        XCTAssertEqual(local.conversationTemplates.first(where:{ $0.id == imported.conversationTemplates[0].id })?.instructions.count,9000)
        try local.validate()
    }
    func testImportedPreviewBoundsAndPartialPatchPreservation() throws {
        var t = ConversationTemplate(title:String(repeating:"a",count:10000),instructions:String(repeating:"\u{0001}",count:8000))
        t.description = "x" + String(repeating:"\u{301}",count:60000)
        let preview = t.representation()
        XCTAssertLessThan(try JSONSerialization.data(withJSONObject:preview).count,100000)
        XCTAssertEqual(preview["needs_review"] as? Bool,true)
        XCTAssertFalse((preview["fields_truncated"] as! [String:Bool]).isEmpty)
        let changed = try t.applying(["character_name":"Loki"])
        XCTAssertEqual(changed.instructions,t.instructions); XCTAssertEqual(changed.description,t.description)
        XCTAssertNotEqual(changed.revision,t.revision)
    }
    func testNamePromptAndReferenceIsolationAndGreetingPatterns() throws {
        var prefs = ConversationPreferences(); prefs.coaching = .direct
        let prompt = VoiceIdentity.conversationInstructions(custom:"Your name is Sam",preferences:prefs,characterName:"Loki")
        XCTAssertTrue(prompt.contains("\"Loki\"")); XCTAssertTrue(prompt.contains("previous names"))
        XCTAssertFalse(prompt.contains("pronounced MOH-chee"))
        let reference = ConversationRequest(history:[],text:"Say this",reference:true,instructions:"Your name is Sam",characterName:"Loki")
        XCTAssertFalse(reference.resolvedInstructions.contains("Loki"))
        var history: [String] = []
        for _ in 0..<30 {
            let greeting = VoiceIdentity.namedGreeting(name:"Loki",excluding:history)
            XCTAssertTrue(greeting.text.contains("Loki")); XCTAssertFalse(history.suffix(3).contains(greeting.pattern)); history.append(greeting.pattern)
        }
    }
    func testToolBooleanOriginAndRevisionSchemas() throws {
        for bad: Any in [1,"true",NSNull()] {
            XCTAssertThrowsError(try MochiTools.validate(name:"update_conversation_template",arguments:["template_id":UUID().uuidString,"expected_template_revision":"r","clear_speed":bad],origin:.external))
        }
        let tool = try MochiTools.validate(name:"create_conversation_template",arguments:["title":"Loki","character_name":"Loki"],origin:.external)
        XCTAssertFalse(tool.required.contains("expected_revision"))
        XCTAssertThrowsError(try MochiTools.validate(name:"create_conversation_template",arguments:["title":"Loki","character_name":"Loki"],origin:.voice))
        _ = try MochiTools.validate(name:"list_conversation_templates",arguments:["offset":200],origin:.external)
        XCTAssertThrowsError(try MochiTools.validate(name:"update_conversation_template",arguments:["template_id":UUID().uuidString,"expected_template_revision":"r","clear_speed":true,"speed":1],origin:.external))
    }
    func testPristineAndHistoricalExport() throws {
        var c = Conversation(); XCTAssertTrue(c.isPristine)
        c.draft = "Unsent"; XCTAssertFalse(c.isPristine); c.draft = ""; c.characterName = "Loki"; XCTAssertFalse(c.isPristine)
        c.messages = [Message(role:"assistant",text:"Hello",speakerName:"Sam")]
        XCTAssertTrue(HistoryExport.markdown([c]).contains("### Sam"))
        c.messages.append(Message(role:"assistant",text:"Old")); XCTAssertTrue(HistoryExport.markdown([c]).contains("### Mochi"))
    }
}

// Audit regressions (2026-10-10).
extension ConversationTemplateTests {
    func testV1MigrationBackupIsPrivateCompleteAndLeavesNoStaging() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let store = LibraryStore(root:root); try store.prepare()
        let original = Data("{\"version\":1,\"conversations\":[{\"id\":\"\(UUID())\",\"title\":\"Old\",\"messages\":[],\"date\":0}],\"expressions\":[]}".utf8)
        try original.write(to:store.file)
        let previous = umask(0o022); defer { umask(previous) }
        try store.save(try store.load())
        let backup = root.appendingPathComponent("library-before-character-templates-v3.json")
        XCTAssertEqual(try Data(contentsOf:backup),original)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath:backup.path)[.posixPermissions] as? NSNumber)?.intValue,0o600)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath:root.path).contains { $0.hasPrefix(".backup-write-") })
        XCTAssertEqual(try JSONDecoder().decode(Library.self,from:Data(contentsOf:store.file)).version,3)
        // Once the file is v3, later saves add no migration copies.
        try store.save(try store.load())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:root.path).filter { $0.hasPrefix("library-before-character-templates-v3") }.count,1)
    }
    func testExplicitMochiKeepsPronunciationAndOtherNamesDropDefaultName() {
        let prefs = ConversationPreferences()
        XCTAssertTrue(VoiceIdentity.conversationInstructions(custom:"",preferences:prefs,characterName:"Mochi").contains("pronounced MOH-chee"))
        let loki = VoiceIdentity.conversationInstructions(custom:"",preferences:prefs,characterName:"Loki")
        XCTAssertFalse(loki.contains("Mochi")); XCTAssertTrue(loki.contains("\"Loki\""))
        XCTAssertEqual(VoiceIdentity.conversationInstructions(custom:"Be brief",preferences:prefs),VoiceIdentity.instructions + "\nConversation-specific instructions (these override the conversational defaults above when they conflict):\nBe brief")
    }
    func testImportSummaryCountsOnlyAddedTemplatesAndReportsSoftCap() {
        let local = (0..<199).map { ConversationTemplate(title:"L\($0)",instructions:"x") }
        var oversized = ConversationTemplate(title:"Big",instructions:"x"); oversized.instructions = String(repeating:"y",count:9000)
        let imported = [local[0],oversized,ConversationTemplate(title:"New",instructions:"x")]
        let merged = local + imported.dropFirst()
        let text = ConversationTemplate.importSummary(conversations:0,imported:imported,merged:merged,localIDs:Set(local.map(\.id)))
        XCTAssertTrue(text.contains("2 templates")); XCTAssertTrue(text.contains("1 duplicate templates skipped"))
        XCTAssertTrue(text.contains("1 imported templates need review")); XCTAssertTrue(text.contains("201 user templates"))
    }
}

extension ConversationTemplateTests {
    func testBackupFailureCannotReplaceOriginalAndReservedTemplateImportFails() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let store = LibraryStore(root:root); try store.prepare()
        var old = Library(); old.version = 2
        let bytes = try JSONEncoder().encode(old); try bytes.write(to:store.file)
        try FileManager.default.createDirectory(at:root.appendingPathComponent("library-before-character-templates-v3.json"),withIntermediateDirectories:false)
        XCTAssertThrowsError(try store.save(try store.load()))
        XCTAssertEqual(try Data(contentsOf:store.file),bytes)
        var bad = Library(); bad.conversationTemplates = [ConversationTemplate.builtins[0]]
        var local = Library()
        XCTAssertThrowsError(try LibraryBackup.merge(bad,from:root,into:&local,root:root))
        XCTAssertTrue(local.conversationTemplates.isEmpty)
    }
    func testTemplateMCPAnnotationsAndDiscoveryInstructions() throws {
        let tools = MochiTools.catalog(origin:.external)
        for name in ["update_conversation_template","delete_conversation_template"] {
            let value = try XCTUnwrap(tools.first(where:{ $0.name == name }))
            let a = value.mcp["annotations"] as! [String:Any]
            XCTAssertEqual(a["destructiveHint"] as? Bool,true); XCTAssertEqual(a["idempotentHint"] as? Bool,false)
        }
        for name in ["list_conversation_templates","get_conversation_template"] {
            let a = tools.first(where:{ $0.name == name })!.mcp["annotations"] as! [String:Any]
            XCTAssertEqual(a["readOnlyHint"] as? Bool,true)
        }
    }
    func testExplicitNamePrecedenceAndNilPromptCompatibility() {
        let prompt = VoiceIdentity.conversationInstructions(custom:"Your name is Sam",preferences:ConversationPreferences(),characterName:"Loki")
        XCTAssertTrue(prompt.hasPrefix("CHARACTER IDENTITY"))
        XCTAssertTrue(prompt.contains("NEVER the configured character name"))
        XCTAssertFalse(prompt.contains("these override the conversational defaults above"))
        XCTAssertTrue(prompt.hasSuffix("earlier turns may use previous names."))
        XCTAssertTrue(VoiceIdentity.conversationInstructions(custom:"Your name is Sam",preferences:ConversationPreferences()).contains("these override the conversational defaults above"))
    }
}
