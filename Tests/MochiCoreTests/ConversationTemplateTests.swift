import MochiKernel
import MochiTestSupport
import XCTest

@testable import MochiCore

final class ConversationTemplateTests: XCTestCase {
    func testSnapshotAndIdentityRoundtrip() throws {
        var template = ConversationTemplate(title: "Loki", characterName: "Loki")
        try template.validateForWrite()
        var library = Library()
        library.conversationTemplates = [template]
        var chat = try template.conversation()
        chat.messages = [Message(role: "assistant", text: "Hello", speakerName: "Loki")]
        library.conversations = [chat]
        let data = try JSONEncoder().encode(library)
        let restored = try JSONDecoder().decode(Library.self, from: data)
        XCTAssertEqual(restored.version, Library.currentVersion)
        XCTAssertEqual(restored.conversations[0].characterName, "Loki")
        XCTAssertEqual(restored.conversations[0].messages[0].speakerName, "Loki")
        XCTAssertEqual(restored.conversations[0].sourceTemplateRevision, template.revision)
        template.characterName = "Sam"
        XCTAssertEqual(restored.conversations[0].displayCharacterName, "Loki")
    }
    func testLegacyDefaultsAndNilIdentityCopy() throws {
        let data = try JSONEncoder().encode(Library())
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        object["version"] = 2
        object.removeValue(forKey: "conversationTemplates")
        let old = try JSONDecoder().decode(Library.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertTrue(old.conversationTemplates.isEmpty)
        let template = ConversationTemplate(title: "Waiter", instructions: "Your name is Sam.")
        XCTAssertNil(try template.conversation().characterName)
        XCTAssertEqual(
            VoiceIdentity.conversationInstructions(custom: template.instructions, preferences: template.preferences),
            VoiceIdentity.conversationInstructions(
                custom: template.instructions, preferences: template.preferences, characterName: nil))
    }
    func testWriteBoundsAndBuiltins() throws {
        XCTAssertEqual(ConversationTemplate.builtins.count, 13)
        XCTAssertEqual(Set(ConversationTemplate.builtins.map(\.id)).count, 13)
        for t in ConversationTemplate.builtins { try t.validateForWrite() }
        XCTAssertThrowsError(try ConversationTemplate(title: "Empty").validateForWrite())
        XCTAssertThrowsError(try ConversationTemplate(title: "Bad", characterName: "\n").validateForWrite())
        let enormous = "a" + String(repeating: "\u{301}", count: 30000)
        XCTAssertLessThan(enormous.count, 80)
        XCTAssertThrowsError(try ConversationTemplate(title: "Huge", instructions: enormous).validateForWrite())
        XCTAssertEqual(ConversationInstructions.bounded(enormous), "")
    }
    func testMigrationBacksUpReupgradeAndStampsVersion() throws {
        let root = TestScratch.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root)
        try store.prepare()
        var old = Library()
        old.version = 2
        old.conversations = [Conversation(title: "Before")]
        let original = try JSONEncoder().encode(old)
        try original.write(to: store.file)
        var loaded = try store.load()
        XCTAssertEqual(loaded.version, Library.currentVersion)
        loaded.version = 2
        try store.save(loaded)
        XCTAssertEqual(
            try JSONDecoder().decode(Library.self, from: Data(contentsOf: store.file)).version, Library.currentVersion)
        XCTAssertEqual(
            try Data(contentsOf: root.appendingPathComponent("library-before-character-templates-v3.json")), original)
        old.conversations[0].title = "After downgrade"
        let changed = try JSONEncoder().encode(old)
        try changed.write(to: store.file)
        try store.save(try store.load())
        let backups = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter {
            $0.lastPathComponent.hasPrefix("library-before-character-templates-v3")
        }
        XCTAssertEqual(backups.count, 2)
        XCTAssertTrue(try backups.contains { try Data(contentsOf: $0) == changed })
    }
}

