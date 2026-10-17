import Darwin
import MochiTestSupport
import XCTest

@testable import MochiApp

final class SingleInstanceTests: XCTestCase {
    private func root() throws -> URL {
        let root = TestScratch.folder()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    func testDuplicateIsRejectedAndTerminationReleasesLockWithoutDeletingFile() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("instance.lock")
        var owner: ProcessInstanceLock? = try XCTUnwrap(ProcessInstanceLock(url: url))
        XCTAssertNotNil(owner)
        XCTAssertEqual(ProcessInstanceLock.ownerPID(at: url), getpid())
        XCTAssertNil(try ProcessInstanceLock(url: url))
        owner = nil
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let replacement = try XCTUnwrap(ProcessInstanceLock(url: url))
        XCTAssertNotNil(replacement)
        XCTAssertNil(try ProcessInstanceLock(url: url))
    }
    func testCrashReleasesKernelLockWithoutPythonOrDeveloperToolStubs() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("instance.lock")
        let helper = root.appendingPathComponent("lock-helper")
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("scripts/tests/fixtures/InstanceLock.c")
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        compiler.arguments = ["clang", source.path, "-o", helper.path]
        try compiler.run()
        compiler.waitUntilExit()
        XCTAssertEqual(compiler.terminationStatus, 0)
        let child = Process()
        let output = Pipe()
        child.executableURL = helper
        child.arguments = [url.path]
        child.standardOutput = output
        try child.run()
        defer {
            if child.isRunning {
                kill(child.processIdentifier, SIGKILL)
                child.waitUntilExit()
            }
        }
        // Bounded: a helper that never reports the lock must fail the test, not hang the suite.
        let locked = expectation(description: "Helper holds the lock")
        var reported = Data()
        output.fileHandleForReading.readabilityHandler = { handle in
            reported.append(handle.availableData)
            if reported.count >= 7 {
                handle.readabilityHandler = nil
                locked.fulfill()
            }
        }
        wait(for: [locked], timeout: 5)
        XCTAssertEqual(reported.prefix(7), Data("locked\n".utf8))
        XCTAssertNil(try ProcessInstanceLock(url: url))
        kill(child.processIdentifier, SIGKILL)
        child.waitUntilExit()
        XCTAssertNotNil(try ProcessInstanceLock(url: url))
    }
    @MainActor func testControllerClaimIsIdempotentAndRejectsAnotherController() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("instance.lock")
        let owner = SingleInstanceController()
        XCTAssertTrue(try owner.claim(at: url, scope: root.lastPathComponent))
        XCTAssertTrue(try owner.claim(at: url, scope: root.lastPathComponent))
        XCTAssertFalse(try SingleInstanceController().claim(at: url, scope: root.lastPathComponent))
    }
    @MainActor func testPendingReopenIsConsumedOnceWhenWorkspaceAttaches() {
        let owner = SingleInstanceController()
        var count = 0
        owner.receiveReopen()
        owner.receiveReopen()
        owner.revealWorkspace = { count += 1 }
        XCTAssertEqual(count, 1)
        owner.revealWorkspace = { count += 1 }
        XCTAssertEqual(count, 1)
        owner.receiveReopen()
        XCTAssertEqual(count, 2)
    }
    func testOnlyLiveFinishedPreGuardBuildsAreLegacyOwners() {
        XCTAssertTrue(LegacyInstance.eligible(build: "25", guarded: false, finished: true, alive: true))
        for build in [nil, "unknown", "0", "26", "999"] {
            XCTAssertFalse(LegacyInstance.eligible(build: build, guarded: false, finished: true, alive: true))
        }
        XCTAssertFalse(LegacyInstance.eligible(build: "25", guarded: true, finished: true, alive: true))
        XCTAssertFalse(LegacyInstance.eligible(build: "25", guarded: false, finished: false, alive: true))
        XCTAssertFalse(LegacyInstance.eligible(build: "25", guarded: false, finished: true, alive: false))
    }
    func testDistributionDoesNotTrustReplacedOnDiskLegacyMetadata() {
        XCTAssertTrue(
            LegacyInstance.eligible(build: "26", guarded: true, finished: true, alive: true, distribution: true))
        XCTAssertTrue(
            LegacyInstance.eligible(build: nil, guarded: true, finished: true, alive: true, distribution: true))
        XCTAssertFalse(
            LegacyInstance.eligible(build: "26", guarded: true, finished: false, alive: true, distribution: true))
        XCTAssertFalse(
            LegacyInstance.eligible(build: "26", guarded: true, finished: true, alive: false, distribution: true))
    }
    func testADevelopmentSessionIsNeverAnOwnerToHandOffTo() {
        // A preview holds no lock and opens a throwaway library; a distribution launch must not reopen it and exit.
        XCTAssertFalse(
            LegacyInstance.eligible(
                build: "26", guarded: true, finished: true, alive: true, distribution: true, development: true))
        XCTAssertFalse(
            LegacyInstance.eligible(
                build: nil, guarded: true, finished: true, alive: true, distribution: true, development: true))
        XCTAssertFalse(
            LegacyInstance.eligible(build: "25", guarded: false, finished: true, alive: true, development: true))
    }
    func testProcessArgumentsAreReadFromTheKernel() throws {
        XCTAssertEqual(SingleInstanceController.arguments(of: getpid()), CommandLine.arguments)
        let preview = Process()
        preview.executableURL = URL(fileURLWithPath: "/bin/sh")
        // The second command keeps the shell running, so its own arguments are the ones read.
        preview.arguments = ["-c", "sleep 30; :", "Mochi", "--preview"]
        try preview.run()
        defer {
            preview.terminate()
            preview.waitUntilExit()
        }
        XCTAssertEqual(
            SingleInstanceController.arguments(of: preview.processIdentifier),
            ["/bin/sh", "-c", "sleep 30; :", "Mochi", "--preview"])
        XCTAssertTrue(SingleInstanceController.launchedForDevelopment(preview.processIdentifier))
        XCTAssertNil(SingleInstanceController.arguments(of: 0), "The kernel's own task is not readable")
    }
    func testAProcessLaunchedWithoutFlagsIsNotADevelopmentSession() throws {
        let plain = Process()
        plain.executableURL = URL(fileURLWithPath: "/bin/sleep")
        plain.arguments = ["30"]
        try plain.run()
        defer {
            plain.terminate()
            plain.waitUntilExit()
        }
        XCTAssertEqual(SingleInstanceController.arguments(of: plain.processIdentifier), ["/bin/sleep", "30"])
        XCTAssertFalse(SingleInstanceController.launchedForDevelopment(plain.processIdentifier))
    }
    func testDevelopmentFlagsAreRecognisedByTheirPrefixAlone() {
        XCTAssertEqual(DevelopmentLaunch.developmentFlags(in: ["/Applications/Mochi.app/Contents/MacOS/Mochi"]), [])
        // What macOS, Xcode and AppKit themselves pass: single-dash user defaults and process serial numbers.
        XCTAssertEqual(
            DevelopmentLaunch.developmentFlags(in: [
                "Mochi", "-psn_0_12345", "-NSDocumentRevisionsDebugMode", "YES", "-ApplePersistenceIgnoreState", "YES",
            ]), [])
        XCTAssertEqual(
            DevelopmentLaunch.developmentFlags(in: ["Mochi", "--hands-free-smoke-test", "/tmp/stream.raw"]),
            ["--hands-free-smoke-test"])
        XCTAssertEqual(
            DevelopmentLaunch.developmentFlags(in: ["--preview"]), [], "The program's own path is not a flag")
        XCTAssertEqual(
            DevelopmentLaunch.developmentFlags(in: ["Mochi", "--a-flag-added-later"]), ["--a-flag-added-later"])
        // Every flag a development build acts on is one a distribution build refuses to start with.
        for flag in DevelopmentLaunch.flags {
            XCTAssertEqual(DevelopmentLaunch.developmentFlags(in: ["Mochi", flag]), [flag])
        }
    }
    func testInvalidAndSymlinkLockPathsFailClosed() throws {
        XCTAssertThrowsError(try ProcessInstanceLock(url: URL(fileURLWithPath: "/dev/null/instance.lock")))
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("instance.lock")
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: root.appendingPathComponent("other"))
        XCTAssertThrowsError(try ProcessInstanceLock(url: url))
        XCTAssertThrowsError(try ProcessInstanceLock(url: root))
    }
}

extension SingleInstanceTests {
    func testBundleMetadataIsTrustedOnlyWhenItPredatesTheProcess() throws {
        let folder = TestScratch.folder("instance")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("Info.plist")
        let started = try XCTUnwrap(SingleInstanceController.startTime(getpid()))
        XCTAssertLessThanOrEqual(started.tv_sec, time(nil))
        try Data("x".utf8).write(to: file)
        // Written after this process started: an upgrade replaced it, so it does not describe the process.
        XCTAssertFalse(SingleInstanceController.unchangedSince(started, [file]))
        var now = timespec()
        clock_gettime(CLOCK_REALTIME, &now)
        XCTAssertTrue(SingleInstanceController.unchangedSince(now, [file]))
        XCTAssertFalse(SingleInstanceController.unchangedSince(now, [folder.appendingPathComponent("missing")]))
    }
}
