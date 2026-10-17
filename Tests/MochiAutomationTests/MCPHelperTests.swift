import MochiAutomation
import MochiTestSupport
import XCTest

final class MCPHelperTests: XCTestCase {
    func testFramerAcceptsTheLimitAndRecoversAfterAnOversizedLine() {
        var framer = MCPStdioFramer(limit: 8)
        XCTAssertEqual(framer.feed(Data("12345678\n".utf8)), [.request(Data("12345678".utf8))])
        XCTAssertEqual(framer.feed(Data("123456789".utf8)), [])
        XCTAssertEqual(framer.feed(Data("more\nok\n".utf8)), [.oversized, .request(Data("ok".utf8))])
        XCTAssertEqual(framer.feed(Data("\n".utf8)), [.request(Data())])
        XCTAssertEqual(framer.feed(Data("par".utf8)), [])
        XCTAssertEqual(framer.feed(Data("tial\nlast".utf8)), [.request(Data("partial".utf8))])
        XCTAssertEqual(framer.finish(), .request(Data("last".utf8)))
        XCTAssertNil(framer.finish())
        _ = framer.feed(Data(repeating: 65, count: 9))
        XCTAssertEqual(framer.finish(), .oversized)
    }

    func testHelperAnswersAnInteractiveClientWithoutWaitingForEndOfInput() throws {
        let helper = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("mochi-mcp")
        XCTAssertTrue(
            FileManager.default.isExecutableFile(atPath: helper.path), "Build the mochi-mcp product before testing")
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = helper
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()
        process.environment = ["MOCHI_CONTROL_SOCKET": "/nonexistent/mochi.sock"]
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        let request =
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#
        input.fileHandleForWriting.write(Data((request + "\n").utf8))
        // Stdin stays open: a helper that waits for more input never answers.
        let answered = expectation(description: "Helper answered")
        var line = Data()
        output.fileHandleForReading.readabilityHandler = { handle in
            line.append(handle.availableData)
            if line.contains(10) {
                handle.readabilityHandler = nil
                answered.fulfill()
            }
        }
        wait(for: [answered], timeout: 5)
        let reply = try XCTUnwrap(try JSONSerialization.jsonObject(with: line.prefix { $0 != 10 }) as? [String: Any])
        XCTAssertEqual((reply["result"] as? [String: Any])?["protocolVersion"] as? String, "2025-06-18")
        XCTAssertTrue(
            ((reply["result"] as? [String: Any])?["instructions"] as? String)?.contains("untrusted_fields") == true)
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    /// The helper keeps reading while an app call is in flight, so ping is answered before the slow call is.
    @MainActor func testHelperAnswersPingWhileAnAppCallIsInFlight() throws {
        let root = TestScratch.folder("mcp")
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("control.sock").path
        let app = LocalControlServer()
        try app.start(path: path) { _ in
            Thread.sleep(forTimeInterval: 1)
            return (try? JSONSerialization.data(withJSONObject: ["ok": true, "revision": "current"])) ?? Data()
        }
        defer { app.stop() }
        let helper = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("mochi-mcp")
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = helper
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()
        process.environment = ["MOCHI_CONTROL_SOCKET": path]
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        let lines = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_session","arguments":{}}}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"ping"}"#,
        ]
        input.fileHandleForWriting.write(Data(lines.map { $0 + "\n" }.joined().utf8))
        try input.fileHandleForWriting.close()
        // End of input arrives while the call is in flight; the helper still answers it before exiting.
        // Read off the main thread: the app's handler runs there while this test waits.
        let reader = output.fileHandleForReading
        let collected = Collected()
        let finished = expectation(description: "Helper finished")
        DispatchQueue.global().async {
            collected.set(reader.readDataToEndOfFile())
            finished.fulfill()
        }
        wait(for: [finished], timeout: 15)
        let all = collected.value
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let ids = all.split(separator: 10).compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any])?["id"] as? Int
        }
        XCTAssertEqual(ids, [1, 3, 2])
    }
}

/// Bytes handed from a reader thread to the test.
private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    var value: Data { lock.withLock { data } }
    func set(_ value: Data) { lock.withLock { data = value } }
}
