import Darwin
import MochiCore
import MochiKernel
import XCTest

@testable import MochiApp
@testable import MochiProviders

final class PersistenceModelTests: XCTestCase {
    // MARK: Opening the library (H2, H3, L2)

    @MainActor func testFirstLaunchWritesItsLibraryImmediately() {
        let root = makeTemporaryFolder()
        _ = makeApp(root: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("library.json").path))
    }
    @MainActor func testNewerLibraryNamesTheRealReasonAndIsNotOverwritten() throws {
        let root = makeTemporaryFolder()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bytes = Data(#"{"version":\#(Library.currentVersion + 1),"conversations":[],"expressions":[]}"#.utf8)
        try bytes.write(to: root.appendingPathComponent("library.json"))
        let app = makeApp(root: root)
        XCTAssertTrue(app.error?.contains("newer version of Mochi") == true, app.error ?? "no error")
        XCTAssertFalse(app.canRestorePreviousLibrary)
        app.draft = "Typed"
        app.save()
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("library.json")), bytes)
    }
    @MainActor func testDamagedLibraryOffersTheEarlierCopyAndRestoresIt() throws {
        let root = makeTemporaryFolder()
        let first = makeApp(root: root)
        first.renameChat(first.selectedID!, title: "Before damage")
        first.draft = "later"
        first.save()
        try Data("damaged".utf8).write(to: root.appendingPathComponent("library.json"))
        let app = makeApp(root: root)
        XCTAssertTrue(app.canRestorePreviousLibrary)
        XCTAssertTrue(app.error?.contains("Restore Earlier Copy") == true, app.error ?? "no error")
        app.restorePreviousLibrary()
        XCTAssertNil(app.error)
        XCTAssertFalse(app.canRestorePreviousLibrary)
        XCTAssertTrue(app.libraryReadable)
        XCTAssertEqual(app.conversation?.title, "Before damage")
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(atPath: root.path).contains {
                $0.hasPrefix("library-unreadable-")
            })
        XCTAssertEqual(makeApp(root: root).conversation?.title, "Before damage")
    }
    @MainActor func testRestoredEarlierCopyStillHasTheRecordingsItNamesAndBacksUp() async throws {
        let root = makeTemporaryFolder()
        let first = makeApp(root: root)
        let id = try XCTUnwrap(first.selectedID)
        let name = "recording-\(UUID().uuidString).wav"
        try Data([1]).write(to: root.appendingPathComponent(name))
        first.append(Message(role: "user", text: "Hello", audio: name), to: id)
        first.deleteChats([id])
        first.history.permanentDeleteIDs = [id]
        first.permanentlyDeleteChats()
        // The earlier copy still names the recording, so it outlives its last use in the library.
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path))
        try Data("damaged".utf8).write(to: root.appendingPathComponent("library.json"))
        let app = makeApp(root: root)
        app.restorePreviousLibrary()
        XCTAssertTrue(app.library.conversations.contains { $0.messages.contains { $0.audio == name } })
        let backup = makeTemporaryFolder().appendingPathComponent("Restored.mochibackup")
        await app.exportLibraryBackup(to: backup)?.value
        XCTAssertNil(app.error)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.appendingPathComponent(name).path))
    }
    @MainActor func testARecordingNoCopyNamesIsSweptAtTheNextLaunch() throws {
        let root = makeTemporaryFolder()
        let first = makeApp(root: root)
        let id = try XCTUnwrap(first.selectedID)
        let name = "recording-\(UUID().uuidString).wav"
        let url = root.appendingPathComponent(name)
        try Data([1]).write(to: url)
        first.append(Message(role: "user", text: "Hello", audio: name), to: id)
        first.deleteChats([id])
        first.history.permanentDeleteIDs = [id]
        first.permanentlyDeleteChats()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        // The next save replaces the earlier copy, so nothing can reinstate the recording any more.
        XCTAssertTrue(first.save())
        _ = makeApp(root: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: Typing (H1)

    @MainActor func testTypingIsWrittenAfterAPauseWithoutChangingTheAutomationRevision() async throws {
        let root = makeTemporaryFolder()
        let app = makeApp(root: root)
        app.externalControlEnabled = true
        defer { app.externalControlEnabled = false }
        app.saveDelay = 20_000_000
        let id = try XCTUnwrap(app.selectedID)
        let revision = app.tools.revision
        for character in "Hello there" { app.draft.append(character) }
        XCTAssertEqual(app.tools.revision, revision)
        XCTAssertTrue(app.hasPendingSave)
        XCTAssertEqual(try LibraryStore(root: root).load().conversations[0].draft, "")
        await waitUntil { !app.hasPendingSave }
        XCTAssertEqual(try LibraryStore(root: root).load().conversations[0].draft, "Hello there")
        // An automation client holding the old revision is not rejected because the user typed.
        let result = try app.tools.execute(
            "save_expression",
            arguments: ["conversation_id": id.uuidString, "expected_revision": revision, "text": "Let me think."],
            origin: .external)
        XCTAssertEqual(result["ok"] as? Bool, true)
    }
    @MainActor func testSwitchingConversationsWritesPendingTypingAtOnce() throws {
        let root = makeTemporaryFolder()
        let app = makeApp(root: root)
        let first = try XCTUnwrap(app.selectedID)
        app.draft = "Keep me"
        app.newChat()
        XCTAssertFalse(app.hasPendingSave)
        XCTAssertEqual(
            try LibraryStore(root: root).load().conversations.first(where: { $0.id == first })?.draft, "Keep me")
    }

    // MARK: Failure messages (M3, M4)

    @MainActor func testSaveFailureMessagesNameTheRealCause() {
        let app = makeApp(demo: true)
        func message(_ error: Error) -> String {
            app.persistenceMessage(error, action: "Test", fallback: "fallback", diskFull: "disk full")
        }
        XCTAssertEqual(message(POSIXError(.ENOSPC)), "disk full")
        XCTAssertEqual(
            message(AppFailure("The library file on disk was written by a newer version of Mochi.")),
            "The library file on disk was written by a newer version of Mochi.")
        XCTAssertEqual(message(POSIXError(.EACCES)), "fallback")
    }
    @MainActor func testReplyKeepsItsTextWhenItsAudioCannotBeWritten() async throws {
        let app = makeApp(root: makeTemporaryFolder())
        // Only the audio write fails; the library itself still saves, so the reply text reaches disk.
        app.writeReplyAudio = { _, _ in throw POSIXError(.EACCES) }
        app.speech.conversationReply = { _, _, callbacks in
            var reply = RealtimeAccumulator()
            reply.text = "Hello back."
            reply.audio = Data(repeating: 0, count: 4800)
            reply.done = true
            try callbacks.response(reply)
        }
        app.draft = "Hello"
        app.send()
        await waitUntil { !app.busy }
        let reply = try XCTUnwrap(app.conversation?.messages.last)
        XCTAssertEqual(reply.role, "assistant")
        XCTAssertEqual(reply.text, "Hello back.")
        XCTAssertNil(reply.audio)
        XCTAssertTrue(app.error?.contains("without its audio") == true, app.error ?? "no error")
        let saved = try LibraryStore(root: app.store.root).load().conversations.first { $0.id == app.selectedID }
        XCTAssertEqual(saved?.messages.map(\.text), ["Hello", "Hello back."])
    }

    // MARK: Creating examples (moved from the retired ElevenLabs tests)

    @MainActor private func practisingApp() -> AppModel {
        let app = makeApp(root: makeTemporaryFolder())
        app.startHelp()
        app.editEnglish("Let me think.")
        return app
    }
    @MainActor func testExampleUsesThePracticeVoiceAndForwardsRegeneration() async throws {
        let app = practisingApp()
        let fixture = fixtureURL("reference.mp3")
        app.settings.builtInPracticeVoice = "cedar"
        var calls: [(String, String, Bool)] = []
        app.speech.referenceAudio = { text, service, root, force in
            calls.append((text, service.voice, force))
            let url = root.appendingPathComponent("builtin-test.mp3")
            if !FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.copyItem(at: fixture, to: url)
            }
            return url
        }
        app.render()
        await waitUntil { !app.busy }
        XCTAssertNil(app.error)
        XCTAssertEqual(app.help.expression?.reference, "builtin-test.mp3")
        XCTAssertEqual(app.help.expression?.referenceKind, "Cedar · Codex voice")
        XCTAssertFalse(app.help.referencePitch.isEmpty)
        app.render(force: true)
        await waitUntil { !app.busy }
        XCTAssertEqual(calls.map(\.0), ["Let me think.", "Let me think."])
        XCTAssertEqual(calls.map(\.1), ["cedar", "cedar"])
        XCTAssertEqual(calls.map(\.2), [false, true])
    }
    @MainActor func testFailedExampleKeepsTheSavedOne() async throws {
        let app = practisingApp()
        app.ensureExpression()
        app.help.expression?.reference = "saved.wav"
        app.help.expression?.referenceKind = "Original"
        app.speech.referenceAudio = { _, _, _, _ in throw AppFailure("The example did not match the sentence exactly.")
        }
        app.render(force: true)
        await waitUntil { !app.busy }
        XCTAssertEqual(app.error, "The example did not match the sentence exactly.")
        XCTAssertEqual(app.help.expression?.reference, "saved.wav")
        XCTAssertEqual(app.help.expression?.referenceKind, "Original")
    }
    @MainActor func testStoppingWhileAnExampleIsCreatedCannotReplaceTheSavedOne() async throws {
        let app = practisingApp()
        let gate = TestGate()
        let started = expectation(description: "Example requested")
        app.ensureExpression()
        app.help.expression?.reference = "saved.wav"
        app.help.expression?.referenceKind = "Original"
        app.speech.referenceAudio = { _, _, root, _ in
            started.fulfill()
            await gate.wait()
            return root.appendingPathComponent("late.wav")
        }
        app.render(force: true)
        await fulfillment(of: [started], timeout: 2)
        let job = try XCTUnwrap(app.currentTask)
        app.stop()
        await gate.release()
        await job.value
        XCTAssertFalse(app.busy)
        XCTAssertNil(app.error)
        XCTAssertEqual(app.help.expression?.reference, "saved.wav")
        XCTAssertEqual(app.help.expression?.referenceKind, "Original")
    }
}