extension ConversationTemplateTests {
    func testRecoveryImportKeepsOverCapTemplatesAndLocalCollisions() throws {
        let root = TestScratch.folder()
        let backup = root.appendingPathComponent("backup.mochilibrary")
        defer { try? FileManager.default.removeItem(at: root) }
        var imported = Library()
        imported.conversationTemplates = (0..<205).map {
            ConversationTemplate(title: "T\($0)", instructions: "Discuss books")
        }
        imported.conversationTemplates[0].instructions = String(repeating: "x", count: 9000)
        try LibraryBackup.write(imported, from: root, to: backup)
        let restored = try LibraryBackup.read(backup)
        var local = Library()
        var original = imported.conversationTemplates[1]
        original.instructions = "Keep local"
        local.conversationTemplates = [original]
        _ = try LibraryBackup.merge(restored, from: backup, into: &local, root: root)
        XCTAssertEqual(local.conversationTemplates.count, 205)
        XCTAssertEqual(local.conversationTemplates.first?.instructions, "Keep local")
        XCTAssertEqual(
            local.conversationTemplates.first(where: { $0.id == imported.conversationTemplates[0].id })?.instructions
                .count, 9000)
        try local.validate()
    }
    func testImportedPreviewBoundsAndPartialPatchPreservation() throws {
        var t = ConversationTemplate(
            title: String(repeating: "a", count: 10000), instructions: String(repeating: "\u{0001}", count: 8000))
        t.description = "x" + String(repeating: "\u{301}", count: 60000)
        let preview = t.representation()
        XCTAssertLessThan(try JSONSerialization.data(withJSONObject: preview).count, 100000)
        XCTAssertEqual(preview["needs_review"] as? Bool, true)
        XCTAssertFalse((preview["fields_truncated"] as! [String: Bool]).isEmpty)
        let changed = try t.applying(.init(settings: .init(characterName: .set("Loki"))))
        XCTAssertEqual(changed.instructions, t.instructions)
        XCTAssertEqual(changed.description, t.description)
        XCTAssertNotEqual(changed.revision, t.revision)
    }
    func testPristineAndHistoricalExport() throws {
        var c = Conversation()
        XCTAssertTrue(c.isPristine)
        c.draft = "Unsent"
        XCTAssertFalse(c.isPristine)
        c.draft = ""
        c.characterName = "Loki"
        XCTAssertFalse(c.isPristine)
        c.messages = [Message(role: "assistant", text: "Hello", speakerName: "Sam")]
        XCTAssertTrue(HistoryExport.markdown([c]).contains("### Sam"))
        c.messages.append(Message(role: "assistant", text: "Old"))
        XCTAssertTrue(HistoryExport.markdown([c]).contains("### Mochi"))
    }
}

extension ConversationTemplateTests {
    func testV1MigrationBackupIsPrivateCompleteAndLeavesNoStaging() throws {
        let root = TestScratch.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root)
        try store.prepare()
        let original = Data(
            "{\"version\":1,\"conversations\":[{\"id\":\"\(UUID())\",\"title\":\"Old\",\"messages\":[],\"date\":0}],\"expressions\":[]}"
                .utf8)
        try original.write(to: store.file)
        let previous = umask(0o022)
        defer { umask(previous) }
        try store.save(try store.load())
        let backup = root.appendingPathComponent("library-before-character-templates-v3.json")
        XCTAssertEqual(try Data(contentsOf: backup), original)
        XCTAssertEqual(
            (try FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions] as? NSNumber)?.intValue,
            0o600)
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".backup-write-") })
        XCTAssertEqual(
            try JSONDecoder().decode(Library.self, from: Data(contentsOf: store.file)).version, Library.currentVersion)
        // Once the file is current, later saves add no migration copies.
        try store.save(try store.load())
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: root.path).filter {
                $0.hasPrefix("library-before-character-templates-v3")
            }.count, 1)
    }
    func testExplicitMochiKeepsPronunciationAndOtherNamesDropDefaultName() {
        let prefs = ConversationPreferences()
        XCTAssertTrue(
            VoiceIdentity.conversationInstructions(custom: "", preferences: prefs, characterName: "Mochi").contains(
                "pronounced MOH-chee"))
        let loki = VoiceIdentity.conversationInstructions(custom: "", preferences: prefs, characterName: "Loki")
        XCTAssertFalse(loki.contains("Mochi"))
        XCTAssertTrue(loki.contains("\"Loki\""))
        XCTAssertEqual(
            VoiceIdentity.conversationInstructions(custom: "Be brief", preferences: prefs),
            VoiceIdentity.instructions + "\nSpeak only English."
                + "\nConversation-specific instructions (these override the conversational defaults above when they conflict):\nBe brief"
                + "\nNAME: If the conversation-specific instructions above give you a name, that name replaces Mochi: when asked your name, answer with it. Earlier turns may use a previous name."
        )
    }
    func testImportSummaryCountsOnlyAddedTemplatesAndReportsSoftCap() {
        let local = (0..<199).map { ConversationTemplate(title: "L\($0)", instructions: "x") }
        var oversized = ConversationTemplate(title: "Big", instructions: "x")
        oversized.instructions = String(repeating: "y", count: 9000)
        let imported = [local[0], oversized, ConversationTemplate(title: "New", instructions: "x")]
        let merged = local + imported.dropFirst()
        let text = ConversationTemplate.importSummary(
            conversations: 0, imported: imported, merged: merged, localIDs: Set(local.map(\.id)))
        XCTAssertTrue(text.contains("2 templates"))
        XCTAssertTrue(text.contains("1 duplicate templates skipped"))
        XCTAssertTrue(text.contains("1 imported templates need review"))
        XCTAssertTrue(text.contains("201 user templates"))
    }
}

