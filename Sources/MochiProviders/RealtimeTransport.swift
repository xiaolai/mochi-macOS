import Foundation
import MochiKernel
import RealtimeConnection

/// The shared clients every OpenAI request goes through: the origin policy, no redirects and the failure taxonomy of
/// the shared package. Minting uses Mochi's 45 s request and 90 s resource limits; sockets bound their own handshake.
enum OpenAIConnection {
    static let policy = OriginPolicy(realNetworkGuard: { LiveAccess.refusal() })
    static let http = HTTPClient(policy: policy, configuration: ServiceHTTP.configuration)
    static let sockets = HTTPClient(policy: policy)
    /// A minted secret is asked to live 600 s, the lifetime OpenAI gave it when Mochi did not ask; it only has to
    /// outlast the handshake it is minted for.
    static let minter = Minter(
        client: http, credentials: CodexSignIn.shared, timeout: 45, lifetimeSeconds: 600, route: "realtime")
    /// The largest event a session accepts; a reply's audio arrives in deltas far below it.
    static let readLimit = 4_000_000
    /// Bounds the WebSocket handshake, as the socket's own request timeout did before the shared package.
    static let handshakeTimeout: TimeInterval = 30
}

/// Where one Realtime session connects, and the minted secret it presents.
struct RealtimeEndpoint {
    let url: URL
    let secret: ClientSecret
}

/// The connection was reported cancelled while the reply was not: it closed underneath.
struct RealtimeConnectionCancelled: Error {}
/// Sendable so a handshake can run in its own task; its closures are driven by one sender and one receiver at a time,
/// and `close` is safe from anywhere.
struct RealtimeChannel: @unchecked Sendable {
    let send: ([String: Any]) async throws -> Void
    let receive: () async throws -> [String: Any]
    let close: @Sendable () -> Void
    /// A session of the shared package: its socket, read limit and handshake classification. Events reach Mochi as
    /// the JSON objects it reads, including the ones the package does not type, such as tool calls.
    static func live(_ endpoint: RealtimeEndpoint) async throws -> RealtimeChannel {
        let session = try await RealtimeSession.open(
            client: OpenAIConnection.sockets, secret: endpoint.secret,
            configuration: .init(
                url: endpoint.url, handshakeTimeout: OpenAIConnection.handshakeTimeout,
                readLimit: OpenAIConnection.readLimit, route: "realtime"))
        return RealtimeChannel(
            send: { event in
                let bytes = try JSONSerialization.data(withJSONObject: event)
                try await surfacing { try await session.send(bytes) }
            },
            receive: { try await event { try await surfacing { try await session.next() } } },
            close: { Task { await session.close() } })
    }
    /// Events the shared package reads, and so can find malformed, that Mochi never consumes. One of these that
    /// arrives unreadable is skipped, as the package itself treats it: failing the reply over it would end a session
    /// that has everything it needs.
    static let unconsumedTypes: Set<String> = [
        RealtimeEvent.responseCreatedType, RealtimeEvent.rateLimitsUpdatedType, RealtimeEvent.transcriptionDeltaType,
    ]
    /// The next event Mochi reads from `next`, skipping unreadable events of a type Mochi never consumes.
    static func event(_ next: () async throws -> RealtimeMessage) async throws -> [String: Any] {
        while true {
            let message: RealtimeMessage
            do { message = try await next() } catch let error as RealtimeError
                where error.errorClass == .protocol && error.code.isEmpty
            {
                // A malformed event; an oversized one carries its close code and ends the session.
                if let type = unconsumedType(of: error) {
                    MochiLog.network.notice("Skipped an unreadable \(type, privacy: .public) event")
                    continue
                }
                throw AppFailure("Invalid Realtime event.", underlying: error)
            }
            guard let event = try JSONSerialization.jsonObject(with: message.raw) as? [String: Any] else {
                throw AppFailure("Invalid Realtime event.")
            }
            return event
        }
    }
    /// The type of a malformed event Mochi does not consume, or nil. A malformed event without a readable type is
    /// never skipped.
    static func unconsumedType(of error: RealtimeError) -> String? {
        unconsumedTypes.contains(error.eventType) ? error.eventType : nil
    }
}
extension RealtimeChannel {
    /// A `CancellationError` from the connection is the reply's cancellation only when the reply was cancelled.
    /// Otherwise it is a failed connection, which must be reported instead of passing silently as the user's choice.
    static func surfacing<T>(_ operation: () async throws -> T) async throws -> T {
        do { return try await operation() } catch is CancellationError where !Task.isCancelled {
            throw RealtimeConnectionCancelled()
        }
    }
}
