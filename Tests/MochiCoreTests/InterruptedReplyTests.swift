import MochiCore
import XCTest

final class InterruptedReplyTests: XCTestCase {
    func testKeepsTheShareHeardCutAtAWordBoundary() {
        let text = "Tell me more about your weekend in the mountains."
        XCTAssertEqual(InterruptedReply.heard(text, fraction: 0.5), "Tell me more about your…")
        XCTAssertEqual(InterruptedReply.heard(text, fraction: 0.1), "Tell…")
        XCTAssertEqual(InterruptedReply.heard(text, fraction: 0.06), "…", "A first word heard only in part is not kept")
    }

    func testNearlyAllHeardKeepsTheWholeReply() {
        let text = "That sounds lovely."
        XCTAssertEqual(InterruptedReply.heard(text, fraction: 0.98), text)
        XCTAssertEqual(InterruptedReply.heard(text, fraction: .nan), text)
    }

    func testInterruptedAtOnceLeavesOnlyTheEllipsis() {
        XCTAssertEqual(InterruptedReply.heard("Hello there.", fraction: 0), "…")
        XCTAssertEqual(InterruptedReply.heard("Hello there.", fraction: -1), "…")
    }

    func testTrailingPunctuationIsDroppedBeforeTheEllipsis() {
        XCTAssertEqual(InterruptedReply.heard("Well, maybe. Or not at all.", fraction: 0.45), "Well, maybe…")
    }

    func testOpeningPunctuationIsKept() {
        XCTAssertEqual(InterruptedReply.heard("¿Qué tal tu fin de semana?", fraction: 12.5 / 26), "¿Qué tal tu…")
        XCTAssertEqual(InterruptedReply.heard("“Really,” she said, smiling.", fraction: 13.5 / 28), "“Really,” she…")
        XCTAssertEqual(InterruptedReply.heard("«Bonjour», dit-il encore.", fraction: 17.5 / 25), "«Bonjour», dit-il…")
        XCTAssertEqual(InterruptedReply.heard("¿Sí? Claro.", fraction: 0.1), "…", "Punctuation alone is not kept")
    }

    func testAWordEndingInPunctuationIsKept() {
        XCTAssertEqual(InterruptedReply.heard("Hello, world. How are you?", fraction: 5.0 / 26), "Hello…")
    }

    func testAWordBeforeADashIsKept() {
        XCTAssertEqual(InterruptedReply.heard("Hello—world", fraction: 0.8), "Hello…")
        XCTAssertEqual(InterruptedReply.heard("今天 wonderful", fraction: 0.6), "今天…")
    }

    func testAContractionIsOneWord() {
        XCTAssertEqual(InterruptedReply.heard("I can't go there today.", fraction: 0.22), "I…")
        XCTAssertEqual(InterruptedReply.heard("I can’t go there today.", fraction: 0.22), "I…", "Curly apostrophe")
        XCTAssertEqual(InterruptedReply.heard("A well-known place to visit.", fraction: 0.22), "A…")
    }

    func testASingleWordHeardInPartIsNotKept() {
        XCTAssertEqual(InterruptedReply.heard("Wonderful", fraction: 0.5), "…")
    }

    func testWordsInMixedTextKeepTheirBoundaries() {
        XCTAssertEqual(InterruptedReply.heard("Wonderful 世界", fraction: 0.25), "…", "A Latin word is not cut")
        XCTAssertEqual(InterruptedReply.heard("Hi 今天天气很好", fraction: 0.7), "Hi 今天天…", "Han text is cut in place")
    }

    func testTextWithoutSpacesIsCutWhereItIs() {
        XCTAssertEqual(InterruptedReply.heard("今天天气很好我们去公园吧", fraction: 0.5), "今天天气很好…")
    }
}
