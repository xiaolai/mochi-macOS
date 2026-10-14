import MochiCore
import XCTest

final class TranscriptTimelineTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }
    /// 14 October 2026 at `hour:minute` in the test time zone, offset by `days`.
    private func date(days: Int = 0, _ hour: Int, _ minute: Int = 0) -> Date {
        let base = calendar.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: hour, minute: minute))!
        return calendar.date(byAdding: .day, value: days, to: base)!
    }
    private func messages(_ dates: [Date]) -> [Message] {
        dates.map {
            var message = Message(role: "user", text: "Hi")
            message.date = $0
            return message
        }
    }
    private func dividers(_ dates: [Date]) -> [Int] {
        let list = messages(dates)
        let ids = TranscriptTimeline.dividerIDs(list, calendar: calendar)
        return list.indices.filter { ids.contains(list[$0].id) }
    }

    func testTheFirstMessageAlwaysStartsADivider() {
        XCTAssertEqual(dividers([date(9)]), [0])
        XCTAssertEqual(dividers([]), [])
    }

    func testAGapOfAnHourOrMoreStartsANewDivider() {
        XCTAssertEqual(dividers([date(9), date(9, 59)]), [0], "59 minutes is the same stretch")
        XCTAssertEqual(dividers([date(9), date(10)]), [0, 1], "An hour exactly starts a new one")
        XCTAssertEqual(dividers([date(9), date(9, 40), date(10, 20), date(11, 30)]), [0, 3])
    }

    func testANewDayStartsADividerEvenAfterAShortGap() {
        XCTAssertEqual(dividers([date(23, 50), date(days: 1, 0, 5)]), [0, 1])
    }

    func testAMessageDatedBeforeTheOneAboveStartsADividerOnlyOnAnotherDay() {
        XCTAssertEqual(dividers([date(10), date(9, 30)]), [0], "A clock set back within the day is no new stretch")
        XCTAssertEqual(dividers([date(10), date(days: -1, 10)]), [0, 1])
    }

    func testLabelsByAge() {
        let now = date(15)
        XCTAssertEqual(TranscriptTimeline.label(for: date(9), now: now, calendar: calendar), .today)
        XCTAssertEqual(TranscriptTimeline.label(for: date(days: -1, 23), now: now, calendar: calendar), .yesterday)
        XCTAssertEqual(TranscriptTimeline.label(for: date(days: -6, 8), now: now, calendar: calendar), .thisWeek)
        XCTAssertEqual(TranscriptTimeline.label(for: date(days: -7, 8), now: now, calendar: calendar), .older)
    }

    func testAFutureDateIsShownInFull() {
        XCTAssertEqual(TranscriptTimeline.label(for: date(days: 1, 9), now: date(15), calendar: calendar), .older)
    }

    func testTodayTurnsIntoYesterdayAtMidnight() {
        XCTAssertEqual(TranscriptTimeline.label(for: date(23), now: date(23, 59), calendar: calendar), .today)
        XCTAssertEqual(
            TranscriptTimeline.label(for: date(23), now: date(days: 1, 0, 1), calendar: calendar), .yesterday)
    }
}
