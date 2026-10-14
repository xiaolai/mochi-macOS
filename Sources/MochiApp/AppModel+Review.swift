import Foundation
import MochiCore

/// Spoken review of My Expressions (plan W5), in the practice sheet: each due expression's meaning is shown and its
/// words hidden; the learner says it, reveals it, compares, and grades it. Grades change only the review state of the
/// expression with that ID, so practice never overwrites them and they never overwrite practice.
extension AppModel {
    var dueExpressionCount: Int { dueExpressionCount(at: Date()) }
    var canStartReview: Bool { canStartReview(at: Date()) }
    func dueExpressionCount(at now: Date) -> Int { ReviewSchedule.queue(library.expressions, at: now).count }
    func canStartReview(at now: Date) -> Bool {
        !busy && !practice && libraryReadable && dueExpressionCount(at: now) > 0
    }

    func startReview() {
        guard canStartReview else { return }
        let queue = ReviewSchedule.queue(library.expressions, at: Date())
        guard !queue.isEmpty else { return }
        openForReview(ReviewRun(queue: queue))
    }
    func revealReview() { help.review?.revealed = true }
    /// Grades the expression under review and moves on. When the grade cannot be saved, nothing moves and the
    /// failure stays visible, so the grade can be given again.
    func gradeReview(_ grade: ReviewState.Grade) {
        guard !busy, var run = help.review, run.revealed, let id = run.current,
            let index = library.expressions.firstIndex(where: { $0.id == id })
        else { return }
        let before = library.expressions[index].review
        let graded = ReviewSchedule.grade(before, grade, at: Date())
        library.expressions[index].review = graded
        guard save() else {
            library.expressions[index].review = before
            return
        }
        help.expression?.review = graded
        run.graded += 1
        if grade == .again, !run.repeated.contains(id) {
            run.repeated.insert(id)
            run.queue.append(id)
        }
        run.position += 1
        run.revealed = false
        if run.current == nil {
            endReview(graded: run.graded)
        } else {
            openForReview(run)
        }
    }
    /// Ends the review early or at its end; the expressions graded so far keep their grades.
    func endReview() { endReview(graded: help.review?.graded ?? 0) }
    private func endReview(graded: Int) {
        // The run ends before resuming: when resume() cannot save and keeps practice open, nothing already graded
        // can be graded again.
        help.review = nil
        resume()
        // resume() keeps practice open when the expression could not be saved; the failure is already shown.
        guard !practice else { return }
        showExpressions = true
        notice = String(localized: "Review finished: \(graded) graded.")
    }
    /// Opens the run's current expression. One that is gone or cannot be opened (its new conversation could not be
    /// saved, already reported) is skipped and stays due, so the rest of the run, its repeats included, goes on; the
    /// previous expression is never left on screen while grades go to another.
    private func openForReview(_ run: ReviewRun) {
        var run = run
        var skipped: String?
        while let id = run.current {
            if let item = library.expressions.first(where: { $0.id == id }), openExpression(item) {
                help.review = run
                // Opening the next one clears errors; why the earlier one was skipped stays visible.
                if let skipped, error == nil { error = skipped }
                return
            }
            skipped = error ?? skipped
            run.position += 1
        }
        // Nothing left to open: the run ends, so nothing graded can be graded again.
        help.review = nil
        if practice { endReview(graded: run.graded) }
    }
}
