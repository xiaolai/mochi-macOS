import XCTest
@testable import MochiCore
final class ProviderTests: XCTestCase {
    func testRestoredHistoryUsesRealtimeContentTypes() throws {
        for (role, expected) in [("assistant", "output_text"), ("user", "input_text"), ("system", "input_text")] {
            let event = RealtimeEvents.message(role:role,text:"Context")
            let item = try XCTUnwrap(event["item"] as? [String:Any])
            let content = try XCTUnwrap(item["content"] as? [[String:String]])
            XCTAssertEqual(item["role"] as? String,role)
            XCTAssertEqual(content.first?["type"],expected)
            XCTAssertEqual(content.first?["text"],"Context")
        }
    }
    func testRequestFormatErrorDoesNotBlameAccountOrEchoMessage() {
        var result = RealtimeAccumulator()
        XCTAssertThrowsError(try result.accept(["type":"error", "error":["code":"invalid_value", "param":"item.content[0].type", "message":"private-token"]])) { error in
            XCTAssertTrue(error.localizedDescription.contains("request format"))
            XCTAssertTrue(error.localizedDescription.contains("item.content[0].type"))
            XCTAssertFalse(error.localizedDescription.contains("account"))
            XCTAssertFalse(error.localizedDescription.contains("private-token"))
        }
        XCTAssertFalse(RealtimeEvents.failure(["code":"private-token", "param":"private-token"]).localizedDescription.contains("private-token"))
        XCTAssertFalse(RealtimeEvents.failure(["code":"invalid_value", "param":"private-token"]).localizedDescription.contains("private-token"))
    }
    func testProviderFailureDoesNotEchoBody() {
        XCTAssertFalse(ServiceHTTP.failure(status: 401, provider: "Voice").localizedDescription.contains("secret"))
        XCTAssertTrue(ServiceHTTP.failure(status: 429, provider: "Voice").localizedDescription.contains("limit"))
    }
    func testRealtimeAccumulator() throws {
        var result = RealtimeAccumulator()
        try result.accept(["type":"response.output_text.delta", "delta":"Hello"])
        XCTAssertEqual(result.text, "Hello")
        try result.accept(["type":"response.output_audio.delta", "delta":Data([0,1]).base64EncodedString()])
        XCTAssertEqual(result.audio.count, 2)
        XCTAssertThrowsError(try result.accept(["type":"error","error":["message":"private-token"]])) { error in
            XCTAssertFalse(error.localizedDescription.contains("private-token"))
        }
    }
    func testFailedResponseCannotBecomeSuccess() {
        var result = RealtimeAccumulator()
        XCTAssertThrowsError(try result.accept(["type":"response.done", "response":["status":"failed"]]))
    }
}
