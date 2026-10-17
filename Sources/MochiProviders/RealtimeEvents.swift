import Foundation
import MochiCore
import MochiKernel
import RealtimeConnection

enum RealtimeEvents {
    static func message(role: String, text: String) -> [String: Any] {
        [
            "type": "conversation.item.create",
            "item": [
                "type": "message", "role": role,
                "content": [["type": role == "assistant" ? "output_text" : "input_text", "text": text]],
            ],
        ]
    }
    /// A server `error` event, classified by the shared package from its type and code.
    static func failure(_ error: [String: Any]?) -> AppFailure {
        func text(_ key: String) -> String {
            (error?[key] as? String) ?? (error?[key] as? NSNumber).map { "\($0)" } ?? ""
        }
        return failure(
            RealtimeError.errorEvent(
                type: text("type"), code: text("code"), param: text("param"), message: text("message")))
    }
    /// Mochi's words for a classified error event: the provider code picks among them, and the class decides the
    /// rest. Never the provider's message: it can contain user input or credentials.
    static func failure(_ event: RealtimeError) -> AppFailure {
        let error = event.withoutProviderMessage
        let code = error.code
        switch code {
        case "invalid_value", "invalid_request_error", "unknown_parameter", "missing_required_parameter",
            "invalid_parameter", "decimal_max_decimal_places_exceeded":
            let param = error.param
            let field =
                (param == "session.audio.output.speed"
                    || param.range(of: #"^item\.content\[[0-9]{1,2}\]\.type$"#, options: .regularExpression) != nil)
                ? "; field: \(param)" : ""
            return AppFailure("OpenAI rejected Mochi's request format (\(code)\(field)).", underlying: error)
        case "invalid_api_key", "authentication_error":
            return AppFailure(
                "Your Codex sign-in was rejected. Sign in through Codex again, then retry.", underlying: error)
        case "model_not_found":
            return AppFailure(
                "OpenAI could not access the selected model. Check the model in Settings.", underlying: error)
        default: break
        }
        if error.type == "authentication_error" {
            return AppFailure(
                "Your Codex sign-in was rejected. Sign in through Codex again, then retry.", underlying: error)
        }
        if error.errorClass == .rateLimited {
            let named = code.isEmpty ? error.type : code
            return AppFailure(
                "OpenAI usage limit reached (\(named)). Check your usage or retry later.", underlying: error)
        }
        return AppFailure(
            "OpenAI rejected this request. Please retry; the cause could not be identified.", underlying: error)
    }
}
extension RealtimeError {
    /// The error without the provider's free text, which can hold user input; class, status, code and request id stay
    /// for diagnostics.
    var withoutProviderMessage: RealtimeError {
        var error = self
        error.message = ""
        return error
    }
}
public struct RealtimeAccumulator {
    public var text = ""
    public var audio = Data()
    public var inputTranscript = ""
    /// The transcriber's confidence in `inputTranscript`; nil when its tokens did not come back whole.
    public var inputEvidence: TranscriptEvidence?
    public var done = false
    public var transcriptionState: TranscriptionState = .pending
    public var transcriptionError: String?
    public var inputItemID: String?
    /// The reply stopped at Mochi's output limit; what streamed before it is kept.
    public var truncated = false
    private var separateNextText = false
    /// How much text and audio earlier rounds left, so a round cut off at the limit is judged by what it said.
    private var roundStart = (text: 0, audio: 0)
    public init() {}
    /// Starts the reply that follows tool results, so its text does not run into the previous round's.
    public mutating func beginNextRound() {
        done = false
        separateNextText = !(text.last?.isWhitespace ?? true)
        roundStart = (text.utf8.count, audio.count)
    }
    /// A log probability is at most 0, but `gpt-transcribe` sends some just above it from rounding (a fifth of its
    /// tokens, at most 1.1e-4, over 531 tokens on 2026-10-14). Those count as 0; anything further above is malformed.
    static let logprobRoundingTolerance = 0.001
    /// Evidence from a completed transcription's `logprobs`: each token's bytes and log probability. Anything
    /// missing or malformed gives none; the transcript itself is kept either way.
    /// A finite JSON number. JSON `true` and `false` also arrive as NSNumber and are refused, never read as 1 or 0.
    private static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite
        else { return nil }
        return value.doubleValue
    }
    static func evidence(text: String, raw: String, logprobs: Any?) -> TranscriptEvidence? {
        guard let entries = logprobs as? [[String: Any]], !entries.isEmpty else { return nil }
        var tokens: [(bytes: [UInt8], logprob: Double)] = []
        for entry in entries {
            guard let values = entry["bytes"] as? [NSNumber], let logprob = number(entry["logprob"]),
                logprob <= logprobRoundingTolerance
            else { return nil }
            let bytes = values.compactMap { value -> UInt8? in
                guard let number = number(value), number.rounded() == number, (0...255).contains(number) else {
                    return nil
                }
                return UInt8(number)
            }
            guard bytes.count == values.count else { return nil }
            tokens.append((bytes, min(logprob, 0)))
        }
        return TranscriptEvidence(text: text, raw: raw, tokens: tokens)
    }
    public mutating func accept(_ event: [String: Any]) throws {
        switch event["type"] as? String {
        case "response.output_text.delta", "response.text.delta", "response.output_audio_transcript.delta",
            "response.audio_transcript.delta":
            let delta = event["delta"] as? String ?? ""
            if separateNextText && !delta.isEmpty {
                text += "\n"
                separateNextText = false
            }
            text += delta
        case "response.output_audio.delta", "response.audio.delta":
            guard let encoded = event["delta"] as? String, let chunk = Data(base64Encoded: encoded) else {
                throw AppFailure("Mochi's response audio arrived damaged. Please retry.")
            }
            audio.append(chunk)
            guard audio.count < 16_000_000 else { throw AppFailure("Mochi's response exceeded the audio limit.") }
        case "input_audio_buffer.committed": inputItemID = event["item_id"] as? String
        case "conversation.item.input_audio_transcription.completed",
            "conversation.item.input_audio_transcription.failed":
            guard transcriptionState == .pending,
                inputItemID != nil && event["item_id"] as? String == inputItemID
            else { return }
            if event["type"] as? String == "conversation.item.input_audio_transcription.completed" {
                let raw = event["transcript"] as? String ?? ""
                inputTranscript = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                inputEvidence = Self.evidence(text: inputTranscript, raw: raw, logprobs: event["logprobs"])
                transcriptionState = inputTranscript.isEmpty ? .failed : .completed
                if inputTranscript.isEmpty {
                    transcriptionError = "No clear speech was recognized. Your recording is saved."
                }
            } else {
                transcriptionState = .failed
                let error = event["error"] as? [String: Any]
                transcriptionError =
                    error?["code"] as? String == "audio_unintelligible"
                    ? String(localized: "No clear speech was recognized. Check your microphone level or add text.")
                    : String(
                        localized: "Transcription failed. Your recording is saved; retry transcription or add text.")
            }
        case "response.done":
            let response = event["response"] as? [String: Any]
            let status = response?["status"] as? String
            let reason = (response?["status_details"] as? [String: Any])?["reason"] as? String
            if status == "incomplete" && reason == "max_output_tokens" {
                // Only words or speech can be cut short; a round of tool calls alone is answered and continues.
                if text.utf8.count > roundStart.text || audio.count > roundStart.audio { truncated = true }
                done = true
                return
            }
            guard status == "completed" else {
                // The message the learner sees cannot say why; the log can.
                MochiLog.network.error(
                    "Response ended \(status ?? "without a status", privacy: .public): \(reason ?? "no reason given", privacy: .public)"
                )
                throw AppFailure("Mochi could not complete that response. Please retry.")
            }
            done = true
        case "error": throw RealtimeEvents.failure(event["error"] as? [String: Any])
        default: break
        }
    }
}
