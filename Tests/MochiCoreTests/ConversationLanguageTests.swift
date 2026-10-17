import MochiKernel
import MochiTestSupport
import XCTest

@testable import MochiCore

/// A conversation is held in the language its user chose, not in a language the app assumes.
final class ConversationLanguageTests: XCTestCase {
    private func prompt(_ language: ConversationLanguage, _ coaching: CoachingStyle = .natural) -> String {
        var preferences = ConversationPreferences()
        preferences.language = language
        preferences.coaching = coaching
        return VoiceIdentity.conversationInstructions(custom: "", preferences: preferences)
    }

    func testTheBuiltInIdentityAssumesNoLanguage() {
        XCTAssertFalse(VoiceIdentity.instructions.contains("English"))
    }

    func testRepliesAndCorrectionsFollowTheConversationsLanguage() {
        XCTAssertTrue(prompt(.english).contains("Speak only English."), "English stays the default")
        XCTAssertTrue(prompt(.japanese).contains("Speak only Japanese."))
        XCTAssertFalse(prompt(.japanese).contains("English"))
        XCTAssertTrue(prompt(.spanish, .direct).contains("correct their Spanish at most once per reply"))
        XCTAssertTrue(prompt(.french, .gentle).contains("correct their French at most once per reply"))
        XCTAssertFalse(prompt(.french, .gentle).contains("English"))
    }

    func testMatchingTheUserNeverFixesALanguageOrCorrects() {
        for coaching in CoachingStyle.allCases {
            let text = prompt(.match, coaching)
            XCTAssertTrue(text.contains("Reply in the language the user speaks"))
            XCTAssertFalse(text.contains("Speak only"))
            XCTAssertFalse(text.localizedCaseInsensitiveContains("corrections"), "\(coaching)")
        }
    }

