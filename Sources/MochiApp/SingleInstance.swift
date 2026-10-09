import AppKit
import Darwin
import MochiCore

/// Never unlink a held lock: another inode could acquire a second owner.
final class ProcessInstanceLock {
    private let descriptor: Int32
    init?(url: URL) throws {
        descriptor = Darwin.open(url.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO) }
        var info = stat()
        guard fstat(descriptor,&info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else {
            Darwin.close(descriptor); throw POSIXError(.EINVAL)
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno; Darwin.close(descriptor)
            if code == EWOULDBLOCK { return nil }
            throw POSIXError(POSIXErrorCode(rawValue:code) ?? .EIO)
        }
        let pid = Data(String(getpid()).utf8)
        let written = pid.withUnsafeBytes { Darwin.pwrite(descriptor,$0.baseAddress,pid.count,0) }
        guard written == pid.count, ftruncate(descriptor,off_t(pid.count)) == 0 else {
            let code = errno; Darwin.close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue:code) ?? .EIO)
        }
    }
    static func ownerPID(at url: URL) -> pid_t? {
        let fd = Darwin.open(url.path,O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }; defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd,&info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else { return nil }
        var bytes = [UInt8](repeating:0,count:32)
        let count = Darwin.read(fd,&bytes,bytes.count)
        guard count > 0, count < bytes.count, let pid = Int32(String(decoding:bytes.prefix(count),as:UTF8.self)), pid > 1 else { return nil }
        return pid
    }
    deinit { Darwin.close(descriptor) }
}

struct LegacyInstance {
    static func eligible(build: String?, guarded: Bool, finished: Bool, alive: Bool, distribution: Bool = false) -> Bool {
        guard finished, alive else { return false }
        // A finished distribution process cannot be an unlocked current owner.
        // Its on-disk bundle may already have been replaced during an upgrade.
        if distribution { return true }
        guard !guarded, let build, let number = Int(build) else { return false }
        return (1...25).contains(number)
    }
}

@MainActor final class SingleInstanceController {
    static let shared = SingleInstanceController()
    private var lock: ProcessInstanceLock?
    private var observer: NSObjectProtocol?
    private var pendingReopen = false
    var revealWorkspace: (() -> Void)? {
        didSet { if pendingReopen, let revealWorkspace { pendingReopen = false; revealWorkspace() } }
    }
    private let notification = Notification.Name(AppIdentity.bundleIdentifier + ".reopen")
    private var fixtureID: String? {
        #if MOCHI_DEVELOPMENT
        if CommandLine.arguments.contains("--single-instance-smoke-test") {
            return ProcessInfo.processInfo.environment["MOCHI_INSTANCE_TEST_ID"] ?? "native-smoke"
        }
        #endif
        return nil
    }
    private var scope: String { String(getuid()) + (fixtureID.map { "." + $0 } ?? "") }
    deinit { if let observer { DistributedNotificationCenter.default().removeObserver(observer) } }

    func receiveReopen() {
        if let revealWorkspace { revealWorkspace() } else { pendingReopen = true }
    }

    /// Testable ownership transition. No UI, library access, or process termination.
    func claim(at url: URL, scope: String) throws -> Bool {
        guard lock == nil else { return true }
        if observer == nil {
            observer = DistributedNotificationCenter.default().addObserver(forName:notification,object:scope,queue:.main) { [weak self] _ in
                MainActor.assumeIsolated { self?.receiveReopen() }
            }
        }
        guard let acquired = try ProcessInstanceLock(url:url) else { return false }
        lock = acquired
        return true
    }

