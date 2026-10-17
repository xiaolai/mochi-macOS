import MochiCore
import MochiKernel
import MochiProviders
import MochiTestSupport
import XCTest

@testable import MochiApp

final class HelpFlowTests: XCTestCase {
    /// Typing a sentence is written after a pause, like the composer, not on every keystroke; an edit that drops the
    /// saved expression is written at once, and Stop writes whatever typing is still waiting.
    @MainActor func testTypingTheSentenceIsWrittenAfterAPause() throws {
        let root = makeTemporaryFolder()
        let app = makeApp(root: root)
        let id = try XCTUnwrap(app.selectedID)
        func saved() throws -> HelpDraft? {
            try LibraryStore(root: root).load().conversations.first { $0.id == id }?.helpDraft
        }
        app.saveDelay = 60_000_000_000
        app.startHelp()
        XCTAssertEqual(try saved()?.english, "", "Opening Help writes its draft")
        app.editEnglish("Let me")
        app.editEnglish("Let me think")
        XCTAssertTrue(app.hasPendingSave, "Typing waits for a pause")
        XCTAssertEqual(try saved()?.english, "", "Nothing is written on a keystroke itself")
        XCTAssertTrue(app.saveExpression())
        let expression = try XCTUnwrap(app.help.expression?.id)
        XCTAssertEqual(try saved()?.expressionID, expression)
        app.editEnglish("Let me think about it")
        XCTAssertNil(app.help.expression)
        XCTAssertFalse(app.hasPendingSave, "Dropping the saved expression is written at once")
        XCTAssertNil(try saved()?.expressionID)
        XCTAssertEqual(try saved()?.english, "Let me think about it")
        app.editEnglish("Let me think about it more")
        XCTAssertTrue(app.hasPendingSave)
        app.stop()
        XCTAssertFalse(app.hasPendingSave)
        XCTAssertEqual(try saved()?.english, "Let me think about it more", "Stop writes the waiting typing")
    }
    @MainActor func testHelpDraftSeedDismissAndRelaunchPreserveMeaningAndEnglish() throws {
        let root = TestScratch.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = makeApp(root: root)
        app.draft = "An unfinished thought"
        app.startHelp()
        XCTAssertEqual(app.help.meaning, "An unfinished thought")
        app.help.meaning = "The original thought"
        app.editEnglish("My English expression")
        XCTAssertEqual(app.help.stage, .english)
        app.beginPractice()
        XCTAssertEqual(app.help.stage, .practice)
        app.stop()
        app.startHelp()
        XCTAssertEqual(app.help.meaning, "The original thought")
        XCTAssertEqual(app.help.english, "My English expression")
        app.stop()
        let reopened = makeApp(root: root)
        reopened.startHelp()
        XCTAssertEqual(reopened.help.meaning, "The original thought")
        XCTAssertEqual(reopened.help.english, "My English expression")
        XCTAssertEqual(reopened.help.stage, .english)
    }
    @MainActor func testHelpThoughtRecordingSurvivesRelaunchWithoutUpload() throws {
        let root = TestScratch.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = makeApp(root: root)
        app.startHelp()
        app.help.thoughtRecording = "thought.wav"
        app.help.meaning = "A thought to review"
        app.resume()
        let restored = makeApp(root: root)
        restored.startHelp()
        XCTAssertEqual(restored.help.thoughtRecording, "thought.wav")
        XCTAssertEqual(restored.help.stage, .thought)
        XCTAssertTrue(restored.library.referencedAudio.contains("thought.wav"))
        XCTAssertFalse(restored.busy)
    }
    @MainActor func testClarificationAndFailureKeepExistingEnglishAndThought() async throws {
        let app = makeApp(demo: true)
        app.startHelp()
        app.help.meaning = "An ambiguous thought"
        app.editEnglish("Existing wording")
        app.speech.textReply = { _, _ in #"{"kind":"clarification","text":"Which project do you mean?"}"# }
        app.translate()
        await waitUntil { !app.busy }
        XCTAssertEqual(app.help.clarification, "Which project do you mean?")
        XCTAssertEqual(app.help.stage, .thought)
        XCTAssertEqual(app.help.english, "Existing wording")
        app.speech.textReply = { _, _ in throw AppFailure("A temporary connection failure") }
        app.translate()
        await waitUntil { !app.busy }
        XCTAssertEqual(app.help.meaning, "An ambiguous thought")
        XCTAssertEqual(app.help.english, "Existing wording")
        XCTAssertNil(app.help.progress)
        XCTAssertNotNil(app.error)
    }
    @MainActor func testHelpAsksCodexFirstWithTheResolvedModelAndSkipsTheVoiceModel() async throws {
        let app = makeApp(demo: true)
        app.codex = CodexStatus(models: [
            CodexModel(slug: "big", name: "Big", priority: 1, efforts: ["low", "high"], defaultEffort: nil),
            CodexModel(slug: "small", name: "Small", priority: 9, efforts: ["low"], defaultEffort: nil),
        ])
        var asked: [String] = []
        app.speech.codexHelpReply = { _, model, effort in
            asked.append("\(model.slug):\(effort ?? "-")")
            return #"{"kind":"expression","text":"From Codex."}"#
        }
        app.speech.textReply = { _, _ in
            XCTFail("The voice model is the fallback only")
            return ""
        }
        app.startHelp()
        app.help.meaning = "我的想法"
        app.translate()
        await waitUntil { !app.busy }
        XCTAssertEqual(asked, ["small:low"])
        XCTAssertEqual(app.help.english, "From Codex.")
        app.settings.textModel = "big"
        app.settings.textEffort = "high"
        app.tryAnotherWording()
        await waitUntil { !app.busy }
        XCTAssertEqual(asked, ["small:low", "big:high"])
        // An effort the model does not support is ignored.
        app.settings.textEffort = "ultra"
        app.tryAnotherWording()
        await waitUntil { !app.busy }
        XCTAssertEqual(asked.last, "big:low")
    }

    @MainActor func testHelpFallsBackToTheVoiceModelWhenCodexFails() async throws {
        let app = makeApp(demo: true)
        app.codex = CodexStatus(models: [
            CodexModel(slug: "small", name: "Small", priority: 9, efforts: ["low"], defaultEffort: nil)
        ])
        app.speech.codexHelpReply = { _, _, _ in throw AppFailure("Codex refused the model.") }
        app.speech.textReply = { _, _ in #"{"kind":"expression","text":"From the voice model."}"# }
        app.startHelp()
        app.help.meaning = "我的想法"
        app.translate()
        await waitUntil { !app.busy }
        XCTAssertEqual(app.help.english, "From the voice model.")
        XCTAssertNil(app.error)
    }

    @MainActor func testHelpSkipsCodexWhenSignedOutOrNoModelsAreListed() async throws {
        let app = makeApp(demo: true)
        app.speech.codexHelpReply = { _, _, _ in
            XCTFail("Codex is not usable")
            return ""
        }
        app.speech.textReply = { _, _ in #"{"kind":"expression","text":"Voice."}"# }
        let small = CodexModel(slug: "small", name: "Small", priority: 9, efforts: [], defaultEffort: nil)
        for status in [CodexStatus(signInProblem: "Signed out", models: [small]), CodexStatus(models: [])] {
            app.codex = status
            app.startHelp()
            app.help.meaning = "我的想法"
            app.translate()
            await waitUntil { !app.busy }
            XCTAssertEqual(app.help.english, "Voice.")
        }
    }

    @MainActor func testRegenerationIncludesPriorWordingButPreservesOriginalMeaning() async throws {
        let app = makeApp(demo: true)
        app.startHelp()
        app.help.meaning = "My actual meaning"
        app.editEnglish("Old wording")
        app.speech.textReply = { _, request in
            XCTAssertTrue(request.help)
            XCTAssertTrue(request.text.contains("Old wording"))
            return #"{"kind":"expression","text":"New wording. Another sentence."}"#
        }
        app.tryAnotherWording()
        await waitUntil { !app.busy }
        XCTAssertEqual(app.help.meaning, "My actual meaning")
        XCTAssertEqual(app.help.english, "New wording. Another sentence.")
        XCTAssertEqual(app.help.stage, .english)
        XCTAssertEqual(app.help.expression?.meaning, "My actual meaning")
    }
    @MainActor func testRecordedThoughtUsesSelectedRealtimeConnectionWithoutTranslation() async throws {
        let app = makeApp(demo: true)
        app.startHelp()
        app.help.meaning = "Previous thought"
        app.editEnglish("Previous English")
        app.editThought()
        app.help.thoughtRecording = "thought.wav"
        app.speech.transcribe = { _, model, _ in
            XCTAssertEqual(model, app.settings.modelName)
            return TranscriptResult(text: "Recognized thought")
        }
        app.transcribeThought()
        await waitUntil { !app.busy }
        XCTAssertEqual(app.help.meaning, "Previous thought")
        XCTAssertEqual(app.help.recognizedThought, "Recognized thought")
        XCTAssertEqual(app.help.english, "Previous English")
        XCTAssertEqual(app.help.stage, .thought)
        XCTAssertFalse(app.busy)
    }
    func testQuietInputWarningDoesNotTreatValidFormatAsGoodSignal() {
        let quiet = RecordingSignal(samples: [Float](repeating: 0.0001, count: 24000))
        let clear = RecordingSignal(samples: (0..<24000).map { sin(Float($0) * 0.1) * 0.2 })
        XCTAssertTrue(quiet.isQuiet)
        XCTAssertFalse(clear.isQuiet)
    }
}

extension HelpFlowTests {
    @MainActor func testTranscribedThoughtRequiresExplicitAddOrReplaceAndPersistsReview() async throws {
        let root = TestScratch.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = makeApp(root: root)
        app.startHelp()
        app.help.meaning = "Typed thought"
        app.editEnglish("Existing English")
        app.editThought()
        app.help.thoughtRecording = "thought.wav"
        app.speech.transcribe = { _, _, _ in TranscriptResult(text: "Recognized thought") }
        app.transcribeThought()
        await waitUntil { !app.busy }
        XCTAssertEqual(app.help.meaning, "Typed thought")
        XCTAssertEqual(app.help.recognizedThought, "Recognized thought")
        app.stop()
        let restored = makeApp(root: root)
        restored.startHelp()
        XCTAssertEqual(restored.help.recognizedThought, "Recognized thought")
        XCTAssertEqual(restored.help.stage, .thought)
        XCTAssertEqual(restored.help.english, "Existing English")
        restored.useRecognizedThought(replace: false)
        XCTAssertEqual(restored.help.meaning, "Typed thought\nRecognized thought")
        XCTAssertNil(restored.help.recognizedThought)
        restored.help.recognizedThought = "Replacement"
        restored.useRecognizedThought(replace: true)
        XCTAssertEqual(restored.help.meaning, "Replacement")
    }

    @MainActor func testRecordingReplacementDiscardAndCancelCleanUpButKeepSharedFile() throws {
        let root = TestScratch.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = makeApp(root: root)
        app.startHelp()
        for name in ["old.wav", "new.wav", "shared.wav", "canceled.wav"] {
            try Data([1]).write(to: root.appendingPathComponent(name))
        }
        app.help.thoughtRecording = "old.wav"
        // A recording the earlier copy still names waits for the launch sweep; any other is removed at once.
        func removedUnlessEarlierCopyNames(_ name: String, line: UInt = #line) {
            XCTAssertFalse(app.library.referencedAudio.contains(name), line: line)
            XCTAssertEqual(
                FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path),
                app.store.previousReferencedAudio().contains(name), line: line)
        }
        app.help.thoughtRecording = "new.wav"
        removedUnlessEarlierCopyNames("old.wav")
        app.discardThoughtRecording()
        removedUnlessEarlierCopyNames("new.wav")
        app.append(Message(role: "user", text: "Shared", audio: "shared.wav"), to: app.selectedID!)
        app.help.thoughtRecording = "shared.wav"
        app.discardThoughtRecording()
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("shared.wav").path))
        app.media.stopRecording = { root.appendingPathComponent("canceled.wav") }
        app.cancelRecording()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("canceled.wav").path))
    }

    @MainActor func testCompletedHelpSeedsNextComposerAndDeletesOnlyUnreferencedAudio() throws {
        let root = TestScratch.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = makeApp(root: root)
        app.startHelp()
        try Data([1]).write(to: root.appendingPathComponent("thought.wav"))
        app.help.meaning = "Finished thought"
        app.help.thoughtRecording = "thought.wav"
        app.editEnglish("Finished English")
        app.resume()
        XCTAssertNil(app.conversation?.helpDraft)
        XCTAssertFalse(app.library.referencedAudio.contains("thought.wav"))
        // A recording the earlier copy still names waits for the launch sweep; any other is removed at once.
        XCTAssertEqual(
            FileManager.default.fileExists(atPath: root.appendingPathComponent("thought.wav").path),
            app.store.previousReferencedAudio().contains("thought.wav"))
        app.draft = "Next thought"
        app.startHelp()
        XCTAssertEqual(app.help.meaning, "Next thought")
        XCTAssertEqual(app.help.english, "")
        XCTAssertEqual(app.help.stage, .thought)
        XCTAssertEqual(app.library.expressions.first?.english, "Finished English")
    }
}
