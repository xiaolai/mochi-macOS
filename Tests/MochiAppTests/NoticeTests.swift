import XCTest
@testable import MochiApp

final class NoticeTests: XCTestCase {
    @MainActor private func wait(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(2)
        while !predicate() && Date() < deadline { try? await Task.sleep(nanoseconds:1_000_000) }
        XCTAssertTrue(predicate(),file:file,line:line)
    }
    @MainActor func testConversationNoticeDismissesAfterFourSeconds() async {
        let app = AppModel(demo:true); app.resume(); app.notice = nil
        let gate = TestGate(); var scheduled = false
        app.noticeSleep = { duration in XCTAssertEqual(duration,4_000_000_000); scheduled = true; await gate.wait() }
        app.notice = "Help draft saved."
        await wait { scheduled }
        XCTAssertNotNil(app.notice)
        await gate.release(); await wait { app.notice == nil }
        app.stop()
    }
    @MainActor func testReplacingEvenIdenticalNoticeRejectsOldExpiry() async {
        let app = AppModel(demo:true); app.resume(); app.notice = nil
        let first = TestGate(), second = TestGate(); var scheduled = 0
        app.noticeSleep = { _ in scheduled += 1; await first.wait() }
        app.notice = "Saved."
        await wait { scheduled == 1 }
        app.noticeSleep = { _ in scheduled += 1; await second.wait() }
        app.notice = "Saved."
        await wait { scheduled == 2 }
        await first.release(); for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(app.notice,"Saved.")
        await second.release(); await wait { app.notice == nil }
        app.stop()
    }
    @MainActor func testManualDismissAndNavigationRejectLateExpiry() async {
        let app = AppModel(demo:true); app.resume(); app.notice = nil
        for navigate in [false,true] {
            let gate = TestGate(); var scheduled = false
            app.noticeSleep = { _ in scheduled = true; await gate.wait() }
            app.notice = "Saved."
            await wait { scheduled }
            if navigate { app.select(app.library.conversations.last!.id) } else { app.notice = nil }
            XCTAssertNil(app.notice)
            await gate.release(); for _ in 0..<10 { await Task.yield() }
            XCTAssertNil(app.notice)
        }
        app.stop()
    }
    @MainActor func testHelpGuidanceAndErrorsDoNotAutoDismiss() async {
        let app = AppModel(demo:true); app.notice = nil
        XCTAssertTrue(app.practice)
        var scheduled = false
        app.noticeSleep = { _ in scheduled = true }
        app.notice = "Check the recognized thought before finding the English."
        app.error = "Connection failed."
        for _ in 0..<10 { await Task.yield() }
        XCTAssertFalse(scheduled); XCTAssertNotNil(app.notice); XCTAssertNotNil(app.error)
        app.stop()
    }
}
