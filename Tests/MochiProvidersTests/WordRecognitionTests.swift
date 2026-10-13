import MochiCore
import MochiKernel
import XCTest

@testable import MochiProviders

/// The gates in front of Apple's recognizer. Only the refusals are tested here: they never reach Apple, so they
/// download nothing. Real recognition is checked on the test Mac.
final class WordRecognitionTests: XCTestCase {
    func testOnlyEnglishIsOffered() async {
        for language in ConversationLanguage.allCases where language != .english {
            let availability = await WordRecognition.availability(for: language)
            XCTAssertEqual(availability, .unavailable(.language), "\(language)")
        }
    }
    func testOtherLanguagesAreRefusedWithoutRecognising() async {
        let url = URL(fileURLWithPath: "/nonexistent.wav")
        do {
            _ = try await WordRecognition.recognize(url, language: .chinese)
            XCTFail("Expected a refusal")
        } catch {
            XCTAssertTrue(error is AppFailure, "\(error)")
        }
        do {
            try await WordRecognition.download(for: .match)
            XCTFail("Expected a refusal")
        } catch {
            XCTAssertTrue(error is AppFailure, "\(error)")
        }
    }
    func testTheMeasuredLocaleIsUsed() {
        XCTAssertEqual(WordRecognition.localeIdentifier, "en-US")
    }
}

/// Apple's recognizer itself, on a sentence spoken by `say`. It needs macOS 26 with the English speech model installed
/// and never downloads it, so it runs only with MOCHI_LIVE_RECOGNITION=1.
final class WordRecognitionLiveTests: XCTestCase {
    func testASpokenSentenceIsCaughtWordByWord() async throws {
        guard ProcessInfo.processInfo.environment["MOCHI_LIVE_RECOGNITION"] == "1" else {
            throw XCTSkip("Uses Apple's speech model; set MOCHI_LIVE_RECOGNITION=1 to run it.")
        }
        let availability = await WordRecognition.availability(for: .english)
        XCTAssertEqual(availability, .ready, "Install the English speech model on this Mac first.")
        let sentence = "I keep putting it off because I don't know where to start."
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mochi-said-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", url.path, "--data-format=LEI16@24000", sentence]
        try say.run()
        say.waitUntilExit()
        XCTAssertEqual(say.terminationStatus, 0)

        let words = try await WordRecognition.recognize(url, language: .english)
        XCTAssertTrue(words.allSatisfy { (0...1).contains($0.confidence) }, "\(words)")
        let check = AttemptCheck(target: sentence, recognized: words)
        XCTAssertGreaterThanOrEqual(check.count(.heard), check.words.count - 1, "\(words)")
    }
}
