import Foundation

public enum TranscriptionState: String, Codable { case pending, completed, failed, timedOut, interrupted }
public struct HelpDraft: Codable {
    public var meaning: String
    public var english: String
    public var recording: String?
    public var expressionID: UUID?
    public var clarification: String?
    public var transcriptReview: String?
    public init(meaning: String = "", english: String = "", recording: String? = nil, expressionID: UUID? = nil) {
        self.meaning = meaning; self.english = english; self.recording = recording; self.expressionID = expressionID
    }
}
public struct HelpSuggestion: Decodable {
    public enum Kind: String, Decodable { case expression, clarification }
    public let kind: Kind
    public let text: String
    public static func parse(_ text: String) throws -> HelpSuggestion {
        guard let value = try? JSONDecoder().decode(Self.self,from:Data(text.utf8)),
              !value.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else {
            throw AppFailure("The English suggestion could not be read. Try again; your thought and previous wording are kept.")
        }
        return value
    }
}
public struct RecordingSignal {
    public let rmsDB: Double
    public let peakDB: Double
    public var isQuiet: Bool { rmsDB < -48 }
    public init(samples: [Float]) {
        let finite = samples.map { $0.isFinite ? Double($0) : 0 }
        let rms = sqrt(finite.reduce(0) { $0 + $1*$1 } / Double(max(1,finite.count)))
        rmsDB = 20*log10(max(rms,1e-9)); peakDB = 20*log10(max(finite.map(abs).max() ?? 0,1e-9))
    }
}
struct RealtimeTimeout: Error {}
/// Cancelling or expiring a deadline closes the transport to unblock a suspended receive.
final class RealtimeDeadline: @unchecked Sendable {
    private let lock = NSLock()
    private var expired = false
    private func expire() { lock.lock(); expired = true; lock.unlock() }
    private var didExpire: Bool { lock.lock(); defer { lock.unlock() }; return expired }
    static func run<T>(nanoseconds: UInt64, close: @escaping @Sendable () -> Void,
                       operation: () async throws -> T) async throws -> T {
        let state = RealtimeDeadline()
        let timer = Task {
            do { try await Task.sleep(nanoseconds:nanoseconds) } catch { return }
            guard !Task.isCancelled else { return }
            state.expire(); close()
        }
        defer { timer.cancel() }
        return try await withTaskCancellationHandler(operation: {
            do {
                try Task.checkCancellation()
                let result = try await operation()
                try Task.checkCancellation()
                if state.didExpire { throw RealtimeTimeout() }
                return result
            } catch {
                if Task.isCancelled { throw CancellationError() }
                if state.didExpire { throw RealtimeTimeout() }
                throw error
            }
        },onCancel:close)
    }
}
struct RealtimeChannel {
    let send: ([String:Any]) async throws -> Void
    let receive: () async throws -> [String:Any]
    let close: @Sendable () -> Void
    static func live(_ request: URLRequest) -> RealtimeChannel {
        let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest = 30
        let session = URLSession(configuration:config)
        let socket = session.webSocketTask(with:request); socket.maximumMessageSize = 4_000_000
        socket.resume()
        return RealtimeChannel(send: { event in
            let bytes = try JSONSerialization.data(withJSONObject:event)
            try await socket.send(.string(String(decoding:bytes,as:UTF8.self)))
        },receive: {
            let message = try await socket.receive()
            let bytes: Data
            switch message {
            case .data(let data): bytes = data
            case .string(let text): bytes = Data(text.utf8)
            @unknown default: throw AppFailure("Unexpected transcription response.")
            }
            guard let event = try JSONSerialization.jsonObject(with:bytes) as? [String:Any] else { throw AppFailure("Invalid transcription event.") }
            return event
        },close: { socket.cancel(with:.goingAway,reason:nil); session.invalidateAndCancel() })
    }
}
extension RealtimeService {
    /// Transcribes one retained recording using the selected Realtime connection.
    /// With VAD disabled, commit starts transcription; no response.create is sent.
    public func transcribe(_ pcm: Data) async throws -> String {
        try await transcribe(pcm,credential: { try await token() },connect:RealtimeChannel.live)
    }
    /// Full transport lifecycle seam: request construction, deadlines and cancellation.
    func transcribe(_ pcm: Data, credential: () async throws -> String,
                    connect: (URLRequest) -> RealtimeChannel,
                    timeoutNanoseconds: UInt64 = 60_000_000_000) async throws -> String {
        try Self.validateTranscriptionAudio(pcm)
        try Task.checkCancellation()
        let token = try await credential()
        try Task.checkCancellation()
        var components = URLComponents(string:"wss://api.openai.com/v1/realtime")!
        components.queryItems = [URLQueryItem(name:"model",value:model)]
        var request = URLRequest(url:components.url!)
        request.setValue("Bearer \(token)",forHTTPHeaderField:"Authorization")
        let channel = connect(request)
        defer { channel.close() }
        do {
            return try await RealtimeDeadline.run(nanoseconds:timeoutNanoseconds,close:channel.close) {
                try await Self.transcribeTurn(pcm,send:channel.send,receive:channel.receive)
            }
        } catch is CancellationError { throw CancellationError() }
        catch is RealtimeTimeout { throw AppFailure("Transcription timed out. Your recording is saved; retry or add text.") }
        catch let error as AppFailure { throw error }
        catch { throw AppFailure("The transcription connection ended. Your recording is saved; check your connection and retry, or add text.") }
    }
    private static func validateTranscriptionAudio(_ pcm: Data) throws {
        guard pcm.count >= 4800, pcm.count <= 65*48000, pcm.count.isMultiple(of:2) else {
            throw AppFailure("Choose a recording between a moment and 65 seconds long to transcribe.")
        }
    }
    /// Same event path for real WebSockets and deterministic transport tests.
    static func transcribeTurn(_ pcm: Data, send: ([String:Any]) async throws -> Void,
                               receive: () async throws -> [String:Any]) async throws -> String {
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
        try await send(["type":"session.update","session":["type":"realtime","output_modalities":["text"],"audio":["input":["format":["type":"audio/pcm","rate":24000],"turn_detection":NSNull(),"transcription":["model":"gpt-4o-mini-transcribe"]]]]])
        try await waitFor("session.updated")
        for offset in stride(from:0,to:pcm.count,by:48000) {
            try Task.checkCancellation()
            try await send(["type":"input_audio_buffer.append","audio":pcm.subdata(in:offset..<min(offset+48000,pcm.count)).base64EncodedString()])
        }
        try Task.checkCancellation()
        try await send(["type":"input_audio_buffer.commit"])
        while accumulator.transcriptionState == .pending {
            try Task.checkCancellation()
            let event = try await receive()
            try Task.checkCancellation()
            // Ignore uncorrelated transcript events until the server acknowledges this commit.
            if accumulator.inputItemID == nil,
               (event["type"] as? String)?.hasPrefix("conversation.item.input_audio_transcription.") == true { continue }
            try accumulator.accept(event)
        }
        try Task.checkCancellation()
        guard accumulator.transcriptionState == .completed else {
            throw AppFailure(accumulator.transcriptionError ?? "Transcription failed. Your recording is saved; retry or add text.")
        }
        return accumulator.inputTranscript
    }
}
