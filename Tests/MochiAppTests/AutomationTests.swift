import MochiAutomation
import MochiCore
import MochiKernel
import MochiTestSupport
import XCTest

@testable import MochiApp
@testable import MochiProviders

private final class AutomationPlayer: PlaybackPlayer {
    var duration: TimeInterval = 5
    var currentTime: TimeInterval = 0
    var enableRate = false
    var rate: Float = 1
    func play() -> Bool { true }
    func pause() {}
    func stop() {}
}
private final class CountingPlayer: PlaybackPlayer {
    var duration: TimeInterval = 5
    var currentTime: TimeInterval = 0
    var enableRate = false
    var rate: Float = 1
    var starts = 0, pauses = 0
    func play() -> Bool {
        starts += 1
        return true
    }
    func pause() { pauses += 1 }
    func stop() {}
}

/// Resumes once, then refuses to play again.
private final class FailingResumePlayer: PlaybackPlayer {
    var duration: TimeInterval = 5
    var currentTime: TimeInterval = 0
    var enableRate = false
    var rate: Float = 1
    var starts = 0
    func play() -> Bool {
        starts += 1
        return starts == 1
    }
    func pause() {}
    func stop() {}
}

final class AutomationTests: XCTestCase {
    @MainActor func testConversationSettingsPersistAndRejectArchivedChanges() throws {
        let root = TestScratch.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = makeApp(root: root, preferences: makePreferences(named: "automation-tests-" + root.lastPathComponent))
        let id = try XCTUnwrap(app.selectedID)
        var preferences = ConversationPreferences()
        preferences.speed = 0.7
        XCTAssertTrue(app.setConversationInstructions(id, instructions: "Interview me", preferences: preferences))
        XCTAssertEqual(
            makeApp(root: root, preferences: makePreferences(named: "automation-tests-" + root.lastPathComponent))
                .conversation?.instructions, "Interview me")
        app.archiveChats([id])
        XCTAssertFalse(app.setConversationInstructions(id, instructions: "No", preferences: preferences))
    }
    @MainActor func testRevisionAndScopeGuardAndExpressionPersistence() throws {
        let root = TestScratch.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = makeApp(root: root, preferences: makePreferences(named: "automation-tests-" + root.lastPathComponent))
        let id = try XCTUnwrap(app.selectedID)
        app.externalControlEnabled = true
        let args: [String: Any] = [
            "conversation_id": id.uuidString, "expected_revision": app.tools.revision,
            "text": "Could you give me a moment?",
        ]
        let result = try app.tools.execute("save_expression", arguments: args, origin: .external)
        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertEqual(
            makeApp(root: root, preferences: makePreferences(named: "automation-tests-" + root.lastPathComponent))
                .library.expressions.count, 1)
        XCTAssertThrowsError(try app.tools.execute("save_expression", arguments: args, origin: .external))
        XCTAssertThrowsError(
            try app.tools.execute(
                "set_conversation_instructions",
                arguments: [
                    "conversation_id": id.uuidString, "instructions": "No", "expected_revision": app.tools.revision,
                ], origin: .voice))
        app.externalControlEnabled = false
        XCTAssertThrowsError(try app.tools.execute("get_session", arguments: [:], origin: .external))
    }
    @MainActor func testVoiceNavigationIsDeferredAndCancelledWithTurn() throws {
        let root = TestScratch.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = makeApp(root: root, preferences: makePreferences(named: "automation-tests-" + root.lastPathComponent))
        let id = try XCTUnwrap(app.selectedID)
        _ = app.turn.begin(.generating)
        _ = try app.tools.execute(
            "prepare_expression", arguments: ["conversation_id": id.uuidString, "text": "Let me think."],
            origin: .voice)
        XCTAssertFalse(app.practice)
        XCTAssertNotNil(app.deferredToolAction)
        XCTAssertThrowsError(
            try app.tools.execute(
                "prepare_expression", arguments: ["conversation_id": id.uuidString, "text": "Overwrite this"],
                origin: .voice))
        XCTAssertNil(app.conversation?.helpDraft)
        app.stop()
        XCTAssertNil(app.deferredToolAction)
        XCTAssertFalse(app.practice)
    }
    @MainActor func testADeferredPreparationIsCancelledWhenTheLanguageChanges() throws {
        let root = TestScratch.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = makeApp(root: root, preferences: makePreferences(named: "automation-tests-" + root.lastPathComponent))
        let id = try XCTUnwrap(app.selectedID)
        let token = app.turn.begin(.generating)
        _ = try app.tools.execute(
            "prepare_expression", arguments: ["conversation_id": id.uuidString, "text": "Let me think."],
            origin: .voice)
        let index = try XCTUnwrap(app.library.conversations.firstIndex { $0.id == id })
        app.library.conversations[index].preferences.language = .match
        _ = app.turn.finish(token)
        let action = try XCTUnwrap(app.deferredToolAction)
        app.deferredToolAction = nil
        action()
        XCTAssertNil(app.conversation?.helpDraft, "Nothing is prepared for a language it was not asked in")
        XCTAssertFalse(app.practice)
        XCTAssertNotNil(app.error)
    }
    @MainActor func testAtomicFailureDoesNotChangeInstructionsOrExpressions() throws {
        let root = TestScratch.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = makeApp(root: root, preferences: makePreferences(named: "automation-tests-" + root.lastPathComponent))
        let id = try XCTUnwrap(app.selectedID)
        try Data("broken".utf8).write(to: app.store.file)
        XCTAssertFalse(app.setConversationInstructions(id, instructions: "New", preferences: ConversationPreferences()))
        XCTAssertEqual(app.conversation?.instructions, "")
        XCTAssertThrowsError(
            try app.tools.execute(
                "save_expression", arguments: ["conversation_id": id.uuidString, "text": "Hello"], origin: .voice))
        XCTAssertTrue(app.library.expressions.isEmpty)
    }
    @MainActor func testRequestUsesConversationInstructionsAndCustomizedEmptyChatIsNotReused() async throws {
        let root = TestScratch.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = makeApp(root: root, preferences: makePreferences())
        let id = try XCTUnwrap(app.selectedID)
        var prefs = ConversationPreferences()
        prefs.coaching = .direct
        prefs.speed = 0.8
        XCTAssertTrue(app.setConversationInstructions(id, instructions: "Interview me", preferences: prefs))
        var captured: ConversationRequest?
        app.speech.conversationReply = { _, request, callbacks in
            captured = request
            var reply = RealtimeAccumulator()
            reply.text = "Hello."
            try callbacks.response(reply)
        }
        app.draft = "Hello"
        app.send()
        await waitUntil { captured != nil }
        XCTAssertEqual(captured?.instructions, "Interview me")
        XCTAssertEqual(captured?.preferences.speed, 0.8)
        app.newChat()
        let second = try XCTUnwrap(app.selectedID)
        XCTAssertNotEqual(second, id)
        XCTAssertEqual(app.conversation?.instructions, "")
        XCTAssertTrue(
            app.setConversationInstructions(
                second, instructions: "Travel roleplay", preferences: ConversationPreferences()))
        app.newChat()
        XCTAssertNotEqual(app.selectedID, second)
        app.stop()
    }
    @MainActor func testExternalBusyAndModalWritesAreRejected() throws {
        let root = TestScratch.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = makeApp(root: root, preferences: makePreferences())
        app.externalControlEnabled = true
        let id = try XCTUnwrap(app.selectedID)
        for activity in [Activity.recording, .requestingPermission, .generating] {
            _ = app.turn.begin(activity)
            XCTAssertThrowsError(
                try app.tools.execute(
                    "save_expression",
                    arguments: [
                        "conversation_id": id.uuidString, "expected_revision": app.tools.revision, "text": "Hello",
                    ], origin: .external))
        }
        app.stop()
        app.customization.instructionsID = id
        XCTAssertThrowsError(
            try app.tools.execute(
                "save_expression",
                arguments: [
                    "conversation_id": id.uuidString, "expected_revision": app.tools.revision, "text": "Hello",
                ], origin: .external))
        app.customization.instructionsID = nil
        app.startHelp()
        XCTAssertThrowsError(
            try app.tools.execute(
                "prepare_expression",
                arguments: [
                    "conversation_id": id.uuidString, "expected_revision": app.tools.revision, "text": "Hello",
                ], origin: .external))
        XCTAssertTrue(app.library.expressions.isEmpty)
        app.externalControlEnabled = false
        app.stop()
    }
    @MainActor func testControlReplayCacheAndChangedArguments() throws {
        let root = TestScratch.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = makeApp(root: root, preferences: makePreferences())
        app.externalControlEnabled = true
        var revealed = 0
        // An assistant shows the workspace without taking the keyboard from the app the user is in.
        app.offerWorkspace = { revealed += 1 }
        app.revealWorkspace = { XCTFail("An external tool must not force Mochi in front") }
        var payload: [String: Any] = [
            "name": "create_conversation",
            "arguments": ["title": "Practice", "expected_revision": app.tools.revision], "request_id": "same",
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let first = app.tools.handleControlRequest(data)
        let count = app.library.conversations.count
        XCTAssertEqual(first, app.tools.handleControlRequest(data))
        XCTAssertEqual(count, app.library.conversations.count)
        XCTAssertEqual(revealed, 1)
        payload["arguments"] = ["title": "Other", "expected_revision": app.tools.revision]
        let changed =
            try JSONSerialization.jsonObject(
                with: app.tools.handleControlRequest(JSONSerialization.data(withJSONObject: payload))) as! [String: Any]
        XCTAssertEqual(changed["ok"] as? Bool, false)
        XCTAssertEqual(count, app.library.conversations.count)
        app.externalControlEnabled = false
        let disabled = try JSONSerialization.jsonObject(with: app.tools.handleControlRequest(data)) as! [String: Any]
        XCTAssertEqual(disabled["ok"] as? Bool, false)
    }
    @MainActor func testReadsAreBoundedAndWrongConversationCannotBeRead() throws {
        let root = TestScratch.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = makeApp(root: root, preferences: makePreferences())
        let id = try XCTUnwrap(app.selectedID)
        var chat = app.conversation!
        chat.messages = (0..<110).map { _ in Message(role: "user", text: String(repeating: "x", count: 10000)) }
        app.library.conversations = [chat, Conversation()]
        let result = try app.tools.execute(
            "get_messages", arguments: ["conversation_id": id.uuidString, "limit": 100], origin: .voice)
        let messages = result["messages"] as! [[String: Any]]
        XCTAssertGreaterThan(messages.count, 0)
        XCTAssertLessThanOrEqual(messages.count, 100)
        XCTAssertEqual(result["has_more"] as? Bool, true)
        XCTAssertEqual((messages[0]["text"] as! String).count, 2000)
        XCTAssertLessThan(try JSONSerialization.data(withJSONObject: result).count, LocalControl.maxFrame)
        XCTAssertThrowsError(
            try app.tools.execute(
                "get_messages", arguments: ["conversation_id": app.library.conversations[1].id.uuidString],
                origin: .voice))
        XCTAssertThrowsError(
            try app.tools.execute(
                "play_audio",
                arguments: ["conversation_id": id.uuidString, "message_id": chat.messages[0].id.uuidString],
                origin: .voice))
    }
    @MainActor func testDeferredPracticeOnlyRunsAfterReplyAndRejectsSecondNavigation() throws {
        let root = TestScratch.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = makeApp(root: root, preferences: makePreferences())
        let id = try XCTUnwrap(app.selectedID)
        let saved = try app.tools.execute(
            "save_expression", arguments: ["conversation_id": id.uuidString, "text": "Let me think."], origin: .voice
        )
        let token = app.turn.begin(.generating)
        let args: [String: Any] = ["conversation_id": id.uuidString, "expression_id": saved["expression_id"]!]
        let result = try app.tools.execute("start_practice", arguments: args, origin: .voice)
        XCTAssertEqual(result["status"] as? String, "scheduled_after_reply")
        XCTAssertFalse(app.practice)
        XCTAssertThrowsError(try app.tools.execute("start_practice", arguments: args, origin: .voice))
        let action = app.deferredToolAction
        app.deferredToolAction = nil
        _ = app.turn.finish(token)
        action?()
        XCTAssertTrue(app.practice)
        XCTAssertEqual(app.help.expression?.english, "Let me think.")
        app.stop()
    }

    @MainActor func testVoiceAcknowledgmentPlaysBeforePracticeAndStopCancelsNavigation() async throws {
        for cancel in [false, true] {
            let root = TestScratch.folder()
            defer { try? FileManager.default.removeItem(at: root) }
            let app = makeApp(root: root, preferences: makePreferences())
            let id = try XCTUnwrap(app.selectedID)
            let player = AutomationPlayer()
            app.audio.makePlayer = { _ in player }
            app.speech.conversationReply = { _, _, callbacks in
                _ = try app.tools.execute(
                    "prepare_expression", arguments: ["conversation_id": id.uuidString, "text": "Let me think."],
                    origin: .voice)
                var response = RealtimeAccumulator()
                response.text = "Let's practise."
                response.audio = Data(repeating: 0, count: 4800)
                try callbacks.response(response)
            }
            app.draft = "Let's practise"
            app.send()
            await waitUntil { app.turn.activity != .generating }
            XCTAssertEqual(app.turn.activity, .playing)
            XCTAssertFalse(app.practice)
            if cancel { app.stop() }
            app.audio.finishPlayback(player, successfully: true)
            XCTAssertEqual(app.practice, !cancel)
            app.stop()
        }
    }

}

extension AutomationTests {
    @MainActor func testBlankConversationReused() throws {
        let app = app()
        defer {
            app.externalControlEnabled = false
            app.stop()
            try? FileManager.default.removeItem(at: app.store.root)
        }
        app.externalControlEnabled = true
        let id = try XCTUnwrap(app.selectedID)
        let count = app.library.conversations.count
        XCTAssertFalse(app.automationModal)
        let result = try app.tools.execute(
            "create_conversation", arguments: ["title": "   ", "expected_revision": app.tools.revision],
            origin: .external)
        XCTAssertEqual(result["conversation_id"] as? String, id.uuidString)
        XCTAssertEqual(app.library.conversations.count, count)
        XCTAssertFalse(app.conversation!.customTitle)
    }

