import MochiAutomation
import MochiCore
import MochiKernel
import PCM16
import XCTest

@testable import MochiApp
@testable import MochiProviders

/// An MCP client's panel and playback requests never cut Mochi's spoken reply off: they wait for it to finish,
/// while the client's own playback of an existing clip stays under its immediate control.
final class ExternalReplyDeferralTests: XCTestCase {
    @MainActor func testPreparingAnExpressionWaitsForTheSpokenReply() async throws {
        let (app, player) = try await speakingApp()
        let request = try controlRequest(
            "prepare_expression", ["conversation_id": id(app), "text": "Let me think.", "expected_revision": rev(app)])
        let result = try response(app, request)
        XCTAssertEqual(result["ok"] as? Bool, true, "\(result["error"] ?? "")")
        XCTAssertEqual(result["status"] as? String, "scheduled_after_reply")
        XCTAssertEqual(result["revision"] as? String, app.tools.revision)
        XCTAssertEqual(app.turn.activity, .playing, "The reply was cut off")
        XCTAssertEqual(app.playbackFile, app.unheardReply)
        XCTAssertFalse(app.practice)
        XCTAssertNil(app.conversation?.helpDraft)
        XCTAssertEqual(try response(app, request)["status"] as? String, "scheduled_after_reply", "A retry is answered")
        XCTAssertThrowsError(
            try app.tools.execute(
                "prepare_expression",
                arguments: ["conversation_id": id(app), "text": "Another", "expected_revision": rev(app)],
                origin: .external)
        ) {
            XCTAssertEqual(
                AppFailure.message(for: $0, fallback: ""),
                "A view or playback action is already scheduled for this reply.")
        }

        app.audio.finishPlayback(player, successfully: true)
        XCTAssertTrue(app.practice, "The panel opens once the reply has been spoken")
        XCTAssertEqual(app.conversation?.helpDraft?.english, "Let me think.")
    }

    @MainActor func testStartingPracticeWaitsForTheSpokenReplyAndStopCancelsIt() async throws {
        for cancel in [false, true] {
            let (app, player) = try await speakingApp()
            let saved = try app.tools.execute(
                "save_expression",
                arguments: ["conversation_id": id(app), "text": "Let me think.", "expected_revision": rev(app)],
                origin: .external)
            let result = try app.tools.execute(
                "start_practice",
                arguments: [
                    "conversation_id": id(app), "expression_id": try XCTUnwrap(saved["expression_id"]),
                    "expected_revision": rev(app),
                ], origin: .external)
            XCTAssertEqual(result["status"] as? String, "scheduled_after_reply")
            XCTAssertEqual(app.turn.activity, .playing)
            XCTAssertFalse(app.practice)
            if cancel {
                _ = try app.tools.execute(
                    "stop_audio", arguments: ["conversation_id": id(app), "expected_revision": rev(app)],
                    origin: .external)
                XCTAssertNil(app.deferredToolAction, "Stop cancels the scheduled panel")
            }
            app.audio.finishPlayback(player, successfully: true)
            XCTAssertEqual(app.practice, !cancel)
        }
    }

    @MainActor func testPlayAudioWaitsForTheSpokenReplyButSeekingIsImmediate() async throws {
        let (app, player) = try await speakingApp()
        let reply = try XCTUnwrap(app.playbackFile)
        let clip = try clipMessage(app)
        let played = try app.tools.execute(
            "play_audio", arguments: ["conversation_id": id(app), "message_id": clip, "expected_revision": rev(app)],
            origin: .external)
        XCTAssertEqual(played["status"] as? String, "scheduled_after_reply")
        XCTAssertEqual(app.playbackFile, reply, "The reply was replaced")
        app.audio.finishPlayback(player, successfully: true)
        XCTAssertEqual(app.playbackFile, "clip.wav", "The clip plays once the reply has been spoken")

        let (speaking, _) = try await speakingApp()
        let sought = try speaking.tools.execute(
            "seek_audio",
            arguments: [
                "conversation_id": id(speaking), "message_id": try clipMessage(speaking), "seconds": 0.5,
                "expected_revision": rev(speaking),
            ], origin: .external)
        XCTAssertEqual(sought["status"] as? String, "completed")
        XCTAssertEqual(speaking.playbackFile, "clip.wav")
    }

