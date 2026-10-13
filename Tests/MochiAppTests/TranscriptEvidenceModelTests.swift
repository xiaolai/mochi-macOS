import MochiCore
import MochiKernel
import XCTest

@testable import MochiApp
@testable import MochiProviders

/// Library v5 in use (plan W4): a voice message keeps how it was transcribed, its transcript keeps its evidence only
/// while unedited, and practice never overwrites review state.
final class TranscriptEvidenceModelTests: XCTestCase {
    private func evidence(_ text: String) -> TranscriptEvidence {
        TranscriptEvidence(text: text, raw: text, tokens: [(Array(text.utf8), -0.3)])!
    }
    private var pcm: Data { Data(repeating: 0, count: 4800) }

    /// Sends a voice message whose turn transcribes it as `heard`, with evidence.
    @MainActor private func sendVoice(_ app: AppModel, heard: String) async throws -> UUID {
        var model: String?
        app.speech.conversationReply = { _, request, callbacks in
            model = request.transcriptionModel
            var reply = RealtimeAccumulator()
            reply.inputTranscript = heard
            reply.inputEvidence = self.evidence(heard)
            reply.transcriptionState = .completed
            callbacks.transcription(reply)
            reply.text = "Nice."
            reply.done = true
            try callbacks.response(reply)
        }
        app.requestReply(history: [], text: "", pcm: pcm, audioFile: "voice.wav", conversationID: app.selectedID!)
        await waitUntil { !app.busy }
        XCTAssertEqual(model, RealtimeService.transcriptionModel)
        return try XCTUnwrap(app.conversation?.messages.first { $0.audio == "voice.wav" }?.id)
    }
    @MainActor private func message(_ app: AppModel, _ id: UUID) -> Message? {
        app.conversation?.messages.first { $0.id == id }
    }

