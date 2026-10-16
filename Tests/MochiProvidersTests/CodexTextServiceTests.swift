import MochiCore
import MochiKernel
import XCTest

@testable import MochiProviders

final class CodexTextServiceTests: XCTestCase {
    private let signIn = CodexAccount(token: "token-value", accountID: "account-1")
    private let model = CodexModel(
        slug: "listed-model", name: "Listed", priority: 3, efforts: ["low", "high"], defaultEffort: "medium")

    private func events(_ pieces: [String], finish: String = "response.completed") -> Data {
        var lines = pieces.map { piece -> String in
            let delta = String(
                decoding: try! JSONSerialization.data(withJSONObject: piece, options: .fragmentsAllowed), as: UTF8.self)
            return
                "event: response.output_text.delta\ndata: {\"type\":\"response.output_text.delta\",\"delta\":\(delta)}\n"
        }
        lines.append("event: \(finish)\ndata: {\"type\":\"\(finish)\"}\n")
        return Data(lines.joined(separator: "\n").utf8)
    }

    func testRequestCarriesTheModelEffortSchemaAndAccount() async throws {
        var sent: URLRequest?
        let help = ConversationRequest(
            history: [Message(role: "user", text: "Earlier"), Message(role: "assistant", text: "Reply")],
            text: "我不太确定", help: true)
        let text = try await CodexTextService(model: model).help(
            help, signIn: { self.signIn },
            transport: {
                sent = $0
                return self.events(#"{"kind":"expression","text":"I'm not sure."}"#.map(String.init))
            })
        XCTAssertEqual(text, #"{"kind":"expression","text":"I'm not sure."}"#)
        let request = try XCTUnwrap(sent)
        XCTAssertEqual(request.url, CodexTextService.endpoint)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token-value")
        XCTAssertEqual(request.value(forHTTPHeaderField: "chatgpt-account-id"), "account-1")
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "listed-model")
        XCTAssertEqual((body["reasoning"] as? [String: Any])?["effort"] as? String, "low")
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["store"] as? Bool, false)
        let format = (body["text"] as? [String: Any])?["format"] as? [String: Any]
        XCTAssertEqual(format?["type"] as? String, "json_schema")
        XCTAssertEqual(format?["strict"] as? Bool, true)
        let items = try XCTUnwrap(body["input"] as? [[String: Any]])
        XCTAssertEqual(items.map { $0["role"] as? String }, ["user", "assistant", "user"])
        let last = (items.last?["content"] as? [[String: Any]])?.first
        XCTAssertEqual(last?["type"] as? String, "input_text")
        XCTAssertEqual(last?["text"] as? String, "我不太确定")
        XCTAssertEqual(body["instructions"] as? String, help.resolvedInstructions)
    }

    func testAMissingAccountIsRefusedBeforeAnyRequest() async {
        do {
            _ = try await CodexTextService(model: model).help(
                ConversationRequest(history: [], text: "x", help: true),
                signIn: { CodexAccount(token: "t", accountID: nil) },
                transport: { _ in
                    XCTFail("no request without an account")
                    return Data()
                })
            XCTFail("expected a failure")
        } catch {}
    }

    func testAStreamThatFailedOrEndedEmptyIsAnError() {
        XCTAssertThrowsError(try CodexTextService.text(fromEvents: events(["{}"], finish: "response.failed")))
        XCTAssertThrowsError(try CodexTextService.text(fromEvents: events([], finish: "response.completed")))
        XCTAssertThrowsError(try CodexTextService.text(fromEvents: events(["{}"], finish: "response.incomplete")))
        // Text that never completed is not trusted.
        XCTAssertThrowsError(
            try CodexTextService.text(
                fromEvents: Data(#"data: {"type":"response.output_text.delta","delta":"{"}"#.utf8)))
    }

    func testDeltasAreJoinedInOrder() throws {
        XCTAssertEqual(
            try CodexTextService.text(fromEvents: events(["{\"kind\":", "\"expression\",", "\"text\":\"Hi\"}"])),
            #"{"kind":"expression","text":"Hi"}"#)
    }
}