    /// Playback of an existing clip, even one of Mochi's, is not a reply in progress: the client controls it.
    @MainActor func testReplayingAnExistingClipDoesNotDeferTheNextRequest() throws {
        let app = controlledApp()
        let clip = try clipMessage(app)
        app.audio.makePlayer = { _ in TestPlayer() }
        let first = try app.tools.execute(
            "play_audio", arguments: ["conversation_id": id(app), "message_id": clip, "expected_revision": rev(app)],
            origin: .external)
        XCTAssertEqual(first["status"] as? String, "completed")
        XCTAssertEqual(app.turn.activity, .playing)
        XCTAssertTrue(app.speaking, "An assistant clip plays as Mochi's voice")
        let replay = try app.tools.execute(
            "play_audio", arguments: ["conversation_id": id(app), "message_id": clip, "expected_revision": rev(app)],
            origin: .external)
        XCTAssertEqual(replay["status"] as? String, "completed")
        let prepared = try app.tools.execute(
            "prepare_expression",
            arguments: ["conversation_id": id(app), "text": "Let me think.", "expected_revision": rev(app)],
            origin: .external)
        XCTAssertEqual(prepared["status"] as? String, "completed")
        XCTAssertTrue(app.practice)
    }

    /// A scheduled request belongs to the reply: playing something else in its place drops it.
    @MainActor func testReplacingTheReplyDropsTheScheduledRequest() async throws {
        let (app, _) = try await speakingApp()
        _ = try app.tools.execute(
            "prepare_expression",
            arguments: ["conversation_id": id(app), "text": "Let me think.", "expected_revision": rev(app)],
            origin: .external)
        XCTAssertNotNil(app.deferredToolAction)
        _ = try clipMessage(app)
        let other = TestPlayer()
        app.audio.makePlayer = { _ in other }
        app.play("clip.wav")
        XCTAssertNil(app.deferredToolAction)
        app.audio.finishPlayback(other, successfully: true)
        XCTAssertFalse(app.practice)
        XCTAssertNil(app.conversation?.helpDraft)
    }

    /// One change waits per reply, whoever asked: the voice model's, scheduled first, is not displaced.
    @MainActor func testAReplyWithAVoiceChangeWaitingRefusesAnExternalOne() async throws {
        var scheduled = false
        let (app, player) = try await speakingApp { app in
            let saved = try app.tools.execute(
                "save_expression", arguments: ["conversation_id": self.id(app), "text": "From the voice model."],
                origin: .voice)
            let started = try app.tools.execute(
                "start_practice",
                arguments: ["conversation_id": self.id(app), "expression_id": try XCTUnwrap(saved["expression_id"])],
                origin: .voice)
            scheduled = started["status"] as? String == "scheduled_after_reply"
        }
        XCTAssertTrue(scheduled)
        XCTAssertThrowsError(
            try app.tools.execute(
                "prepare_expression",
                arguments: ["conversation_id": id(app), "text": "From the client.", "expected_revision": rev(app)],
                origin: .external)
        ) {
            XCTAssertEqual(
                AppFailure.message(for: $0, fallback: ""),
                "A view or playback action is already scheduled for this reply.")
        }
        app.audio.finishPlayback(player, successfully: true)
        XCTAssertTrue(app.practice)
        XCTAssertEqual(app.help.expression?.english, "From the voice model.")
        XCTAssertNil(app.error)
    }

