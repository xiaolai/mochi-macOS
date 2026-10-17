import Foundation
import RealtimeConnection

extension RealtimeService {
    /// One deadline over sign-in, minting and the WebSocket handshake of a reply or a transcription. Each has its own
    /// bound (Codex's 30 s, minting's 45 s request and 90 s resource limits, the handshake's 30 s), but in sequence
    /// they could hold a request for minutes before its own deadline began.
    static let connectTimeout: UInt64 = 30_000_000_000

    /// Fetches a secret with `credential` and connects with it, both within `timeout`. On expiry the deadline stops
    /// waiting for either, even one that ignores cancellation, and closes a connection that opens too late, so a
    /// stalled sign-in or handshake cannot hold the request beyond it.
    func open(
        credential: @escaping @Sendable () async throws -> ClientSecret,
        connect: @escaping @Sendable (RealtimeEndpoint) async throws -> RealtimeChannel, timeout: UInt64
    ) async throws -> RealtimeChannel {
        let channel = OpenedChannel()
        do {
            return try await RealtimeDeadline.run(seconds: Self.seconds(timeout), close: channel.close) {
                let secret = try await channel.abandoning { try await credential() }
                try Task.checkCancellation()
                let endpoint = endpoint(secret)
                let opened = try await channel.abandoning({ try await connect(endpoint) }, late: { $0.close() })
                channel.set(opened)
                return opened
            }
        } catch {
            channel.close()
            throw error
        }
    }
}

/// Resumes its one waiter with the first result offered; later offers are dropped.
final class FirstResult<Value: Sendable>: @unchecked Sendable {
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
    /// True when this result was the first; a later one is dropped and returns false.
    @discardableResult func offer(_ result: Result<Value, Error>) -> Bool {
        lock.lock()
        guard !settled else {
            lock.unlock()
            return false
        }
        settled = true
        let waiting = waiter
        waiter = nil
        if waiting == nil { early = result }
        lock.unlock()
        waiting?.resume(with: result)
        return true
    }
}

/// The connection a handshake opened, so its deadline can close it from another task.
/// Closing is latched: a connection or credential request registered after `close()` is closed or cancelled at once,
/// so one that arrives after the deadline cannot stall the handshake.
final class OpenedChannel: @unchecked Sendable {
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
    /// Runs `work` until it finishes or this channel closes, whichever is first. Closing cancels it and stops waiting
    /// for it even if it ignores the cancellation; a value it delivers after that goes to `late`.
    func abandoning<Value: Sendable>(
        _ work: @escaping @Sendable () async throws -> Value, late: @escaping @Sendable (Value) -> Void = { _ in }
    ) async throws -> Value {
        let pending = Task { try await work() }
        let first = FirstResult<Value>()
        Task {
            let result = await pending.result
            if !first.offer(result), case .success(let value) = result { late(value) }
        }
        onClose {
            pending.cancel()
            first.offer(.failure(CancellationError()))
        }
        return try await first.wait()
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
