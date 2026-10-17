import Darwin
import Foundation
import MochiAutomation

let socketPath = ProcessInfo.processInfo.environment["MOCHI_CONTROL_SOCKET"] ?? LocalControl.defaultPath
let server = MochiMCPProtocol(
    bridge: { try LocalControl.request($0, path: socketPath) },
    diagnostics: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) })
// Bounded newline framing. Stdout carries protocol responses only; diagnostics go to stderr. Tool calls are answered
// from the server's call queue while this loop keeps reading, so each response is written whole under a lock.
let output = NSLock()
@Sendable func write(_ response: Data) {
    output.withLock { FileHandle.standardOutput.write(response + Data([10])) }
}
var framer = MCPStdioFramer()
func answer(_ line: MCPStdioFramer.Line) {
    switch line {
    case .request(let data): server.receive(data, send: write)
    case .oversized: if let response = server.oversizedResponse() { write(response) }
    }
}
// read(2) returns as soon as any bytes arrive, so an interactive client is answered without waiting for more input.
var buffer = [UInt8](repeating: 0, count: 65536)
while true {
    let count = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
    if count < 0 {
        let code = errno
        if code == EINTR { continue }
        // A transport failure is not end of input: buffered bytes may be a truncated request, so none is answered.
        let reason = String(cString: strerror(code))
        FileHandle.standardError.write(Data("mochi-mcp: reading stdin failed: \(reason)\n".utf8))
        exit(EXIT_FAILURE)
    }
    if count == 0 { break }
    for line in framer.feed(Data(buffer[0..<count])) { answer(line) }
}
if let last = framer.finish() { answer(last) }
// Calls accepted before the end of input are still answered.
server.drain()
