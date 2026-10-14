import XCTest

@testable import MochiCore

final class AttemptCheckTests: XCTestCase {
    private func words(_ pairs: [(String, Double)]) -> [RecognizedWord] {
        pairs.map { RecognizedWord(text: $0.0, confidence: $0.1) }
    }
    private func states(_ result: AttemptCheck) -> [String] {
        result.words.map {
            switch $0.state {
            case .heard: return "heard"
            case .heardAs(let other): return "as:\(other)"
            case .notCaught: return "missing"
            case .uncertain: return "uncertain"
            }
        }
    }

    func testEveryWordHeardKeepsTheTargetsOwnSpelling() {
        let result = AttemptCheck(
            target: "I don’t know where to start.",
            recognized: words([("I", 0.9), ("don't", 0.9), ("know", 0.9), ("where", 0.9), ("to", 0.9), ("start.", 0.9)])
        )
        XCTAssertEqual(result.words.map(\.text), ["I", "don’t", "know", "where", "to", "start."])
        XCTAssertEqual(states(result), Array(repeating: "heard", count: 6))
        XCTAssertTrue(result.extra.isEmpty)
    }

    func testCaseAndPunctuationDoNotCount() {
        let result = AttemptCheck(
            target: "Well, maybe NOT!", recognized: words([("well", 0.8), ("Maybe", 0.8), ("not", 0.8)]))
        XCTAssertEqual(states(result), ["heard", "heard", "heard"])
    }

    func testAWordHeardAsAnotherShowsWhatWasRecognised() {
        let result = AttemptCheck(
            target: "I live here", recognized: words([("I", 0.9), ("leave", 0.9), ("here", 0.9)]))
        XCTAssertEqual(states(result), ["heard", "as:leave", "heard"])
    }

    func testAMissingWordIsNotCaught() {
        let result = AttemptCheck(
            target: "She went to the shop",
            recognized: words([("She", 0.9), ("went", 0.9), ("to", 0.9), ("shop", 0.9)]))
        XCTAssertEqual(states(result), ["heard", "heard", "heard", "missing", "heard"])
    }

    func testExtraRecognisedWordsAreReportedSeparately() {
        let result = AttemptCheck(
            target: "Good morning",
            recognized: words([("Um", 0.6), ("good", 0.9), ("morning", 0.9), ("everyone", 0.9)]))
        XCTAssertEqual(states(result), ["heard", "heard"])
        XCTAssertEqual(result.extra, ["Um", "everyone"])
    }

    func testLowConfidenceIsUncertainWhetherItMatchedOrNot() {
        let cutoff = AttemptCheck.uncertainBelow
        let result = AttemptCheck(
            target: "red bag here",
            recognized: words([("red", cutoff - 0.01), ("bike", cutoff - 0.2), ("here", cutoff)]))
        XCTAssertEqual(states(result), ["uncertain", "uncertain", "heard"])
        if case .uncertain(let recognised) = result.words[1].state {
            XCTAssertEqual(recognised, "bike")
        } else {
            XCTFail("expected uncertain")
        }
    }

    func testTheCutoffIsTheMeasuredOne() {
        // Chosen on speechocean762's train half and checked on its test half (plan E5, 2026-10-14).
        XCTAssertEqual(AttemptCheck.uncertainBelow, 0.43)
    }

    func testNumbersMatchTheirSpelling() {
        let result = AttemptCheck(
            target: "I have three apples and 2 pears",
            recognized: words([
                ("I", 0.9), ("have", 0.9), ("3", 0.9), ("apples", 0.9), ("and", 0.9), ("two", 0.9),
                ("pears", 0.9),
            ]))
        XCTAssertEqual(states(result), Array(repeating: "heard", count: 7))
    }

    func testDigitsReadOneByOneMatchASpelledSequence() {
        let result = AttemptCheck(
            target: "two six four eight", recognized: words([("2648", 0.9)]))
        XCTAssertEqual(states(result), ["heard", "heard", "heard", "heard"])
    }

    func testContractionsMatchTheirLongForm() {
        let result = AttemptCheck(
            target: "I do not think it is ready",
            recognized: words([("I", 0.9), ("don't", 0.9), ("think", 0.9), ("it's", 0.9), ("ready", 0.9)]))
        XCTAssertEqual(states(result), Array(repeating: "heard", count: 7))
        let reverse = AttemptCheck(
            target: "I don't think", recognized: words([("I", 0.9), ("do", 0.9), ("not", 0.9), ("think", 0.9)]))
        XCTAssertEqual(states(reverse), ["heard", "heard", "heard"])
    }

    func testRepeatedWordsAlignInOrder() {
        let result = AttemptCheck(
            target: "the cat saw the dog", recognized: words([("the", 0.9), ("cat", 0.9), ("saw", 0.9), ("dog", 0.9)]))
        XCTAssertEqual(states(result), ["heard", "heard", "heard", "missing", "heard"])
    }