    @MainActor func testBlankChatReusePreservesPinDateAndIntroduction() throws {
        let app = app()
        defer {
            app.externalControlEnabled = false
            app.stop()
            try? FileManager.default.removeItem(at: app.store.root)
        }
        app.externalControlEnabled = true
        let id = try XCTUnwrap(app.selectedID)
        let date = Date(timeIntervalSince1970: 1234)
        app.library.conversations[0].pinned = true
        app.library.conversations[0].date = date
        app.library.conversations[0].voiceIntroduced = true
        _ = try app.tools.execute(
            "create_conversation", arguments: ["title": "Practice", "expected_revision": app.tools.revision],
            origin: .external)
        XCTAssertEqual(app.selectedID, id)
        XCTAssertTrue(app.conversation!.pinned)
        XCTAssertEqual(app.conversation!.date, date)
        XCTAssertTrue(app.conversation!.voiceIntroduced)
    }

    @MainActor func testDraftProtectedAndCancelledPreparationNeverWrites() throws {
        let app = app()
        defer {
            app.stop()
            try? FileManager.default.removeItem(at: app.store.root)
        }
        let id = try XCTUnwrap(app.selectedID)
        let args: [String: Any] = ["conversation_id": id.uuidString, "text": "New sentence"]
        app.library.conversations[0].helpDraft = HelpDraft(
            meaning: "My thought", english: "My draft", recording: "recording.wav")
        XCTAssertThrowsError(try app.tools.execute("prepare_expression", arguments: args, origin: .voice))
        XCTAssertEqual(app.conversation?.helpDraft?.english, "My draft")
        app.library.conversations[0].helpDraft = nil
        _ = app.turn.begin(.generating)
        _ = try app.tools.execute("prepare_expression", arguments: args, origin: .voice)
        XCTAssertNil(app.conversation?.helpDraft)
        app.stop()
        XCTAssertNil(app.conversation?.helpDraft)
    }

