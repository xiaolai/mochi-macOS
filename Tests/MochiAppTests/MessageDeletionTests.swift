import MochiCore
import MochiProviders
import MochiTestSupport
import PCM16
import XCTest

@testable import MochiApp
@testable import MochiProviders

final class MessageDeletionTests: XCTestCase {
    private func temporary() -> URL { TestScratch.folder() }

    @MainActor func testDeletePersistsAndRemovesSearchAndContextWithoutDeletingOtherMessages() throws {
        let root = temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = makeApp(root: root)
        let id = try XCTUnwrap(app.selectedID)
        let first = Message(role: "user", text: "Forget this phrase")
        let reply = Message(role: "assistant", text: "A response")
        let last = Message(role: "user", text: "Keep this phrase")
        for message in [first, reply, last] { app.append(message, to: id) }
        app.find.query = "Forget"
        app.deleteMessage(first.id)
        XCTAssertEqual(app.conversation?.messages.map(\.id), [reply.id, last.id])
        XCTAssertTrue(app.find.matchIDs.isEmpty)
        XCTAssertEqual(app.conversation?.title, "Keep this phrase")
        XCTAssertTrue(app.library.history(in: .active, query: "Forget").isEmpty)
        let reopened = makeApp(root: root)
        XCTAssertEqual(reopened.conversation?.messages.map(\.id), [reply.id, last.id])
        app.undoMessageDeletion()
        XCTAssertEqual(app.conversation?.messages.map(\.id), [first.id, reply.id, last.id])
        XCTAssertEqual(makeApp(root: root).conversation?.messages.map(\.id), [first.id, reply.id, last.id])
        app.stop()
    }

    @MainActor func testUndoRetainsAudioAndDismissalRemovesOnlyUnreferencedAudio() throws {
        let root = temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = makeApp(root: root)
        let id = try XCTUnwrap(app.selectedID)
        let url = root.appendingPathComponent("message.wav")
        try Data([1, 2]).write(to: url)
        let message = Message(role: "user", text: "Audio", audio: "message.wav")
        app.append(message, to: id)
        app.deleteMessage(message.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        app.undoMessageDeletion()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        app.deleteMessage(message.id)
        app.notice = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(app.canUndoMessageDeletion)
    }

    @MainActor func testConsecutiveDeletionOfSharedAudioKeepsLatestUndoAndSavedExpressions() throws {
        let root = temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = makeApp(root: root)
        let id = try XCTUnwrap(app.selectedID)
        let url = root.appendingPathComponent("shared.wav")
        try Data([1]).write(to: url)
        let a = Message(role: "user", text: "First", audio: "shared.wav")
        let b = Message(role: "assistant", text: "Second", audio: "shared.wav")
        app.append(a, to: id)
        app.append(b, to: id)
        app.deleteMessage(a.id)
        app.deleteMessage(b.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        var item = PracticeExpression(conversationID: id, meaning: "", english: "Saved", language: .english)
        item.reference = "shared.wav"
        app.library.expressions = [item]
        app.save()
        app.notice = nil
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(app.library.expressions.count, 1)
    }

    @MainActor func testFailedDeletionKeepsMessageRecordingAndActiveTurn() throws {
        let root = temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = makeApp(root: root)
        let id = try XCTUnwrap(app.selectedID)
        let message = Message(role: "user", text: "Keep", audio: "keep.wav")
        try Data([1]).write(to: root.appendingPathComponent("keep.wav"))
        app.append(message, to: id)
        try Data("broken".utf8).write(to: app.store.file)
        let token = app.turn.begin(.generating)
        app.deleteMessage(message.id)
        XCTAssertEqual(app.conversation?.messages.first?.id, message.id)
        XCTAssertEqual(app.turn.epoch, token)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("keep.wav").path))
        XCTAssertFalse(app.canUndoMessageDeletion)
        app.stop()
    }