extension ConversationTemplateTests {
    func testBackupFailureCannotReplaceOriginalAndReservedTemplateImportFails() throws {
        let root = TestScratch.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root)
        try store.prepare()
        var old = Library()
        old.version = 2
        let bytes = try JSONEncoder().encode(old)
        try bytes.write(to: store.file)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("library-before-character-templates-v3.json"),
            withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.save(try store.load()))
        XCTAssertEqual(try Data(contentsOf: store.file), bytes)
        var bad = Library()
        bad.conversationTemplates = [ConversationTemplate.builtins[0]]
        var local = Library()
        XCTAssertThrowsError(try LibraryBackup.merge(bad, from: root, into: &local, root: root))
        XCTAssertTrue(local.conversationTemplates.isEmpty)
    }
    func testExplicitNamePrecedenceAndNilPromptCompatibility() {
        let prompt = VoiceIdentity.conversationInstructions(
            custom: "Your name is Sam", preferences: ConversationPreferences(), characterName: "Loki")
        XCTAssertTrue(prompt.hasPrefix("CHARACTER IDENTITY"))
        XCTAssertTrue(prompt.contains("NEVER the configured character name"))
        XCTAssertFalse(prompt.contains("these override the conversational defaults above"))
        XCTAssertTrue(prompt.hasSuffix("earlier turns may use previous names."))
        XCTAssertTrue(
            VoiceIdentity.conversationInstructions(custom: "Your name is Sam", preferences: ConversationPreferences())
                .contains("these override the conversational defaults above"))
        XCTAssertFalse(prompt.contains("that name replaces Mochi"), "a configured character keeps its own name")
    }
    /// Without a configured character, a name the instructions give replaces Mochi, and the prompt says so last,
    /// after the instructions, so an earlier "Hi, I'm Mochi." does not outweigh it.
    func testInstructionNameReplacesTheDefaultLast() throws {
        let prompt = VoiceIdentity.conversationInstructions(
            custom: "Your name is Sam.", preferences: ConversationPreferences())
        XCTAssertTrue(prompt.hasSuffix("Earlier turns may use a previous name."))
        let named = try XCTUnwrap(prompt.range(of: "that name replaces Mochi"))
        XCTAssertLessThan(try XCTUnwrap(prompt.range(of: "Your name is Sam.")).lowerBound, named.lowerBound)
        XCTAssertFalse(
            VoiceIdentity.conversationInstructions(custom: "", preferences: ConversationPreferences())
                .contains("that name replaces Mochi"), "no instructions, no name rule")
    }
}

