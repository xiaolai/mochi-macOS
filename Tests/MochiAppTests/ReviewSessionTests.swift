import Darwin
import MochiCore
import MochiKernel
import XCTest

@testable import MochiApp

/// Spoken review of My Expressions (plan W5).
final class ReviewSessionTests: XCTestCase {
    /// A library with `count` saved expressions, all due now, in the order of their names.
    @MainActor private func appWithDueExpressions(_ count: Int, root: URL? = nil) -> AppModel {
        let app = makeApp(root: root ?? makeTemporaryFolder())
        app.resume()
        let chatID = app.selectedID!
        let yesterday = Date().addingTimeInterval(-86400)
        app.library.expressions = (1...count).map { n in
            var item = PracticeExpression(
                conversationID: chatID, meaning: "meaning \(n)", english: "Sentence \(n).", language: .english)
            item.review = ReviewState(
                due: yesterday.addingTimeInterval(Double(n)), enrolled: yesterday.addingTimeInterval(-86400))
            return item
        }
        XCTAssertTrue(app.save())
        return app
    }
    @MainActor private func reviewed(_ app: AppModel) -> String? { app.help.expression?.english }

    @MainActor func testAReviewShowsEachDueExpressionHiddenThenGradesItByID() async throws {
        let root = makeTemporaryFolder()
        let app = appWithDueExpressions(2, root: root)
        XCTAssertEqual(app.dueExpressionCount, 2)
        app.startReview()
        await waitUntil { !app.busy }
        XCTAssertTrue(app.practice)
        XCTAssertEqual(reviewed(app), "Sentence 1.")
        XCTAssertEqual(app.help.review?.revealed, false)
        app.gradeReview(.good)
        await waitUntil { !app.busy }
        XCTAssertEqual(reviewed(app), "Sentence 1.", "Nothing is graded before it is revealed")
        app.revealReview()
        app.gradeReview(.good)
        await waitUntil { !app.busy }
        XCTAssertEqual(reviewed(app), "Sentence 2.")
        XCTAssertEqual(app.help.review?.revealed, false)
        app.revealReview()
        app.gradeReview(.hard)
        await waitUntil { !app.busy }
        XCTAssertFalse(app.practice, "The last grade ends the review")
        XCTAssertTrue(app.showExpressions)
        XCTAssertEqual(app.dueExpressionCount, 0)
        let saved = try LibraryStore(root: root).load().expressions
        XCTAssertEqual(saved.map { $0.review?.box }, [1, 0])
        XCTAssertEqual(saved.map { $0.review?.grades.map(\.grade) }, [[.good], [.hard]])
    }
    @MainActor func testAgainComesBackOnceMoreInTheSameReview() async {
        let app = appWithDueExpressions(2)
        app.startReview()
        await waitUntil { !app.busy }
        app.revealReview()
        app.gradeReview(.again)
        await waitUntil { !app.busy }
        XCTAssertEqual(reviewed(app), "Sentence 2.")
        app.revealReview()
        app.gradeReview(.good)
        await waitUntil { !app.busy }
        XCTAssertEqual(reviewed(app), "Sentence 1.", "Again brings it back at the end")
        XCTAssertEqual(app.help.review?.queue.count, 3)
        app.revealReview()
        app.gradeReview(.again)
        await waitUntil { !app.busy }
        XCTAssertFalse(app.practice, "Only once: a second Again waits for tomorrow")
        XCTAssertEqual(app.library.expressions[0].review?.box, 0)
        XCTAssertEqual(app.library.expressions[0].review?.grades.map(\.grade), [.again, .again])
    }
    @MainActor func testAReviewThatCannotOpenItsExpressionDoesNotStart() async {
        let root = makeTemporaryFolder()
        let app = appWithDueExpressions(1, root: root)
        // Its conversation is gone, so opening it must first save a new one.
        app.library.expressions[0].conversationID = UUID()
        XCTAssertTrue(app.save())
        XCTAssertEqual(chmod(root.path, 0o500), 0)
        defer { chmod(root.path, 0o700) }
        app.startReview()
        await waitUntil { !app.busy }
        XCTAssertNotNil(app.error)
        XCTAssertFalse(app.practice)
        XCTAssertNil(app.help.review, "No review runs over an expression that is not on screen")
    }
    @MainActor func testAnExpressionThatCannotBeOpenedIsSkippedAndStaysDue() async {
        let root = makeTemporaryFolder()
        let app = appWithDueExpressions(2, root: root)
        app.library.expressions[0].conversationID = UUID()
        XCTAssertTrue(app.save())
        XCTAssertEqual(chmod(root.path, 0o500), 0)
        defer { chmod(root.path, 0o700) }
        app.startReview()
        await waitUntil { !app.busy }
        XCTAssertNotNil(app.error)
        XCTAssertTrue(app.practice)
        XCTAssertEqual(reviewed(app), "Sentence 2.", "The review goes on with the next expression")
        XCTAssertEqual(app.help.review?.current, app.library.expressions[1].id)
        XCTAssertEqual(app.library.expressions[0].review?.grades, [], "The skipped one is not graded and stays due")
    }
    @MainActor func testAReviewThatCannotCloseCannotBeGradedAgain() async {
        let root = makeTemporaryFolder()
        let app = appWithDueExpressions(1, root: root)
        app.startReview()
        await waitUntil { !app.busy }
        app.revealReview()
        XCTAssertEqual(chmod(root.path, 0o500), 0)
        defer { chmod(root.path, 0o700) }
        // Ending runs resume(), which cannot save, so practice stays open; the run must not.
        app.endReview()
        XCTAssertTrue(app.practice)
        XCTAssertNil(app.help.review)
        XCTAssertEqual(chmod(root.path, 0o700), 0)
        app.gradeReview(.good)
        XCTAssertEqual(app.library.expressions[0].review?.grades, [], "Nothing is graded outside a review")
    }
    @MainActor func testResumingKeepsPracticeOpenWhenTheExpressionCannotBeSaved() async {
        let root = makeTemporaryFolder()
        let app = appWithDueExpressions(1, root: root)
        app.openExpression(app.library.expressions[0])
        await waitUntil { !app.busy }
        XCTAssertTrue(app.practice)
        app.editEnglish("Sentence one, edited.")
        XCTAssertEqual(chmod(root.path, 0o500), 0)
        defer { chmod(root.path, 0o700) }
        app.resume()
        XCTAssertTrue(app.practice, "The unsaved edit stays on screen")
        XCTAssertNotNil(app.error)
        XCTAssertNil(app.notice)
        XCTAssertEqual(chmod(root.path, 0o700), 0)
        app.resume()
        XCTAssertFalse(app.practice)
        XCTAssertTrue(app.library.expressions.contains { $0.english == "Sentence one, edited." })
    }
    @MainActor func testAFailedSaveKeepsTheExpressionToGradeAgain() async {
        let root = makeTemporaryFolder()
        let app = appWithDueExpressions(2, root: root)
        app.startReview()
        await waitUntil { !app.busy }
        app.revealReview()
        XCTAssertEqual(chmod(root.path, 0o500), 0)
        defer { chmod(root.path, 0o700) }
        app.gradeReview(.good)
        await waitUntil { !app.busy }
        XCTAssertNotNil(app.error)
        XCTAssertEqual(reviewed(app), "Sentence 1.")
        XCTAssertEqual(app.help.review?.revealed, true)
        XCTAssertEqual(app.library.expressions[0].review?.grades, [], "The unsaved grade is not kept in memory")
        XCTAssertEqual(chmod(root.path, 0o700), 0)
        app.gradeReview(.good)
        await waitUntil { !app.busy }
        XCTAssertEqual(reviewed(app), "Sentence 2.")
        XCTAssertEqual(app.library.expressions[0].review?.box, 1)
    }
    @MainActor func testEndingEarlyKeepsTheGradesGiven() async {
        let app = appWithDueExpressions(3)
        app.startReview()
        await waitUntil { !app.busy }
        app.revealReview()
        app.gradeReview(.good)
        await waitUntil { !app.busy }
        app.endReview()
        XCTAssertFalse(app.practice)
        XCTAssertNil(app.help.review)
        XCTAssertEqual(app.dueExpressionCount, 2)
        XCTAssertEqual(app.notice, String(localized: "Review finished: 1 graded."))
    }
    @MainActor func testAnAttemptRecordedInReviewIsSavedAndKeepsTheGrade() async throws {
        let root = makeTemporaryFolder()
        let app = appWithDueExpressions(1, root: root)
        app.startReview()
        await waitUntil { !app.busy }
        var pcm = Data()
        for i in 0..<12000 {
            var value = Int16(sin(2 * Double.pi * 180 * Double(i) / 24000) * 12000).littleEndian
            withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) }
        }
        let take = root.appendingPathComponent("attempt.wav")
        try PCM.wav(pcm).write(to: take)
        app.media.permission = { true }
        app.media.record = { _ in }
        app.media.stopRecording = { take }
        app.toggleRecord()
        await waitUntil { app.turn.activity == .recording }
        app.finishRecording()
        await waitUntil { !app.busy }
        XCTAssertEqual(app.help.expression?.attempts.map(\.file), ["attempt.wav"])
        app.revealReview()
        app.gradeReview(.good)
        await waitUntil { !app.busy }
        let saved = try XCTUnwrap(try LibraryStore(root: root).load().expressions.first)
        XCTAssertEqual(saved.attempts.map(\.file), ["attempt.wav"])
        XCTAssertEqual(saved.review?.box, 1)
    }
    @MainActor func testOrdinaryPracticeIsNotAReview() async {
        let app = appWithDueExpressions(1)
        app.openExpression(app.library.expressions[0])
        await waitUntil { !app.busy }
        XCTAssertTrue(app.practice)
        XCTAssertNil(app.help.review)
        app.resume()
        XCTAssertEqual(app.dueExpressionCount, 1, "Practising does not grade")
    }
    @MainActor func testNothingDueMeansNoReview() {
        let app = appWithDueExpressions(1)
        app.library.expressions[0].review?.due = Date().addingTimeInterval(86400)
        XCTAssertFalse(app.canStartReview)
        app.startReview()
        XCTAssertFalse(app.practice)
    }
    @MainActor func testANewExpressionIsEnrolledForTomorrow() throws {
        let app = makeApp(root: makeTemporaryFolder())
        app.resume()
        app.startHelp()
        app.editEnglish("Let me think.")
        app.beginPractice()
        XCTAssertTrue(app.saveExpression())
        let review = try XCTUnwrap(app.library.expressions.first?.review)
        XCTAssertEqual(review.box, 0)
        XCTAssertEqual(
            review.due, Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date())))
        XCTAssertEqual(app.dueExpressionCount, 0)
        XCTAssertTrue(app.saveExpression())
        XCTAssertEqual(app.library.expressions.first?.review, review, "Saving again never re-enrols")
    }
}
