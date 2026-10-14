import Foundation
import MochiCore
import MochiKernel

/// How a listening session decides that the learner has finished a turn.
public enum TurnDetection: Equatable, Sendable {
    /// Judged from the words said; `eagerness` is `low`, `medium` or `high` (plan F9).
    case semantic(eagerness: String)
    /// Judged from silence alone: the turn ends after this many milliseconds without speech. E5's baseline.
    case silence(milliseconds: Int)

    /// The session's `turn_detection`. It never creates or interrupts a response: the session only listens.
    var configuration: [String: Any] {
        switch self {
        case .semantic(let eagerness):
            return [
                "type": "semantic_vad", "eagerness": eagerness, "create_response": false,
                "interrupt_response": false,
            ]
        case .silence(let milliseconds):
            return [
                "type": "server_vad", "silence_duration_ms": milliseconds, "prefix_padding_ms": 300,
                "create_response": false, "interrupt_response": false,
            ]
        }
    }
}

/// What a listening session reports about the turn being streamed.
public enum ListeningSignal: Equatable, Sendable {
    /// The API heard speech begin, at this point of the streamed audio.
    case speechStarted(audioMilliseconds: Int?)
    /// The API judged the turn ended, at this point of the streamed audio.
    case speechStopped(audioMilliseconds: Int?)
    /// The heard turn's transcript; empty when nothing was recognized.
    case transcribed(String)
}

/// One hands-free turn streamed to a transcription-only Realtime session with turn detection on (plan D2, H2).
/// The app opens it when listening starts or resumes, so no handshake delays the turn, but appends audio only once
/// the Mac hears speech start; it closes when the turn ends, so nothing streams between turns. The session never
/// answers: the turn's audio, kept on the Mac, goes through the ordinary reply path afterwards (D3).
public final class ListeningSession: @unchecked Sendable {
    /// Signals in the order the API sent them. Ends when the session closes; throws when it fails.
    public let signals: AsyncThrowingStream<ListeningSignal, Error>
    private let outgoing: AsyncStream<Data>.Continuation
    private let signalSink: AsyncThrowingStream<ListeningSignal, Error>.Continuation
    private let channel: RealtimeChannel
    private let lock = NSLock()
    private var workers: [Task<Void, Never>] = []
    private var closed = false
    private var sent = 0
    /// Bytes of audio the connection has accepted so far, not counting audio still queued behind it.
    public var sentBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return sent
    }

    private init(channel: RealtimeChannel) {
        self.channel = channel
        (signals, signalSink) = AsyncThrowingStream.makeStream(of: ListeningSignal.self)
        let (audio, outgoing) = AsyncStream.makeStream(of: Data.self)
        self.outgoing = outgoing
        let send = channel.send
        let receive = channel.receive
        let sink = signalSink
        // One sender keeps audio in capture order; the receiver turns events into signals until the session ends.
        let sender = Task { [weak self] in
            do {
                for await chunk in audio {
                    try await send([
                        "type": "input_audio_buffer.append", "audio": chunk.base64EncodedString(),
                    ])
                    self?.countSent(chunk.count)
                }
            } catch { self?.fail(error) }
        }
        let receiver = Task { [weak self] in
            var item = ListeningItem()
            do {
                while !Task.isCancelled {
                    let event = try await receive()
                    if let signal = try item.accept(event) { sink.yield(signal) }
                }
            } catch { self?.fail(error) }
        }
        // A worker that failed at once may already have closed the session; then nothing must keep running.
        lock.lock()
        let alreadyClosed = closed
        if !alreadyClosed { workers = [sender, receiver] }
        lock.unlock()
        if alreadyClosed {
            sender.cancel()
            receiver.cancel()
        }
    }

    /// Opens a session for one turn. `handshakeTimeout` bounds credential, connection and configuration together.
    public static func open(
        model: String = RealtimeService.defaultModel, detection: TurnDetection,
        transcriptionModel: String = RealtimeService.transcriptionModel, languages: [String] = [],
        handshakeTimeout: UInt64 = 10_000_000_000
    ) async throws -> ListeningSession {
        let service = RealtimeService(model: model)
        return try await open(
            service: service, detection: detection, transcriptionModel: transcriptionModel, languages: languages,
            credential: { try await service.token() }, connect: RealtimeChannel.live,
            handshakeTimeout: handshakeTimeout)
    }

    /// Transport seam: request construction, handshake, deadline and failures.
    static func open(
        service: RealtimeService, detection: TurnDetection, transcriptionModel: String, languages: [String],
        credential: @escaping @Sendable () async throws -> String, connect: (URLRequest) -> RealtimeChannel,
        handshakeTimeout: UInt64 = 10_000_000_000
    ) async throws -> ListeningSession {
        let transcription = try RealtimeService.transcriptionFields(model: transcriptionModel, languages: languages)
        let channel = OpenedChannel()
        do {
            // The deadline settles on the configured channel; the session, whose workers run until it is closed, is
            // made only once the deadline has accepted it, so a handshake rejected at the last moment leaves none.
            let configured = try await RealtimeDeadline.run(nanoseconds: handshakeTimeout, close: channel.close) {
                // The deadline cancels a credential request still running when it expires, and stops waiting for it
                // even if it ignores the cancellation; a credential arriving later is dropped.
                let pending = Task { try await credential() }
                let first = FirstResult<String>()
                Task { first.offer(await pending.result) }
                channel.onClose {
                    pending.cancel()
                    first.offer(.failure(CancellationError()))
                }
                let token = try await first.wait()
                try Task.checkCancellation()
                let opened = connect(service.realtimeRequest(token: token))
                channel.set(opened)
                var accumulator = RealtimeAccumulator()
                try await RealtimeService.waitFor("session.created", into: &accumulator, receive: opened.receive)
                try await opened.send([
                    "type": "session.update", "session": configuration(detection, transcription: transcription),
                ])
                try await RealtimeService.waitFor("session.updated", into: &accumulator, receive: opened.receive)
                return opened
            }
            return ListeningSession(channel: configured)
        } catch {
            channel.close()
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            throw failure(error)
        }
    }

    /// The session's settings: text only, its transcription, and turn detection that never creates a response.
    static func configuration(_ detection: TurnDetection, transcription: [String: Any]) -> [String: Any] {
        [
            "type": "realtime", "output_modalities": ["text"],
            "audio": [
                "input": [
                    "format": ["type": "audio/pcm", "rate": 24000], "turn_detection": detection.configuration,
                    "transcription": transcription,
                ]
            ],
        ]
    }

    private func countSent(_ bytes: Int) {
        lock.lock()
        sent += bytes
        lock.unlock()
    }

    /// Queues 24 kHz mono 16-bit PCM for sending, in order. Audio queued after `close()` is dropped.
    public func append(_ pcm: Data) {
        guard !pcm.isEmpty else { return }
        outgoing.yield(pcm)
    }

    /// Ends the session: no more audio is sent and the connection closes. Safe to call more than once.
    public func close() {
        lock.lock()
        let first = !closed
        closed = true
        let running = workers
        lock.unlock()
        guard first else { return }
        outgoing.finish()
        signalSink.finish()
        for worker in running { worker.cancel() }
        channel.close()
    }

    private func fail(_ error: Error) {
        lock.lock()
        let open = !closed
        lock.unlock()
        // A failure after `close()` is the connection being closed on purpose.
        guard open else { return }
        signalSink.finish(throwing: Self.failure(error))
        close()
    }

    static func failure(_ error: Error) -> AppFailure {
        if error is RealtimeTimeout {
            return AppFailure(
                "Mochi could not start listening in time. Check your connection; press to send still works.")
        }
        if let failure = error as? AppFailure { return failure }
        if error is URLError { return ServiceHTTP.transportFailure(error, provider: "OpenAI") }
        return AppFailure(
            "The listening connection ended. Check your connection; press to send still works.", underlying: error)
    }
}

