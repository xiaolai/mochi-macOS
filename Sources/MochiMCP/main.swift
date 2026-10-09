import Foundation
import MochiAutomation

let server = MochiMCPProtocol { try LocalControl.request($0,path:ProcessInfo.processInfo.environment["MOCHI_CONTROL_SOCKET"] ?? LocalControl.defaultPath) }
// Bounded newline framing, no banners or diagnostic output on stdout.
var frame = Data(), oversized = false
while let byte = try? FileHandle.standardInput.read(upToCount:1), !byte.isEmpty {
    if byte[byte.startIndex] == 10 {
        let response = oversized ? server.respond(Data(repeating:0,count:LocalControl.maxFrame+1)) : server.respond(frame)
        if let response { FileHandle.standardOutput.write(response + Data([10])) }
        frame.removeAll(keepingCapacity:true); oversized = false
    } else if !oversized {
        if frame.count == LocalControl.maxFrame { oversized = true; frame.removeAll(keepingCapacity:true) }
        else { frame.append(byte) }
    }
}

// Be tolerant of a complete final JSON request followed directly by EOF.
if oversized || !frame.isEmpty {
    let response = oversized ? server.respond(Data(repeating:0,count:LocalControl.maxFrame+1)) : server.respond(frame)
    if let response { FileHandle.standardOutput.write(response + Data([10])) }
}
