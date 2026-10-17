import AppKit
import Darwin
import MochiCore
import MochiKernel

/// Never unlink a held lock: another inode could acquire a second owner.
final class ProcessInstanceLock {
    private let descriptor: Int32
    init?(url: URL) throws {
        descriptor = Darwin.open(url.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else {
            Darwin.close(descriptor)
            throw POSIXError(.EINVAL)
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            if code == EWOULDBLOCK { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        let pid = Data(String(getpid()).utf8)
        let written = pid.withUnsafeBytes { Darwin.pwrite(descriptor, $0.baseAddress, pid.count, 0) }
        guard written == pid.count, ftruncate(descriptor, off_t(pid.count)) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }
    static func ownerPID(at url: URL) -> pid_t? {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else { return nil }
        var bytes = [UInt8](repeating: 0, count: 32)
        let count = Darwin.read(fd, &bytes, bytes.count)
        guard count > 0, count < bytes.count, let pid = Int32(String(decoding: bytes.prefix(count), as: UTF8.self)),
            pid > 1
        else { return nil }
        return pid
    }
    deinit { Darwin.close(descriptor) }
}

struct LegacyInstance {
    static func eligible(build: String?, guarded: Bool, finished: Bool, alive: Bool, distribution: Bool = false) -> Bool
    {
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
        didSet {
            if pendingReopen, let revealWorkspace {
                pendingReopen = false
                revealWorkspace()
            }
        }
    }
    private let notification = Notification.Name(AppIdentity.bundleIdentifier + ".reopen")
    private var fixtureID: String? {
        #if MOCHI_DEVELOPMENT
            if DevelopmentLaunch.Flag.singleInstanceSmokeTest.isSet {
                return ProcessInfo.processInfo.environment["MOCHI_INSTANCE_TEST_ID"] ?? "native-smoke"
            }
        #endif
        return nil
    }
    private var scope: String { String(getuid()) + (fixtureID.map { "." + $0 } ?? "") }
    deinit { if let observer { DistributedNotificationCenter.default().removeObserver(observer) } }

    /// True when this process holds the instance lock and no Mochi build is running beside it.
    /// Builds before the lock existed can still be running, so every identifier is checked.
    var ownsLibrary: Bool {
        guard lock != nil else { return false }
        let identifiers = [AppIdentity.bundleIdentifier] + AppIdentity.legacyBundleIdentifiers
        return !identifiers.contains {
            NSRunningApplication.runningApplications(withBundleIdentifier: $0).contains {
                $0.processIdentifier != getpid()
            }
        }
    }
    func receiveReopen() {
        if let revealWorkspace { revealWorkspace() } else { pendingReopen = true }
    }

    /// Testable ownership transition. No UI, library access, or process termination.
    func claim(at url: URL, scope: String) throws -> Bool {
        guard lock == nil else { return true }
        if observer == nil {
            observer = DistributedNotificationCenter.default().addObserver(
                forName: notification, object: scope, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.receiveReopen() }
            }
        }
        guard let acquired = try ProcessInstanceLock(url: url) else { return false }
        lock = acquired
        return true
    }

    func enforce() {
        guard lock == nil else { return }
        #if MOCHI_DEVELOPMENT
            if DevelopmentLaunch.demo && fixtureID == nil { return }
        #endif
        do {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            var directory = support.appendingPathComponent(AppIdentity.bundleIdentifier, isDirectory: true)
            #if MOCHI_DEVELOPMENT
                if let fixtureID {
                    // Fixtures are outside Application Support and removed by the remote runner.
                    directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                        "mochi-instance-" + fixtureID, isDirectory: true)
                }
            #endif
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard try claim(at: directory.appendingPathComponent("instance.lock"), scope: scope) else {
                DistributedNotificationCenter.default().postNotificationName(
                    notification, object: scope, userInfo: nil, deliverImmediately: true)
                // Launch Services supplies an activation request, which a bare
                // distributed notification cannot reliably transfer on modern macOS.
                if let pid = ProcessInstanceLock.ownerPID(at: directory.appendingPathComponent("instance.lock")),
                    pid != getpid(), kill(pid, 0) == 0,
                    let owner = NSRunningApplication(processIdentifier: pid), let url = owner.bundleURL,
                    owner.bundleIdentifier == AppIdentity.bundleIdentifier, try !Self.reopen(url)
                {
                    InstanceEvidence.record("duplicate-reopen-failed")
                    Self.fail(
                        "Mochi is already running, but its window could not be shown. Click Mochi in the menu bar to open it."
                    )
                }
                InstanceEvidence.record("duplicate-exit")
                exit(EXIT_SUCCESS)
            }
            InstanceEvidence.record("lock-acquired")
            if fixtureID == nil, try handOffToLegacyOwner() { exit(EXIT_SUCCESS) }
        } catch {
            Self.fail("Unable to establish exclusive access to Mochi. \(error.localizedDescription)")
        }
    }

    private static func fail(_ explanation: String.LocalizationValue) -> Never {
        // NSApplication must exist before presenting startup failures.
        _ = NSApplication.shared
        let alert = NSAlert()
        alert.messageText = String(localized: "Mochi couldn’t start safely")
        alert.informativeText = String(localized: explanation)
        alert.runModal()
        exit(EXIT_FAILURE)
    }

    /// Asks Launch Services to reopen a running copy. False when `open` fails or does not finish in time.
    static func reopen(_ url: URL, timeout: TimeInterval = 10) throws -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", url.path]
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        guard finished.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            return false
        }
        return process.terminationReason == .exit && process.terminationStatus == 0
    }

    /// A process of a lock-aware build resolves itself through the instance lock; any other may become an owner.
    /// An upgrade can replace the bundle under a running legacy process, so its on-disk metadata is trusted
    /// only when the bundle, its Info.plist and its executable all predate the process.
    private static func lockAware(_ app: NSRunningApplication) -> Bool {
        guard let bundle = trustedBundle(app) else { return false }
        return bundle.object(forInfoDictionaryKey: "MochiSingleInstanceProtocol") as? Bool == true
    }

    /// The process's bundle, only if the bundle, its Info.plist and its executable all predate the process,
    /// so its metadata describes the code actually running.
    private static func trustedBundle(_ app: NSRunningApplication) -> Bundle? {
        guard let url = app.bundleURL, let bundle = Bundle(url: url), let executable = bundle.executableURL,
            let started = startTime(app.processIdentifier),
            unchangedSince(started, [url, url.appendingPathComponent("Contents/Info.plist"), executable])
        else { return nil }
        return bundle
    }

    /// True when every path exists and its inode last changed no later than `start`.
    /// The inode change time cannot be preserved by a copy or set by a tool, unlike the modification time.
    nonisolated static func unchangedSince(_ start: timespec, _ paths: [URL]) -> Bool {
        paths.allSatisfy { url in
            var info = stat()
            guard stat(url.path, &info) == 0 else { return false }
            let changed = info.st_ctimespec
            return changed.tv_sec < start.tv_sec || (changed.tv_sec == start.tv_sec && changed.tv_nsec <= start.tv_nsec)
        }
    }

    /// The kernel's record of when a process started, independent of how it was launched.
    nonisolated static func startTime(_ pid: pid_t) -> timespec? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&name, u_int(name.count), &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else {
            return nil
        }
        let started = info.kp_proc.p_un.__p_starttime
        return timespec(tv_sec: started.tv_sec, tv_nsec: Int(started.tv_usec) * 1000)
    }

    /// Waits for Mochi processes that are still launching, so a legacy build cannot finish starting unseen.
    private static func awaitLaunching(_ identifiers: [String], timeout: TimeInterval = 5) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        func launching() -> Bool {
            identifiers.contains { identifier in
                NSRunningApplication.runningApplications(withBundleIdentifier: identifier).contains {
                    $0.processIdentifier != getpid() && !$0.isFinishedLaunching && !$0.isTerminated
                        && kill($0.processIdentifier, 0) == 0 && !lockAware($0)
                }
            }
        }
        while launching() {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw AppFailure("Another copy of Mochi is still starting. Quit it, then open Mochi again.")
            }
            // NSRunningApplication refreshes its launch state as the main run loop runs.
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }

    private func handOffToLegacyOwner() throws -> Bool {
        #if MOCHI_DEVELOPMENT
            let distribution = false
        #else
            let distribution = true
        #endif
        let identifiers = [AppIdentity.bundleIdentifier] + AppIdentity.legacyBundleIdentifiers
        try Self.awaitLaunching(identifiers)
        for identifier in identifiers {
            for existing in NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            where existing.processIdentifier != getpid() {
                // A distribution owner is recognised by its running process alone; an upgrade may have removed its bundle.
                // A bundle replaced after the process started says nothing about the running code, so that process is
                // treated like a distribution owner too.
                let bundle = Self.trustedBundle(existing)
                guard
                    LegacyInstance.eligible(
                        build: bundle?.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
                        guarded: bundle?.object(forInfoDictionaryKey: "MochiSingleInstanceProtocol") as? Bool == true,
                        finished: existing.isFinishedLaunching && !existing.isTerminated,
                        alive: kill(existing.processIdentifier, 0) == 0, distribution: distribution || bundle == nil)
                else { continue }
                // Without a bundle to reopen, fail closed rather than run beside it.
                guard let url = existing.bundleURL else {
                    throw AppFailure("Another copy of Mochi is running. Quit it, then open Mochi again.")
                }
                let reopened = try Self.reopen(url)
                // A dead legacy owner must not swallow the new launch. Continue as owner.
                guard kill(existing.processIdentifier, 0) == 0, !existing.isTerminated else { continue }
                guard reopened else {
                    throw AppFailure("The running Mochi window could not be reopened.")
                }
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
            let directory = URL(fileURLWithPath: root).appendingPathComponent(String(getpid()), isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data: [String: Any] = ["event": event, "pid": getpid(), "time": Date().timeIntervalSince1970]
            if let bytes = try? JSONSerialization.data(withJSONObject: data, options: .sortedKeys) {
                try? bytes.write(to: directory.appendingPathComponent(event + ".json"), options: .atomic)
            }
        #endif
    }
}