    /// Deleting the voice message a reply is being prepared for cancels that reply and its transcription.
    @MainActor func testDeleteInvalidatesReplyAndUndoInterruptsPendingTranscript() async throws {
        let app = makeApp(demo: true)
        app.resume()
        app.newChat()
        let id = try XCTUnwrap(app.selectedID)
        let gate = TestGate()
        let started = expectation(description: "Reply started")
        app.speech.conversationReply = { _, _, _ in
            started.fulfill()
            await gate.wait()
            try Task.checkCancellation()
            XCTFail("The reply to a deleted message must not go on")
        }
        app.requestReply(
            history: [], text: "", pcm: Data(repeating: 0, count: 4800), audioFile: "pending.wav", conversationID: id)
        let message = try XCTUnwrap(app.conversation?.messages.first)
        XCTAssertEqual(message.transcriptionState, .pending)
        let job = try XCTUnwrap(app.transcripts.task(for: message.id))
        await fulfillment(of: [started], timeout: 2)
        let token = app.turn.epoch
        app.deleteMessage(message.id)
        XCTAssertNotEqual(app.turn.epoch, token)
        XCTAssertFalse(app.busy)
        XCTAssertTrue(app.transcribingMessageIDs.isEmpty)
        await gate.release()
        await job.value
        app.undoMessageDeletion()
        XCTAssertEqual(app.conversation?.messages.first?.transcriptionState, .interrupted)
        app.turn.begin(.recording)
        app.deleteMessage(message.id)
        XCTAssertEqual(app.conversation?.messages.first?.id, message.id)
        app.stop()
        app.archiveChats([id])
        app.select(id)
        app.deleteMessage(message.id)
        XCTAssertEqual(app.conversation?.messages.first?.id, message.id)
    }