    /// A seek within the reply makes it a replay, but the voice model's change still waits for it: a later external
    /// panel or playback is refused rather than acting at once and dropping that change.
    @MainActor func testAfterASeekWithinTheReplyAWaitingVoiceChangeStillRefusesExternalOnes() async throws {
        for name in ["prepare_expression", "play_audio"] {
            let (app, player) = try await speakingApp(duringReply: voiceStartsPractice)
            let replyMessage = try XCTUnwrap(app.conversation?.messages.last { $0.audio == app.playbackFile })
            let sought = try app.tools.execute(
                "seek_audio",
                arguments: [
                    "conversation_id": id(app), "message_id": replyMessage.id.uuidString, "seconds": 0.01,
                    "expected_revision": rev(app),
                ], origin: .external)
            XCTAssertEqual(sought["status"] as? String, "completed", name)
            XCTAssertFalse(app.speakingReply, name)
            XCTAssertNotNil(app.deferredToolAction, "A seek within the reply keeps the waiting change")
            var arguments: [String: Any] = ["conversation_id": try id(app), "expected_revision": rev(app)]
            if name == "prepare_expression" {
                arguments["text"] = "From the client."
            } else {
                arguments["message_id"] = try clipMessage(app)
                arguments["expected_revision"] = rev(app)
            }
            XCTAssertThrowsError(try app.tools.execute(name, arguments: arguments, origin: .external)) {
                XCTAssertEqual(
                    AppFailure.message(for: $0, fallback: ""),
                    "A view or playback action is already scheduled for this reply.", name)
            }
            XCTAssertEqual(app.playbackFile, replyMessage.audio, "\(name) replaced the reply")
            app.audio.finishPlayback(player, successfully: true)
            XCTAssertTrue(app.practice, name)
            XCTAssertEqual(app.help.expression?.english, "From the voice model.", name)
        }
    }

    /// Seeking to other audio replaces the reply, as Stop ends it: the change waiting for that reply is dropped.
    @MainActor func testSeekingToOtherAudioDropsTheChangeWaitingForTheReply() async throws {
        let (app, player) = try await speakingApp(duringReply: voiceStartsPractice)
        let sought = try app.tools.execute(
            "seek_audio",
            arguments: [
                "conversation_id": id(app), "message_id": try clipMessage(app), "seconds": 0.5,
                "expected_revision": rev(app),
            ], origin: .external)
        XCTAssertEqual(sought["status"] as? String, "completed")
        XCTAssertEqual(app.playbackFile, "clip.wav")
        XCTAssertNil(app.deferredToolAction)
        app.audio.finishPlayback(player, successfully: true)
        XCTAssertFalse(app.practice)
    }

    /// A paused reply is still Mochi's reply: a change waits through the pause until the reply finishes.
    @MainActor func testAPausedReplyKeepsTheChangeWaiting() async throws {
        let (app, player) = try await speakingApp()
        _ = try app.tools.execute(
            "pause_audio", arguments: ["conversation_id": id(app), "expected_revision": rev(app)], origin: .external)
        XCTAssertTrue(app.audio.paused)
        let result = try app.tools.execute(
            "prepare_expression",
            arguments: ["conversation_id": id(app), "text": "Let me think.", "expected_revision": rev(app)],
            origin: .external)
        XCTAssertEqual(result["status"] as? String, "scheduled_after_reply")
        XCTAssertFalse(app.practice)
        _ = try app.tools.execute(
            "resume_audio", arguments: ["conversation_id": id(app), "expected_revision": rev(app)], origin: .external)
        XCTAssertFalse(app.practice)
        app.audio.finishPlayback(player, successfully: true)
        XCTAssertTrue(app.practice)
    }

    /// The reason a reply could not be played stays in front of the learner when the waiting panel opens.
    @MainActor func testAReplyThatFailsToPlayKeepsItsErrorWhenTheWaitingPanelOpens() async throws {
        let (app, player) = try await speakingApp()
        _ = try app.tools.execute(
            "prepare_expression",
            arguments: ["conversation_id": id(app), "text": "Let me think.", "expected_revision": rev(app)],
            origin: .external)
        app.audio.finishPlayback(player, successfully: false)
        XCTAssertTrue(app.practice)
        XCTAssertEqual(app.error, "This recording could not be played. Try another recording.")
    }

