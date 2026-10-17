import MochiProviders
import XCTest

@testable import MochiApp

@MainActor final class PracticeTimbrePreferencesTests: XCTestCase {
    func testPracticeTimbreIsOffUntilTheLearnerTurnsItOn() throws {
        let settings = PreferencesStore(makePreferences(), importLegacy: false, allowExternalControl: true)

        XCTAssertFalse(settings.practiceTimbreEnabled)
        XCTAssertNil(try settings.practiceTimbre(), "no conversion may run while the setting is off")
        XCTAssertEqual(settings.practiceVoiceLabel, "\(RealtimeService.defaultVoice.capitalized) · Codex voice")
    }

    func testTurningItOnNeedsAValidVoiceIDAndLabelsExamplesAsYourVoice() throws {
        let defaults = makePreferences()
        let settings = PreferencesStore(defaults, importLegacy: false, allowExternalControl: true)
        settings.practiceTimbreEnabled = true

        XCTAssertThrowsError(try settings.practiceTimbre(), "an empty voice ID must be refused before any request")
        settings.practiceTimbreVoiceID = "VOICE123"
        XCTAssertEqual(try settings.practiceTimbre()?.voiceID, "VOICE123")
        XCTAssertEqual(settings.practiceVoiceLabel, "Your voice")

        let reloaded = PreferencesStore(defaults, importLegacy: false, allowExternalControl: true)
        XCTAssertTrue(reloaded.practiceTimbreEnabled)
        XCTAssertEqual(reloaded.practiceTimbreVoiceID, "VOICE123")
    }
}
