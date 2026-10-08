import XCTest
import MochiCore
@testable import MochiApp
final class HelpFlowTests: XCTestCase {
    @MainActor private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds:1_000_000) }
        XCTAssertTrue(condition(),file:file,line:line)
    }
    @MainActor func testHelpDraftSeedDismissAndRelaunchPreserveMeaningAndEnglish() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let app = AppModel(libraryRoot:root)
        app.draft = "An unfinished thought"; app.startHelp()
        XCTAssertEqual(app.meaning,"An unfinished thought")
        app.meaning = "The original thought"; app.editEnglish("My English expression")
        XCTAssertEqual(app.helpStage,.english)
        app.beginPractice(); XCTAssertEqual(app.helpStage,.practice)
        app.stop(); app.startHelp()
        XCTAssertEqual(app.meaning,"The original thought")
        XCTAssertEqual(app.english,"My English expression")
        app.stop()
        let reopened = AppModel(libraryRoot:root); reopened.startHelp()
        XCTAssertEqual(reopened.meaning,"The original thought")
        XCTAssertEqual(reopened.english,"My English expression")
        XCTAssertEqual(reopened.helpStage,.english)
    }
    @MainActor func testTranscriptRecoveryDoesNotDuplicateMessagesOrReplies() async throws {
        let app = AppModel(demo:true)
        app.resume()
        var voice = Message(role:"user",text:"",audio:"saved.wav"); voice.transcriptionState = .failed
        app.append(voice,to:app.selectedID!)
        app.append(Message(role:"assistant",text:"Existing reply"),to:app.selectedID!)
        let count = app.conversation!.messages.count
        app.auth = "codex"
        app.transcribeRecording = { _,connection,model in
            XCTAssertEqual(connection,"codex"); XCTAssertEqual(model,app.modelName)
            return "Recovered thought"
        }
        app.retryTranscription(voice.id)
        try await waitUntil { !app.transcribingMessageIDs.contains(voice.id) }
        XCTAssertEqual(app.conversation!.messages.count,count)
        XCTAssertEqual(app.conversation!.messages.first(where:{$0.id == voice.id})?.text,"Recovered thought")
        XCTAssertEqual(app.conversation!.messages.last?.text,"Existing reply")
    }
    @MainActor func testManualEditOverridesLateRecovery() async throws {
        let app = AppModel(demo:true); app.resume()
        var voice = Message(role:"user",text:"",audio:"saved.wav"); voice.transcriptionState = .failed
        app.append(voice,to:app.selectedID!)
        let gate = TestGate(), started = expectation(description:"Recovery started")
        app.transcribeRecording = { _,_,_ in started.fulfill(); await gate.wait(); return "Late recognition" }
        app.retryTranscription(voice.id)
        let job = try XCTUnwrap(app.transcriptTasks[voice.id]); await fulfillment(of:[started],timeout:2)
        app.editTranscript(voice.id,text:"My correction")
        await gate.release(); await job.value
        XCTAssertEqual(app.conversation!.messages.first(where:{$0.id == voice.id})?.text,"My correction")
        XCTAssertTrue(app.transcribingMessageIDs.isEmpty)
    }
    @MainActor func testDeletionAndStopRejectLateRecoveryAndKeepAudioReference() async throws {
        let app = AppModel(demo:true); app.resume(); app.auth = "api"
        var voice = Message(role:"user",text:"",audio:"saved.wav"); voice.transcriptionState = .failed
        let chatID = app.selectedID!; app.append(voice,to:chatID)
        let gate = TestGate(), started = expectation(description:"Recovery started")
        app.transcribeRecording = { _,_,_ in started.fulfill(); await gate.wait(); return "Late recognition" }
        app.retryTranscription(voice.id)
        let job = try XCTUnwrap(app.transcriptTasks[voice.id]); await fulfillment(of:[started],timeout:2)
        app.deleteChats([chatID]); await gate.release(); await job.value
        let deleted = app.library.conversations.first(where:{$0.id == chatID})!
        XCTAssertTrue(deleted.isDeleted); XCTAssertTrue(deleted.messages.first(where:{$0.id == voice.id})!.text.isEmpty)
        XCTAssertTrue(app.transcribingMessageIDs.isEmpty)
        XCTAssertTrue(app.library.referencedAudio.contains("saved.wav"))
    }
    @MainActor func testHelpThoughtRecordingSurvivesRelaunchWithoutUpload() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let app = AppModel(libraryRoot:root); app.startHelp()
        app.thoughtRecording = "thought.wav"; app.meaning = "A thought to review"; app.resume()
        let restored = AppModel(libraryRoot:root); restored.startHelp()
        XCTAssertEqual(restored.thoughtRecording,"thought.wav")
        XCTAssertEqual(restored.helpStage,.thought)
        XCTAssertTrue(restored.library.referencedAudio.contains("thought.wav"))
        XCTAssertFalse(restored.busy)
    }
    @MainActor func testClarificationAndFailureKeepExistingEnglishAndThought() async throws {
        let app = AppModel(demo:true); app.startHelp(); app.meaning = "An ambiguous thought"; app.editEnglish("Existing wording")
        app.findEnglishSuggestion = { _ in #"{"kind":"clarification","text":"Which project do you mean?"}"# }
        app.translate()
        try await waitUntil { !app.busy }
        XCTAssertEqual(app.helpClarification,"Which project do you mean?")
        XCTAssertEqual(app.helpStage,.thought)
        XCTAssertEqual(app.english,"Existing wording")
        app.findEnglishSuggestion = { _ in throw AppFailure("A temporary connection failure") }
        app.translate()
        try await waitUntil { !app.busy }
        XCTAssertEqual(app.meaning,"An ambiguous thought"); XCTAssertEqual(app.english,"Existing wording")
        XCTAssertNil(app.helpProgress); XCTAssertNotNil(app.error)
    }
    @MainActor func testRegenerationIncludesPriorWordingButPreservesOriginalMeaning() async throws {
        let app = AppModel(demo:true); app.startHelp(); app.meaning = "My actual meaning"; app.editEnglish("Old wording")
        app.findEnglishSuggestion = { request in
            XCTAssertTrue(request.help); XCTAssertTrue(request.text.contains("Old wording"))
            return #"{"kind":"expression","text":"New wording. Another sentence."}"#
        }
        app.tryAnotherWording()
        try await waitUntil { !app.busy }
        XCTAssertEqual(app.meaning,"My actual meaning")
        XCTAssertEqual(app.english,"New wording. Another sentence.")
        XCTAssertEqual(app.helpStage,.english)
        XCTAssertEqual(app.expression?.meaning,"My actual meaning")
    }
    @MainActor func testRecordedThoughtUsesSelectedRealtimeConnectionWithoutTranslation() async throws {
        let app = AppModel(demo:true); app.startHelp(); app.auth = "codex"
        app.meaning = "Previous thought"; app.editEnglish("Previous English"); app.editThought()
        app.thoughtRecording = "thought.wav"
        app.transcribeRecording = { _,connection,model in
            XCTAssertEqual(connection,"codex"); XCTAssertEqual(model,app.modelName)
            return "Recognized thought"
        }
        app.transcribeThought()
        try await waitUntil { !app.busy }
        XCTAssertEqual(app.meaning,"Previous thought")
        XCTAssertEqual(app.recognizedThought,"Recognized thought")
        XCTAssertEqual(app.english,"Previous English")
        XCTAssertEqual(app.helpStage,.thought)
        XCTAssertFalse(app.busy)
    }
    func testQuietInputWarningDoesNotTreatValidFormatAsGoodSignal() {
        let quiet = RecordingSignal(samples:[Float](repeating:0.0001,count:24000))
        let clear = RecordingSignal(samples:(0..<24000).map { sin(Float($0)*0.1)*0.2 })
        XCTAssertTrue(quiet.isQuiet)
        XCTAssertFalse(clear.isQuiet)
    }
}
