import XCTest
import MochiCore
@testable import MochiApp

final class HelpAuditTests: XCTestCase {
    @MainActor func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds:1_000_000) }
        XCTAssertTrue(condition(),file:file,line:line)
    }
    @MainActor func testSavedPracticeDoesNotReplaceUnfinishedDraftOrRecording() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let app = AppModel(libraryRoot:root); app.startHelp()
        try PCM.wav(Data(repeating:0,count:4800)).write(to:root.appendingPathComponent("thought.wav"))
        app.meaning = "Unfinished thought"; app.thoughtRecording = "thought.wav"; app.resume()
        let item = PracticeExpression(conversationID:app.selectedID!,meaning:"Saved meaning",english:"Saved English")
        app.openExpression(item); app.resume(); app.startHelp()
        XCTAssertEqual(app.meaning,"Unfinished thought"); XCTAssertEqual(app.thoughtRecording,"thought.wav")
        XCTAssertTrue(app.library.referencedAudio.contains("thought.wav"))
        XCTAssertTrue(FileManager.default.fileExists(atPath:root.appendingPathComponent("thought.wav").path))
    }
    @MainActor func testCompletedHelpSeedsNextComposerAndDeletesOnlyUnreferencedAudio() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let app = AppModel(libraryRoot:root); app.startHelp()
        try Data([1]).write(to:root.appendingPathComponent("thought.wav"))
        app.meaning = "Finished thought"; app.thoughtRecording = "thought.wav"; app.editEnglish("Finished English"); app.resume()
        XCTAssertNil(app.conversation?.helpDraft)
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("thought.wav").path))
        app.draft = "Next thought"; app.startHelp()
        XCTAssertEqual(app.meaning,"Next thought"); XCTAssertEqual(app.english,""); XCTAssertEqual(app.helpStage,.thought)
        XCTAssertEqual(app.library.expressions.first?.english,"Finished English")
    }
    @MainActor func testRecordingReplacementDiscardAndCancelCleanUpButKeepSharedFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let app = AppModel(libraryRoot:root); app.startHelp()
        for name in ["old.wav","new.wav","shared.wav","canceled.wav"] { try Data([1]).write(to:root.appendingPathComponent(name)) }
        app.thoughtRecording = "old.wav"; app.thoughtRecording = "new.wav"
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("old.wav").path))
        app.discardThoughtRecording()
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("new.wav").path))
        app.append(Message(role:"user",text:"Shared",audio:"shared.wav"),to:app.selectedID!)
        app.thoughtRecording = "shared.wav"; app.discardThoughtRecording()
        XCTAssertTrue(FileManager.default.fileExists(atPath:root.appendingPathComponent("shared.wav").path))
        app.endRecording = { root.appendingPathComponent("canceled.wav") }; app.cancelRecording()
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("canceled.wav").path))
    }
    @MainActor func testTranscribedThoughtRequiresExplicitAddOrReplaceAndPersistsReview() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let app = AppModel(libraryRoot:root); app.startHelp(); app.meaning = "Typed thought"; app.editEnglish("Existing English"); app.editThought(); app.thoughtRecording = "thought.wav"
        app.transcribeRecording = { _,_,_ in "Recognized thought" }
        app.transcribeThought(); try await waitUntil { !app.busy }
        XCTAssertEqual(app.meaning,"Typed thought"); XCTAssertEqual(app.recognizedThought,"Recognized thought")
        app.stop()
        let restored = AppModel(libraryRoot:root); restored.startHelp()
        XCTAssertEqual(restored.recognizedThought,"Recognized thought")
        XCTAssertEqual(restored.helpStage,.thought); XCTAssertEqual(restored.english,"Existing English")
        restored.useRecognizedThought(replace:false)
        XCTAssertEqual(restored.meaning,"Typed thought\nRecognized thought"); XCTAssertNil(restored.recognizedThought)
        restored.recognizedThought = "Replacement"; restored.useRecognizedThought(replace:true)
        XCTAssertEqual(restored.meaning,"Replacement")
    }
    @MainActor func testRetryReplyUsesCorrectedTextAndDoesNotRearmTranscription() async throws {
        let app = AppModel(demo:true); app.resume(); app.newChat()
        var voice = Message(role:"user",text:"Old recognition",audio:"does-not-need-reading.wav"); voice.transcriptionState = .failed
        app.append(voice,to:app.selectedID!); app.editTranscript(voice.id,text:"My correction")
        app.conversationReply = { request,callbacks in
            XCTAssertNil(request.pcm); XCTAssertEqual(request.text,"My correction"); XCTAssertTrue(request.spoken)
            var reply = RealtimeAccumulator(); reply.text = "New reply"; reply.done = true
            try callbacks.response(reply)
            reply.inputTranscript = "Wrong late recognition"; reply.transcriptionState = .completed
            callbacks.transcription(reply)
        }
        app.retryReply(); try await waitUntil { !app.busy }
        XCTAssertEqual(app.conversation?.messages.first?.text,"My correction")
        XCTAssertEqual(app.conversation?.messages.count,2); XCTAssertTrue(app.transcribingMessageIDs.isEmpty)
    }
    @MainActor func testLateTranscriptDuringPlaybackAndStopRejectsFurtherWrites() async throws {
        let app = AppModel(demo:true); app.resume(); app.newChat()
        let delivered = expectation(description:"Reply delivered"), finished = expectation(description:"Late callback sent")
        app.playReply = { _ in _ = app.turn.begin(.playing) }
        app.conversationReply = { _,callbacks in
            var reply = RealtimeAccumulator(); reply.text = "Reply"; reply.audio = Data([0,0]); reply.done = true
            try callbacks.response(reply); delivered.fulfill()
            try? await Task.sleep(nanoseconds:30_000_000)
            reply.inputTranscript = "Late speech"; reply.transcriptionState = .completed; callbacks.transcription(reply); finished.fulfill()
        }
        app.requestReply(history:[],text:"",pcm:Data(repeating:0,count:4800),audioFile:"saved.wav",conversationID:app.selectedID!)
        await fulfillment(of:[delivered],timeout:2)
        XCTAssertEqual(app.turn.activity,.playing)
        app.stop()
        await fulfillment(of:[finished],timeout:2)
        XCTAssertEqual(app.conversation?.messages.first?.text,"")
        XCTAssertEqual(app.conversation?.messages.first?.transcriptionState,.interrupted)
        XCTAssertEqual(app.conversation?.messages.count,2)
    }
    @MainActor func testLateTranscriptCompletesWhileReplyIsPlaying() async throws {
        let app = AppModel(demo:true); app.resume(); app.newChat()
        let done = expectation(description:"Late transcript delivered")
        app.playReply = { _ in _ = app.turn.begin(.playing) }
        app.conversationReply = { _,callbacks in
            var reply = RealtimeAccumulator(); reply.text = "Reply"; reply.audio = Data([0,0]); reply.done = true
            try callbacks.response(reply)
            XCTAssertEqual(app.turn.activity,.playing)
            reply.inputTranscript = "Late speech"; reply.transcriptionState = .completed; callbacks.transcription(reply)
            done.fulfill()
        }
        app.requestReply(history:[],text:"",pcm:Data(repeating:0,count:4800),audioFile:"saved.wav",conversationID:app.selectedID!)
        await fulfillment(of:[done],timeout:2)
        XCTAssertEqual(app.conversation?.messages.first?.text,"Late speech")
        XCTAssertEqual(app.conversation?.messages.first?.transcriptionState,.completed)
        XCTAssertEqual(app.conversation?.messages.count,2); XCTAssertEqual(app.turn.activity,.playing)
        app.stop()
    }
    @MainActor func testRecordingClockUpdatesAndStopsWithoutMicrophone() async throws {
        let app = AppModel(demo:true); var now = Date(); app.recordingNow = { now }
        app.recordingMeter = { -60 }
        let gate = TestGate(), ticked = expectation(description:"Feedback updated"); var ticks = 0
        app.recordingSleep = { _ in
            ticks += 1
            if ticks == 1 { now = now.addingTimeInterval(2) }
            else { ticked.fulfill(); await gate.wait() }
        }
        let token = app.turn.begin(.recording); app.startRecordingFeedback(token:token)
        let clock = try XCTUnwrap(app.recordingClock)
        await fulfillment(of:[ticked],timeout:2)
        XCTAssertEqual(app.recordingSeconds,2); XCTAssertNotNil(app.recordingWarning)
        app.stop(); await gate.release(); await clock.value
        XCTAssertEqual(app.recordingSeconds,2); XCTAssertEqual(app.recordingLevel,-80)
    }
    @MainActor func testHelpCancelLeavesIndependentRecoveryRunning() async throws {
        let app = AppModel(demo:true); app.resume(); app.newChat(); app.startHelp(); app.meaning = "Typed thought"
        var voice = Message(role:"user",text:"",audio:"saved.wav"); voice.transcriptionState = .failed; app.append(voice,to:app.selectedID!)
        let started = expectation(description:"Recovery started"), finished = expectation(description:"Recovery completed")
        app.transcribeRecording = { _,_,_ in started.fulfill(); try await Task.sleep(nanoseconds:30_000_000); finished.fulfill(); return "Recovered" }
        app.findEnglishSuggestion = { _ in try await Task.sleep(nanoseconds:1_000_000_000); return #"{"kind":"expression","text":"English"}"# }
        app.retryTranscription(voice.id); await fulfillment(of:[started],timeout:2)
        app.translate(); app.cancelHelpWork()
        await fulfillment(of:[finished],timeout:2)
        try await waitUntil { app.transcribingMessageIDs.isEmpty }
        XCTAssertEqual(app.conversation?.messages.last?.text,"Recovered")
        XCTAssertEqual(app.meaning,"Typed thought"); XCTAssertNil(app.helpProgress)
    }
    @MainActor func testArchiveRejectsPendingRecoveryAndRetainsAudio() async throws {
        let app = AppModel(demo:true); app.resume(); app.newChat(); let chatID = app.selectedID!
        var voice = Message(role:"user",text:"",audio:"saved.wav"); voice.transcriptionState = .failed; app.append(voice,to:chatID)
        let gate = TestGate(), started = expectation(description:"Recovery started")
        app.transcribeRecording = { _,_,_ in started.fulfill(); await gate.wait(); return "Late speech" }
        app.retryTranscription(voice.id)
        let job = try XCTUnwrap(app.transcriptTasks[voice.id]); await fulfillment(of:[started],timeout:2)
        app.archiveChats([chatID]); await gate.release(); await job.value
        let chat = try XCTUnwrap(app.library.conversations.first { $0.id == chatID })
        XCTAssertTrue(chat.archived); XCTAssertEqual(chat.messages.first?.text,"")
        XCTAssertTrue(app.library.referencedAudio.contains("saved.wav")); XCTAssertTrue(app.transcribingMessageIDs.isEmpty)
    }
    @MainActor func testRetryReplyCannotOverlapPendingTranscriptRecovery() async throws {
        let app = AppModel(demo:true); app.resume(); app.newChat()
        var voice = Message(role:"user",text:"",audio:"saved.wav"); voice.transcriptionState = .failed; app.append(voice,to:app.selectedID!)
        let gate = TestGate(), started = expectation(description:"Recovery started")
        app.transcribeRecording = { _,_,_ in started.fulfill(); await gate.wait(); return "Recovered" }
        app.conversationReply = { _,_ in XCTFail("Reply must wait for recovery") }
        app.retryTranscription(voice.id); let job = try XCTUnwrap(app.transcriptTasks[voice.id])
        await fulfillment(of:[started],timeout:2)
        XCTAssertFalse(app.canRetry); app.retryReply()
        await gate.release(); await job.value
        XCTAssertEqual(app.conversation?.messages.count,1); XCTAssertEqual(app.conversation?.messages.first?.text,"Recovered")
        XCTAssertTrue(app.transcriptTasks.isEmpty)
    }
    @MainActor func testOpeningHelpKeepsLateVoiceTranscriptionRunning() async throws {
        let app = AppModel(demo:true); app.resume(); app.newChat()
        let gate = TestGate(), delivered = expectation(description:"Reply delivered"), finished = expectation(description:"Transcript delivered")
        app.playReply = { _ in _ = app.turn.begin(.playing) }
        app.conversationReply = { _,callbacks in
            var result = RealtimeAccumulator(); result.text = "Reply"; result.done = true; result.audio = Data([0,0])
            try callbacks.response(result); delivered.fulfill(); await gate.wait()
            result.inputTranscript = "Late transcript"; result.transcriptionState = .completed; callbacks.transcription(result); finished.fulfill()
        }
        app.requestReply(history:[],text:"",pcm:Data(repeating:0,count:4800),audioFile:"saved.wav",conversationID:app.selectedID!)
        await fulfillment(of:[delivered],timeout:2)
        app.startHelp(); XCTAssertTrue(app.practice)
        await gate.release(); await fulfillment(of:[finished],timeout:2)
        XCTAssertEqual(app.conversation?.messages.first?.text,"Late transcript")
        XCTAssertEqual(app.conversation?.messages.first?.transcriptionState,.completed)
    }
    @MainActor func testOpeningHelpOrExpressionsBeforeReplyExplicitlyCancelsForegroundRequest() async throws {
        for destination in 0..<3 {
            let app = AppModel(demo:true); app.resume(); app.newChat()
            let gate = TestGate(), started = expectation(description:"Voice request started")
            app.conversationReply = { _,callbacks in
                started.fulfill(); await gate.wait()
                XCTAssertTrue(Task.isCancelled)
                try Task.checkCancellation()
                var result = RealtimeAccumulator(); result.text = "Must not silently detach"; result.done = true
                try callbacks.response(result)
            }
            app.requestReply(history:[],text:"",pcm:Data(repeating:0,count:4800),audioFile:"saved.wav",conversationID:app.selectedID!)
            let voiceID = try XCTUnwrap(app.conversation?.messages.first?.id)
            let job = try XCTUnwrap(app.voiceRequests[voiceID]); await fulfillment(of:[started],timeout:2)
            if destination == 0 { app.startHelp() }
            else if destination == 1 { app.openExpressions() }
            else { app.openExpression(PracticeExpression(conversationID:app.selectedID!,meaning:"Saved meaning",english:"Saved English")) }
            await gate.release(); await job.value
            XCTAssertEqual(app.conversation?.messages.count,1)
            XCTAssertEqual(app.conversation?.messages.first?.transcriptionState,.interrupted)
            XCTAssertTrue(app.voiceRequests.isEmpty)
            XCTAssertTrue(app.notice?.contains("pending reply was cancelled") == true)
        }
    }
    @MainActor func testCancellationReturningNormallyStillSettlesVoiceStateAndExplainsTypedReply() async throws {
        for voice in [true,false] {
            let app = AppModel(demo:true); app.resume(); app.newChat()
            let gate = TestGate(), started = expectation(description:"Request started"), returned = expectation(description:"Canceled stub returned normally")
            app.conversationReply = { _,callbacks in
                started.fulfill(); await gate.wait()
                XCTAssertTrue(Task.isCancelled)
                var result = RealtimeAccumulator(); result.text = "Cancelled result"; result.done = true
                try callbacks.response(result); returned.fulfill()
            }
            if voice { app.requestReply(history:[],text:"",pcm:Data(repeating:0,count:4800),audioFile:"saved.wav",conversationID:app.selectedID!) }
            else { app.draft = "Typed message"; app.send() }
            let id = try XCTUnwrap(app.conversation?.messages.first?.id), job = app.voiceRequests[id]
            await fulfillment(of:[started],timeout:2)
            app.startHelp(); await gate.release(); await fulfillment(of:[returned],timeout:2)
            if let job { await job.value; XCTAssertEqual(app.conversation?.messages.first?.transcriptionState,.interrupted) }
            XCTAssertEqual(app.conversation?.messages.count,1)
            XCTAssertTrue(app.notice?.contains("pending reply was cancelled") == true)
        }
    }
    @MainActor func testSavedPracticeCannotRecordAndExitCleansTransientAudioAndFlag() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let app = AppModel(libraryRoot:root)
        app.openExpression(PracticeExpression(conversationID:app.selectedID!,meaning:"Meaning",english:"English"))
        try await waitUntil { !app.busy }
        app.editThought(); app.recordMeaning()
        XCTAssertEqual(app.turn.activity,.idle); XCTAssertTrue(app.notice?.contains("new thought") == true)
        try Data([1]).write(to:root.appendingPathComponent("transient.wav"))
        app.thoughtRecording = "transient.wav"; app.discardThoughtRecording()
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("transient.wav").path))
        try Data([1]).write(to:root.appendingPathComponent("exit.wav")); app.thoughtRecording = "exit.wav"
        let next = Conversation(); app.library.conversations.append(next); app.select(next.id)
        XCTAssertFalse(app.isSavedPractice)
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("exit.wav").path))
    }
    @MainActor func testRecordingFeedbackUsesElapsedTimeAndSanitizesMeter() {
        let app = AppModel(demo:true)
        app.updateRecordingFeedback(elapsed:3.4,level:-60)
        XCTAssertEqual(app.recordingSeconds,3); XCTAssertNotNil(app.recordingWarning)
        app.updateRecordingFeedback(elapsed:4.1,level:-12)
        XCTAssertEqual(app.recordingSeconds,4); XCTAssertNil(app.recordingWarning)
        app.updateRecordingFeedback(elapsed:0.4,level:.nan)
        XCTAssertEqual(app.recordingLevel,-80); XCTAssertNil(app.recordingWarning)
    }
}
