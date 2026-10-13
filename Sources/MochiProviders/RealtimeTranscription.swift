import Foundation
import MochiCore
import MochiKernel

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
            pcm, transcriptionModel: transcriptionModel, languages: languages, credential: { try await token() },
            connect: RealtimeChannel.live)
    }
    /// Full transport lifecycle seam: request construction, deadlines and cancellation.
    func transcribe(
        _ pcm: Data, transcriptionModel: String = RealtimeService.transcriptionModel, languages: [String] = [],
        credential: () async throws -> String, connect: (URLRequest) -> RealtimeChannel,
        timeoutNanoseconds: UInt64 = 60_000_000_000
    ) async throws -> TranscriptResult {
        try Self.validateTranscriptionAudio(pcm)
        try Task.checkCancellation()
        let token = try await credential()
        try Task.checkCancellation()
        let channel = connect(realtimeRequest(token: token))
        defer { channel.close() }
        do {
            return try await RealtimeDeadline.run(nanoseconds: timeoutNanoseconds, close: channel.close) {
                try await Self.transcribeTurn(
                    pcm, transcriptionModel: transcriptionModel, languages: languages, send: channel.send,
                    receive: channel.receive)
            }
        } catch is CancellationError { throw CancellationError() } catch is RealtimeTimeout {
            throw AppFailure("Transcription timed out. Your recording is saved; retry or add text.")
        } catch let error as AppFailure { throw error } catch let error as URLError {
            throw AppFailure(
                "\(ServiceHTTP.transportFailure(error, provider: "OpenAI").message) Your recording is saved.",
                underlying: error)
        } catch {
            throw AppFailure(
                "The transcription connection ended. Your recording is saved; check your connection and retry, or add text.",
                underlying: error)
        }
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
        func waitFor(_ type: String) async throws {
            while true {
                try Task.checkCancellation()
                let event = try await receive()
                try Task.checkCancellation()
                try accumulator.accept(event)
                if event["type"] as? String == type { return }
            }
        }
        try await waitFor("session.created")
        try await send([
            "type": "session.update",
            "session": [
                "type": "realtime", "output_modalities": ["text"], "include": RealtimeService.transcriptionInclude,
                "audio": [
                    "input": [
                        "format": ["type": "audio/pcm", "rate": 24000], "turn_detection": NSNull(),
                        "transcription": RealtimeService.transcriptionFields(
                            model: transcriptionModel, languages: languages),
                    ]
                ],
            ],
        ])
        try await waitFor("session.updated")
        for offset in stride(from: 0, to: pcm.count, by: 48000) {
            try Task.checkCancellation()
            try await send([
                "type": "input_audio_buffer.append",
                "audio": pcm.subdata(in: offset..<min(offset + 48000, pcm.count)).base64EncodedString(),
            ])
        }
        try Task.checkCancellation()
        try await send(["type": "input_audio_buffer.commit"])
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