/// The connection a handshake opened, so its deadline can close it from another task.
/// Closing is latched: a connection or credential request registered after `close()` is closed or cancelled at once,
/// so one that arrives after the deadline cannot stall the handshake.
/// Resumes its one waiter with the first result offered; later offers are dropped.
private final class FirstResult<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var waiter: CheckedContinuation<Value, Error>?
    private var early: Result<Value, Error>?
    private var settled = false
    func wait() async throws -> Value {
        try await withCheckedThrowingContinuation { waiter in
            lock.lock()
            if let early {
                lock.unlock()
                waiter.resume(with: early)
            } else {
                self.waiter = waiter
                lock.unlock()
            }
        }
    }
    func offer(_ result: Result<Value, Error>) {
        lock.lock()
        guard !settled else {
            lock.unlock()
            return
        }
        settled = true
        let waiting = waiter
        waiter = nil
        if waiting == nil { early = result }
        lock.unlock()
        waiting?.resume(with: result)
    }
}

private final class OpenedChannel: @unchecked Sendable {
    private let lock = NSLock()
    private var channel: RealtimeChannel?
    private var cancellations: [@Sendable () -> Void] = []
    private var closed = false
    func set(_ opened: RealtimeChannel) {
        lock.lock()
        channel = opened
        let late = closed
        lock.unlock()
        if late { opened.close() }
    }
    func onClose(_ cancel: @escaping @Sendable () -> Void) {
        lock.lock()
        let late = closed
        if !late { cancellations.append(cancel) }
        lock.unlock()
        if late { cancel() }
    }
    @Sendable func close() {
        lock.lock()
        closed = true
        let opened = channel
        let pending = cancellations
        cancellations = []
        lock.unlock()
        for cancel in pending { cancel() }
        opened?.close()
    }
}

/// Reads one turn's events: speech start and stop, and the transcript of the item the API committed for it.
struct ListeningItem {
    private var committed: String?
    private var transcribed = false

    mutating func accept(_ event: [String: Any]) throws -> ListeningSignal? {
        switch event["type"] as? String {
        case "input_audio_buffer.speech_started":
            return .speechStarted(audioMilliseconds: event["audio_start_ms"] as? Int)
        case "input_audio_buffer.speech_stopped":
            return .speechStopped(audioMilliseconds: event["audio_end_ms"] as? Int)
        case "input_audio_buffer.committed":
            // The first committed item is the turn; anything later was heard after it ended.
            if committed == nil { committed = event["item_id"] as? String }
            return nil
        case "conversation.item.input_audio_transcription.completed",
            "conversation.item.input_audio_transcription.failed":
            guard !transcribed, let committed, event["item_id"] as? String == committed else { return nil }
            transcribed = true
            let text = event["transcript"] as? String ?? ""
            return .transcribed(text.trimmingCharacters(in: .whitespacesAndNewlines))
        case "error": throw RealtimeEvents.failure(event["error"] as? [String: Any])
        default: return nil
        }
    }
}