    func testStoredLanguagesSurviveAndOldOrUnknownOnesAreEnglish() throws {
        func decoded(_ json: String) throws -> ConversationPreferences {
            try JSONDecoder().decode(ConversationPreferences.self, from: Data(json.utf8))
        }
        XCTAssertEqual(try decoded(#"{"coaching":"gentle"}"#).language, .english, "Saved before languages")
        XCTAssertEqual(try decoded(#"{"language":"klingon"}"#).language, .english)
        XCTAssertEqual(try decoded(#"{"language":"match"}"#).language, .match)
        var preferences = ConversationPreferences()
        preferences.language = .korean
        XCTAssertEqual(
            try JSONDecoder().decode(ConversationPreferences.self, from: JSONEncoder().encode(preferences)), preferences
        )
        // Expressions saved before languages have none, which means English.
        let legacy =
            #"{"id":"\#(UUID().uuidString)","conversationID":"\#(UUID().uuidString)","meaning":"","english":"Hi","referenceKind":"Your voice","attempts":[],"date":0}"#
        XCTAssertNil(try JSONDecoder().decode(PracticeExpression.self, from: Data(legacy.utf8)).language)
    }

    func testALanguageThisVersionDoesNotKnowIsKeptAndReadsAsEnglish() throws {
        let decoded = try JSONDecoder().decode(ConversationPreferences.self, from: Data(#"{"language":"sv"}"#.utf8))
        XCTAssertEqual(decoded.language, .english)
        XCTAssertEqual(decoded.unknownLanguage, "sv")
        XCTAssertEqual(try storedLanguage(of: decoded), "sv", "Written back as stored")
        var chosen = decoded
        chosen.language = .english
        XCTAssertNil(chosen.unknownLanguage, "Choosing a language replaces the stored one, even English")
        XCTAssertEqual(try storedLanguage(of: chosen), "en")
        for json in [#"{"language":"two words"}"#, #"{"language":""}"#, #"{"language":7}"#] {
            let dropped = try JSONDecoder().decode(ConversationPreferences.self, from: Data(json.utf8))
            XCTAssertNil(dropped.unknownLanguage, json)
            XCTAssertEqual(try storedLanguage(of: dropped), "en", json)
        }
        // A settings change that leaves the language alone leaves the stored code alone.
        var chat = Conversation()
        chat.preferences = decoded
        try ConversationSettingsPatch(coaching: .direct).apply(to: &chat)
        XCTAssertEqual(chat.preferences.unknownLanguage, "sv")
        var edited = chat
        edited.preferences.coaching = .gentle
        XCTAssertNil(ConversationSettingsPatch(changing: chat, to: edited).language)
    }

    func testALibraryWithLanguagesThisVersionDoesNotKnowOpensAndKeepsThem() throws {
        let root = TestScratch.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        var chat = Conversation()
        var message = Message(role: "user", text: "Hej", audio: "recording-\(UUID()).wav")
        message.recording = RecordingMetadata(model: "transcriber", language: "en")
        chat.messages = [message]
        var library = Library()
        library.conversations = [chat]
        library.conversationTemplates = [ConversationTemplate(title: "Svenska")]
        library.expressions = [
            PracticeExpression(conversationID: chat.id, meaning: "", english: "Hej", language: .english)
        ]
        // A newer Mochi wrote Swedish everywhere a language is stored.
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(library)) as? [String: Any])
        func swedish(_ key: String, _ edit: (inout [String: Any]) -> Void) {
            var items = json[key] as! [[String: Any]]
            edit(&items[0])
            json[key] = items
        }
        swedish("conversations") { chat in
            var preferences = chat["preferences"] as! [String: Any]
            preferences["language"] = "sv"
            chat["preferences"] = preferences
            var messages = chat["messages"] as! [[String: Any]]
            var recording = messages[0]["recording"] as! [String: Any]
            recording["language"] = "sv"
            messages[0]["recording"] = recording
            chat["messages"] = messages
        }
        swedish("conversationTemplates") { template in
            var preferences = template["preferences"] as! [String: Any]
            preferences["language"] = "sv"
            template["preferences"] = preferences
        }
        swedish("expressions") { $0["language"] = "sv" }
        let store = LibraryStore(root: root)
        try store.prepare()
        try JSONSerialization.data(withJSONObject: json).write(to: store.file)
        let opened = try store.load()
        XCTAssertEqual(opened.conversations[0].preferences.language, .english)
        XCTAssertEqual(
            opened.expressions[0].language, .english, "Read as English, the language a newer one falls back to")
        try store.save(opened)
        let saved = try String(contentsOf: store.file)
        XCTAssertEqual(saved.components(separatedBy: #""language" : "sv""#).count - 1, 4, saved)
        XCTAssertFalse(saved.contains(#""language" : "en""#), saved)
    }

    func testOnlyLanguageCodesAreKept() throws {
        for code in ["sv", "pt-BR", "yue", "zh-Hant-TW"] {
            XCTAssertTrue(ConversationLanguage.isPlausibleCode(code), code)
        }
        for code in ["", "two words", "sv_SE", "émoji", String(repeating: "a", count: 36)] {
            XCTAssertFalse(ConversationLanguage.isPlausibleCode(code), code)
        }
        var library = Library()
        let chat = Conversation()
        library.conversations = [chat]
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(
                    PracticeExpression(conversationID: chat.id, meaning: "", english: "Hi", language: .english)))
                as? [String: Any])
        json["language"] = "two words"
        library.expressions = [
            try JSONDecoder().decode(PracticeExpression.self, from: JSONSerialization.data(withJSONObject: json))
        ]
        XCTAssertThrowsError(try library.validate(), "Text that is no language code is refused, as before")
        XCTAssertFalse(RecordingMetadata(model: "m", language: "two words").isValid)
        XCTAssertFalse(RecordingMetadata(model: "m", language: "match").isValid)
        XCTAssertTrue(RecordingMetadata(model: "m", language: "sv").isValid)
    }

    private func storedLanguage(of preferences: ConversationPreferences) throws -> String? {
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(preferences)) as? [String: Any]
        return object?["language"] as? String
    }

    func testANewConversationIsPristineInAnyLanguage() {
        var chat = Conversation()
        chat.preferences.language = .german
        XCTAssertTrue(chat.isPristine)
        chat.preferences.coaching = .direct
        XCTAssertFalse(chat.isPristine)
    }

    func testTemplatesAndSettingChangesCarryTheLanguage() throws {
        var chat = Conversation()
        try ConversationSettingsPatch(language: .italian).apply(to: &chat)
        XCTAssertEqual(chat.preferences.language, .italian)
        var template = ConversationTemplate(title: "Italiano")
        template.preferences.language = .italian
        XCTAssertNoThrow(try template.validateForWrite(), "A language alone is a meaningful template")
        XCTAssertEqual(template.representation()["language"] as? String, "it")
        XCTAssertEqual(try template.conversation(title: nil).preferences.language, .italian)
    }

    func testEveryLanguageHasNames() {
        for language in ConversationLanguage.allCases {
            XCTAssertFalse(language.displayName.isEmpty)
            XCTAssertEqual(language.englishName == nil, language == .match)
            XCTAssertNotEqual(language.englishName, language.rawValue, "Named, not shown as a code")
        }
    }
}
