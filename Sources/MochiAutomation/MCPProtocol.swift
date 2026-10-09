import Foundation
import CoreFoundation

/// A deliberately pinned MCP 2025-06-18 stdio server, independent of app/UI lifetimes.
public final class MochiMCPProtocol {
    private var initialized = false, ready = false
    private let clientID = UUID().uuidString
    private let bridge: (Data) throws -> Data
    public init(bridge: @escaping (Data) throws -> Data = { try LocalControl.request($0) }) { self.bridge = bridge }
    public func respond(_ data: Data) -> Data? {
        var id: Any = NSNull()
        func error(_ code: Int, _ message: String) -> Data? { try? JSONSerialization.data(withJSONObject:["jsonrpc":"2.0","id":id,"error":["code":code,"message":message]]) }
        guard data.count <= LocalControl.maxFrame else { return error(-32600,"Request exceeds the size limit.") }
        guard let parsed = try? JSONSerialization.jsonObject(with:data) else { return error(-32700,"Parse error.") }
        guard let request = parsed as? [String:Any], request["jsonrpc"] as? String == "2.0", let method = request["method"] as? String else { return error(-32600,"Invalid request.") }
        if let value = request["id"] { id = value }
                if request["id"] == nil {
            if method == "notifications/initialized" && initialized { ready = true }
            return nil
        }
        if let text = id as? String {
            guard text.count <= 200 else { id = NSNull(); return error(-32600,"Request ID is too long.") }
        } else if let number = id as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { id = NSNull(); return error(-32600,"Invalid request ID.") }
        } else { id = NSNull(); return error(-32600,"Invalid request ID.") }
        guard request["params"] == nil || request["params"] is [String:Any] else { return error(-32602,"Parameters must be an object.") }
        let params = request["params"] as? [String:Any] ?? [:]
        let result: [String:Any]
        switch method {
        case "initialize":
            guard !initialized, params["protocolVersion"] is String, params["clientInfo"] is [String:Any], params["capabilities"] is [String:Any] else { return error(-32602,"Invalid initialization.") }
            initialized = true
            let requested = params["protocolVersion"] as! String
            let supported = ["2025-06-18","2025-03-26","2024-11-05"]
            result = ["protocolVersion":supported.contains(requested) ? requested : "2025-06-18","capabilities":["tools":["listChanged":false]],"serverInfo":["name":"mochi","version":"1.0.0"],"instructions":"Control the running Mochi app. External control must be enabled in Settings. Read get_session before mutations and pass its revision as expected_revision. Scope operations to the open conversation. Recording is always user initiated."]
        case "ping": result = [:]
        case "tools/list":
            guard ready else { return error(-32002,"Initialize the server first.") }
            result = ["tools":MochiTools.catalog(origin:.external).map(\.mcp)]
        case "tools/call":
            guard ready else { return error(-32002,"Initialize the server first.") }
            guard let name = params["name"] as? String else { return error(-32602,"Tool name required.") }
            guard params["arguments"] == nil || params["arguments"] is [String:Any] else { return error(-32602,"Arguments must be an object.") }
            let arguments = params["arguments"] as? [String:Any] ?? [:]
            guard MochiTools.catalog(origin:.external).contains(where:{ $0.name == name }) else { return error(-32602,"Unknown tool name.") }
            do { _ = try MochiTools.validate(name:name,arguments:arguments,origin:.external) }
            catch let failure { return error(-32602,(failure as? AppFailure)?.message ?? "Invalid tool arguments.") }
            do {
                let payload: [String:Any] = ["name":name,"arguments":arguments,"request_id":clientID + ":" + (try MochiTools.signature(name:"mcp_request",arguments:["id":id]))]
                let response = try bridge(JSONSerialization.data(withJSONObject:payload))
                guard let object = try JSONSerialization.jsonObject(with:response) as? [String:Any] else { throw AppFailure("Invalid app control response.") }
                result = ["content":[["type":"text","text":try MochiTools.encode(object)]],"isError":object["ok"] as? Bool != true]
            } catch { result = ["content":[["type":"text","text":(error as? AppFailure)?.message ?? "Mochi could not execute this action."]],"isError":true] }
        default: return error(-32601,"Method not found.")
        }
        return try? JSONSerialization.data(withJSONObject:["jsonrpc":"2.0","id":id,"result":result],options:[.sortedKeys])
    }
}
