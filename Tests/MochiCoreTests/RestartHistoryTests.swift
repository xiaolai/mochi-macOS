import XCTest

@testable import MochiCore

final class RestartHistoryTests: XCTestCase {
    private func messages(_ count: Int) -> [Message] {
        (1...count).map { Message(role: $0 % 2 == 1 ? "user" : "assistant", text: "m\($0)") }
    }

    func testAShortConversationIsSentWhole() {
        let all = messages(30)
        XCTAssertEqual(RestartHistory.select(all).map(\.text), all.map(\.text))
    }
    func testALongConversationKeepsItsOpeningAndItsLatestInOrder() {
        let selected = RestartHistory.select(messages(46)).map(\.text)
        XCTAssertEqual(selected.count, RestartHistory.total)
        XCTAssertEqual(Array(selected.prefix(10)), (1...10).map { "m\($0)" })
        XCTAssertEqual(Array(selected.suffix(20)), (27...46).map { "m\($0)" })
    }
    func testOpeningAndLatestNeverRepeatAMessage() {
        let selected = RestartHistory.select(messages(31))
        XCTAssertEqual(Set(selected.map(\.id)).count, selected.count)
        XCTAssertEqual(selected.map(\.text), (1...10).map { "m\($0)" } + (12...31).map { "m\($0)" })
    }
    func testOnlyMessagesThatAreSentCount() {
        var all = messages(40)
        // A voice message whose transcript failed is never sent, so it neither fills nor ends the opening.
        all[2] = Message(role: "user", text: "", audio: "voice.wav")
        var transcribed = Message(role: "user", text: "spoken words", audio: "spoken.wav")
        transcribed.transcriptionState = nil
        all[4] = transcribed
        let selected = RestartHistory.select(all)
        XCTAssertFalse(selected.contains { $0.audio == "voice.wav" })
        XCTAssertTrue(selected.contains { $0.text == "spoken words" })
        XCTAssertEqual(selected.count, 30)
        XCTAssertEqual(selected[9].text, "m11", "The opening is ten sent messages")
    }
}
