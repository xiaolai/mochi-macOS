import Foundation
import MochiCore
import MochiKernel

/// A one-shot text reply from the endpoint Codex itself uses with a ChatGPT sign-in, for requests that need
/// structured text rather than a live voice session. It is not a documented public API, so every caller keeps the
/// Realtime path as its fallback.
public struct CodexTextService {
    public static let endpoint = URL(string: "https://chatgpt.com/backend-api/codex/responses")!
    /// The reply shape for Help Me Say This; the service enforces it, so no code fence or lead-in can appear.
    static let helpSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "kind": ["type": "string", "enum": ["expression", "clarification"]],
            "text": ["type": "string"],
        ],
        "required": ["kind", "text"], "additionalProperties": false,
    ]
    public var model: CodexModel
    /// The reasoning effort to send; nil leaves the model's own default.
    public var effort: String?
    public init(model: CodexModel, effort: String? = nil) {
        self.model = model
        self.effort = effort ?? model.lightestEffort
    }

    /// The text of the reply to a Help Me Say This request.
    public func help(
        _ input: ConversationRequest,
        signIn: () async throws -> CodexAccount = { try await CodexSignIn.account() },
        transport: (URLRequest) async throws -> Data = { try await ServiceHTTP.data($0, provider: "OpenAI") }
    ) async throws -> String {
        let signedIn = try await signIn()
        guard let account = signedIn.accountID else {
            throw AppFailure(verbatim: "Codex's sign-in has no ChatGPT account id.")
        }
        try Task.checkCancellation()
        let data = try await transport(request(input, token: signedIn.token, account: account))
        return try Self.text(fromEvents: data)
    }

    func request(_ input: ConversationRequest, token: String, account: String) throws -> URLRequest {
        var items: [[String: Any]] = []
        for message in input.history.suffix(30) {
            guard let text = message.contextText else { continue }
            let assistant = message.role == "assistant"
            items.append([
                "type": "message", "role": assistant ? "assistant" : "user",
                "content": [["type": assistant ? "output_text" : "input_text", "text": text]],
            ])
        }
        items.append(["type": "message", "role": "user", "content": [["type": "input_text", "text": input.text]]])
        var body: [String: Any] = [
            "model": model.slug, "instructions": input.resolvedInstructions, "input": items, "stream": true,
            "store": false,
            "text": ["format": ["type": "json_schema", "name": "help", "strict": true, "schema": Self.helpSchema]],
        ]
        if let effort { body["reasoning"] = ["effort": effort] }
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(account, forHTTPHeaderField: "chatgpt-account-id")
        request.setValue("responses=experimental", forHTTPHeaderField: "OpenAI-Beta")
        request.setValue("codex_cli_rs", forHTTPHeaderField: "originator")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// The output text of a finished server-sent-event stream; a failed or empty stream is an error.
    static func text(fromEvents data: Data) throws -> String {
        var text = ""
        var completed = false
        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            guard line.hasPrefix("data:"),
                let event = try? JSONSerialization.jsonObject(
                    with: Data(line.dropFirst(5).trimmingCharacters(in: .whitespaces).utf8)) as? [String: Any]
            else { continue }
            switch event["type"] as? String {
            case "response.output_text.delta": text += event["delta"] as? String ?? ""
            case "response.completed": completed = true
            case "response.failed", "response.incomplete", "error":
                throw AppFailure(verbatim: "The Codex text reply did not finish (\(event["type"] as? String ?? "")).")
            default: break
            }
        }
        guard completed, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppFailure(verbatim: "The Codex text reply was empty or incomplete.")
        }
        return text
    }
}
