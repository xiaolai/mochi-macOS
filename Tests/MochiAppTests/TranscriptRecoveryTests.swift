import MochiCore
import MochiProviders
import PCM16
import XCTest
import os

@testable import MochiApp
@testable import MochiProviders

final class TranscriptRecoveryTests: XCTestCase {
    @MainActor func testTranscriptRecoveryDoesNotDuplicateMessagesOrReplies() async throws {
        let app = makeApp(demo: true)
        app.resume()
        var voice = Message(role: "user", text: "", audio: "saved.wav")
        voice.transcriptionState = .failed
        app.append(voice, to: app.selectedID!)
        app.append(Message(role: "assistant", text: "Existing reply"), to: app.selectedID!)
        let count = app.conversation!.messages.count

        app.speech.transcribe = { _, model, _ in
            XCTAssertEqual(model, app.settings.modelName)
            return TranscriptResult(text: "Recovered thought")
        }
        app.retryTranscription(voice.id)
        await waitUntil { !app.transcribingMessageIDs.contains(voice.id) }
        XCTAssertEqual(app.conversation!.messages.count, count)
        XCTAssertEqual(app.conversation!.messages.first(where: { $0.id == voice.id })?.text, "Recovered thought")
        XCTAssertEqual(app.conversation!.messages.last?.text, "Existing reply")
    }

    @MainActor func testManualEditOverridesLateRecovery() async throws {
        let app = makeApp(demo: true)
        app.resume()
        var voice = Message(role: "user", text: "", audio: "saved.wav")
        voice.transcriptionState = .failed
        app.append(voice, to: app.selectedID!)
        let gate = TestGate()
        let started = expectation(description: "Recovery started")
        app.speech.transcribe = { _, _, _ in
            started.fulfill()
            await gate.wait()
            return TranscriptResult(text: "Late recognition")
        }
        app.retryTranscription(voice.id)
        let job = try XCTUnwrap(app.transcripts.task(for: voice.id))
        await fulfillment(of: [started], timeout: 2)
        app.editTranscript(voice.id, text: "My correction")
        await gate.release()
        await job.value
        XCTAssertEqual(app.conversation!.messages.first(where: { $0.id == voice.id })?.text, "My correction")
        XCTAssertTrue(app.transcribingMessageIDs.isEmpty)
    }

    @MainActor func testDeletionAndStopRejectLateRecoveryAndKeepAudioReference() async throws {
        let app = makeApp(demo: true)
        app.resume()
        var voice = Message(role: "user", text: "", audio: "saved.wav")
        voice.transcriptionState = .failed
        let chatID = app.selectedID!
        app.append(voice, to: chatID)
        let gate = TestGate()
        let started = expectation(description: "Recovery started")
        app.speech.transcribe = { _, _, _ in
            started.fulfill()
            await gate.wait()
            return TranscriptResult(text: "Late recognition")
        }
        app.retryTranscription(voice.id)
        let job = try XCTUnwrap(app.transcripts.task(for: voice.id))
        await fulfillment(of: [started], timeout: 2)
        app.deleteChats([chatID])
        await gate.release()
        await job.value
        let deleted = app.library.conversations.first(where: { $0.id == chatID })!
        XCTAssertTrue(deleted.isDeleted)
        XCTAssertTrue(deleted.messages.first(where: { $0.id == voice.id })!.text.isEmpty)
        XCTAssertTrue(app.transcribingMessageIDs.isEmpty)
        XCTAssertTrue(app.library.referencedAudio.contains("saved.wav"))
    }

    /// Retrying the reply to an untranscribed voice message reads its recording in the background, as a new take is
    /// read: the turn is taken at once, and the reply is asked for once the audio is ready.
    @MainActor func testRetryReplyReadsTheRecordingInTheBackground() async throws {
        let app = makeApp(root: makeTemporaryFolder())
        app.resume()
        app.newChat()
        let audio = Data((0..<48000).map { UInt8(truncatingIfNeeded: $0 * 7) })
        try PCM.wav(audio, rate: PCM.sampleRate).write(to: app.store.root.appendingPathComponent("voice.wav"))
        var voice = Message(role: "user", text: "", audio: "voice.wav")
        voice.transcriptionState = .failed
        app.append(voice, to: app.selectedID!)
        var sent: Data?
        app.speech.conversationReply = { _, request, callbacks in
            sent = request.pcm
            var reply = RealtimeAccumulator()
            reply.text = "Sorry?"
            reply.done = true
            try callbacks.response(reply)
        }
        let readOnMain = OSAllocatedUnfairLock<Bool?>(initialState: nil)
        app.readRecording = { url in
            readOnMain.withLock { $0 = Thread.isMainThread }
            return try AudioFile.pcm(url)
        }
        app.retryReply()
        XCTAssertEqual(app.turn.activity, .generating, "The turn is taken while the recording is read")
        XCTAssertFalse(app.canRetry)
        await waitUntil { readOnMain.withLock { $0 } != nil }
        XCTAssertEqual(readOnMain.withLock { $0 }, false, "The recording is decoded off the main thread")
        await waitUntil { !app.busy }
        XCTAssertEqual(sent?.count, audio.count, "The reply is asked for with the decoded recording")
        XCTAssertEqual(app.conversation?.messages.last?.text, "Sorry?")
        XCTAssertNil(app.error)
    }

