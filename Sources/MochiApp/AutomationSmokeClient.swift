#if MOCHI_DEVELOPMENT
import Foundation
import MochiCore

/// Only used by --smoke-test, with a temporary library and socket; no provider traffic.
enum AutomationSmokeClient {
    private final class Client {
        let process = Process(), input = Pipe(), output = Pipe()
        var transcript: [[String:Any]] = []
        init(helper: String, socketPath: String) throws {
            process.executableURL = URL(fileURLWithPath:helper)
            process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
            var environment = ProcessInfo.processInfo.environment; environment["MOCHI_CONTROL_SOCKET"] = socketPath; process.environment = environment
            try process.run()
        }
        deinit { try? input.fileHandleForWriting.close(); if process.isRunning { process.terminate() }; process.waitUntilExit() }
        func write(_ object: [String:Any]) throws { try input.fileHandleForWriting.write(contentsOf:JSONSerialization.data(withJSONObject:object) + Data([10])) }
        func request(_ method: String, id: Int, params: [String:Any] = [:]) throws -> [String:Any] {
            try write(["jsonrpc":"2.0","id":id,"method":method,"params":params])
            var data = Data()
            let deadline = Date().addingTimeInterval(10)
            let fd = output.fileHandleForReading.fileDescriptor
            while true {
                var item = pollfd(fd:fd,events:Int16(POLLIN),revents:0)
                guard Date() < deadline, poll(&item,1,1000) >= 0 else { throw AppFailure("MCP helper timed out.") }
                if item.revents == 0 { continue }
                guard let byte = try output.fileHandleForReading.read(upToCount:1), !byte.isEmpty else { throw AppFailure("MCP helper ended.") }
                if byte[byte.startIndex] == 10 { break }; data.append(byte)
                guard data.count <= LocalControl.maxFrame else { throw AppFailure("MCP helper response exceeded limit.") }
            }
            guard let object = try JSONSerialization.jsonObject(with:data) as? [String:Any] else { throw AppFailure("Invalid MCP helper JSON.") }
            transcript.append(object); return object
        }
        func initialize() throws {
            _ = try request("initialize",id:1,params:["protocolVersion":"2025-06-18","clientInfo":["name":"mochi-native-smoke","version":"1"],"capabilities":[:]])
            try write(["jsonrpc":"2.0","method":"notifications/initialized"])
        }
        func call(_ name: String, id: Int, arguments: [String:Any] = [:]) throws -> [String:Any] {
            let response = try request("tools/call",id:id,params:["name":name,"arguments":arguments])
            guard let result = response["result"] as? [String:Any], result["isError"] as? Bool == false,
                  let content = result["content"] as? [[String:Any]], let text = content.first?["text"] as? String,
                  let object = try JSONSerialization.jsonObject(with:Data(text.utf8)) as? [String:Any], object["ok"] as? Bool == true else { throw AppFailure("MCP helper tool call failed.") }
            return object
        }
    }
    static func run(helper: String, socketPath: String) throws -> Data {
        let client = try Client(helper:helper,socketPath:socketPath); try client.initialize()
        let list = try client.request("tools/list",id:2)
        guard ((list["result"] as? [String:Any])?["tools"] as? [[String:Any]])?.count == MochiTools.catalog(origin:.external).count else { throw AppFailure("MCP tools were not discovered.") }
        let session = try client.call("get_session",id:3)
        guard let id = session["conversation_id"] as? String, let revision = session["revision"] as? String else { throw AppFailure("MCP session missing state.") }
        _ = try client.call("save_expression",id:4,arguments:["conversation_id":id,"expected_revision":revision,"english":"Could you give me a moment?","meaning":"Ask politely for time to think."])
        let replay = try client.call("save_expression",id:4,arguments:["conversation_id":id,"expected_revision":revision,"english":"Could you give me a moment?","meaning":"Ask politely for time to think."])
        guard replay["expression_id"] != nil else { throw AppFailure("MCP replay failed.") }
        return try JSONSerialization.data(withJSONObject:client.transcript,options:[.prettyPrinted,.sortedKeys])
    }
    static func disabled(helper: String, socketPath: String) throws -> Bool {
        let client = try Client(helper:helper,socketPath:socketPath); try client.initialize()
        let response = try client.request("tools/call",id:2,params:["name":"get_session","arguments":[:]])
        return (response["result"] as? [String:Any])?["isError"] as? Bool == true
    }
}

#endif
