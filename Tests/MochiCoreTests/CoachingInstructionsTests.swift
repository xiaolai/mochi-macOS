import MochiKernel
import XCTest

@testable import MochiCore

/// Coaching corrects with restraint (plan W2): each rule is pinned here; whether the model follows them is checked
/// by the live coaching audition.
final class CoachingInstructionsTests: XCTestCase {
    private func coaching(_ style: CoachingStyle, _ language: ConversationLanguage = .english) -> String {
        var preferences = ConversationPreferences()
        preferences.language = language
        preferences.coaching = style
        return VoiceIdentity.languageInstructions(preferences)
    }
    /// The rules gentle and direct share.
    private let shared = [
        "ask you not to correct them, do not correct at all",
        "correct their English at most once per reply",
        "choosing the error that most hurts understanding",
        "always also respond to what they said",
        "Never also improve words that were already correct",
        "Leave accent, style choices and acceptable informal or spoken English alone",
        "ask them instead of correcting",
    ]

    func testGentleCorrectsRarelyAndInsideAGenuineReply() {
        let text = coaching(.gentle)
        for rule in shared { XCTAssertTrue(text.contains(rule), rule) }
        XCTAssertTrue(text.contains("only now and then"))
        XCTAssertTrue(text.contains("weaving the right form into your genuine reply, never as a separate lesson"))
    }
    func testDirectCorrectsBriefly() {
        let text = coaching(.direct)
        for rule in shared { XCTAssertTrue(text.contains(rule), rule) }
        XCTAssertTrue(text.contains("say the corrected words briefly"))
        // Self-repair on a repeated error was tried and dropped: by instruction alone the model never did it on an
        // error the instructions did not spell out (coaching audition, 2026-10-14).
        XCTAssertFalse(text.contains("try saying it again"))
    }
    func testTranscriptsMayBeMisheardSoUncertaintyAsks() {
        for style in [CoachingStyle.gentle, .direct] {
            XCTAssertTrue(coaching(style).contains("automatic transcripts, which can contain recognition mistakes"))
        }
    }
    func testNaturalAndMatchMeNeverCorrect() {
        XCTAssertEqual(coaching(.natural), "Speak only English.")
        for style in CoachingStyle.allCases {
            let text = coaching(style, .match)
            XCTAssertFalse(text.contains("at most once"), "\(style)")
            XCTAssertTrue(text.contains("Do not correct their language."), "\(style)")
        }
    }
    func testTheRulesNameTheLanguagePractised() {
        let text = coaching(.direct, .korean)
        XCTAssertTrue(text.contains("correct their Korean"))
        XCTAssertTrue(text.contains("informal or spoken Korean"))
        XCTAssertFalse(text.contains("English"))
    }
    func testConversationInstructionsStillOverrideCoaching() throws {
        var preferences = ConversationPreferences()
        preferences.coaching = .direct
        let prompt = VoiceIdentity.conversationInstructions(
            custom: "Never correct my English.", preferences: preferences)
        let rules = try XCTUnwrap(prompt.range(of: "at most once per reply"))
        let custom = try XCTUnwrap(prompt.range(of: "these override the conversational defaults above"))
        XCTAssertLessThan(rules.lowerBound, custom.lowerBound, "Custom instructions come after, and win")
    }
}