    @MainActor func testForeignOversizedInstructionsRetainedButRequestAndToolsBounded() async throws {
        let app = app()
        defer {
            app.stop()
            try? FileManager.default.removeItem(at: app.store.root)
        }
        let original = String(repeating: "文", count: 9000)
        app.library.conversations[0].instructions = original
        try app.store.save(app.library)
        XCTAssertEqual(try app.store.load().conversations[0].instructions, original)
        let session = try app.tools.execute("get_session", arguments: [:], origin: .voice)
        XCTAssertEqual((session["instructions"] as? String)?.count, 1000)
        XCTAssertEqual(session["instructions_truncated"] as? Bool, true)
        var captured: ConversationRequest?
        app.speech.conversationReply = { _, request, callbacks in
            captured = request
            var reply = RealtimeAccumulator()
            reply.text = "Hello."
            try callbacks.response(reply)
        }
        app.draft = "Hello"
        app.send()
        await waitUntil { captured != nil }
        XCTAssertEqual(captured?.instructions.count, 8000)
        XCTAssertEqual(app.conversation?.instructions, original)
    }

    @MainActor func testSheetAndAssistantShareValidationAndKeepOversizedLegacyInstructions() throws {
        let app = controlledApp()
        let id = try XCTUnwrap(app.selectedID)
        let legacy = String(repeating: "文", count: 9000)
        app.library.conversations[0].instructions = legacy
        try app.store.save(app.library)
        var preferences = ConversationPreferences()
        preferences.coaching = .direct
        XCTAssertTrue(
            app.setConversationInstructions(id, instructions: legacy, preferences: preferences, characterName: " Loki ")
        )
        XCTAssertEqual(app.conversation?.instructions, legacy)
        XCTAssertEqual(app.conversation?.characterName, "Loki")
        XCTAssertFalse(
            app.setConversationInstructions(
                id, instructions: legacy, preferences: preferences, characterName: "Bad\nName"))
        XCTAssertEqual(app.conversation?.characterName, "Loki")
        XCTAssertThrowsError(
            try app.tools.execute(
                "set_conversation_instructions",
                arguments: [
                    "conversation_id": id.uuidString, "character_name": "Bad\nName",
                    "expected_revision": app.tools.revision,
                ], origin: .external))
        XCTAssertEqual(app.conversation?.characterName, "Loki")
        _ = try app.tools.execute(
            "set_conversation_preferences",
            arguments: ["conversation_id": id.uuidString, "speed": 0.9, "expected_revision": app.tools.revision],
            origin: .external)
        XCTAssertEqual(app.conversation?.preferences.speed, 0.9)
        XCTAssertEqual(app.conversation?.preferences.coaching, .direct)
    }

