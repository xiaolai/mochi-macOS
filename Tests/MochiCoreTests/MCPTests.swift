import XCTest
@testable import MochiCore
final class MCPTests: XCTestCase {
    func response(_ server: MochiMCPProtocol, _ request: [String:Any]) throws -> [String:Any] {
        try JSONSerialization.jsonObject(with:XCTUnwrap(server.respond(JSONSerialization.data(withJSONObject:request)))) as! [String:Any]
    }
    func testLifecycleDiscoveryCallAndErrors() throws {
        var count = 0
        let server = MochiMCPProtocol { data in
            count += 1
            let payload = try JSONSerialization.jsonObject(with:data) as! [String:Any]
            XCTAssertEqual(payload["name"] as? String,"get_session")
            return try JSONSerialization.data(withJSONObject:["ok":true,"revision":"current"])
        }
        XCTAssertNotNil(try response(server,["jsonrpc":"2.0","id":0,"method":"tools/list"])["error"])
        let initialize = try response(server,["jsonrpc":"2.0","id":1,"method":"initialize","params":["protocolVersion":"2025-06-18","capabilities":[:],"clientInfo":["name":"test","version":"1"]]])
        XCTAssertEqual((initialize["result"] as? [String:Any])?["protocolVersion"] as? String,"2025-06-18")
        XCTAssertNil(server.respond(try JSONSerialization.data(withJSONObject:["jsonrpc":"2.0","method":"notifications/initialized"])))
        let list = try response(server,["jsonrpc":"2.0","id":2,"method":"tools/list"])
        let tools = (list["result"] as! [String:Any])["tools"] as! [[String:Any]]
        XCTAssertEqual(tools.count,MochiTools.catalog(origin:.external).count); XCTAssertFalse(tools.contains { ($0["name"] as? String ?? "").contains("record") })
        let call = try response(server,["jsonrpc":"2.0","id":3,"method":"tools/call","params":["name":"get_session","arguments":[:]]])
        XCTAssertEqual((call["result"] as? [String:Any])?["isError"] as? Bool,false); XCTAssertEqual(count,1)
        XCTAssertNotNil(try response(server,["jsonrpc":"2.0","id":4,"method":"server/discover"])["error"])
        XCTAssertNotNil(server.respond(Data("invalid".utf8)))
    }
    @MainActor func testRealSocketPermissionsRoundtripAndStop() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let path = root.appendingPathComponent("control.sock").path
        let server = LocalControlServer(); try server.start(path:path) { data in data }
        let attrs = try FileManager.default.attributesOfItem(atPath:path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue,0o600)
        let response = try await Task.detached { try LocalControl.request(Data("hello".utf8),path:path) }.value
        XCTAssertEqual(response,Data("hello".utf8))
        let another = LocalControlServer(); XCTAssertThrowsError(try another.start(path:path) { $0 })
        server.stop(); XCTAssertFalse(FileManager.default.fileExists(atPath:path))
        XCTAssertThrowsError(try LocalControl.request(Data(),path:path))
    }
    func testUntrustedSocketPathRejected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let path = root.appendingPathComponent("control.sock").path
        try Data().write(to:URL(fileURLWithPath:path))
        XCTAssertThrowsError(try LocalControl.request(Data("{}".utf8),path:path))
        XCTAssertThrowsError(try LocalControlServer().start(path:path) { $0 })
    }
}
extension MCPTests {
    func testInvalidIDsAndToolArgumentsAreProtocolErrors() throws {
        let server = MochiMCPProtocol { _ in XCTFail("Invalid request reached app"); return Data() }
        for id: Any in [true,["bad":"id"],String(repeating:"x",count:201)] {
            let reply = try response(server,["jsonrpc":"2.0","id":id,"method":"ping"])
            XCTAssertTrue(reply["id"] is NSNull); XCTAssertEqual((reply["error"] as? [String:Any])?["code"] as? Int,-32600)
        }
        _ = try response(server,["jsonrpc":"2.0","id":1,"method":"initialize","params":["protocolVersion":"2025-06-18","clientInfo":[:],"capabilities":[:]]])
        _ = server.respond(try JSONSerialization.data(withJSONObject:["jsonrpc":"2.0","method":"notifications/initialized"]))
        for params: [String:Any] in [["name":"unknown"],["name":"get_messages","arguments":["conversation_id":"invalid"]]] {
            let reply = try response(server,["jsonrpc":"2.0","id":2,"method":"tools/call","params":params])
            XCTAssertEqual((reply["error"] as? [String:Any])?["code"] as? Int,-32602)
        }
        let tools = MochiTools.catalog(origin:.external).map(\.mcp)
        for name in ["set_conversation_instructions","set_conversation_preferences"] {
            XCTAssertEqual((tools.first { $0["name"] as? String == name }?["annotations"] as? [String:Any])?["destructiveHint"] as? Bool,true)
        }
        for name in ["list_conversations","create_conversation","open_conversation","set_conversation_instructions"] {
            XCTAssertThrowsError(try MochiTools.validate(name:name,arguments:[:],origin:.voice))
        }
    }
}