    /// A recording that cannot be read fails the retry with an explanation, and is kept: it is the saved message's.
    @MainActor func testRetryReplyWithAnUnreadableRecordingKeepsIt() async throws {
        let app = makeApp(root: makeTemporaryFolder())
        app.resume()
        app.newChat()
        let file = app.store.root.appendingPathComponent("broken.wav")
        try Data("not audio".utf8).write(to: file)
        var voice = Message(role: "user", text: "", audio: "broken.wav")
        voice.transcriptionState = .failed
        app.append(voice, to: app.selectedID!)
        app.retryReply()
        await waitUntil { !app.busy }
        XCTAssertEqual(
            app.error, String(localized: "The saved recording could not be read. Record a new message to continue."))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(app.conversation?.messages.count, 1)
        XCTAssertTrue(app.canRetry)
    }

    @MainActor func testRetryReplyUsesCorrectedTextAndDoesNotRearmTranscription() async throws {
        let app = makeApp(demo: true)
        app.resume()
        app.newChat()
        var voice = Message(role: "user", text: "Old recognition", audio: "does-not-need-reading.wav")
        voice.transcriptionState = .failed
        app.append(voice, to: app.selectedID!)
        app.editTranscript(voice.id, text: "My correction")
        app.speech.conversationReply = { _, request, callbacks in
            XCTAssertNil(request.pcm)
            XCTAssertEqual(request.text, "My correction")
            XCTAssertTrue(request.spoken)
            var reply = RealtimeAccumulator()
            reply.text = "New reply"
            reply.done = true
            try callbacks.response(reply)
            reply.inputTranscript = "Wrong late recognition"
            reply.transcriptionState = .completed
            callbacks.transcription(reply)
        }
        app.retryReply()
        await waitUntil { !app.busy }
        XCTAssertEqual(app.conversation?.messages.first?.text, "My correction")
        XCTAssertEqual(app.conversation?.messages.count, 2)
        XCTAssertTrue(app.transcribingMessageIDs.isEmpty)
    }

    @MainActor func testRetryReplyCannotOverlapPendingTranscriptRecovery() async throws {
        let app = makeApp(demo: true)
        app.resume()
        app.newChat()
        var voice = Message(role: "user", text: "", audio: "saved.wav")
        voice.transcriptionState = .failed
        app.append(voice, to: app.selectedID!)
        let gate = TestGate()
        let started = expectation(description: "Recovery started")
        app.speech.transcribe = { _, _, _ in
            started.fulfill()
            await gate.wait()
            return TranscriptResult(text: "Recovered")
        }
        app.speech.conversationReply = { _, _, _ in XCTFail("Reply must wait for recovery") }
        app.retryTranscription(voice.id)
        let job = try XCTUnwrap(app.transcripts.task(for: voice.id))
        await fulfillment(of: [started], timeout: 2)
        XCTAssertFalse(app.canRetry)
        app.retryReply()
        await gate.release()
        await job.value
        XCTAssertEqual(app.conversation?.messages.count, 1)
        XCTAssertEqual(app.conversation?.messages.first?.text, "Recovered")
        XCTAssertTrue(app.transcripts.isIdle)
    }

    /// The reply was already delivered, so Stop has nothing of this message's to cancel: its transcript still arrives.
    /// (It used to be discarded and marked interrupted; the transcript writes by conversation and refuses archived or
    /// deleted ones, so nothing makes it unsafe to let it finish.)
    @MainActor func testLateTranscriptStillArrivesAfterStopDuringPlayback() async throws {
        let app = makeApp(demo: true)
        app.resume()
        app.newChat()
        let delivered = expectation(description: "Reply delivered")
        let finished = expectation(description: "Late callback sent")
        app.playReply = { _ in _ = app.turn.begin(.playing) }
        let gate = TestGate()
        app.speech.conversationReply = { _, _, callbacks in
            var reply = RealtimeAccumulator()
            reply.text = "Reply"
            reply.audio = Data([0, 0])
            reply.done = true
            try callbacks.response(reply)
            delivered.fulfill()
            await gate.wait()
            reply.inputTranscript = "Late speech"
            reply.transcriptionState = .completed
            callbacks.transcription(reply)
            finished.fulfill()
        }
        app.requestReply(
            history: [], text: "", pcm: Data(repeating: 0, count: 4800), audioFile: "saved.wav",
            conversationID: app.selectedID!)
        await fulfillment(of: [delivered], timeout: 2)
        XCTAssertEqual(app.turn.activity, .playing)
        app.stop()
        XCTAssertEqual(app.turn.activity, .idle)
        XCTAssertEqual(app.conversation?.messages.first?.transcriptionState, .pending)
        await gate.release()
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(app.conversation?.messages.first?.text, "Late speech")
        XCTAssertEqual(app.conversation?.messages.first?.transcriptionState, .completed)
        XCTAssertEqual(app.conversation?.messages.count, 2)
        await waitUntil { app.transcripts.isIdle }
    }

