import MochiKernel
import RealtimeConnection
import XCTest

@testable import MochiProviders

final class RealtimeEventsTests: XCTestCase {
    func testRestoredHistoryUsesRealtimeContentTypes() throws {
        for (role, expected) in [("assistant", "output_text"), ("user", "input_text"), ("system", "input_text")] {
            let event = RealtimeEvents.message(role: role, text: "Context")
            let item = try XCTUnwrap(event["item"] as? [String: Any])
            let content = try XCTUnwrap(item["content"] as? [[String: String]])
            XCTAssertEqual(item["role"] as? String, role)
            XCTAssertEqual(content.first?["type"], expected)
            XCTAssertEqual(content.first?["text"], "Context")
        }
    }
    func testRequestFormatErrorDoesNotBlameAccountOrEchoMessage() {
        var result = RealtimeAccumulator()
        XCTAssertThrowsError(
            try result.accept([
                "type": "error",
                "error": ["code": "invalid_value", "param": "item.content[0].type", "message": "private-token"],
            ])
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("request format"))
            XCTAssertTrue(error.localizedDescription.contains("item.content[0].type"))
            XCTAssertFalse(error.localizedDescription.contains("account"))
            XCTAssertFalse(error.localizedDescription.contains("private-token"))
        }
        XCTAssertFalse(
            RealtimeEvents.failure(["code": "private-token", "param": "private-token"]).localizedDescription.contains(
                "private-token"))
        XCTAssertFalse(
            RealtimeEvents.failure(["code": "invalid_value", "param": "private-token"]).localizedDescription.contains(
                "private-token"))
    }
    func testRealtimeAccumulator() throws {
        var result = RealtimeAccumulator()
        try result.accept(["type": "response.output_text.delta", "delta": "Hello"])
        XCTAssertEqual(result.text, "Hello")
        try result.accept(["type": "response.output_audio.delta", "delta": Data([0, 1]).base64EncodedString()])
        XCTAssertEqual(result.audio.count, 2)
        XCTAssertThrowsError(try result.accept(["type": "error", "error": ["message": "private-token"]])) { error in
            XCTAssertFalse(error.localizedDescription.contains("private-token"))
        }
    }
    func testFailedResponseCannotBecomeSuccess() {
        var result = RealtimeAccumulator()
        XCTAssertThrowsError(try result.accept(["type": "response.done", "response": ["status": "failed"]]))
    }
}

extension RealtimeEventsTests {
    func testDamagedAudioDeltaIsRejected() {
        var reply = RealtimeAccumulator()
        XCTAssertThrowsError(try reply.accept(["type": "response.output_audio.delta", "delta": "not base64!"]))
        XCTAssertThrowsError(try reply.accept(["type": "response.output_audio.delta"]))
        XCTAssertTrue(reply.audio.isEmpty)
    }

    func testReplyStoppedAtTheLengthLimitIsKeptAndMarked() throws {
        var reply = RealtimeAccumulator()
        try reply.accept(["type": "response.output_text.delta", "delta": "A long answer"])
        try reply.accept([
            "type": "response.done",
            "response": ["status": "incomplete", "status_details": ["reason": "max_output_tokens"]],
        ])
        XCTAssertTrue(reply.done)
        XCTAssertTrue(reply.truncated)
        XCTAssertEqual(reply.text, "A long answer")
        var other = RealtimeAccumulator()
        XCTAssertThrowsError(
            try other.accept([
                "type": "response.done",
                "response": ["status": "incomplete", "status_details": ["reason": "content_filter"]],
            ]))
    }

    /// An unreadable event of a type Mochi never reads is skipped; one Mochi depends on, or one without a readable
    /// type, still fails the session. The errors are the shared package's own, from its own decoder.
    func testOnlyUnreadableEventsMochiDoesNotConsumeAreSkipped() async throws {
        func decoded(_ json: String) -> Result<RealtimeMessage, Error> {
            Result { try RealtimeMessage(raw: Data(json.utf8)) }
        }
        let next = decoded(#"{"type":"response.output_text.delta","delta":"Hi"}"#)
        for malformed in [
            #"{"type":"rate_limits.updated"}"#, #"{"type":"rate_limits.updated","rate_limits":[{"name":"requests"}]}"#,
            #"{"type":"response.created"}"#,
            #"{"type":"conversation.item.input_audio_transcription.delta","delta":7}"#,
        ] {
            guard case .failure = decoded(malformed) else { return XCTFail("The package read \(malformed)") }
            var queue = [decoded(malformed), next]
            let event = try await RealtimeChannel.event { try queue.removeFirst().get() }
            XCTAssertEqual(event["delta"] as? String, "Hi", malformed)
        }
        for malformed in [
            #"{"type":"response.done"}"#, #"{"type":"session.created"}"#, #"{"type":"error","error":7}"#,
            #"{"type":"response.output_audio.delta","response_id":"r","delta":"not base64!"}"#,
            #"{"type":"input_audio_buffer.committed","item_id":7}"#,
            #"{"type":"conversation.item.input_audio_transcription.completed","item_id":7}"#, #"{"no":"type"}"#,
            "not json",
        ] {
            guard case .failure = decoded(malformed) else { return XCTFail("The package read \(malformed)") }
            var queue = [decoded(malformed), next]
            do {
                _ = try await RealtimeChannel.event { try queue.removeFirst().get() }
                XCTFail("\(malformed) was skipped")
            } catch { XCTAssertEqual((error as? AppFailure)?.message, "Invalid Realtime event.", malformed) }
        }
    }
}
