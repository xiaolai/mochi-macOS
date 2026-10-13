import Foundation
import MochiCore
import MochiKernel

/// Spoken review of My Expressions (plan W5), in the practice sheet: each due expression's meaning is shown and its
/// words hidden; the learner says it, reveals it, compares, and grades it. Grades change only the review state of the
/// expression with that ID, so practice never overwrites them and they never overwrite practice.
extension AppModel {
    var dueExpressionCount: Int { ReviewSchedule.queue(library.expressions, at: Date()).count }
    var canStartReview: Bool { !busy && !practice && libraryReadable && dueExpressionCount > 0 }

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
        resume()
        guard !practice else { return }
        showExpressions = true
        notice = String(localized: "Review finished: \(graded) graded.")
    }
    private func openForReview(_ run: ReviewRun) {
        guard let id = run.current, let item = library.expressions.first(where: { $0.id == id }) else {
            endReview(graded: run.graded)
            return
        }
        openExpression(item)
        help.review = run
    }
}