extension ConversationTemplateTests {
    /// Conversations record the revision of the built-in they started from, and MCP clients send it back as
    /// expected_template_revision. Adding built-ins must leave the original six byte-identical.
    func testOriginalBuiltinsKeepTheirIDsAndRevisions() {
        let pinned = [
            "788bd244725bb4cef0627a1158d117618a2bbe52c514dfbac8203577c69065b6",
            "b846858dffe2de75a3c9ac8a4055eb4e242edbf530f4178dc349a1646e47b43e",
            "368c83848f80437d24dceb9efdb516be3a52e65bac131ef350839fccae47c2bc",
            "78d495c2a07ceb798cdc4958eaa8f993b8c9dd3904fd16c53b9e6b7744bb4eab",
            "b109239e39fce3c6fae25783d6efd38018944509688c605e0cb6bb2df42ff0ed",
            "dcd2ca6965486214080e7ad218ae57bfe13170761b3a72cb246dd6d71d9eb0f6",
        ]
        for (index, revision) in pinned.enumerated() {
            let t = ConversationTemplate.builtins[index]
            XCTAssertEqual(t.id.uuidString, String(format: "DAF3D003-0000-4000-8000-%012d", index + 1))
            XCTAssertEqual(t.revision, revision, t.title)
            XCTAssertEqual(t.category, .languagePractice, t.title)
        }
    }
    /// The general built-ins work in any language: they follow the user's, correct nothing and leave naming free,
    /// so a role-play can name the other person.
    func testGeneralBuiltinsFollowTheUsersLanguage() throws {
        let general = ConversationTemplate.builtins.filter { $0.category == .general }
        XCTAssertEqual(
            general.map(\.title),
            [
                "Brainstorm with me", "Think out loud", "Rehearse a conversation", "Make a story with me",
                "Interview my character", "Learn by teaching", "Remember a moment",
            ])
        XCTAssertEqual(
            general.map(\.id.uuidString), (7...13).map { String(format: "DAF3D003-0000-4000-8000-%012d", $0) })
        for t in general {
            XCTAssertEqual(t.preferences.language, .match, t.title)
            XCTAssertEqual(t.preferences.coaching, .natural, t.title)
            XCTAssertNil(t.preferences.speed, t.title)
            XCTAssertNil(t.characterName, t.title)
            XCTAssertFalse(t.description.isEmpty, t.title)
            XCTAssertNoThrow(try t.validateForWrite(), t.title)
            XCTAssertNoThrow(try t.conversation(), t.title)
        }
        XCTAssertNil(ConversationTemplate(title: "Mine", instructions: "Chat").category)
        XCTAssertEqual(Set(ConversationTemplate.builtins.map(\.revision)).count, ConversationTemplate.builtins.count)
    }
    func testBuiltinIDsAreReservedFromOneDefinition() {
        XCTAssertEqual(ConversationTemplate.reservedIDs, Set(ConversationTemplate.builtins.map(\.id)))
        XCTAssertEqual(ConversationTemplate.reservedIDs.count, ConversationTemplate.builtins.count)
        XCTAssertTrue(ConversationTemplate.builtins.allSatisfy(\.isBuiltin))
    }

    func testInstructionPreviewUsesTheValidationLimit() {
        var t = ConversationTemplate(title: "Long", instructions: "x")
        t.instructions = String(repeating: "y", count: ConversationInstructions.maxCharacters + 5)
        let preview = t.representation()
        XCTAssertEqual((preview["instructions"] as? String)?.count, ConversationInstructions.maxCharacters)
        XCTAssertEqual((preview["fields_truncated"] as? [String: Bool])?["instructions"], true)
    }

    func testRealNamesWithJoinersAreAcceptedAndSpoofingIsNot() {
        for name in ["Teacher 👩‍🏫", "می‌خواهم", "Renée", "❤️ Mochi"] {
            XCTAssertNoThrow(try ConversationTemplate.validateName(name), name)
        }
        for name in ["Line\nbreak", "Nul\u{0}", "Tab\tbed", "Evil\u{202E}txt.exe", "Iso\u{2066}late"] {
            XCTAssertThrowsError(try ConversationTemplate.validateName(name), name)
        }
    }
}

