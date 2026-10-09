import XCTest
@testable import MochiCore
final class VoiceOptionsTests: XCTestCase {
    func testProviderPayloadsAndValidation() throws {
        var open = OpenAIVoiceOptions(); open.speed = 0.8
        XCTAssertEqual((try open.output(voice:"marin")["speed"] as? NSNumber)?.doubleValue,0.8)
        let json = String(decoding:try JSONSerialization.data(withJSONObject:open.output(voice:"marin")),as:UTF8.self)
        XCTAssertTrue(json.contains("\"speed\":0.8")); XCTAssertFalse(json.contains("0.800000"))
        open.speed = .nan; XCTAssertThrowsError(try open.validate())
        open.speed = 1.6; XCTAssertThrowsError(try open.validate())
    }
}