    func enforce() {
        guard lock == nil else { return }
        #if MOCHI_DEVELOPMENT
        if DevelopmentLaunch.demo && fixtureID == nil { return }
        #endif
        do {
            let support = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
            var directory = support.appendingPathComponent(AppIdentity.bundleIdentifier,isDirectory:true)
            #if MOCHI_DEVELOPMENT
            if let fixtureID {
                // Fixtures are outside Application Support and removed by the remote runner.
                directory = FileManager.default.temporaryDirectory.appendingPathComponent("mochi-instance-" + fixtureID,isDirectory:true)
            }
            #endif
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            guard try claim(at:directory.appendingPathComponent("instance.lock"),scope:scope) else {
                DistributedNotificationCenter.default().postNotificationName(notification,object:scope,userInfo:nil,deliverImmediately:true)
                // Launch Services supplies an activation request, which a bare
                // distributed notification cannot reliably transfer on modern macOS.
                if let pid = ProcessInstanceLock.ownerPID(at:directory.appendingPathComponent("instance.lock")),
                   pid != getpid(), kill(pid,0) == 0,
                   let owner = NSRunningApplication(processIdentifier:pid), let url = owner.bundleURL,
                   owner.bundleIdentifier == AppIdentity.bundleIdentifier {
                    let reopen = Process(); reopen.executableURL = URL(fileURLWithPath:"/usr/bin/open")
                    reopen.arguments = ["-a",url.path]; try reopen.run(); reopen.waitUntilExit()
                }
                InstanceEvidence.record("duplicate-exit")
                exit(EXIT_SUCCESS)
            }
            InstanceEvidence.record("lock-acquired")
            if fixtureID == nil, try handOffToLegacyOwner() { exit(EXIT_SUCCESS) }
        } catch {
            // NSApplication must exist before presenting startup failures.
            _ = NSApplication.shared
            let alert = NSAlert(); alert.messageText = "Mochi couldn’t start safely"
            alert.informativeText = "Unable to establish exclusive access to Mochi. \(error.localizedDescription)"
            alert.runModal(); exit(EXIT_FAILURE)
        }
    }

    private func handOffToLegacyOwner() throws -> Bool {
        #if MOCHI_DEVELOPMENT
        let distribution = false
        #else
        let distribution = true
        #endif
        let identifiers = [AppIdentity.bundleIdentifier] + AppIdentity.legacyBundleIdentifiers
        for identifier in identifiers {
            for existing in NSRunningApplication.runningApplications(withBundleIdentifier:identifier) where existing.processIdentifier != getpid() {
                guard let url = existing.bundleURL, let bundle = Bundle(url:url),
                      LegacyInstance.eligible(build:bundle.object(forInfoDictionaryKey:"CFBundleVersion") as? String,
                        guarded:bundle.object(forInfoDictionaryKey:"MochiSingleInstanceProtocol") as? Bool == true,
                        finished:existing.isFinishedLaunching && !existing.isTerminated,alive:kill(existing.processIdentifier,0) == 0,distribution:distribution) else { continue }
                let reopen = Process(); reopen.executableURL = URL(fileURLWithPath:"/usr/bin/open")
                reopen.arguments = ["-a",url.path]; try reopen.run(); reopen.waitUntilExit()
                // A dead legacy owner must not swallow the new launch. Continue as owner.
                guard kill(existing.processIdentifier,0) == 0, !existing.isTerminated else { continue }
                guard reopen.terminationStatus == 0 else { throw AppFailure("The running Mochi window could not be reopened.") }
                InstanceEvidence.record("legacy-handoff")
                return true
            }
        }
        return false
    }
}

/// Development-only process evidence; production binaries contain no paths or hooks.
enum InstanceEvidence {
    static func record(_ event: String) {
        #if MOCHI_DEVELOPMENT
        guard let root = ProcessInfo.processInfo.environment["MOCHI_INSTANCE_EVENTS_DIR"] else { return }
        let directory = URL(fileURLWithPath:root).appendingPathComponent(String(getpid()),isDirectory:true)
        try? FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let data: [String:Any] = ["event":event,"pid":getpid(),"time":Date().timeIntervalSince1970]
        if let bytes = try? JSONSerialization.data(withJSONObject:data,options:.sortedKeys) {
            try? bytes.write(to:directory.appendingPathComponent(event + ".json"),options:.atomic)
        }
        #endif
    }
}
