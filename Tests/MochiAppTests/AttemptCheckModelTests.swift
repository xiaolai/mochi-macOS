import MochiCore
import MochiKernel
import MochiProviders
import XCTest

@testable import MochiApp

/// The word check of practice attempts (plan W6): when it runs, and that it never costs the attempt.
final class AttemptCheckModelTests: XCTestCase {
    private func tone() -> Data {
        var pcm = Data()
        for i in 0..<12000 {
            var value = Int16(sin(2 * Double.pi * 180 * Double(i) / 24000) * 12000).littleEndian
            withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) }
        }
        return PCM.wav(pcm)
    }
    private let heard = [RecognizedWord(text: "Let", confidence: 0.9), RecognizedWord(text: "me", confidence: 0.9)]

    /// Records one practice attempt of "Let me think." and waits for it to be analysed.
    @MainActor private func recordAttempt(_ app: AppModel) async throws {
        app.startHelp()
        app.editEnglish("Let me think.")
        app.beginPractice()
        let take = app.store.root.appendingPathComponent("attempt.wav")
        try tone().write(to: take)
        app.media.permission = { true }
        app.media.record = { _ in }
        app.media.stopRecording = { take }
        app.toggleRecord()
        await waitUntil { app.turn.activity == .recording }
        app.finishRecording()
        await waitUntil { !app.busy }
    }

    @MainActor func testAnAttemptIsCheckedAgainstTheSentence() async throws {
        let app = makeApp(root: makeTemporaryFolder(), recognition: .hearing(heard))
        var recognized: (URL, ConversationLanguage)?
        app.recognition.recognize = { url, language in
            recognized = (url, language)
            return self.heard
        }
        try await recordAttempt(app)
        XCTAssertEqual(recognized?.0.lastPathComponent, "attempt.wav")
        XCTAssertEqual(recognized?.1, .english)
        XCTAssertEqual(
            app.help.attemptCheck, .checked(AttemptCheck(target: "Let me think.", recognized: heard)))
        XCTAssertNil(app.error)
    }

    @MainActor func testAFailedCheckKeepsTheAttemptAndSaysSo() async throws {
        let root = makeTemporaryFolder()
        let app = makeApp(root: root, recognition: .hearing([]))
        app.recognition.recognize = { _, _ in throw AppFailure("Recognizer broke.") }
        try await recordAttempt(app)
        XCTAssertEqual(app.help.attemptCheck, .failed)
        XCTAssertEqual(app.help.expression?.attempts.map(\.file), ["attempt.wav"])
        XCTAssertFalse(app.help.attemptPitch.isEmpty)
        XCTAssertEqual(try LibraryStore(root: root).load().expressions.first?.attempts.count, 1)
        XCTAssertNil(app.error)
    }

    @MainActor func testUnavailableRecognitionShowsTheReasonAndNeverRecognises() async throws {
        let app = makeApp(root: makeTemporaryFolder())
        try await recordAttempt(app)
        XCTAssertEqual(app.help.attemptCheck, .unavailable(.olderMacOS))
        XCTAssertEqual(app.help.expression?.attempts.count, 1)
    }

    @MainActor func testTheSpeechModelDownloadsOnlyWhenChosenThenChecks() async throws {
        let app = makeApp(root: makeTemporaryFolder(), recognition: .hearing(heard))
        var downloaded = false
        app.recognition.availability = { _ in downloaded ? .ready : .needsDownload }
        app.recognition.download = { _ in downloaded = true }
        try await recordAttempt(app)
        XCTAssertEqual(app.help.attemptCheck, .needsDownload)
        XCTAssertFalse(downloaded)
        app.downloadSpeechModel()
        await waitUntil { !app.busy }
        XCTAssertTrue(downloaded)
        XCTAssertEqual(
            app.help.attemptCheck, .checked(AttemptCheck(target: "Let me think.", recognized: heard)))
    }

    @MainActor func testAFailedDownloadIsReportedAndCanBeRetried() async throws {
        let app = makeApp(root: makeTemporaryFolder(), recognition: .hearing(heard))
        app.recognition.availability = { _ in .needsDownload }
        app.recognition.download = { _ in throw AppFailure("No connection.") }
        try await recordAttempt(app)
        app.downloadSpeechModel()
        await waitUntil { !app.busy }
        XCTAssertNotNil(app.error)
        XCTAssertEqual(app.help.attemptCheck, .needsDownload)
    }

    @MainActor func testReopeningASavedExpressionChecksItsLatestAttempt() async throws {
        let root = makeTemporaryFolder()
        let app = makeApp(root: root, recognition: .hearing(heard))
        var recognized: [String] = []
        app.recognition.recognize = { url, _ in
            recognized.append(url.lastPathComponent)
            return self.heard
        }
        try tone().write(to: root.appendingPathComponent("first.wav"))
        try tone().write(to: root.appendingPathComponent("latest.wav"))
        var item = PracticeExpression(
            conversationID: try XCTUnwrap(app.selectedID), meaning: "", english: "Let me in.", language: .english)
        item.attempts = [Attempt(file: "first.wav"), Attempt(file: "latest.wav")]
        app.library.expressions = [item]
        app.openExpression(item)
        await waitUntil { !app.busy }
        XCTAssertEqual(recognized, ["latest.wav"])
        XCTAssertEqual(app.help.attemptCheck, .checked(AttemptCheck(target: "Let me in.", recognized: heard)))
    }

    @MainActor func testANewSentenceForgetsTheCheck() async throws {
        let app = makeApp(root: makeTemporaryFolder(), recognition: .hearing(heard))
        try await recordAttempt(app)
        XCTAssertNotEqual(app.help.attemptCheck, .none)
        app.editEnglish("Something else.")
        XCTAssertEqual(app.help.attemptCheck, .none)
        XCTAssertTrue(app.help.attemptPitch.isEmpty)
    }
}
