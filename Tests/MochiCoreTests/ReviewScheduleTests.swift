import MochiKernel
import XCTest

@testable import MochiCore

final class ReviewScheduleTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar
    }
    private func date(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = calendar.timeZone
        formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        return formatter.date(from: text)!
    }
    private func start(of day: String) -> Date { calendar.startOfDay(for: date(day + "T12:00:00")) }

    func testEnrolmentIsBoxZeroDueTheNextDay() {
        let now = date("2026-10-14T21:30:00")
        let state = ReviewSchedule.enrol(at: now, calendar: calendar)
        XCTAssertEqual(state.box, 0)
        XCTAssertEqual(state.due, start(of: "2026-10-15"))
        XCTAssertEqual(state.enrolled, now)
        XCTAssertTrue(state.grades.isEmpty)
        XCTAssertFalse(ReviewSchedule.isDue(state, at: now))
        XCTAssertTrue(ReviewSchedule.isDue(state, at: start(of: "2026-10-15")))
    }
    func testGoodClimbsTheBoxesWithDoublingGapsAndStopsAtFive() {
        var now = date("2026-01-05T09:00:00")
        var state = ReviewSchedule.enrol(at: now, calendar: calendar)
        var seen: [(Int, Int)] = []
        for _ in 0..<7 {
            now = state.due.addingTimeInterval(3600)
            state = ReviewSchedule.grade(state, .good, at: now, calendar: calendar)
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: state.due).day!
            seen.append((state.box, days))
        }
        XCTAssertEqual(seen.map(\.0), [1, 2, 3, 4, 5, 5, 5])
        XCTAssertEqual(seen.map(\.1), [2, 4, 8, 16, 32, 32, 32])
    }
    func testHardKeepsTheBoxAndAgainStartsOver() {
        let now = date("2026-03-02T10:00:00")
        let state = ReviewState(box: 3, due: now, enrolled: date("2026-01-01T10:00:00"))
        let hard = ReviewSchedule.grade(state, .hard, at: now, calendar: calendar)
        XCTAssertEqual(hard.box, 3)
        XCTAssertEqual(hard.due, start(of: "2026-03-10"))
        let again = ReviewSchedule.grade(state, .again, at: now, calendar: calendar)
        XCTAssertEqual(again.box, 0)
        XCTAssertEqual(again.due, start(of: "2026-03-03"))
        XCTAssertEqual(again.grades.map(\.grade), [.again])
        XCTAssertEqual(again.enrolled, state.enrolled)
    }
    func testDaylightSavingNeverMovesADueDay() {
        // London moves to summer time on 29 March 2026.
        let now = date("2026-03-27T23:30:00")
        let state = ReviewSchedule.grade(
            ReviewState(box: 1, due: now, enrolled: now), .hard, at: now, calendar: calendar)
        XCTAssertEqual(state.due, start(of: "2026-03-29"))
        XCTAssertEqual(calendar.component(.hour, from: state.due), 0)
        let autumn = date("2026-10-24T08:00:00")
        let later = ReviewSchedule.grade(
            ReviewState(box: 2, due: autumn, enrolled: autumn), .hard, at: autumn, calendar: calendar)
        XCTAssertEqual(later.due, start(of: "2026-10-28"))
        XCTAssertEqual(calendar.component(.hour, from: later.due), 0)
    }
    func testAnExpressionSavedBeforeReviewIsEnrolledWhenGraded() {
        let now = date("2026-10-14T09:00:00")
        XCTAssertTrue(ReviewSchedule.isDue(nil, at: now))
        let state = ReviewSchedule.grade(nil, .good, at: now, calendar: calendar)
        XCTAssertEqual(state.box, 1)
        XCTAssertEqual(state.enrolled, now)
        XCTAssertEqual(state.due, start(of: "2026-10-16"))
        XCTAssertTrue(state.isValid)
    }
    func testGradesKeepOnlyTheLatestHundred() {
        let now = date("2026-10-14T09:00:00")
        var state = ReviewSchedule.enrol(at: now, calendar: calendar)
        for _ in 0..<ReviewState.maximumGrades {
            state = ReviewSchedule.grade(state, .hard, at: now, calendar: calendar)
        }
        state = ReviewSchedule.grade(state, .good, at: now, calendar: calendar)
        XCTAssertEqual(state.grades.count, ReviewState.maximumGrades)
        XCTAssertEqual(state.grades.last?.grade, .good)
        XCTAssertTrue(state.isValid)
    }
    func testTheQueueHoldsDueExpressionsLongestWaitingFirst() {
        let now = date("2026-10-14T09:00:00")
        func item(_ english: String, due: String?, saved: String = "2026-09-01T09:00:00") -> PracticeExpression {
            var item = PracticeExpression(conversationID: UUID(), meaning: "", english: english, language: .english)
            item.date = date(saved)
            item.review = due.map { ReviewState(due: date($0), enrolled: date("2026-08-01T09:00:00")) }
            return item
        }
        let items = [
            item("later", due: "2026-10-20T00:00:00"), item("today", due: "2026-10-14T00:00:00"),
            item("old", due: nil, saved: "2026-10-01T09:00:00"), item("overdue", due: "2026-10-02T00:00:00"),
        ]
        XCTAssertEqual(
            ReviewSchedule.queue(items, at: now).compactMap { id in items.first { $0.id == id }?.english },
            ["old", "overdue", "today"])
    }

    func testStoringEnrolsANewExpressionAndKeepsAStoredReview() {
        var library = Library()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let item = PracticeExpression(conversationID: UUID(), meaning: "m", english: "E.", language: .english)
        XCTAssertEqual(library.storeExpression(item, at: now).review, ReviewSchedule.enrol(at: now))
        let graded = ReviewSchedule.grade(library.expressions[0].review, .good, at: now)
        library.expressions[0].review = graded
        var stale = item
        stale.english = "Edited."
        stale.review = nil
        XCTAssertEqual(library.storeExpression(stale, at: now).review, graded, "A stale copy never undoes a grade")
        XCTAssertEqual(library.expressions.map(\.english), ["Edited."])
    }

    func testDueIsTheStartOfTheDayAfterAMidnightDaylightSavingChange() throws {
        // Chile moves its clocks from 00:00 to 01:00 on 6 September 2026, so that day starts at 01:00.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Santiago"))
        let noon = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 6, hour: 12)))
        XCTAssertEqual(calendar.component(.hour, from: calendar.startOfDay(for: noon)), 1, "the fixture's premise")
        let due = ReviewSchedule.enrol(at: noon, calendar: calendar).due
        let nextDay = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 7)))
        XCTAssertEqual(due, calendar.startOfDay(for: nextDay))
        XCTAssertEqual(calendar.component(.hour, from: due), 0)
    }
}
