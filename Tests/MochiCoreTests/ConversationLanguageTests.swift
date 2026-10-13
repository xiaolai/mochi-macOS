import MochiKernel
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
