import Foundation

/// Spaced spoken review of saved expressions (plan W5): boxes 0–5 come back after 1, 2, 4, 8, 16 and 32 days.
/// Again sends an expression back to box 0, Hard keeps its box, Good moves it up one. Due dates fall at the start of a
/// local day, counted in calendar days, so a change to or from daylight saving time never moves one.
public enum ReviewSchedule {
    public static let gaps = [1, 2, 4, 8, 16, 32]

    /// A newly saved expression: box 0, due the next day.
    public static func enrol(at now: Date, calendar: Calendar = .current) -> ReviewState {
        ReviewState(box: 0, due: day(after: now, days: gaps[0], calendar), enrolled: now)
    }
    /// The state after grading. An expression saved before review existed is enrolled as it is graded.
    public static func grade(
        _ state: ReviewState?, _ grade: ReviewState.Grade, at now: Date, calendar: Calendar = .current
    ) -> ReviewState {
        var next = state ?? ReviewState(box: 0, due: now, enrolled: now)
        switch grade {
        case .again: next.box = 0
        case .hard: break
        case .good: next.box = min(next.box + 1, ReviewState.boxes.upperBound)
        }
        next.due = max(day(after: now, days: gaps[next.box], calendar), next.enrolled)
        next.grades = Array((next.grades + [.init(date: now, grade: grade)]).suffix(ReviewState.maximumGrades))
        return next
    }
    /// Whether an expression is waiting for review; one saved before review existed always is.
    public static func isDue(_ state: ReviewState?, at now: Date) -> Bool { state.map { $0.due <= now } ?? true }
    /// The expressions due now, longest waiting first; those saved before review existed count from when saved.
    public static func queue(_ expressions: [PracticeExpression], at now: Date) -> [UUID] {
        expressions.filter { isDue($0.review, at: now) }
            .sorted { ($0.review?.due ?? $0.date, $0.id.uuidString) < ($1.review?.due ?? $1.date, $1.id.uuidString) }
            .map(\.id)
    }
    private static func day(after now: Date, days: Int, _ calendar: Calendar) -> Date {
        let today = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: days, to: today) ?? today.addingTimeInterval(Double(days) * 86400)
    }
}

extension Library {
    /// Stores a practice copy of an expression by its ID and returns what was stored. Review state belongs to the
    /// library: a new expression is enrolled, and replacing one keeps the review state already stored, so a copy
    /// opened before a grade never undoes it.
    @discardableResult public mutating func storeExpression(_ item: PracticeExpression, at now: Date = Date())
        -> PracticeExpression
    {
        var stored = item
        if let index = expressions.firstIndex(where: { $0.id == item.id }) {
            stored.review = expressions[index].review
            expressions[index] = stored
        } else {
            stored.review = ReviewSchedule.enrol(at: now)
            expressions.insert(stored, at: 0)
        }
        return stored
    }
}
