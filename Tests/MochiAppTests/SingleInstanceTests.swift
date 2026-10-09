import XCTest
import Darwin
@testable import MochiApp

final class SingleInstanceTests: XCTestCase {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        return root
    }
    func testDuplicateIsRejectedAndTerminationReleasesLockWithoutDeletingFile() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at:root) }
        let url = root.appendingPathComponent("instance.lock")
        var owner: ProcessInstanceLock? = try XCTUnwrap(ProcessInstanceLock(url:url))
        XCTAssertNotNil(owner); XCTAssertEqual(ProcessInstanceLock.ownerPID(at:url),getpid()); XCTAssertNil(try ProcessInstanceLock(url:url)); owner = nil
        XCTAssertTrue(FileManager.default.fileExists(atPath:url.path))
        let replacement = try XCTUnwrap(ProcessInstanceLock(url:url))
        XCTAssertNotNil(replacement); XCTAssertNil(try ProcessInstanceLock(url:url))
    }
    func testCrashReleasesKernelLockWithoutPythonOrDeveloperToolStubs() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at:root) }
        let url = root.appendingPathComponent("instance.lock")
        let helper = root.appendingPathComponent("lock-helper")
        let source = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("scripts/tests/fixtures/InstanceLock.c")
        let compiler = Process(); compiler.executableURL = URL(fileURLWithPath:"/usr/bin/xcrun")
        compiler.arguments = ["clang",source.path,"-o",helper.path]
        try compiler.run(); compiler.waitUntilExit(); XCTAssertEqual(compiler.terminationStatus,0)
        let child = Process(), output = Pipe(); child.executableURL = helper; child.arguments = [url.path]; child.standardOutput = output
        try child.run()
        defer { if child.isRunning { kill(child.processIdentifier,SIGKILL); child.waitUntilExit() } }
        XCTAssertEqual(output.fileHandleForReading.readData(ofLength:7),Data("locked\n".utf8))
        XCTAssertNil(try ProcessInstanceLock(url:url))
        kill(child.processIdentifier,SIGKILL); child.waitUntilExit()
        XCTAssertNotNil(try ProcessInstanceLock(url:url))
    }
    @MainActor func testControllerClaimIsIdempotentAndRejectsAnotherController() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at:root) }
        let url = root.appendingPathComponent("instance.lock"), owner = SingleInstanceController()
        XCTAssertTrue(try owner.claim(at:url,scope:root.lastPathComponent))
        XCTAssertTrue(try owner.claim(at:url,scope:root.lastPathComponent))
        XCTAssertFalse(try SingleInstanceController().claim(at:url,scope:root.lastPathComponent))
    }
    @MainActor func testPendingReopenIsConsumedOnceWhenWorkspaceAttaches() {
        let owner = SingleInstanceController(); var count = 0
        owner.receiveReopen(); owner.receiveReopen()
        owner.revealWorkspace = { count += 1 }; XCTAssertEqual(count,1)
        owner.revealWorkspace = { count += 1 }; XCTAssertEqual(count,1)
        owner.receiveReopen(); XCTAssertEqual(count,2)
    }
    func testOnlyLiveFinishedPreGuardBuildsAreLegacyOwners() {
        XCTAssertTrue(LegacyInstance.eligible(build:"25",guarded:false,finished:true,alive:true))
        for build in [nil,"unknown","0","26","999"] {
            XCTAssertFalse(LegacyInstance.eligible(build:build,guarded:false,finished:true,alive:true))
        }
        XCTAssertFalse(LegacyInstance.eligible(build:"25",guarded:true,finished:true,alive:true))
        XCTAssertFalse(LegacyInstance.eligible(build:"25",guarded:false,finished:false,alive:true))
        XCTAssertFalse(LegacyInstance.eligible(build:"25",guarded:false,finished:true,alive:false))
    }
    func testDistributionDoesNotTrustReplacedOnDiskLegacyMetadata() {
        XCTAssertTrue(LegacyInstance.eligible(build:"26",guarded:true,finished:true,alive:true,distribution:true))
        XCTAssertTrue(LegacyInstance.eligible(build:nil,guarded:true,finished:true,alive:true,distribution:true))
        XCTAssertFalse(LegacyInstance.eligible(build:"26",guarded:true,finished:false,alive:true,distribution:true))
        XCTAssertFalse(LegacyInstance.eligible(build:"26",guarded:true,finished:true,alive:false,distribution:true))
    }
    func testInvalidAndSymlinkLockPathsFailClosed() throws {
        XCTAssertThrowsError(try ProcessInstanceLock(url:URL(fileURLWithPath:"/dev/null/instance.lock")))
        let root = try root(); defer { try? FileManager.default.removeItem(at:root) }
        let url = root.appendingPathComponent("instance.lock")
        try FileManager.default.createSymbolicLink(at:url,withDestinationURL:root.appendingPathComponent("other"))
        XCTAssertThrowsError(try ProcessInstanceLock(url:url))
        XCTAssertThrowsError(try ProcessInstanceLock(url:root))
    }
}
