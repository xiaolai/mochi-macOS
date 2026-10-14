import XCTest

@testable import MochiApp

final class TimeDividerTests: XCTestCase {
    private let locale = Locale(identifier: "en_US")
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }
    private func date(days: Int = 0, _ hour: Int, _ minute: Int = 0) -> Date {
        let base = calendar.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: hour, minute: minute))!
        return calendar.date(byAdding: .day, value: days, to: base)!
    }
    private func text(_ date: Date) -> String {
        TimeDivider.text(for: date, now: self.date(20), calendar: calendar, locale: locale)
            .replacingOccurrences(of: "\u{202F}", with: " ")
    }

    func testEachAgeReadsAsItsLabel() {
        XCTAssertEqual(text(date(19, 3)), "Today 7:03 PM")
        XCTAssertEqual(text(date(days: -1, 9, 12)), "Yesterday 9:12 AM")
        XCTAssertEqual(text(date(days: -2, 15, 40)), "Monday 3:40 PM")
        XCTAssertEqual(text(date(days: -11, 15, 40)), "Oct 3, 2026 at 3:40 PM")
    }
}