    func testNothingRecognisedMarksEveryWordNotCaught() {
        let result = AttemptCheck(target: "Hello there", recognized: [])
        XCTAssertEqual(states(result), ["missing", "missing"])
        XCTAssertFalse(result.anythingHeard)
    }

    func testAnEmptyTargetHasNoWords() {
        let result = AttemptCheck(target: "  ", recognized: words([("hello", 0.9)]))
        XCTAssertTrue(result.words.isEmpty)
        XCTAssertEqual(result.extra, ["hello"])
    }

    func testCountsSummariseTheStates() {
        let result = AttemptCheck(
            target: "one two three four",
            recognized: words([("one", 0.9), ("too", 0.9), ("three", 0.1)]))
        XCTAssertEqual(result.count(.heard), 1)
        XCTAssertEqual(result.count(.heardAs), 1)
        XCTAssertEqual(result.count(.uncertain), 1)
        XCTAssertEqual(result.count(.notCaught), 1)
    }

    func testSameWordsIgnoresSpellingDifferences() {
        XCTAssertTrue(AttemptCheck.sameWords("Don’t", "do not"))
        XCTAssertTrue(AttemptCheck.sameWords("start.", "start"))
        XCTAssertFalse(AttemptCheck.sameWords("off", "of"))
    }

    func testAPartlyMatchedWordKeepsItsExtraUnit() {
        // "don't" matches "do" and adds "not": the target word was heard differently, never silently heard.
        let result = AttemptCheck(
            target: "I do agree", recognized: words([("I", 0.9), ("don't", 0.9), ("agree", 0.9)]))
        XCTAssertEqual(states(result), ["heard", "as:don't", "heard"])
        XCTAssertEqual(result.extra, ["not"], "The unmatched unit is listed as heard in addition")
    }
    func testAPossessiveIsNotItsContraction() {
        let possessive = AttemptCheck(
            target: "John's book is here.",
            recognized: words([("John", 0.9), ("is", 0.9), ("book", 0.9), ("is", 0.9), ("here", 0.9)]))
        XCTAssertEqual(states(possessive), ["as:John is", "heard", "heard", "heard"])
        let said = AttemptCheck(
            target: "John's book is here.",
            recognized: words([("John's", 0.9), ("book", 0.9), ("is", 0.9), ("here", 0.9)]))
        XCTAssertEqual(states(said), ["heard", "heard", "heard", "heard"])
        let contraction = AttemptCheck(
            target: "She's gone home.",
            recognized: words([("She", 0.9), ("has", 0.9), ("gone", 0.9), ("home", 0.9)]))
        XCTAssertEqual(states(contraction), ["heard", "heard", "heard"], "A contraction still accepts its long form")
        XCTAssertFalse(AttemptCheck.sameWords("John's book", "John is book"))
        XCTAssertTrue(AttemptCheck.sameWords("John's book", "John's book"))
        XCTAssertTrue(AttemptCheck.sameWords("She's gone", "She has gone"))
    }

    func testAmbiguousEndingsMatchEitherReading() {
        let had = AttemptCheck(
            target: "I'd already left",
            recognized: words([("I", 0.9), ("had", 0.9), ("already", 0.9), ("left", 0.9)]))
        XCTAssertEqual(states(had), ["heard", "heard", "heard"])
        let would = AttemptCheck(
            target: "I'd like that", recognized: words([("I", 0.9), ("would", 0.9), ("like", 0.9), ("that", 0.9)]))
        XCTAssertEqual(states(would), ["heard", "heard", "heard"])
        XCTAssertTrue(AttemptCheck.sameWords("it's done", "it has done"))
        XCTAssertFalse(AttemptCheck.sameWords("I'd go", "I will go"))
    }

    func testDashesAndSlashesSeparateWords() {
        let result = AttemptCheck(target: "Wait—what?", recognized: words([("Wait", 0.9), ("what", 0.9)]))
        XCTAssertEqual(states(result), ["heard"])
        XCTAssertTrue(result.extra.isEmpty)
        XCTAssertTrue(AttemptCheck.sameWords("and/or", "and or"))
        XCTAssertTrue(AttemptCheck.sameWords("don't", "do not"), "The apostrophe still joins a contraction")
    }

    func testOtherNumericCharactersNeverCrashAndAreNotSpelled() {
        XCTAssertEqual(AttemptCheck.units(of: "㊿"), ["㊿"])
        XCTAssertEqual(AttemptCheck.units(of: "½"), ["½"])
        XCTAssertEqual(AttemptCheck.units(of: "١٢٣"), ["١٢٣"], "Arabic-Indic digits are not read as English")
        XCTAssertEqual(AttemptCheck.units(of: "42"), ["forty", "two"])
    }
}