    /// A transcription left running in a conversation the learner moved away from ends when that conversation is
    /// archived: its result could no longer be written there.
    @MainActor func testArchivingAConversationEndsItsTranscription() async throws {
        let app = makeApp(demo: true)
        app.resume()
        app.newChat()
        let id = try XCTUnwrap(app.selectedID)
        var voice = Message(role: "user", text: "", audio: "saved.wav")
        voice.transcriptionState = .failed
        app.append(voice, to: id)
        let gate = TestGate()
        let started = expectation(description: "Transcription started")
        app.speech.transcribe = { _, _, _ in
            started.fulfill()
            await gate.wait()
            return TranscriptResult(text: "Too late")
        }
        app.retryTranscription(voice.id)
        let job = try XCTUnwrap(app.transcripts.task(for: voice.id))
        await fulfillment(of: [started], timeout: 2)
        app.newChat()
        XCTAssertTrue(app.transcribingMessageIDs.contains(voice.id), "A change of conversation leaves it running")
        XCTAssertTrue(app.archiveChats([id]))
        XCTAssertTrue(app.transcribingMessageIDs.isEmpty)
        let archived = app.library.conversations.first { $0.id == id }?.messages.first
        XCTAssertEqual(archived?.transcriptionState, .interrupted)
        await gate.release()
        await job.value
        XCTAssertEqual(app.library.conversations.first { $0.id == id }?.messages.first?.text, "")
    }

    /// Switching to another conversation leaves a late transcript to finish in the one it belongs to; quitting
    /// cancels it and records it as interrupted.
    @MainActor func testLateTranscriptFinishesAcrossAConversationSwitchButNotAQuit() async throws {
        let root = makeTemporaryFolder()
        let app = makeApp(root: root)
        for quitting in [false, true] {
            app.newChat()
            let id = try XCTUnwrap(app.selectedID)
            let delivered = expectation(description: "Reply delivered")
            let finished = expectation(description: "Late callback sent")
            app.playReply = { _ in }
            let gate = TestGate()
            app.speech.conversationReply = { _, _, callbacks in
                var reply = RealtimeAccumulator()
                reply.text = "Reply"
                reply.audio = Data([0, 0])
                reply.done = true
                try callbacks.response(reply)
                delivered.fulfill()
                await gate.wait()
                reply.inputTranscript = "Late speech"
                reply.transcriptionState = .completed
                callbacks.transcription(reply)
                finished.fulfill()
            }
            app.requestReply(
                history: [], text: "", pcm: Data(repeating: 0, count: 4800), audioFile: "saved.wav",
                conversationID: id)
            await fulfillment(of: [delivered], timeout: 2)
            if quitting {
                XCTAssertTrue(TrayController.finishWork(app))
            } else {
                app.newChat()
                XCTAssertNotEqual(app.selectedID, id)
            }
            if quitting {
                let voice = app.library.conversations.first { $0.id == id }?.messages.first
                XCTAssertEqual(
                    voice?.transcriptionState, .interrupted, "Quitting records the transcript as interrupted")
            }
            await gate.release()
            await fulfillment(of: [finished], timeout: 2)
            await waitUntil { app.transcripts.isIdle }
            let voice = try XCTUnwrap(
                try LibraryStore(root: root).load().conversations.first { $0.id == id }?.messages.first)
            XCTAssertEqual(voice.text, quitting ? "" : "Late speech")
            XCTAssertEqual(voice.transcriptionState, quitting ? .interrupted : .completed)
        }
    }