    @MainActor func testAVoiceTurnKeepsItsModelAndItsTranscriptsEvidence() async throws {
        let root = makeTemporaryFolder()
        let app = makeApp(root: root)
        app.resume()
        app.newChat()
        let id = try await sendVoice(app, heard: "I go home.")
        let saved = try XCTUnwrap(message(app, id))
        XCTAssertEqual(saved.recording, RecordingMetadata(model: RealtimeService.transcriptionModel))
        XCTAssertEqual(saved.transcriptEvidence, evidence("I go home."))
        let reopened = try LibraryStore(root: root).load().conversations.flatMap(\.messages).first { $0.id == id }
        XCTAssertEqual(reopened?.transcriptEvidence, evidence("I go home."))
    }
    @MainActor func testEditingATranscriptDropsItsEvidence() async throws {
        let app = makeApp(root: makeTemporaryFolder())
        app.resume()
        app.newChat()
        let id = try await sendVoice(app, heard: "I go home.")
        XCTAssertTrue(app.editTranscript(id, text: "I went home."))
        XCTAssertEqual(message(app, id)?.text, "I went home.")
        XCTAssertNil(message(app, id)?.transcriptEvidence)
        XCTAssertNotNil(message(app, id)?.recording, "How it was recorded never changes")
    }
    @MainActor func testARetryReplacesTextAndEvidenceTogetherWithTheRecordingsModel() async throws {
        let app = makeApp(root: makeTemporaryFolder())
        app.resume()
        app.newChat()
        let id = try await sendVoice(app, heard: "I go home.")
        let chat = try XCTUnwrap(app.selectedID)
        let index = try XCTUnwrap(app.library.conversations.firstIndex { $0.id == chat })
        let at = try XCTUnwrap(app.library.conversations[index].messages.firstIndex { $0.id == id })
        app.library.conversations[index].messages[at].recording = RecordingMetadata(model: "recorded-model")
        var used: String?
        app.speech.transcribe = { _, _, model in
            used = model
            return TranscriptResult(text: " I go to home. ", evidence: self.evidence("I go to home."))
        }
        app.retryTranscription(id)
        await waitUntil { !app.transcribingMessageIDs.contains(id) }
        XCTAssertEqual(used, "recorded-model")
        XCTAssertEqual(message(app, id)?.text, "I go to home.")
        XCTAssertEqual(message(app, id)?.transcriptEvidence, evidence("I go to home."))
    }
    @MainActor func testAFailedRetryLeavesTextAndEvidenceAsTheyWere() async throws {
        let app = makeApp(root: makeTemporaryFolder())
        app.resume()
        app.newChat()
        let id = try await sendVoice(app, heard: "I go home.")
        app.speech.transcribe = { _, _, _ in throw AppFailure("Offline.") }
        app.retryTranscription(id)
        await waitUntil { !app.transcribingMessageIDs.contains(id) }
        XCTAssertEqual(message(app, id)?.text, "I go home.")
        XCTAssertEqual(message(app, id)?.transcriptEvidence, evidence("I go home."))
        XCTAssertEqual(message(app, id)?.transcriptionState, .failed)
    }
    @MainActor func testEvidenceForOtherTextIsNeverStored() async throws {
        let app = makeApp(root: makeTemporaryFolder())
        app.resume()
        app.newChat()
        let id = try await sendVoice(app, heard: "I go home.")
        app.speech.transcribe = { _, _, _ in
            TranscriptResult(text: "Something else.", evidence: self.evidence("I go home."))
        }
        app.retryTranscription(id)
        await waitUntil { !app.transcribingMessageIDs.contains(id) }
        XCTAssertEqual(message(app, id)?.text, "Something else.")
        XCTAssertNil(message(app, id)?.transcriptEvidence)
        XCTAssertNil(app.error, "The save went through")
    }
    @MainActor func testRetryingTheReplyToAnUntranscribedVoiceMessageUsesItsRecordingsModel() async throws {
        let app = makeApp(root: makeTemporaryFolder())
        app.resume()
        app.newChat()
        let wav = app.store.root.appendingPathComponent("voice.wav")
        try PCM.wav(Data(repeating: 0, count: 4800)).write(to: wav)
        var voice = Message(role: "user", text: "", audio: "voice.wav")
        voice.recording = RecordingMetadata(model: "recorded-model")
        voice.transcriptionState = .failed
        app.append(voice, to: app.selectedID!)
        var model: String?
        app.speech.conversationReply = { _, request, callbacks in
            model = request.transcriptionModel
            var reply = RealtimeAccumulator()
            reply.text = "Sorry?"
            reply.done = true
            try callbacks.response(reply)
        }
        XCTAssertTrue(app.canRetry)
        app.retryReply()
        await waitUntil { !app.busy }
        XCTAssertEqual(model, "recorded-model")
    }
    @MainActor func testEditThenChangeLanguageThenRetryThenReopenKeepsEverythingConsistent() async throws {
        let root = makeTemporaryFolder()
        let app = makeApp(root: root)
        app.resume()
        app.newChat()
        let id = try await sendVoice(app, heard: "I go home.")
        XCTAssertTrue(app.editTranscript(id, text: "I went home."))
        let chat = try XCTUnwrap(app.selectedID)
        let index = try XCTUnwrap(app.library.conversations.firstIndex { $0.id == chat })
        app.library.conversations[index].preferences.language = .french
        XCTAssertTrue(app.save())
        var used: String?
        app.speech.transcribe = { _, _, model in
            used = model
            return TranscriptResult(text: "I go home.", evidence: self.evidence("I go home."))
        }
        app.retryTranscription(id)
        await waitUntil { !app.transcribingMessageIDs.contains(id) }
        XCTAssertEqual(used, RealtimeService.transcriptionModel, "The recording's own model, whatever the language now")
        let reopened = try XCTUnwrap(
            try LibraryStore(root: root).load().conversations.flatMap(\.messages).first { $0.id == id })
        XCTAssertEqual(reopened.text, "I go home.")
        XCTAssertEqual(reopened.transcriptEvidence, evidence("I go home."))
        XCTAssertEqual(reopened.recording, RecordingMetadata(model: RealtimeService.transcriptionModel))
    }
    @MainActor func testPractisingAnExpressionNeverOverwritesItsReviewState() throws {
        let app = makeApp(root: makeTemporaryFolder())
        app.resume()
        let chatID = try XCTUnwrap(app.selectedID)
        let item = PracticeExpression(conversationID: chatID, meaning: "m", english: "Hello.", language: .english)
        app.library.expressions = [item]
        app.openExpression(item)
        let now = Date()
        let review = ReviewState(box: 3, due: now.addingTimeInterval(86400 * 8), enrolled: now)
        app.library.expressions[0].review = review
        XCTAssertNil(app.help.expression?.review, "The practice copy is older than the stored review")
        XCTAssertTrue(app.saveExpression())
        XCTAssertEqual(app.library.expressions[0].review, review)
        XCTAssertEqual(app.help.expression?.review, review)
    }
}