    /// A greeting heard for the first time is Mochi speaking: the panel waits for it, and the recording a greeting
    /// starts afterwards does not open over the panel.
    @MainActor func testPreparingAnExpressionWaitsForTheGreeting() async throws {
        let app = controlledApp()
        let player = TestPlayer()
        app.audio.makePlayer = { _ in player }
        var recordings = 0
        app.media.permission = { true }
        app.media.record = { _ in recordings += 1 }
        app.speech.referenceAudio = { _, _, _, root, _ in root.appendingPathComponent("greeting.wav") }
        app.toggleConversationVoice()
        await waitUntil { app.turn.activity == .playing }
        XCTAssertTrue(app.speakingReply)
        let result = try app.tools.execute(
            "prepare_expression",
            arguments: ["conversation_id": id(app), "text": "Let me think.", "expected_revision": rev(app)],
            origin: .external)
        XCTAssertEqual(result["status"] as? String, "scheduled_after_reply")
        XCTAssertEqual(app.turn.activity, .playing)
        app.audio.finishPlayback(player, successfully: true)
        XCTAssertTrue(app.practice)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(recordings, 0)
    }

    // MARK: Support

    /// The voice model's tool calls during its reply: it saves an expression and asks to practise it.
    @MainActor private func voiceStartsPractice(_ app: AppModel) throws {
        let saved = try app.tools.execute(
            "save_expression", arguments: ["conversation_id": id(app), "text": "From the voice model."],
            origin: .voice)
        let started = try app.tools.execute(
            "start_practice",
            arguments: ["conversation_id": id(app), "expression_id": try XCTUnwrap(saved["expression_id"])],
            origin: .voice)
        XCTAssertEqual(started["status"] as? String, "scheduled_after_reply")
    }

    /// An app with external control on, playing a reply Mochi has just spoken, as a real send produces it.
    /// `duringReply` runs while the reply is generated, as the voice model's tool calls do.
    @MainActor private func speakingApp(
        duringReply: @escaping @MainActor (AppModel) throws -> Void = { _ in }
    ) async throws -> (AppModel, TestPlayer) {
        let app = controlledApp()
        let player = TestPlayer()
        app.audio.makePlayer = { _ in player }
        app.speech.conversationReply = { _, _, callbacks in
            try duringReply(app)
            var response = RealtimeAccumulator()
            response.text = "Here is a long answer."
            response.audio = Data(repeating: 0, count: 4800)
            try callbacks.response(response)
        }
        app.draft = "Tell me something"
        app.send()
        await waitUntil { app.turn.activity != .generating }
        XCTAssertEqual(app.turn.activity, .playing)
        XCTAssertNotNil(app.unheardReply)
        XCTAssertEqual(app.playbackFile, app.unheardReply)
        return (app, player)
    }
    /// Adds an assistant message with audio, as one replayed from the conversation; returns its ID.
    @MainActor private func clipMessage(_ app: AppModel) throws -> String {
        try PCM.wav(Data(repeating: 0, count: 4800), rate: PCM.sampleRate).write(
            to: app.store.root.appendingPathComponent("clip.wav"))
        let message = Message(role: "assistant", text: "An earlier reply", audio: "clip.wav")
        app.append(message, to: try XCTUnwrap(app.selectedID))
        return message.id.uuidString
    }
    @MainActor private func id(_ app: AppModel) throws -> String { try XCTUnwrap(app.selectedID).uuidString }
    @MainActor private func rev(_ app: AppModel) -> String { app.tools.revision }
    private func controlRequest(_ name: String, _ arguments: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "name": name, "arguments": arguments, "request_id": UUID().uuidString,
        ])
    }
    @MainActor private func response(_ app: AppModel, _ request: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: app.tools.handleControlRequest(request)) as? [String: Any])
    }
    @MainActor private func controlledApp() -> AppModel {
        let app = makeApp(root: makeTemporaryFolder("mochi-external-deferral"), preferences: makePreferences())
        app.externalControlEnabled = true
        addTeardownBlock { @MainActor in
            app.externalControlEnabled = false
            app.stop()
        }
        return app
    }
}
