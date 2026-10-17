import CoreFoundation
import Foundation
import MochiKernel

/// A deliberately pinned MCP stdio server for the handshake revisions up to 2025-11-25, independent of app/UI
/// lifetimes. A client of the stateless 2026 revisions probes with `server/discover`, is told the method is not
/// found, and falls back to `initialize`.
///
/// `receive` answers each message as it arrives: tool calls run one at a time on their own queue, so a slow app
/// call never delays `ping` or a cancellation. `respond` answers synchronously and is what `receive` builds on.
public final class MochiMCPProtocol: @unchecked Sendable {
    /// Guards the lifecycle state below, which the reader and the call queue both use.
    private let lock = NSLock()
    private var initialized = false, ready = false
    /// The revision agreed at initialization; it decides whether batches are accepted.
    private var negotiated: String?
    /// Tool calls accepted and not yet answered, and those of them the client cancelled, by request ID.
    private var pending = Set<String>(), cancelled = Set<String>()
    private let calls = DispatchQueue(label: "mochi.mcp.calls")
    private let clientID = UUID().uuidString
    private let bridge: (Data) throws -> Data
    private let diagnostics: (String) -> Void
    /// `diagnostics` receives one line per failed bridge call; the helper writes it to stderr, never stdout.
    public init(
        bridge: @escaping (Data) throws -> Data = { try LocalControl.request($0) },
        diagnostics: @escaping (String) -> Void = { _ in }
    ) {
        self.bridge = bridge
        self.diagnostics = diagnostics
    }
    /// The app version when the helper runs inside Mochi.app; "development" for a bare build.
    public static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
    }
    /// The response to a request line that exceeded the frame limit.
    public func oversizedResponse() -> Data? {
        Self.encode(Self.error(NSNull(), -32600, "Request exceeds the size limit."))
    }
    /// Answers one line synchronously, running any tool call before returning; nil when nothing is answered.
    public func respond(_ data: Data) -> Data? {
        switch parse(data) {
        case .answer(let reply): return reply.flatMap(Self.encode)
        case .call(let call): return Self.encode(run(call))
        case .batch(let messages): return batch(messages).flatMap(Self.encode)
        }
    }
    /// Answers one line through `send`, which may be called from another thread. Everything except tool calls and
    /// batches is answered before this returns; those run in order on the call queue, so `ping` and
    /// `notifications/cancelled` are handled while one is in flight. A cancelled call is never answered.
    public func receive(_ data: Data, send: @escaping @Sendable (Data) -> Void) {
        switch parse(data) {
        case .answer(let reply): if let reply, let data = Self.encode(reply) { send(data) }
        case .call(let call):
            let key = Self.key(call.id)
            lock.withLock { _ = pending.insert(key) }
            calls.async { [self] in
                let reply = isCancelled(key) ? nil : run(call)
                if finish([key]).isEmpty, let reply, let data = Self.encode(reply) { send(data) }
            }
        case .batch(let messages):
            calls.async { [self] in if let reply = batch(messages), let data = Self.encode(reply) { send(data) } }
        }
    }
    /// Waits until every accepted tool call has been answered or dropped.
    public func drain() { calls.sync {} }

    /// Newest first; a client asking for any other revision is offered the newest.
    static let supportedVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    /// The only revision whose transport requires receiving JSON-RPC batches: 2025-03-26 added them and
    /// 2025-06-18 removed them.
    static let batchingVersion = "2025-03-26"

    /// A tool call accepted for the bridge.
    private struct Call {
        let id: Any, name: String, arguments: [String: Any]
    }
    private enum Parsed {
        /// The reply to send now, or nil for a notification.
        case answer([String: Any]?)
        case call(Call)
        case batch([Any])
    }
    private enum Step {
        case answer([String: Any]?)
        case call(Call)
    }
    private func parse(_ data: Data) -> Parsed {
        guard data.count <= LocalControl.maxFrame else {
            return .answer(Self.error(NSNull(), -32600, "Request exceeds the size limit."))
        }
        // Scalars parse, so valid JSON that is not a request object is reported as an invalid request.
        guard let parsed = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) else {
            return .answer(Self.error(NSNull(), -32700, "Parse error."))
        }
        if let messages = parsed as? [Any] {
            guard lock.withLock({ negotiated == Self.batchingVersion }) else {
                return .answer(Self.error(NSNull(), -32600, "Batches are not supported in this protocol revision."))
            }
            guard !messages.isEmpty else { return .answer(Self.error(NSNull(), -32600, "Invalid request.")) }
            return .batch(messages)
        }
        switch step(parsed, batched: false) {
        case .answer(let reply): return .answer(reply)
        case .call(let call): return .call(call)
        }
    }
    /// The replies to a batch, in request order, without notifications and cancelled calls; nil when none remain.
    private func batch(_ messages: [Any]) -> [[String: Any]]? {
        var replies: [(key: String?, reply: [String: Any])] = []
        var keys: [String] = []
        for message in messages {
            switch step(message, batched: true) {
            case .answer(let reply): if let reply { replies.append((nil, reply)) }
            case .call(let call):
                let key = Self.key(call.id)
                lock.withLock { _ = pending.insert(key) }
                keys.append(key)
                if !isCancelled(key) { replies.append((key, run(call))) }
            }
        }
        let dropped = finish(keys)
        let kept = replies.filter { $0.key.map { !dropped.contains($0) } ?? true }.map(\.reply)
        return kept.isEmpty ? nil : kept
    }
    /// Handles one request or notification; a tool call is returned to be run through the bridge.
    private func step(_ parsed: Any, batched: Bool) -> Step {
        guard let request = parsed as? [String: Any] else {
            return .answer(Self.error(NSNull(), -32600, "Invalid request."))
        }
        // A readable ID is echoed even when the rest of the request is invalid, so the client can match the error.
        let readableID = request["id"].flatMap { Self.validID($0) ? $0 : nil }
        guard request["jsonrpc"] as? String == "2.0", let method = request["method"] as? String else {
            return .answer(Self.error(readableID ?? NSNull(), -32600, "Invalid request."))
        }
        guard let requestID = request["id"] else {
            notify(method, params: request["params"])
            return .answer(nil)
        }
        guard let id = readableID else { return .answer(Self.error(NSNull(), -32600, Self.idProblem(requestID))) }
        func error(_ code: Int, _ message: String) -> Step { .answer(Self.error(id, code, message)) }
        guard request["params"] == nil || request["params"] is [String: Any] else {
            return error(-32602, "Parameters must be an object.")
        }
        let params = request["params"] as? [String: Any] ?? [:]
        let result: [String: Any]
        switch method {
        case "initialize":
            guard !batched else { return error(-32600, "Initialization cannot be part of a batch.") }
            guard let requested = params["protocolVersion"] as? String,
                let client = params["clientInfo"] as? [String: Any], client["name"] is String,
                client["version"] is String, params["capabilities"] is [String: Any]
            else { return error(-32602, "Invalid initialization.") }
            let offered = Self.supportedVersions.contains(requested) ? requested : Self.supportedVersions[0]
            let accepted = lock.withLock {
                guard !initialized else { return false }
                initialized = true
                negotiated = offered
                return true
            }
            guard accepted else { return error(-32602, "Invalid initialization.") }
            result = [
                "protocolVersion": offered,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": [
                    "name": "mochi", "title": "Mochi", "version": Self.version,
                    "description": "Conversation practice in the running Mochi app on this Mac.",
                ],
                "instructions":
                    "Control the running Mochi app. External control must be enabled in Settings. Read get_session before conversation mutations and pass its revision as expected_revision; every result returns the new revision. Conversation tools act on the open conversation; open_conversation, rename_conversation and archive_conversation take any active conversation ID from list_conversations. Template tools (*_conversation_template) work without an open conversation, use template_id and expected_template_revision, and do not accept expected_revision. list_characters reads the user's characters; copy a character's name, personality and voice into a conversation or template to use it. A failed call explains what to change before retrying. Recording is always user initiated. "
                    + MochiTools.untrustedTextNotice,
            ]
        case "ping": result = [:]
        case "tools/list":
            guard lock.withLock({ ready }) else { return error(-32002, "Initialize the server first.") }
            result = ["tools": MochiTools.catalog(origin: .external).map(\.mcp)]
        case "tools/call":
            guard lock.withLock({ ready }) else { return error(-32002, "Initialize the server first.") }
            guard let name = params["name"] as? String else { return error(-32602, "Tool name required.") }
            guard params["arguments"] == nil || params["arguments"] is [String: Any] else {
                return error(-32602, "Arguments must be an object.")
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            guard MochiTools.catalog(origin: .external).contains(where: { $0.name.rawValue == name }) else {
                return error(-32602, "Unknown tool name.")
            }
            // Invalid arguments are a tool error, not a protocol error, so the model sees why and can correct them.
            do {
                _ = try MochiTools.validate(name: name, arguments: arguments, origin: .external)
            } catch let failure {
                return .answer(
                    Self.success(
                        id, Self.toolError(AppFailure.message(for: failure, fallback: "Invalid tool arguments."))))
            }
            return .call(Call(id: id, name: name, arguments: arguments))
        default: return error(-32601, "Method not found.")
        }
        return .answer(Self.success(id, result))
    }
    private static func success(_ id: Any, _ result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }
    private static func error(_ id: Any, _ code: Int, _ message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }
    private static func encode(_ value: Any) -> Data? {
        try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }
    private static func toolError(_ message: String) -> [String: Any] {
        ["content": [["type": "text", "text": message]], "isError": true]
    }
    /// Notifications are never answered; a malformed one is discarded without changing state.
    private func notify(_ method: String, params: Any?) {
        guard params == nil || params is [String: Any] else { return }
        let params = params as? [String: Any] ?? [:]
        lock.withLock {
            switch method {
            case "notifications/initialized": if initialized { ready = true }
            case "notifications/cancelled":
                // Only a call still in progress can be cancelled, so the set never outgrows the calls accepted.
                guard let id = params["requestId"], Self.validID(id), pending.contains(Self.key(id)) else { return }
                cancelled.insert(Self.key(id))
            default: break
            }
        }
    }
    private func isCancelled(_ key: String) -> Bool { lock.withLock { cancelled.contains(key) } }
    /// Ends the calls named by `keys` and returns those of them that were cancelled, whose replies are dropped.
    private func finish(_ keys: [String]) -> Set<String> {
        lock.withLock {
            var dropped = Set<String>()
            for key in keys {
                pending.remove(key)
                if cancelled.remove(key) != nil { dropped.insert(key) }
            }
            return dropped
        }
    }
    /// Request IDs compare by type and value, so the string "1" and the number 1 are different requests.
    private static func key(_ id: Any) -> String {
        if let text = id as? String { return "s:" + text }
        return "n:" + ((id as? NSNumber)?.stringValue ?? String(describing: id))
    }
    /// MCP request IDs are strings or integers of any size; booleans, fractions and other JSON values are refused.
    /// Integers parse as integer numbers, or as exact decimals beyond 64 bits, and both are echoed back unchanged.
    /// A number parsed as a Double cannot prove its literal had no fraction (`1.0`, `1e3`, `2^53 + 0.5`).
    static func validID(_ id: Any) -> Bool {
        if let text = id as? String { return text.count <= 200 }
        if let decimal = id as? NSDecimalNumber {
            let whole = decimal.rounding(
                accordingToBehavior: NSDecimalNumberHandler(
                    roundingMode: .plain, scale: 0, raiseOnExactness: false, raiseOnOverflow: false,
                    raiseOnUnderflow: false, raiseOnDivideByZero: false))
            return decimal == whole
        }
        guard let number = id as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
        return ["c", "s", "i", "l", "q", "C", "S", "I", "L", "Q"].contains(String(cString: number.objCType))
    }
    private static func idProblem(_ id: Any) -> String {
        id is String ? "Request ID is too long." : "Invalid request ID."
    }
    /// Forwards a validated call to the app and wraps its result as the call's response; bridge failures become
    /// tool errors, diagnosed on stderr. A successful result is returned twice: as `structuredContent` matching the
    /// tool's output schema, and as its serialized text for clients that read only text.
    private func run(_ call: Call) -> [String: Any] {
        do {
            let payload: [String: Any] = [
                "name": call.name, "arguments": call.arguments,
                "request_id": clientID + ":"
                    + (try MochiTools.signature(name: "mcp_request", arguments: ["id": call.id])),
            ]
            let response = try bridge(JSONSerialization.data(withJSONObject: payload))
            guard let object = try JSONSerialization.jsonObject(with: response) as? [String: Any] else {
                throw AppFailure("Invalid app control response.")
            }
            let succeeded = object["ok"] as? Bool == true
            var result: [String: Any] = [
                "content": [["type": "text", "text": try MochiTools.encode(object)]], "isError": !succeeded,
            ]
            if succeeded { result["structuredContent"] = object }
            return Self.success(call.id, result)
        } catch {
            diagnostics("mochi-mcp: \(call.name) failed: \(String(describing:error))")
            return Self.success(
                call.id,
                Self.toolError(AppFailure.message(for: error, fallback: "Mochi could not execute this action.")))
        }
    }
}