    @MainActor func testReadResultsNameTheirLibraryTextFields() throws {
        let app = controlledApp()
        let id = try XCTUnwrap(app.selectedID)
        let session = try app.tools.execute("get_session", arguments: [:], origin: .external)
        XCTAssertEqual(
            Set(session["untrusted_fields"] as? [String] ?? []),
            [
                "title", "instructions", "character_name", "display_character_name", "personality", "greeting",
                "phrases",
            ])
        let messages = try app.tools.execute(
            "get_messages", arguments: ["conversation_id": id.uuidString], origin: .external)
        XCTAssertEqual(messages["untrusted_fields"] as? [String], ["messages.text"])
        let template = try app.tools.execute(
            "get_conversation_template", arguments: ["template_id": ConversationTemplate.builtins[0].id.uuidString],
            origin: .external)
        XCTAssertTrue((template["untrusted_fields"] as? [String] ?? []).contains("template.instructions"))
    }

    @MainActor func testLongMultibyteMessageIsShortenedNotDropped() throws {
        let app = app()
        defer {
            app.stop()
            try? FileManager.default.removeItem(at: app.store.root)
        }
        let id = try XCTUnwrap(app.selectedID)
        let text = String(repeating: "我", count: 2000)
        app.append(Message(role: "user", text: text), to: id)
        let voice = try app.tools.execute("get_messages", arguments: ["conversation_id": id.uuidString], origin: .voice)
        let messages = try XCTUnwrap(voice["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1)
        let shown = try XCTUnwrap(messages.first?["text"] as? String)
        XCTAssertFalse(shown.isEmpty)
        XCTAssertTrue(text.hasPrefix(shown))
        XCTAssertEqual(messages.first?["text_truncated"] as? Bool, true)
        XCTAssertLessThanOrEqual(try JSONSerialization.data(withJSONObject: messages[0]).count, 6000)
        XCTAssertEqual(voice["has_more"] as? Bool, false)

        app.externalControlEnabled = true
        defer { app.externalControlEnabled = false }
        let external = try app.tools.execute(
            "get_messages", arguments: ["conversation_id": id.uuidString], origin: .external)
        let whole = try XCTUnwrap((external["messages"] as? [[String: Any]])?.last)
        XCTAssertEqual(whole["text"] as? String, text)
        XCTAssertEqual(whole["text_truncated"] as? Bool, false)
    }

    @MainActor func testLongMultibyteExpressionIsShortenedNotDropped() throws {
        let app = app()
        defer {
            app.stop()
            try? FileManager.default.removeItem(at: app.store.root)
        }
        let id = try XCTUnwrap(app.selectedID)
        let english = String(repeating: "我", count: 1000)
        let meaning = String(repeating: "意", count: 1000)
        app.library.expressions = [
            PracticeExpression(conversationID: id, meaning: meaning, english: english, language: .english)
        ]
        let result = try app.tools.execute(
            "search_expressions", arguments: ["conversation_id": id.uuidString, "query": ""], origin: .voice)
        let expressions = try XCTUnwrap(result["expressions"] as? [[String: Any]])
        XCTAssertEqual(expressions.count, 1)
        XCTAssertEqual(expressions.first?["text_truncated"] as? Bool, true)
        XCTAssertTrue(english.hasPrefix(try XCTUnwrap(expressions.first?["text"] as? String)))
        XCTAssertLessThanOrEqual(try JSONSerialization.data(withJSONObject: expressions[0]).count, 6000)
    }

    @MainActor func testPauseResumeAndRecentExpressionOrdering() throws {
        let app = app()
        defer {
            app.stop()
            try? FileManager.default.removeItem(at: app.store.root)
        }
        let id = try XCTUnwrap(app.selectedID)
        let first = try app.tools.execute(
            "save_expression", arguments: ["conversation_id": id.uuidString, "text": "First"], origin: .voice)
        let last = try app.tools.execute(
            "save_expression", arguments: ["conversation_id": id.uuidString, "text": "Last"], origin: .voice)
        let search = try app.tools.execute(
            "search_expressions", arguments: ["conversation_id": id.uuidString, "query": "", "limit": 1], origin: .voice
        )
        let found = try XCTUnwrap((search["expressions"] as? [[String: Any]])?.first)
        XCTAssertEqual(found["id"] as? String, last["expression_id"] as? String)
        XCTAssertNotEqual(first["expression_id"] as? String, last["expression_id"] as? String)
        app.externalControlEnabled = true
        let player = CountingPlayer()
        app.audio.makePlayer = { _ in player }
        app.play("fixture.wav")
        _ = try app.tools.execute(
            "pause_audio", arguments: ["conversation_id": id.uuidString, "expected_revision": app.tools.revision],
            origin: .external)
        XCTAssertTrue(app.audio.paused)
        _ = try app.tools.execute(
            "resume_audio", arguments: ["conversation_id": id.uuidString, "expected_revision": app.tools.revision],
            origin: .external)
        XCTAssertFalse(app.audio.paused)
        XCTAssertEqual(player.starts, 2)
        app.externalControlEnabled = false
    }

    @MainActor func testResumeThatCannotRestartPlaybackFails() throws {
        let app = app()
        defer {
            app.externalControlEnabled = false
            app.stop()
            try? FileManager.default.removeItem(at: app.store.root)
        }
        let id = try XCTUnwrap(app.selectedID)
        app.externalControlEnabled = true
        let player = FailingResumePlayer()
        app.audio.makePlayer = { _ in player }
        app.play("fixture.wav")
        _ = try app.tools.execute(
            "pause_audio", arguments: ["conversation_id": id.uuidString, "expected_revision": app.tools.revision],
            origin: .external)
        XCTAssertTrue(app.audio.paused)
        XCTAssertThrowsError(
            try app.tools.execute(
                "resume_audio",
                arguments: ["conversation_id": id.uuidString, "expected_revision": app.tools.revision],
                origin: .external))
        XCTAssertNil(app.playbackFile)
    }

    @MainActor func testVoiceRetryCachesCompletedMutationButNotCancelledNavigation() throws {
        let app = app()
        defer {
            app.stop()
            try? FileManager.default.removeItem(at: app.store.root)
        }
        let id = try XCTUnwrap(app.selectedID)
        let operation = UUID()
        let args: [String: Any] = ["conversation_id": id.uuidString, "speed": 0.8]
        _ = try app.tools.executeVoice("set_conversation_preferences", arguments: args, operationID: operation)
        app.library.conversations[0].preferences.speed = 1.0
        let replay = try app.tools.executeVoice("set_conversation_preferences", arguments: args, operationID: operation)
        XCTAssertEqual(replay["status"] as? String, "previously_completed")
        XCTAssertEqual(app.conversation?.preferences.speed, 1.0)
        _ = app.turn.begin(.generating)
        let prepare: [String: Any] = ["conversation_id": id.uuidString, "text": "Let me think."]
        _ = try app.tools.executeVoice("prepare_expression", arguments: prepare, operationID: operation)
        app.stop()
        XCTAssertNil(app.conversation?.helpDraft)
        let token = app.turn.begin(.generating)
        _ = try app.tools.executeVoice("prepare_expression", arguments: prepare, operationID: operation)
        let action = app.deferredToolAction
        app.deferredToolAction = nil
        _ = app.turn.finish(token)
        action?()
        XCTAssertTrue(app.practice)
        XCTAssertEqual(app.conversation?.helpDraft?.english, "Let me think.")
        app.leavePractice()
        for _ in 0..<140 {
            _ = try app.tools.executeVoice("set_conversation_preferences", arguments: args, operationID: UUID())
        }
        XCTAssertEqual(app.automation.voiceResults.count, 128)
    }

    @MainActor func testVoiceRetryOfScheduledActionIsNotRefused() throws {
        let app = app()
        defer {
            app.stop()
            try? FileManager.default.removeItem(at: app.store.root)
        }
        let id = try XCTUnwrap(app.selectedID)
        let operation = UUID()
        let args: [String: Any] = ["conversation_id": id.uuidString, "text": "Let me think."]
        _ = app.turn.begin(.generating)
        let first = try app.tools.executeVoice("prepare_expression", arguments: args, operationID: operation)
        XCTAssertEqual(first["status"] as? String, "scheduled_after_reply")
        let retry = try app.tools.executeVoice("prepare_expression", arguments: args, operationID: operation)
        XCTAssertEqual(retry["status"] as? String, "scheduled_after_reply")
        XCTAssertThrowsError(
            try app.tools.executeVoice(
                "prepare_expression", arguments: ["conversation_id": id.uuidString, "text": "Something else"],
                operationID: operation))
        app.stop()
        XCTAssertNil(app.deferredToolAction)
        _ = app.turn.begin(.generating)
        let rescheduled = try app.tools.executeVoice("prepare_expression", arguments: args, operationID: operation)
        XCTAssertEqual(rescheduled["status"] as? String, "scheduled_after_reply")
        XCTAssertNotNil(app.deferredToolAction)
    }

    @MainActor func testDeferredNavigationAndPlaybackRejectNewModal() throws {
        for name in ["start_practice", "play_audio", "seek_audio"] {
            let app = app()
            defer {
                app.stop()
                try? FileManager.default.removeItem(at: app.store.root)
            }
            let id = try XCTUnwrap(app.selectedID)
            var item = PracticeExpression(conversationID: id, meaning: "", english: "Hello", language: .english)
            item.reference = "fixture.wav"
            app.library.expressions = [item]
            try PCM.wav(Data(repeating: 0, count: 4800)).write(to: app.store.root.appendingPathComponent("fixture.wav"))
            var args: [String: Any] = ["conversation_id": id.uuidString, "expression_id": item.id.uuidString]
            if name == "seek_audio" { args["seconds"] = 1 }
            let token = app.turn.begin(.generating)
            _ = try app.tools.executeVoice(name, arguments: args, operationID: UUID())
            let action = app.deferredToolAction
            app.deferredToolAction = nil
            _ = app.turn.finish(token)
            app.history.managerOpen = true
            action?()
            XCTAssertFalse(app.practice)
            XCTAssertNil(app.playbackFile)
            XCTAssertNotNil(app.error)
            XCTAssertTrue(app.automation.voiceResults.isEmpty)
        }
    }

    @MainActor func testFailedAcknowledgmentStillOpensPreparedExpression() async throws {
        let app = app()
        defer {
            app.stop()
            try? FileManager.default.removeItem(at: app.store.root)
        }
        let id = try XCTUnwrap(app.selectedID)
        let player = CountingPlayer()
        app.audio.makePlayer = { _ in player }
        app.speech.conversationReply = { _, _, callbacks in
            _ = try app.tools.execute(
                "prepare_expression", arguments: ["conversation_id": id.uuidString, "text": "A sentence."],
                origin: .voice)
            var reply = RealtimeAccumulator()
            reply.text = "Ready."
            reply.audio = Data(repeating: 0, count: 4800)
            try callbacks.response(reply)
        }
        app.draft = "Prepare a sentence"
        app.send()
        await waitUntil { app.turn.activity != .generating }
        XCTAssertEqual(app.turn.activity, .playing)
        XCTAssertFalse(app.practice)
        app.audio.finishPlayback(player, successfully: false)
        XCTAssertTrue(app.practice)
        XCTAssertEqual(app.conversation?.helpDraft?.english, "A sentence.")
    }

    @MainActor private func app() -> AppModel {
        makeApp(root: TestScratch.folder("mochi-automation"), preferences: makePreferences())
    }

    @MainActor private func controlledApp() -> AppModel {
        let app = makeApp(root: makeTemporaryFolder())
        app.externalControlEnabled = true
        addTeardownBlock { @MainActor in app.externalControlEnabled = false }
        return app
    }
}