    @MainActor func testLateTranscriptCompletesWhileReplyIsPlaying() async throws {
        let app = makeApp(demo: true)
        app.resume()
        app.newChat()
        let done = expectation(description: "Late transcript delivered")
        app.playReply = { _ in _ = app.turn.begin(.playing) }
        app.speech.conversationReply = { _, _, callbacks in
            var reply = RealtimeAccumulator()
            reply.text = "Reply"
            reply.audio = Data([0, 0])
            reply.done = true
            try callbacks.response(reply)
            XCTAssertEqual(app.turn.activity, .playing)
            reply.inputTranscript = "Late speech"
            reply.transcriptionState = .completed
            callbacks.transcription(reply)
            done.fulfill()
        }
        app.requestReply(
            history: [], text: "", pcm: Data(repeating: 0, count: 4800), audioFile: "saved.wav",
            conversationID: app.selectedID!)
        await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(app.conversation?.messages.first?.text, "Late speech")
        XCTAssertEqual(app.conversation?.messages.first?.transcriptionState, .completed)
        XCTAssertEqual(app.conversation?.messages.count, 2)
        XCTAssertEqual(app.turn.activity, .playing)
        app.stop()
    }

    @MainActor func testOpeningHelpKeepsLateVoiceTranscriptionRunning() async throws {
        let app = makeApp(demo: true)
        app.resume()
        app.newChat()
        let gate = TestGate()
        let delivered = expectation(description: "Reply delivered")
        let finished = expectation(description: "Transcript delivered")
        app.playReply = { _ in _ = app.turn.begin(.playing) }
        app.speech.conversationReply = { _, _, callbacks in
            var result = RealtimeAccumulator()
            result.text = "Reply"
            result.done = true
            result.audio = Data([0, 0])
            try callbacks.response(result)
            delivered.fulfill()
            await gate.wait()
            result.inputTranscript = "Late transcript"
            result.transcriptionState = .completed
            callbacks.transcription(result)
            finished.fulfill()
        }
        app.requestReply(
            history: [], text: "", pcm: Data(repeating: 0, count: 4800), audioFile: "saved.wav",
            conversationID: app.selectedID!)
        await fulfillment(of: [delivered], timeout: 2)
        app.startHelp()
        XCTAssertTrue(app.practice)
        await gate.release()
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(app.conversation?.messages.first?.text, "Late transcript")
        XCTAssertEqual(app.conversation?.messages.first?.transcriptionState, .completed)
    }

    @MainActor func testHelpCancelLeavesIndependentRecoveryRunning() async throws {
        let app = makeApp(demo: true)
        app.resume()
        app.newChat()
        app.startHelp()
        app.help.meaning = "Typed thought"
        var voice = Message(role: "user", text: "", audio: "saved.wav")
        voice.transcriptionState = .failed
        app.append(voice, to: app.selectedID!)
        let started = expectation(description: "Recovery started")
        let finished = expectation(description: "Recovery completed")
        let recovery = TestGate()
        let english = TestGate()
        app.speech.transcribe = { _, _, _ in
            started.fulfill()
            await recovery.wait()
            finished.fulfill()
            return TranscriptResult(text: "Recovered")
        }
        app.speech.textReply = { _, _ in
            await english.wait()
            return #"{"kind":"expression","text":"English"}"#
        }
        app.retryTranscription(voice.id)
        await fulfillment(of: [started], timeout: 2)
        // The recovery is still held here, so it provably outlives the cancelled Help work.
        app.translate()
        app.cancelHelpWork()
        await recovery.release()
        await english.release()
        await fulfillment(of: [finished], timeout: 2)
        await waitUntil { app.transcribingMessageIDs.isEmpty }
        XCTAssertEqual(app.conversation?.messages.last?.text, "Recovered")
        XCTAssertEqual(app.help.meaning, "Typed thought")
        XCTAssertNil(app.help.progress)
    }

    @MainActor func testArchiveRejectsPendingRecoveryAndRetainsAudio() async throws {
        let app = makeApp(demo: true)
        app.resume()
        app.newChat()
        let chatID = app.selectedID!
        var voice = Message(role: "user", text: "", audio: "saved.wav")
        voice.transcriptionState = .failed
        app.append(voice, to: chatID)
        let gate = TestGate()
        let started = expectation(description: "Recovery started")
        app.speech.transcribe = { _, _, _ in
            started.fulfill()
            await gate.wait()
            return TranscriptResult(text: "Late speech")
        }
        app.retryTranscription(voice.id)
        let job = try XCTUnwrap(app.transcripts.task(for: voice.id))
        await fulfillment(of: [started], timeout: 2)
        app.archiveChats([chatID])
        await gate.release()
        await job.value
        let chat = try XCTUnwrap(app.library.conversations.first { $0.id == chatID })
        XCTAssertTrue(chat.archived)
        XCTAssertEqual(chat.messages.first?.text, "")
        XCTAssertTrue(app.library.referencedAudio.contains("saved.wav"))
        XCTAssertTrue(app.transcribingMessageIDs.isEmpty)
    }
}
