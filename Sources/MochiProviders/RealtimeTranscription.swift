import Foundation
import MochiCore
import MochiKernel
import RealtimeConnection

/// A finished transcription: the trimmed text, and the transcriber's confidence in it when that came back whole.
public struct TranscriptResult: Equatable, Sendable {
    public var text: String
    public var evidence: TranscriptEvidence?
    public init(text: String, evidence: TranscriptEvidence? = nil) {
        self.text = text
        self.evidence = evidence
    }
}
extension RealtimeService {
    /// Transcribes one retained recording using the selected Realtime connection and `transcriptionModel`, with an
    /// optional language hint (`languages`, ISO 639-1). With VAD disabled, commit starts transcription; no
    /// response.create is sent.
    public func transcribe(
        _ pcm: Data, transcriptionModel: String = RealtimeService.transcriptionModel, languages: [String] = []
    ) async throws -> TranscriptResult {
        try await transcribe(
            pcm, transcriptionModel: transcriptionModel, languages: languages, credential: { try await secret() },
            connect: { try await RealtimeChannel.live($0) })
    }
    /// Full transport lifecycle seam: request construction, deadlines and cancellation.
    func transcribe(
        _ pcm: Data, transcriptionModel: String = RealtimeService.transcriptionModel, languages: [String] = [],
        credential: @escaping @Sendable () async throws -> ClientSecret,
        connect: @escaping @Sendable (RealtimeEndpoint) async throws -> RealtimeChannel,
        connectTimeout: UInt64 = RealtimeService.connectTimeout, timeoutNanoseconds: UInt64 = 60_000_000_000
    ) async throws -> TranscriptResult {
        try Self.validateTranscriptionAudio(pcm)
        // An unsupported model and language combination fails here, before any credential or connection.
        _ = try Self.transcriptionFields(model: transcriptionModel, languages: languages)
        try Task.checkCancellation()
        do {
            let channel = try await open(credential: credential, connect: connect, timeout: connectTimeout)
            defer { channel.close() }
            return try await RealtimeDeadline.run(seconds: Self.seconds(timeoutNanoseconds), close: channel.close) {
                try await Self.transcribeTurn(
                    pcm, transcriptionModel: transcriptionModel, languages: languages, send: channel.send,
                    receive: channel.receive)
            }
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            throw Self.transcriptionFailure(error)
        }
    }
    /// The words for a failed transcription. A broken connection says the recording is kept, as a timeout does.
    static func transcriptionFailure(_ error: Error) -> AppFailure {
        switch error {
        case is RealtimeDeadline.Expired:
            return AppFailure("Transcription timed out. Your recording is saved; retry or add text.")
        case let error as AppFailure: return error
        case let error as RealtimeError where error.errorClass == .network:
            let message = ServiceHTTP.failure(error, provider: "OpenAI")?.message ?? ""
            return AppFailure("\(message) Your recording is saved.", underlying: error)
        case let error as RealtimeError:
            if let failure = ServiceHTTP.failure(error, provider: "OpenAI") { return failure }
        case let error as URLError:
            return AppFailure(
                "\(ServiceHTTP.transportFailure(error, provider: "OpenAI").message) Your recording is saved.",
                underlying: error)
        default:
            if let failure = CodexSignIn.failure(error) as? AppFailure { return failure }
        }
        return AppFailure(
            "The transcription connection ended. Your recording is saved; check your connection and retry, or add text.",
            underlying: error)
    }
    /// 16-bit mono 24 kHz PCM from a moment (0.1 s) up to 65 seconds long.
    static func isRecordedAudio(_ pcm: Data) -> Bool {
        pcm.count >= 4800 && pcm.count <= 65 * 48000 && pcm.count.isMultiple(of: 2)
    }
    private static func validateTranscriptionAudio(_ pcm: Data) throws {
        guard isRecordedAudio(pcm) else {
            throw AppFailure("Choose a recording between a moment and 65 seconds long to transcribe.")
        }
    }
    /// Same event path for real WebSockets and deterministic transport tests.
    static func transcribeTurn(
        _ pcm: Data, transcriptionModel: String = RealtimeService.transcriptionModel, languages: [String] = [],
        send: ([String: Any]) async throws -> Void, receive: () async throws -> [String: Any]
    ) async throws -> TranscriptResult {
        try validateTranscriptionAudio(pcm)
        var accumulator = RealtimeAccumulator()
        try await waitFor("session.created", into: &accumulator, receive: receive)
        try await send([
            "type": "session.update",
            "session": [
                "type": "realtime", "output_modalities": ["text"], "include": RealtimeService.transcriptionInclude,
                "audio": [
                    "input": [
                        "format": ["type": "audio/pcm", "rate": 24000], "turn_detection": NSNull(),
                        "transcription": try RealtimeService.transcriptionFields(
                            model: transcriptionModel, languages: languages),
                    ]
                ],
            ],
        ])
        try await waitFor("session.updated", into: &accumulator, receive: receive)
        try await upload(pcm, send: send)
        while accumulator.transcriptionState == .pending {
            try Task.checkCancellation()
            let event = try await receive()
            try Task.checkCancellation()
            // The accumulator ignores transcript events that do not match this commit's item.
            try accumulator.accept(event)
        }
        try Task.checkCancellation()
        guard accumulator.transcriptionState == .completed else {
            throw AppFailure(
                verbatim: accumulator.transcriptionError
                    ?? String(localized: "Transcription failed. Your recording is saved; retry or add text."))
        }
        return TranscriptResult(text: accumulator.inputTranscript, evidence: accumulator.inputEvidence)
    }
}