extension ConversationTemplateTests {
    /// Settings added in version 4 are left out of a template's encoding until set, so a built-in without them keeps
    /// the revision it had before they existed, and an older library's template reads back unchanged.
    func testNewSettingsAreWrittenOnlyWhenSetAndRoundTrip() throws {
        func object(_ t: ConversationTemplate) throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(t)) as? [String: Any])
        }
        let plain = ConversationTemplate(title: "Plain", instructions: "Chat")
        let keys = Set(try object(plain).keys)
        XCTAssertTrue(keys.isDisjoint(with: ["personality", "greeting", "phrases"]), "\(keys)")
        XCTAssertNil((try object(plain)["preferences"] as? [String: Any])?["voice"])
        var full = plain
        full.personality = "Wry"
        full.greeting = "Ready?"
        full.phrases = ["Again."]
        full.preferences.voice = "ash"
        let encoded = try object(full)
        XCTAssertEqual(encoded["personality"] as? String, "Wry")
        XCTAssertEqual(encoded["phrases"] as? [String], ["Again."])
        XCTAssertEqual(try JSONDecoder().decode(ConversationTemplate.self, from: JSONEncoder().encode(full)), full)
        XCTAssertEqual(try JSONDecoder().decode(ConversationTemplate.self, from: JSONEncoder().encode(plain)), plain)
    }

    func testANewSettingAloneMakesATemplateMeaningful() throws {
        var empty = ConversationTemplate(title: "Empty")
        XCTAssertThrowsError(try empty.validateForWrite())
        let alone: [(inout ConversationTemplate) -> Void] = [
            { $0.personality = "Wry" }, { $0.greeting = "Ready?" }, { $0.phrases = ["Again."] },
            { $0.preferences.voice = "ash" },
        ]
        for set in alone {
            var t = empty
            set(&t)
            XCTAssertNoThrow(try t.validateForWrite())
        }
        empty.greeting = "Line\nbreak"
        XCTAssertThrowsError(try empty.validateForWrite())
    }

    /// The general built-ins open with a greeting and offer phrases; every one has a translation key, which a typo
    /// would miss. The practice six have neither, so they stay byte-identical.
    func testGeneralBuiltinsHaveGreetingsAndPhrasesWithTranslations() {
        for t in ConversationTemplate.builtins {
            if t.category == .general {
                XCTAssertFalse(t.greeting.isEmpty, t.title)
                XCTAssertEqual(t.phrases.count, 3, t.title)
                XCTAssertNoThrow(try ConversationGreeting.validate(t.greeting), t.title)
                XCTAssertNoThrow(try ConversationPhrases.validate(t.phrases), t.title)
                XCTAssertEqual(ConversationTemplate.localizedGreeting(t.greeting), t.greeting, t.title)
                for phrase in t.phrases {
                    XCTAssertEqual(ConversationTemplate.localizedPhrase(phrase), phrase, "\(t.title): \(phrase)")
                }
                XCTAssertTrue(ConversationTemplate.isBuiltinGreeting(t.greeting))
            } else {
                XCTAssertEqual(t.greeting, "", t.title)
                XCTAssertEqual(t.phrases, [], t.title)
            }
        }
        XCTAssertNil(ConversationTemplate.localizedGreeting("A greeting of my own."))
        XCTAssertFalse(ConversationTemplate.isBuiltinGreeting(""))
    }

    /// A conversation copies every setting. A built-in greeting is kept only when the conversation will be greeted
    /// in the interface language, which has its text; otherwise the standard greeting in the conversation's
    /// language is spoken instead. A user's own greeting is always kept.
    func testStartingFromATemplateCopiesEverySettingAndFitsTheBuiltinGreeting() throws {
        var mine = ConversationTemplate(title: "Mine", characterName: "Bea", instructions: "Interview me")
        mine.personality = "Wry"
        mine.greeting = "Ready when you are."
        mine.phrases = ["Next question."]
        mine.preferences.voice = "ash"
        mine.preferences.speed = 0.8
        mine.preferences.coaching = .direct
        mine.preferences.language = .japanese
        let chat = try mine.conversation(title: "Mine", interface: "en")
        XCTAssertEqual(chat.instructions, mine.instructions)
        XCTAssertEqual(chat.characterName, "Bea")
        XCTAssertEqual(chat.personality, "Wry")
        XCTAssertEqual(chat.greeting, "Ready when you are.", "A user's greeting is spoken as written")
        XCTAssertEqual(chat.phrases, ["Next question."])
        XCTAssertEqual(chat.preferences, mine.preferences)
        XCTAssertEqual(chat.sourceTemplateID, mine.id)
        XCTAssertEqual(chat.sourceTemplateRevision, mine.revision)

        let story = try XCTUnwrap(ConversationTemplate.builtins.first { $0.title == "Make a story with me" })
        XCTAssertEqual(try story.conversation(interface: "en").greeting, story.greeting, "Match Me greets in English")
        XCTAssertEqual(try story.conversation(interface: "en").phrases, story.phrases)
        var japanese = story
        japanese.preferences.language = .japanese
        XCTAssertEqual(try japanese.conversation(interface: "en").greeting, "", "No Japanese text: standard greeting")
        XCTAssertEqual(try japanese.conversation(interface: "ja").greeting, story.greeting)
        var english = story
        english.preferences.language = .english
        XCTAssertEqual(try english.conversation(interface: "en").greeting, story.greeting)
        XCTAssertEqual(try english.conversation(interface: "zh-Hans").greeting, "")
        // Edited text is the user's own and is kept in any language.
        japanese.greeting = "物語はどこから始まる？"
        XCTAssertEqual(try japanese.conversation(interface: "en").greeting, "物語はどこから始まる？")
        // So is a user template's, even when it reads exactly like a built-in greeting: what it stores is all it has.
        var duplicate = ConversationTemplate(title: "My story", instructions: story.instructions)
        duplicate.greeting = story.greeting
        duplicate.preferences.language = .japanese
        XCTAssertEqual(try duplicate.conversation(interface: "en").greeting, story.greeting)
        XCTAssertEqual(try duplicate.conversation(interface: "zh-Hans").greeting, story.greeting)
    }
}
