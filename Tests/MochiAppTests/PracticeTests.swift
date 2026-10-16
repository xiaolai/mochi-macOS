import MochiCore
import MochiTestSupport
import PCM16
import XCTest

@testable import MochiApp

final class PracticeTests: XCTestCase {
    @MainActor func testSavedPracticeDoesNotReplaceUnfinishedDraftOrRecording() throws {
        let root = TestScratch.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = makeApp(root: root)
        app.startHelp()
        try PCM.wav(Data(repeating: 0, count: 4800), rate: PCM.sampleRate).write(
            to: root.appendingPathComponent("thought.wav"))
        app.help.meaning = "Unfinished thought"
        app.help.thoughtRecording = "thought.wav"
        app.resume()
        let item = PracticeExpression(
            conversationID: app.selectedID!, meaning: "Saved meaning", english: "Saved English", language: .english)
        app.openExpression(item)
        app.resume()
        app.startHelp()
        XCTAssertEqual(app.help.meaning, "Unfinished thought")
        XCTAssertEqual(app.help.thoughtRecording, "thought.wav")
        XCTAssertTrue(app.library.referencedAudio.contains("thought.wav"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("thought.wav").path))
    }

    @MainActor func testSavedPracticeCannotRecordAndExitCleansTransientAudioAndFlag() async throws {
        let root = TestScratch.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = makeApp(root: root)
        app.openExpression(
            PracticeExpression(
                conversationID: app.selectedID!, meaning: "Meaning", english: "English", language: .english))
        await waitUntil { !app.busy }
        app.editThought()
        app.recordMeaning()
        XCTAssertEqual(app.turn.activity, .idle)
        XCTAssertTrue(app.notice?.contains("new thought") == true)
        try Data([1]).write(to: root.appendingPathComponent("transient.wav"))
        app.help.thoughtRecording = "transient.wav"
        app.discardThoughtRecording()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("transient.wav").path))
        try Data([1]).write(to: root.appendingPathComponent("exit.wav"))
        app.help.thoughtRecording = "exit.wav"
        let next = Conversation()
        app.library.conversations.append(next)
        app.select(next.id)
        XCTAssertFalse(app.help.isSavedPractice)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("exit.wav").path))
    }

    @MainActor func testEditedThoughtIsSavedWithTheExistingExpression() throws {
        let app = makeApp(root: makeTemporaryFolder())
        app.startHelp()
        app.help.meaning = "Old meaning"
        app.editEnglish("Hello there.")
        app.beginPractice()
        app.editThought()
        app.help.meaning = "New meaning"
        XCTAssertTrue(app.saveExpression())
        XCTAssertEqual(app.library.expressions.first?.meaning, "New meaning")
    }

    @MainActor func testReopeningAnExpressionWithoutItsConversationReusesTheReplacement() async throws {
        let app = makeApp(root: makeTemporaryFolder())
        let item = PracticeExpression(
            conversationID: UUID(), meaning: "Meaning", english: "Orphaned sentence", language: .english)
        app.library.expressions = [item]
        app.openExpression(item)
        await waitUntil { !app.busy }
        let replacement = try XCTUnwrap(app.selectedID)
        XCTAssertEqual(app.library.expressions.first?.conversationID, replacement)
        let count = app.library.conversations.count
        app.resume()
        app.openExpression(try XCTUnwrap(app.library.expressions.first))
        await waitUntil { !app.busy }
        XCTAssertEqual(app.library.conversations.count, count)
        XCTAssertEqual(app.selectedID, replacement)
    }

    @MainActor func testMissingReferenceDoesNotHideTheLatestAttemptContour() async throws {
        let root = makeTemporaryFolder()
        let app = makeApp(root: root)
        try tone().write(to: root.appendingPathComponent("attempt.wav"))
        var item = PracticeExpression(
            conversationID: try XCTUnwrap(app.selectedID), meaning: "", english: "Hello.", language: .english)
        item.reference = "missing.wav"
        item.attempts = [Attempt(file: "attempt.wav")]
        app.library.expressions = [item]
        app.openExpression(item)
        await waitUntil { !app.busy }
        XCTAssertTrue(app.help.referencePitch.isEmpty)
        XCTAssertFalse(app.help.attemptPitch.isEmpty)
        XCTAssertNotNil(app.error)
    }

    @MainActor func testReferenceCannotBeImportedWithoutEnglish() throws {
        let root = makeTemporaryFolder()
        let app = makeApp(root: root)
        app.startHelp()
        app.editEnglish("Hello.")
        app.beginPractice()
        app.editEnglish("   ")
        XCTAssertFalse(app.canImportReference)
        app.importReference(from: fixtureURL("reference.mp3"))
        XCTAssertFalse(app.busy)
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix("import-") })
    }

    private func tone(seconds: Double = 0.5) -> Data {
        var pcm = Data()
        for i in 0..<Int(24000 * seconds) {
            var value = Int16(sin(2 * Double.pi * 180 * Double(i) / 24000) * 12000).littleEndian
            withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) }
        }
        // Half a second of 24 kHz audio is far inside the header's range, so writing it cannot fail.
        return try! PCM.wav(pcm, rate: PCM.sampleRate)
    }
}