extension PersistenceModelTests {
    @MainActor func testUnsavedMessageKeepsTheDraftAndIsNotSent() async throws {
        let root = makeTemporaryFolder()
        let app = makeApp(root: root)
        defer { chmod(root.path, 0o700) }
        let id = try XCTUnwrap(app.selectedID)
        let title = app.conversation?.title
        var requests = 0
        app.speech.conversationReply = { _, _, callbacks in
            requests += 1
            var reply = RealtimeAccumulator()
            reply.text = "Hello back."
            reply.done = true
            try callbacks.response(reply)
        }
        XCTAssertEqual(chmod(root.path, 0o500), 0)
        app.draft = "  Hello  "
        app.send()
        XCTAssertEqual(app.draft, "  Hello  ")
        XCTAssertNotNil(app.error)
        XCTAssertFalse(app.busy)
        XCTAssertEqual(requests, 0)
        XCTAssertEqual(app.conversation?.messages.count, 0)
        XCTAssertEqual(app.conversation?.title, title)
        XCTAssertEqual(app.conversation?.draft, "  Hello  ")

        XCTAssertEqual(chmod(root.path, 0o700), 0)
        app.send()
        await waitUntil { !app.busy }
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(app.draft, "")
        XCTAssertNil(app.error)
        let saved = try LibraryStore(root: root).load().conversations.first { $0.id == id }
        XCTAssertEqual(saved?.messages.map(\.text), ["Hello", "Hello back."])
        XCTAssertEqual(saved?.draft, "")
    }

