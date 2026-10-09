import XCTest
import Darwin
@testable import MochiAutomation
final class LocalControlTests: XCTestCase {
    private func path() -> String { "/tmp/mochi-socket-tests-\(UUID().uuidString)/control.sock" }
    private func connect(_ path: String) throws -> Int32 {
        let fd = socket(AF_UNIX,SOCK_STREAM,0)
        var address = try LocalControl.address(path)
        let result = withUnsafePointer(to:&address) { $0.withMemoryRebound(to:sockaddr.self,capacity:1) { Darwin.connect(fd,$0,socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard result == 0 else { close(fd); throw POSIXError(.ECONNREFUSED) }
        try LocalControl.configure(fd); return fd
    }
    @MainActor func testDelayedRequestAndLargeSlowResponse() async throws {
        let path = path(), root = URL(fileURLWithPath:path).deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at:root) }
        let server = LocalControlServer(), response = Data(repeating:65,count:200000)
        try server.start(path:path) { _ in response }; defer { server.stop() }
        let result = try await Task.detached { [self] in
            let fd = try connect(path); defer { close(fd) }
            Thread.sleep(forTimeInterval:0.15)
            try LocalControl.sendFrame(Data("hello".utf8),fd:fd)
            var data = Data(), buffer = [UInt8](repeating:0,count:2048)
            while true {
                let count = recv(fd,&buffer,buffer.count,0)
                guard count > 0 else { throw POSIXError(.EIO) }
                if let newline = buffer.prefix(count).firstIndex(of:10) { data.append(contentsOf:buffer[..<newline]); return data }
                data.append(contentsOf:buffer.prefix(count)); Thread.sleep(forTimeInterval:0.001)
            }
        }.value
        XCTAssertEqual(result,response)
    }
    @MainActor func testShutdownRejectsPendingClientAndRemovesSocket() async throws {
        let path = path(), root = URL(fileURLWithPath:path).deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at:root) }
        var calls = 0; let server = LocalControlServer()
        try server.start(path:path) { data in calls += 1; return data }
        let client = try connect(path); defer { close(client) }
        try await Task.sleep(nanoseconds:50_000_000)
        server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath:path))
        let result = await Task.detached { () -> Bool in
            do { try LocalControl.sendFrame(Data("late".utf8),fd:client); _ = try LocalControl.receiveFrame(fd:client); return true } catch { return false }
        }.value
        XCTAssertFalse(result); XCTAssertEqual(calls,0)
    }
    @MainActor func testStaleSocketRecoveredAndOwnedFolderProtected() throws {
        let path = path(), root = URL(fileURLWithPath:path).deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at:root) }
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o755])
        let fd = socket(AF_UNIX,SOCK_STREAM,0); var address = try LocalControl.address(path)
        let bound = withUnsafePointer(to:&address) { $0.withMemoryRebound(to:sockaddr.self,capacity:1) { Darwin.bind(fd,$0,socklen_t(MemoryLayout<sockaddr_un>.size)) } }; close(fd)
        XCTAssertEqual(bound,0)
        let server = LocalControlServer(); try server.start(path:path) { $0 }; defer { server.stop() }
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath:root.path)[.posixPermissions] as? NSNumber)?.intValue,0o700)
    }
    func testStableShortEndpointForLongAndCustomRoots() {
        let root = URL(fileURLWithPath:"/Users/"+String(repeating:"long",count:100)+"/Library/Application Support/Mochi")
        let path = LocalControl.path(forLibraryRoot:root)
        XCTAssertLessThan(path.utf8.count,104); XCTAssertEqual(path,LocalControl.path(forLibraryRoot:root))
        XCTAssertNotEqual(path,LocalControl.path(forLibraryRoot:root.appendingPathComponent("other")))
    }
}
extension LocalControlTests {
    @MainActor func testOversizedAndIdleClientsDoNotInvokeHandler() async throws {
        let path = path(), root = URL(fileURLWithPath:path).deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at:root) }
        var calls = 0; let server = LocalControlServer()
        try server.start(path:path) { data in calls += 1; return data }; defer { server.stop() }
        let rejected = try await Task.detached { [self] in
            let fd = try connect(path); defer { close(fd) }
            let huge = Data(repeating:65,count:LocalControl.maxFrame+10)
            do { try LocalControl.sendFrame(huge,fd:fd); return false } catch { return true }
        }.value
        XCTAssertTrue(rejected)
        let fd = try connect(path); defer { close(fd) }
        let start = Date()
        let timedOut = await Task.detached { () -> Bool in
            do { _ = try LocalControl.receiveFrame(fd:fd); return false } catch { return true }
        }.value
        XCTAssertTrue(timedOut); XCTAssertLessThan(Date().timeIntervalSince(start),6.5); XCTAssertEqual(calls,0)
    }
    func testSymlinkFolderAndSocketAreRejected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mochi-links-\(UUID())")
        defer { try? FileManager.default.removeItem(at:root) }
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let actual = root.appendingPathComponent("actual"), link = root.appendingPathComponent("link")
        try FileManager.default.createDirectory(at:actual,withIntermediateDirectories:true)
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:actual)
        XCTAssertThrowsError(try LocalControlServer().start(path:link.appendingPathComponent("c.sock").path) { $0 })
        let socketPath = actual.appendingPathComponent("c.sock")
        try FileManager.default.createSymbolicLink(at:socketPath,withDestinationURL:root.appendingPathComponent("missing"))
        XCTAssertThrowsError(try LocalControlServer().start(path:socketPath.path) { $0 })
        XCTAssertThrowsError(try LocalControl.request(Data(),path:socketPath.path))
    }
    @MainActor func testExcessConnectionsRejectedAndRecovered() async throws {
        let path = path(), root = URL(fileURLWithPath:path).deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at:root) }
        let server = LocalControlServer(); try server.start(path:path) { $0 }; defer { server.stop() }
        var sockets: [Int32] = []; defer { sockets.forEach { close($0) } }
        for _ in 0..<8 { sockets.append(try connect(path)) }
        try await Task.sleep(nanoseconds:100_000_000)
        let excess = try connect(path); defer { close(excess) }
        let rejected = await Task.detached { () -> Bool in
            do { try LocalControl.sendFrame(Data("excess".utf8),fd:excess); _ = try LocalControl.receiveFrame(fd:excess); return false } catch { return true }
        }.value
        XCTAssertTrue(rejected)
        sockets.forEach { shutdown($0,SHUT_RDWR) }
        try await Task.sleep(nanoseconds:100_000_000)
        let reply = try await Task.detached { try LocalControl.request(Data("ready".utf8),path:path) }.value
        XCTAssertEqual(reply,Data("ready".utf8))
    }
}
extension LocalControlTests {
    func testEndpointUsesMacOSPrivateUserTemporaryDirectory() throws {
        let path = LocalControl.defaultPath
        XCTAssertFalse(path.hasPrefix("/tmp/")); XCTAssertFalse(path.hasPrefix("/private/tmp/"))
        let parent = URL(fileURLWithPath:path).deletingLastPathComponent().deletingLastPathComponent()
        var info = stat(); XCTAssertEqual(lstat(parent.path,&info),0)
        XCTAssertEqual(info.st_uid,getuid()); XCTAssertEqual(info.st_mode & 0o077,0)
        XCTAssertLessThan(path.utf8.count,104)
    }
}
