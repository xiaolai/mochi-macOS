import Foundation
import Darwin
import CryptoKit

/// Private, same-user IPC. The MCP process is stdio; this socket is only its app bridge.
public enum LocalControl {
    public static let maxFrame = 262144
    public static func path(forLibraryRoot root: URL) -> String {
        let digest = SHA256.hash(data:Data(root.standardizedFileURL.path.utf8)).prefix(12).map { String(format:"%02x",$0) }.joined()
        let count = confstr(_CS_DARWIN_USER_TEMP_DIR,nil,0)
        var buffer = [CChar](repeating:0,count:max(count,1))
        let written = confstr(_CS_DARWIN_USER_TEMP_DIR,&buffer,buffer.count)
        // Use the OS-owned per-user directory, never an environment-selected global /tmp path.
        let root = written > 0 && written <= buffer.count ? URL(fileURLWithPath:String(cString:buffer)) : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches")
        return root.appendingPathComponent("mochi-control").appendingPathComponent("\(digest).sock").path
    }
    public static var defaultPath: String {
        path(forLibraryRoot:FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Mochi"))
    }
    static func address(_ path: String) throws -> sockaddr_un {
        let bytes = Array(path.utf8) + [0]
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        guard bytes.count <= MemoryLayout.size(ofValue:address.sun_path) else { throw AppFailure("The local control socket path is too long.") }
        withUnsafeMutableBytes(of:&address.sun_path) { buffer in buffer.copyBytes(from:bytes) }
        return address
    }
    static func configure(_ fd: Int32) throws {
        let flags = fcntl(fd,F_GETFL)
        guard flags >= 0, fcntl(fd,F_SETFL,flags & ~O_NONBLOCK) == 0 else { throw AppFailure("Could not configure local control connection.") }
        var enabled: Int32 = 1
        guard setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&enabled,socklen_t(MemoryLayout<Int32>.size)) == 0 else { throw AppFailure("Could not configure local control connection.") }
    }
    private static func waitReady(_ fd: Int32, event: Int16, deadline: Date) throws {
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw AppFailure("Local control connection timed out.") }
            var item = pollfd(fd:fd,events:event,revents:0)
            let status = poll(&item,1,Int32(min(remaining*1000+1,5000)))
            if status < 0 && errno == EINTR { continue }
            guard status > 0, item.revents & Int16(POLLNVAL) == 0 else { throw AppFailure("Local control connection ended or timed out.") }
            return
        }
    }
    static func sendFrame(_ data: Data, fd: Int32) throws {
        guard data.count <= maxFrame else { throw AppFailure("Control response exceeds the size limit.") }
        let frame = data + Data([10]), deadline = Date().addingTimeInterval(5)
        try frame.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                try waitReady(fd,event:Int16(POLLOUT),deadline:deadline)
                let count = Darwin.send(fd,buffer.baseAddress!.advanced(by:offset),min(4096,buffer.count-offset),MSG_DONTWAIT)
                if count < 0 && [EINTR,EAGAIN,EWOULDBLOCK].contains(errno) { continue }
                guard count > 0 else { throw AppFailure("Local control connection ended.") }; offset += count
            }
        }
    }
    static func receiveFrame(fd: Int32) throws -> Data {
        var data = Data(), buffer = [UInt8](repeating:0,count:4096)
        let deadline = Date().addingTimeInterval(5)
        while true {
            try waitReady(fd,event:Int16(POLLIN),deadline:deadline)
            let count = recv(fd,&buffer,buffer.count,MSG_DONTWAIT)
            if count < 0 && [EINTR,EAGAIN,EWOULDBLOCK].contains(errno) { continue }
            guard count > 0 else { throw AppFailure("Local control connection ended.") }
            if let newline = buffer.prefix(count).firstIndex(of:10) {
                data.append(contentsOf:buffer[..<newline]); guard data.count <= maxFrame else { throw AppFailure("Control request exceeds the size limit.") }; return data
            }
            data.append(contentsOf:buffer.prefix(count))
            guard data.count <= maxFrame else { throw AppFailure("Control request exceeds the size limit.") }
        }
    }
    public static func request(_ data: Data, path: String = defaultPath) throws -> Data {
        var info = stat()
        guard lstat(path,&info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFSOCK, info.st_mode & 0o077 == 0 else { throw AppFailure("Open Mochi and enable external control in Settings → Automation.") }
        let fd = socket(AF_UNIX,SOCK_STREAM,0); guard fd >= 0 else { throw AppFailure("Could not open local control connection.") }
        defer { close(fd) }
        guard fcntl(fd,F_SETFL,O_NONBLOCK) == 0 else { throw AppFailure("Could not configure local control connection.") }
        var address = try address(path)
        let connected = withUnsafePointer(to:&address) { $0.withMemoryRebound(to:sockaddr.self,capacity:1) { connect(fd,$0,socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        if connected != 0 {
            guard errno == EINPROGRESS else { throw AppFailure("Mochi is not listening. Enable external control in Settings → Automation.") }
            try waitReady(fd,event:Int16(POLLOUT),deadline:Date().addingTimeInterval(5))
            var failure: Int32 = 0, length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd,SOL_SOCKET,SO_ERROR,&failure,&length) == 0, failure == 0 else { throw AppFailure("Mochi is not listening. Enable external control in Settings → Automation.") }
        }
        try configure(fd)
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd,&uid,&gid) == 0, uid == getuid() else { throw AppFailure("Local control belongs to another user.") }
        try sendFrame(data,fd:fd); return try receiveFrame(fd:fd)
    }
}
public final class LocalControlServer {
    private let lock = NSLock()
    private var active = false
    private var clients = Set<Int32>()
    private var generation = UUID()
    private var source: DispatchSourceRead?
    private var path: String?
    private var inode: ino_t = 0
    public init() {}
    public var endpointAvailable: Bool {
        guard let path else { return false }
        var info = stat()
        return lstat(path,&info) == 0 && info.st_ino == inode && info.st_uid == getuid() && info.st_mode & S_IFMT == S_IFSOCK && info.st_mode & 0o077 == 0
    }
    public func start(path: String, handler: @escaping @MainActor (Data) -> Data) throws {
        guard source == nil else { return }
        let directory = URL(fileURLWithPath:path).deletingLastPathComponent().path
        var info = stat()
        if lstat(directory,&info) == 0 {
            guard info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFDIR else { throw AppFailure("Automation needs a real folder owned by your macOS user. Remove the conflicting path and enable control again.") }
            guard chmod(directory,0o700) == 0 else { throw AppFailure("Could not protect the automation folder. Check its permissions and enable control again.") }
        } else {
            try FileManager.default.createDirectory(atPath:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        }
        if lstat(path,&info) == 0 {
            guard info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFSOCK else { throw AppFailure("The automation path is already in use.") }
            let probe = socket(AF_UNIX,SOCK_STREAM,0); defer { close(probe) }
            guard probe >= 0, fcntl(probe,F_SETFL,O_NONBLOCK) == 0 else { throw AppFailure("Could not inspect the automation socket.") }
            var address = try LocalControl.address(path)
            let result = withUnsafePointer(to:&address) { $0.withMemoryRebound(to:sockaddr.self,capacity:1) { connect(probe,$0,socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            guard result != 0, errno == ECONNREFUSED else { throw AppFailure("Another Mochi instance owns external control.") }
            guard unlink(path) == 0 else { throw AppFailure("Could not clean up the inactive automation socket.") }
        }
        var address = try LocalControl.address(path)
        let fd = socket(AF_UNIX,SOCK_STREAM,0); guard fd >= 0 else { throw AppFailure("Could not create local control socket.") }
        let bound = withUnsafePointer(to:&address) { $0.withMemoryRebound(to:sockaddr.self,capacity:1) { bind(fd,$0,socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard bound == 0 else { close(fd); throw AppFailure("Could not bind local control socket.") }
        guard chmod(path,0o600) == 0, listen(fd,8) == 0 else { close(fd); unlink(path); throw AppFailure("Could not protect local control socket.") }
        guard fcntl(fd,F_SETFL,O_NONBLOCK) == 0 else { close(fd); unlink(path); throw AppFailure("Could not configure the control listener.") }
        _ = lstat(path,&info); inode = info.st_ino; self.path = path
        let generation = UUID()
        lock.lock(); active = true; self.generation = generation; lock.unlock()
        let source = DispatchSource.makeReadSource(fileDescriptor:fd,queue:DispatchQueue(label:"mochi.control.accept"))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            while true {
                let client = accept(fd,nil,nil); if client < 0 { break }
                self.lock.lock(); let allowed = self.active && self.clients.count < 8; if allowed { self.clients.insert(client) }; self.lock.unlock()
                guard allowed else { close(client); continue }
                DispatchQueue.global(qos:.utility).async { [weak self] in
                    guard let self else { close(client); return }
                    let activity = ProcessInfo.processInfo.beginActivity(options:[.userInitiated,.latencyCritical],reason:"Handle a local Mochi control request")
                    defer { ProcessInfo.processInfo.endActivity(activity); self.lock.lock(); self.clients.remove(client); self.lock.unlock(); close(client) }
                    do { try LocalControl.configure(client) } catch { return }
                    var uid: uid_t = 0, gid: gid_t = 0
                    guard getpeereid(client,&uid,&gid) == 0, uid == getuid(), let data = try? LocalControl.receiveFrame(fd:client) else { return }
                    let deadline = Date().addingTimeInterval(4), complete = DispatchSemaphore(value:0)
                    let result = ControlReplyBox()
                    Task { @MainActor [weak self] in
                        guard let self else { complete.signal(); return }
                        let active = self.isActive(generation)
                        if active && Date() < deadline { result.set(handler(data)) }
                        complete.signal()
                    }
                    if complete.wait(timeout:.now()+5) == .success, let response = result.get() { try? LocalControl.sendFrame(response,fd:client) }
                }
            }
        }
        source.setCancelHandler { close(fd) }; self.source = source; source.resume()
    }
    private func isActive(_ expected: UUID) -> Bool { lock.lock(); defer { lock.unlock() }; return active && generation == expected }
    public func stop() {
        lock.lock(); active = false; generation = UUID(); for fd in clients { shutdown(fd,SHUT_RDWR) }; lock.unlock()
        source?.cancel(); source = nil
        if let path { var info = stat(); if lstat(path,&info) == 0 && info.st_ino == inode && info.st_uid == getuid() { unlink(path) } }
        path = nil
    }
    deinit { stop() }
}
private final class ControlReplyBox {
    private let lock = NSLock(); private var value: Data?
    func set(_ data: Data) { lock.lock(); value = data; lock.unlock() }
    func get() -> Data? { lock.lock(); defer { lock.unlock() }; return value }
}