    @MainActor func testAnUnsavedVoiceMessageIsNeitherTranscribedNorAnswered() async throws {
        let root = makeTemporaryFolder()
        let app = makeApp(root: root)
        defer { chmod(root.path, 0o700) }
        let id = try XCTUnwrap(app.selectedID)
        var requests = 0
        app.speech.conversationReply = { _, _, _ in requests += 1 }
        XCTAssertEqual(chmod(root.path, 0o500), 0)
        app.requestReply(
            history: [], text: "", pcm: Data(repeating: 0, count: 4800), audioFile: "recording-\(UUID()).wav",
            conversationID: id)
        await waitUntil { !app.busy }
        XCTAssertEqual(requests, 0)
        XCTAssertNotNil(app.error, "The save failure is reported")
        XCTAssertEqual(app.conversation?.messages.count, 0, "Memory never holds a message the disk lacks")
        XCTAssertFalse(app.busy)
    }
    @MainActor func testAnUnsavedVoiceMessageKeepsItsRecordingWhereLaunchCleanupLeavesIt() async throws {
        let root = makeTemporaryFolder()
        let app = makeApp(root: root)
        let id = try XCTUnwrap(app.selectedID)
        XCTAssertTrue(app.save())
        var requests = 0
        app.speech.conversationReply = { _, _, _ in requests += 1 }
        let name = "recording-\(UUID()).wav"
        try Data(repeating: 0, count: 48).write(to: root.appendingPathComponent(name))
        // A library file that is a link is never replaced, so the save fails while the folder stays writable.
        let moved = root.appendingPathComponent("elsewhere.json")
        try FileManager.default.moveItem(at: app.store.file, to: moved)
        try FileManager.default.createSymbolicLink(at: app.store.file, withDestinationURL: moved)
        app.requestReply(
            history: [], text: "", pcm: Data(repeating: 0, count: 4800), audioFile: name, conversationID: id)
        await waitUntil { !app.busy }
        XCTAssertEqual(requests, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path))
        let kept = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(atPath: root.path).first { $0.hasPrefix("Unsent voice message ") })
        XCTAssertTrue(app.error?.contains(kept) == true, "The learner is told where it is")
        // On the next launch, cleanup removes an orphaned recording but keeps the unsent one.
        try FileManager.default.removeItem(at: app.store.file)
        try FileManager.default.moveItem(at: moved, to: app.store.file)
        let orphan = root.appendingPathComponent("recording-\(UUID()).wav")
        try Data(repeating: 0, count: 48).write(to: orphan)
        _ = makeApp(root: root)
        await waitUntil { !FileManager.default.fileExists(atPath: orphan.path) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path), "Launch cleanup ran")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(kept).path))
    }

    @MainActor func testUnsavedTextReplyIsNotReportedAsSavedWithoutAudio() async throws {
        let root = makeTemporaryFolder()
        let app = makeApp(root: root)
        defer { chmod(root.path, 0o700) }
        app.writeReplyAudio = { _, _ in throw POSIXError(.EACCES) }
        app.speech.conversationReply = { _, _, callbacks in
            // The message saved; the library becomes unwritable before the reply arrives.
            XCTAssertEqual(chmod(root.path, 0o500), 0)
            var reply = RealtimeAccumulator()
            reply.text = "Hello back."
            reply.audio = Data(repeating: 0, count: 4800)
            reply.done = true
            try callbacks.response(reply)
        }
        app.draft = "Hello"
        app.send()
        await waitUntil { !app.busy }
        let error = try XCTUnwrap(app.error)
        XCTAssertFalse(error.contains("was saved"), error)
        XCTAssertTrue(error.contains("Could not save your conversation"), error)
    }

    @MainActor func testAudioOnlyReplyThatCannotBeWrittenIsReportedAsLost() async throws {
        let app = makeApp(root: makeTemporaryFolder())
        // Only the audio write fails; a failed message save now stops the send, which
        // testUnsavedMessageKeepsTheDraftAndIsNotSent covers.
        app.writeReplyAudio = { _, _ in throw POSIXError(.EACCES) }
        app.speech.conversationReply = { _, _, callbacks in
            var reply = RealtimeAccumulator()
            reply.audio = Data(repeating: 0, count: 4800)
            reply.done = true
            try callbacks.response(reply)
        }
        app.draft = "Hello"
        app.send()
        await waitUntil { !app.busy }
        XCTAssertFalse(app.conversation?.messages.contains { $0.role == "assistant" } == true)
        XCTAssertTrue(app.error?.contains("reply could not be saved") == true, app.error ?? "no error")
    }

    @MainActor func testStopSavesOnceSoTheEarlierCopyIsTheStateBeforeStop() throws {
        let root = makeTemporaryFolder()
        let app = makeApp(root: root)
        app.startHelp()
        XCTAssertTrue(app.practice)
        XCTAssertTrue(app.save())
        // Typing in an existing draft is only scheduled, so disk still lacks it when Stop runs.
        app.help.meaning = "Typed just before Stop"
        XCTAssertTrue(app.hasPendingSave)
        XCTAssertTrue(app.stop())
        let store = LibraryStore(root: root)
        XCTAssertEqual(try store.load().conversations.first?.helpDraft?.meaning, "Typed just before Stop")
        // A second save would have replaced the earlier copy with the state Stop wrote.
        let previous = try String(contentsOf: store.previousFile, encoding: .utf8)
        XCTAssertFalse(previous.contains("Typed just before Stop"))
    }
}