    @MainActor func testExpiryEndsUndoAndCleansTheDeletedRecording() async throws {
        let root = temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = makeApp(root: root)
        let id = try XCTUnwrap(app.selectedID)
        let file = root.appendingPathComponent("expire.wav")
        try Data([1]).write(to: file)
        let message = Message(role: "user", text: "Delete", audio: "expire.wav")
        app.append(message, to: id)
        let gate = TestGate()
        let scheduled = expectation(description: "Undo deadline scheduled")
        app.noticeSleep = { duration in
            XCTAssertEqual(duration, 10_000_000_000)
            scheduled.fulfill()
            await gate.wait()
        }
        app.deleteMessage(message.id)
        await fulfillment(of: [scheduled], timeout: 2)
        XCTAssertTrue(app.canUndoMessageDeletion)
        let expiry = try XCTUnwrap(app.pendingNoticeDismissal)
        await gate.release()
        await expiry.value
        XCTAssertNil(app.notice)
        XCTAssertFalse(app.canUndoMessageDeletion)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    @MainActor func testLateTranscriptionCannotRewriteAnUndoneDeletion() async throws {
        let app = makeApp(demo: true)
        app.resume()
        app.newChat()
        let id = try XCTUnwrap(app.selectedID)
        var message = Message(role: "user", text: "", audio: "late.wav")
        message.transcriptionState = .failed
        app.append(message, to: id)
        let gate = TestGate()
        let started = expectation(description: "Transcription started")
        app.speech.transcribe = { _, _, _ in
            started.fulfill()
            await gate.wait()
            return TranscriptResult(text: "Late text")
        }
        app.retryTranscription(message.id)
        let job = try XCTUnwrap(app.transcripts.task(for: message.id))
        await fulfillment(of: [started], timeout: 2)
        app.deleteMessage(message.id)
        app.undoMessageDeletion()
        await gate.release()
        await job.value
        XCTAssertEqual(app.conversation?.messages.first?.text, "")
        XCTAssertEqual(app.conversation?.messages.first?.transcriptionState, .interrupted)
        XCTAssertTrue(app.transcribingMessageIDs.isEmpty)
        app.stop()
    }

    @MainActor func testNextRequestExcludesDeletedMessageAndLateReplyCannotReturn() async throws {
        let app = makeApp(demo: true)
        app.resume()
        app.newChat()
        let id = try XCTUnwrap(app.selectedID)
        let removed = Message(role: "user", text: "Remove from context")
        app.append(removed, to: id)
        app.deleteMessage(removed.id)
        let gate = TestGate()
        let started = expectation(description: "Reply started")
        let returned = expectation(description: "Late reply attempted")
        app.speech.conversationReply = { _, request, callbacks in
            XCTAssertFalse(request.history.contains { $0.id == removed.id })
            started.fulfill()
            await gate.wait()
            var result = RealtimeAccumulator()
            result.text = "Late reply"
            result.done = true
            try callbacks.response(result)
            returned.fulfill()
        }
        app.draft = "New message"
        app.send()
        await fulfillment(of: [started], timeout: 2)
        app.deleteMessage(try XCTUnwrap(app.conversation?.messages.last?.id))
        await gate.release()
        await fulfillment(of: [returned], timeout: 2)
        XCTAssertTrue(app.conversation?.messages.isEmpty == true)
        app.notice = nil
        app.stop()
    }

    /// Deleting a message stops only what involves it: a reply to another message and another message's retried
    /// transcription go on.
    @MainActor func testDeletingAnUnrelatedMessageLeavesTheReplyAndOtherTranscriptionsRunning() async throws {
        let app = makeApp(demo: true)
        app.resume()
        app.newChat()
        let id = try XCTUnwrap(app.selectedID)
        let unrelated = Message(role: "user", text: "An earlier message")
        var other = Message(role: "user", text: "", audio: "other.wav")
        other.transcriptionState = .failed
        app.append(unrelated, to: id)
        app.append(other, to: id)
        let transcribing = TestGate()
        let transcriptionStarted = expectation(description: "Transcription started")
        app.speech.transcribe = { _, _, _ in
            transcriptionStarted.fulfill()
            await transcribing.wait()
            return TranscriptResult(text: "Recovered")
        }
        app.retryTranscription(other.id)
        let transcription = try XCTUnwrap(app.transcripts.task(for: other.id))
        await fulfillment(of: [transcriptionStarted], timeout: 2)
        let replying = TestGate()
        let replyStarted = expectation(description: "Reply started")
        app.speech.conversationReply = { _, _, callbacks in
            replyStarted.fulfill()
            await replying.wait()
            var reply = RealtimeAccumulator()
            reply.text = "Still here."
            reply.done = true
            try callbacks.response(reply)
        }
        app.draft = "A new message"
        app.send()
        await fulfillment(of: [replyStarted], timeout: 2)
        XCTAssertEqual(app.turn.activity, .generating)
        app.deleteMessage(unrelated.id)
        XCTAssertEqual(app.turn.activity, .generating, "The reply to another message goes on")
        XCTAssertTrue(app.transcribingMessageIDs.contains(other.id), "Another message's transcription goes on")
        await replying.release()
        await waitUntil { !app.busy }
        XCTAssertEqual(app.conversation?.messages.last?.text, "Still here.")
        await transcribing.release()
        await transcription.value
        XCTAssertEqual(app.conversation?.messages.first { $0.id == other.id }?.text, "Recovered")
        app.notice = nil
    }

    /// Deleting the reply that is playing stops it; deleting another message leaves it playing.
    @MainActor func testDeletingTheMessageThatPlaysStopsOnlyThatPlayback() throws {
        let root = temporary()
        let app = makeApp(root: root)
        let id = try XCTUnwrap(app.selectedID)
        try PCM.wav(Data(repeating: 0, count: 4800), rate: PCM.sampleRate).write(
            to: root.appendingPathComponent("reply.wav"))
        let earlier = Message(role: "user", text: "Earlier")
        let reply = Message(role: "assistant", text: "Playing", audio: "reply.wav")
        app.append(earlier, to: id)
        app.append(reply, to: id)
        let player = TestPlayer()
        app.audio.makePlayer = { _ in player }
        app.play("reply.wav", mochi: true)
        XCTAssertEqual(app.turn.activity, .playing)
        app.deleteMessage(earlier.id)
        XCTAssertEqual(app.turn.activity, .playing, "Another message's deletion leaves the reply playing")
        XCTAssertTrue(player.playing)
        app.deleteMessage(reply.id)
        XCTAssertEqual(app.turn.activity, .idle)
        XCTAssertNil(app.playbackFile)
        XCTAssertFalse(player.playing)
        app.notice = nil
    }
}
