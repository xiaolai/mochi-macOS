import MochiCore
import MochiKernel
import MochiProviders
import XCTest

@testable import MochiApp

private final class SilentPlayer: PlaybackPlayer {
    var duration: TimeInterval = 5
    var currentTime: TimeInterval = 0
    var enableRate = false
    var rate: Float = 1
    func play() -> Bool { true }
    func pause() {}
    func stop() {}
}

/// Who the companion is and how a conversation opens: per-conversation voice and personality, the greeting, phrase
/// chips, characters, and the paths that copy settings between setups.
final class CompanionModelTests: XCTestCase {
    @MainActor private func app() -> AppModel {
        let app = makeApp(root: makeTemporaryFolder("mochi-companion"))
        addTeardownBlock { @MainActor in app.stop() }
        return app
    }
    /// Distinct values for every setting, so a copy that drops one is caught.
    private func sentinel<Settings: ConversationSettingsHolder>(_ settings: inout Settings) {
        settings.instructions = "Sentinel instructions"
        settings.characterName = "Sentinel"
        settings.personality = "Sentinel personality"
        settings.greeting = "Sentinel greeting?"
        settings.phrases = ["Sentinel one.", "Sentinel two."]
        settings.preferences.speed = 0.85
        settings.preferences.coaching = .gentle
        settings.preferences.language = .german
        settings.preferences.voice = "verse"
    }
    private func assertSentinel(
        _ settings: some ConversationSettingsHolder, _ label: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(settings.instructions, "Sentinel instructions", label, file: file, line: line)
        XCTAssertEqual(settings.characterName, "Sentinel", label, file: file, line: line)
        XCTAssertEqual(settings.personality, "Sentinel personality", label, file: file, line: line)
        XCTAssertEqual(settings.greeting, "Sentinel greeting?", label, file: file, line: line)
        XCTAssertEqual(settings.phrases, ["Sentinel one.", "Sentinel two."], label, file: file, line: line)
        XCTAssertEqual(settings.preferences.speed, 0.85, label, file: file, line: line)
        XCTAssertEqual(settings.preferences.coaching, .gentle, label, file: file, line: line)
        XCTAssertEqual(settings.preferences.language, .german, label, file: file, line: line)
        XCTAssertEqual(settings.preferences.voice, "verse", label, file: file, line: line)
    }

    // MARK: Voice and personality

    @MainActor func testRepliesUseTheConversationsVoiceAndPersonality() async throws {
        let app = app()
        app.settings.conversationVoice = "marin"
        let id = try XCTUnwrap(app.selectedID)
        var services: [RealtimeService] = []
        var requests: [ConversationRequest] = []
        app.speech.conversationReply = { service, request, callbacks in
            services.append(service)
            requests.append(request)
            var reply = RealtimeAccumulator()
            reply.text = "Sure."
            try callbacks.response(reply)
        }
        func send(_ text: String) async {
            let before = services.count
            app.draft = text
            app.send()
            await waitUntil { services.count == before + 1 && !app.busy }
        }
        await send("No voice of its own")
        XCTAssertEqual(services.last?.voice, "marin")
        var draft = ConversationSettingsDraft(try XCTUnwrap(app.conversation))
        draft.preferences.voice = "cedar"
        draft.personality = "Brisk and curious."
        XCTAssertTrue(app.saveConversationSettings(id, draft))
        await send("Its own voice")
        XCTAssertEqual(services.last?.voice, "cedar")
        XCTAssertEqual(requests.last?.personality, "Brisk and curious.")
        XCTAssertTrue(requests.last?.resolvedInstructions.contains("Brisk and curious.") == true)
        // A voice this version does not know is kept, and the Settings voice speaks instead.
        app.library.conversations[0].preferences.voice = "future_voice"
        await send("Imported voice")
        XCTAssertEqual(services.last?.voice, "marin")
        XCTAssertEqual(app.conversation?.preferences.voice, "future_voice")
    }

    /// The connection check and Help Me Say This produce no speech, so they keep the Settings voice.
    @MainActor func testTextOnlyRequestsKeepTheSettingsVoice() async throws {
        let app = app()
        app.settings.conversationVoice = "ash"
        app.library.conversations[0].preferences.voice = "cedar"
        app.library.conversations[0].preferences.language = .spanish
        var voices: [String] = []
        app.speech.textReply = { service, _ in
            voices.append(service.voice)
            return #"{"kind":"expression","text":"Hola"}"#
        }
        app.checkConnection()
        await waitUntil { voices.count == 1 && !app.busy }
        app.startHelp()
        app.help.meaning = "hello"
        app.translate()
        await waitUntil { voices.count == 2 && !app.busy }
        XCTAssertEqual(voices, ["ash", "ash"])
    }

    // MARK: Greeting

    @MainActor func testTheGreetingIsTheConversationsOwnSpokenInItsVoice() async throws {
        let app = app()
        app.library.conversations[0].greeting = "Where does our story begin?"
        app.library.conversations[0].preferences.voice = "coral"
        app.settings.recentGreetings = []
        var spoken: [(String, String)] = []
        app.media.permission = { true }
        app.media.record = { _ in }
        app.audio.makePlayer = { _ in SilentPlayer() }
        app.speech.referenceAudio = { text, _, service, root, _ in
            spoken.append((text, service.voice))
            return root.appendingPathComponent("greeting.wav")
        }
        XCTAssertEqual(app.microphoneLabel, "Start Voice Conversation")
        app.toggleConversationVoice()
        await waitUntil { app.turn.activity == .playing }
        XCTAssertEqual(spoken.map(\.0), ["Where does our story begin?"])
        XCTAssertEqual(spoken.map(\.1), ["coral"])
        XCTAssertEqual(app.conversation?.messages.first?.text, "Where does our story begin?")
        XCTAssertEqual(app.conversation?.messages.first?.role, "assistant")
        XCTAssertEqual(app.settings.recentGreetings, [], "Only standard greetings are remembered for variety")
    }

    /// Typing first means the conversation has started: the first microphone use records at once, with no greeting.
    @MainActor func testATypedConversationIsNeverGreetedMidway() async throws {
        let app = app()
        app.library.conversations[0].greeting = "Who will you be talking to?"
        app.library.conversations[0].messages = [Message(role: "user", text: "I already started")]
        var greetings = 0
        var recordings = 0
        app.media.permission = { true }
        app.media.record = { _ in recordings += 1 }
        app.speech.referenceAudio = { _, _, _, root, _ in
            greetings += 1
            return root.appendingPathComponent("greeting.wav")
        }
        XCTAssertEqual(app.microphoneLabel, "Record Voice Message")
        app.toggleConversationVoice()
        await waitUntil { app.turn.activity == .recording }
        XCTAssertEqual(greetings, 0)
        XCTAssertEqual(recordings, 1)
        XCTAssertEqual(app.conversation?.messages.count, 1)
    }

    /// A greeting that cannot be read back exactly is the user's text to shorten, not a practice example to retry.
    @MainActor func testAGreetingThatCannotBeSpokenExactlySaysSo() async throws {
        let app = app()
        app.library.conversations[0].greeting = "A long and awkward greeting."
        app.media.permission = { true }
        app.speech.referenceAudio = { _, _, _, _, _ in
            throw AppFailure("The example did not match the sentence exactly.", underlying: ReferenceSpeech.Mismatch())
        }
        app.toggleConversationVoice()
        await waitUntil { app.turn.activity == .idle && app.error != nil }
        XCTAssertEqual(
            app.error,
            "Mochi could not say this greeting exactly. Try again, or shorten the greeting in Conversation Instructions."
        )
        XCTAssertTrue(app.conversation?.messages.isEmpty == true)
        XCTAssertFalse(app.conversation?.voiceIntroduced == true, "Still retryable")
    }

    // MARK: Phrase chips

    @MainActor func testAPhraseIsSentExactlyAndTheComposerKeepsItsDraft() async throws {
        let app = app()
        app.library.conversations[0].phrases = ["Give it an ending."]
        var requests: [ConversationRequest] = []
        app.speech.conversationReply = { _, request, callbacks in
            requests.append(request)
            var reply = RealtimeAccumulator()
            reply.text = "And so it ended."
            try callbacks.response(reply)
        }
        app.draft = "A half-written thought"
        app.sendPhrase("Give it an ending.")
        await waitUntil { requests.count == 1 && !app.busy }
        XCTAssertEqual(requests.first?.text, "Give it an ending.")
        XCTAssertEqual(app.conversation?.messages.map(\.role), ["user", "assistant"])
        XCTAssertEqual(app.conversation?.messages.first?.text, "Give it an ending.")
        XCTAssertEqual(app.draft, "A half-written thought")
        XCTAssertEqual(app.conversation?.draft, "A half-written thought")
    }

    @MainActor func testABlockedPhraseAddsNothing() async throws {
        let app = app()
        app.draft = "Keep me"
        // A character name that needs review blocks sending, with a reason.
        app.library.conversations[0].characterName = "Bad\nName"
        app.sendPhrase("Add a twist.")
        XCTAssertEqual(app.conversation?.messages.count, 0)
        XCTAssertEqual(app.error, "Review the character name in Conversation Instructions before sending.")
        XCTAssertEqual(app.draft, "Keep me")
        app.library.conversations[0].characterName = nil
        app.error = nil
        // While Mochi is busy, nothing is sent.
        _ = app.turn.begin(.generating)
        XCTAssertFalse(app.canSendPhrase)
        app.sendPhrase("Add a twist.")
        XCTAssertEqual(app.conversation?.messages.count, 0)
        app.turn.stop()
        // A message that cannot be saved is not kept in memory either.
        try FileManager.default.removeItem(at: app.store.root)
        try Data("not a folder".utf8).write(to: app.store.root)
        app.sendPhrase("Add a twist.")
        XCTAssertEqual(app.conversation?.messages.count, 0)
        XCTAssertEqual(app.draft, "Keep me")
        XCTAssertNotNil(app.error)
    }

    // MARK: Copying settings

    /// Every setting survives each path between setups: the instructions sheet, Save as Template and back, the
    /// template editor, the picker, a duplicate, and an external assistant reusing an empty conversation.
    @MainActor func testEveryCopyPathCarriesEverySetting() throws {
        let app = app()
        let id = try XCTUnwrap(app.selectedID)
        var draft = ConversationSettingsDraft(id: id)
        sentinel(&draft)
        app.customization.instructionsID = id
        app.saveConversationAsTemplate(id, draft: draft)
        let editor = try XCTUnwrap(app.customization.templateDraft)
        assertSentinel(editor.value, "Save as Template draft")
        app.customization.templateDraft?.value.title = "Sentinel template"
        try app.saveTemplateDraft(asNew: false)
        let saved = try XCTUnwrap(app.library.conversationTemplates.first)
        assertSentinel(saved, "saved template")
        XCTAssertEqual(app.customization.retainedInstructionsDraft, draft, "Closing the editor returns to the draft")
        XCTAssertTrue(app.saveConversationSettings(id, draft))
        assertSentinel(try XCTUnwrap(app.conversation), "conversation sheet save")
        app.customization = CustomizationSheet()

        // Editing the template clears what the draft cleared and keeps the rest.
        app.customization.showTemplates(.manager)
        app.customization.editTemplate(saved)
        app.customization.templateDraft?.value.preferences.voice = nil
        app.customization.templateDraft?.value.phrases = []
        try app.saveTemplateDraft(asNew: false)
        let edited = try XCTUnwrap(app.library.conversationTemplates.first)
        XCTAssertNil(edited.preferences.voice)
        XCTAssertEqual(edited.phrases, [])
        XCTAssertEqual(edited.personality, "Sentinel personality")
        app.customization.editTemplate(saved, duplicate: true)
        try app.saveTemplateDraft(asNew: false)
        assertSentinel(try XCTUnwrap(app.library.conversationTemplates.last), "duplicate")
        app.customization = CustomizationSheet()

        app.openTemplatePicker()
        app.customization.previewTemplate(saved)
        let started = try app.startTemplateSnapshot(try XCTUnwrap(app.customization.templateDraft).value)
        assertSentinel(try XCTUnwrap(app.library.conversations.first { $0.id == started }), "picker start")

        // An external assistant creating a conversation reuses an untouched one, with every setting it sent.
        app.newChat()
        let blank = try XCTUnwrap(app.selectedID)
        XCTAssertTrue(try XCTUnwrap(app.conversation).isPristine)
        app.externalControlEnabled = true
        defer { app.externalControlEnabled = false }
        _ = try app.tools.execute(
            "create_conversation",
            arguments: [
                "instructions": "Sentinel instructions", "character_name": "Sentinel",
                "personality": "Sentinel personality", "greeting": "Sentinel greeting?",
                "phrases": ["Sentinel one.", "Sentinel two."], "speed": 0.85, "coaching": "gentle",
                "language": "de", "voice": "verse", "expected_revision": app.tools.revision,
            ], origin: .external)
        XCTAssertEqual(app.selectedID, blank)
        assertSentinel(try XCTUnwrap(app.conversation), "MCP reuse")
    }

    /// Any one new setting is a change on its own, through the same external entry point a client uses.
    @MainActor func testEachNewSettingAloneUpdatesThroughTheExternalEntryPoint() throws {
        let app = app()
        app.externalControlEnabled = true
        defer { app.externalControlEnabled = false }
        let id = try XCTUnwrap(app.selectedID).uuidString
        func call(_ name: String, _ arguments: [String: Any]) throws -> [String: Any] {
            let request = try JSONSerialization.data(withJSONObject: [
                "name": name, "arguments": arguments, "request_id": UUID().uuidString,
            ])
            return try XCTUnwrap(
                JSONSerialization.jsonObject(with: app.tools.handleControlRequest(request)) as? [String: Any])
        }
        func set(_ arguments: [String: Any]) throws -> [String: Any] {
            try call(
                "set_conversation_instructions",
                arguments.merging(["conversation_id": id, "expected_revision": app.tools.revision]) { _, new in new })
        }
        XCTAssertEqual(try set(["personality": "Calm"])["ok"] as? Bool, true)
        XCTAssertEqual(try set(["greeting": "Ready?"])["ok"] as? Bool, true)
        XCTAssertEqual(try set(["phrases": ["Again.", " Slower. "]])["ok"] as? Bool, true)
        XCTAssertEqual(try set(["voice": "sage"])["ok"] as? Bool, true)
        let chat = try XCTUnwrap(app.conversation)
        XCTAssertEqual(chat.personality, "Calm")
        XCTAssertEqual(chat.greeting, "Ready?")
        XCTAssertEqual(chat.phrases, ["Again.", "Slower."])
        XCTAssertEqual(chat.preferences.voice, "sage")
        XCTAssertEqual(try set(["voice": "sage", "clear_voice": true])["ok"] as? Bool, false)
        XCTAssertEqual(try set(["voice": "future_voice"])["ok"] as? Bool, false)
        XCTAssertEqual(try set(["phrases": (1...7).map { "P\($0)" }])["ok"] as? Bool, false)
        XCTAssertEqual(try set(["phrases": [3]])["ok"] as? Bool, false)
        XCTAssertEqual(try set(["clear_voice": true])["ok"] as? Bool, true)
        XCTAssertEqual(try set(["phrases": []])["ok"] as? Bool, true)
        XCTAssertNil(app.conversation?.preferences.voice)
        XCTAssertEqual(app.conversation?.phrases, [])
        // Templates take the same fields alone.
        let created = try call("create_conversation_template", ["title": "Only a greeting", "greeting": "Hi?"])
        let template = try XCTUnwrap(created["template"] as? [String: Any])
        XCTAssertEqual(template["greeting"] as? String, "Hi?")
        let updated = try call(
            "update_conversation_template",
            [
                "template_id": try XCTUnwrap(template["id"] as? String),
                "expected_template_revision": try XCTUnwrap(template["template_revision"] as? String),
                "phrases": ["One more."],
            ])
        XCTAssertEqual((updated["template"] as? [String: Any])?["phrases"] as? [String], ["One more."])
    }

    // MARK: Characters

    @MainActor func testCharactersAreCreatedEditedAndDeletedWithoutTouchingSetups() throws {
        let app = app()
        let rose = try app.characters.create(
            .init(name: "Rose", description: "Patient", personality: "Kind and slow.", voice: .set("sage")))
        XCTAssertEqual(app.library.characters, [rose])
        let id = try XCTUnwrap(app.selectedID)
        var draft = ConversationSettingsDraft(try XCTUnwrap(app.conversation))
        draft.adoptCharacter(rose)
        XCTAssertTrue(app.saveConversationSettings(id, draft))
        let edited = try app.characters.update(id: rose.id, revision: rose.revision, .init(personality: "Brisk."))
        XCTAssertThrowsError(try app.characters.update(id: rose.id, revision: rose.revision, .init(name: "Stale")))
        try app.characters.delete(id: edited.id, revision: edited.revision)
        XCTAssertTrue(app.library.characters.isEmpty)
        XCTAssertEqual(app.conversation?.personality, "Kind and slow.", "The conversation keeps its copy")
        XCTAssertEqual(app.conversation?.preferences.voice, "sage")
        let builtin = ConversationCharacter.builtins[1]
        XCTAssertThrowsError(try app.characters.update(id: builtin.id, revision: builtin.revision, .init(name: "X")))
        XCTAssertThrowsError(try app.characters.delete(id: builtin.id, revision: builtin.revision))
        XCTAssertThrowsError(try app.characters.create(.init(name: "Bad", voice: .set("future_voice"))))
    }

    /// Save as Character starts from the conversation's unsaved settings, and closing the editor returns to them.
    @MainActor func testSaveAsCharacterTakesTheUnsavedCompanionAndReturns() throws {
        let app = app()
        let id = try XCTUnwrap(app.selectedID)
        app.openConversationInstructions(id)
        var draft = ConversationSettingsDraft(try XCTUnwrap(app.conversation))
        draft.characterName = "Juno"
        draft.personality = "Dry wit."
        draft.preferences.voice = "echo"
        draft.instructions = "Unsaved instructions"
        app.saveConversationAsCharacter(id, draft: draft)
        XCTAssertEqual(app.customization.characterPresentation, .editor)
        let value = try XCTUnwrap(app.customization.characterDraft?.value)
        XCTAssertEqual(value.name, "Juno")
        XCTAssertEqual(value.personality, "Dry wit.")
        XCTAssertEqual(value.voice, "echo")
        app.customization.characterDraft?.value.description = "From a conversation"
        try app.saveCharacterDraft(asNew: false)
        XCTAssertEqual(app.library.characters.map(\.name), ["Juno"])
        XCTAssertNil(app.customization.characterPresentation)
        XCTAssertEqual(app.customization.instructionsID, id)
        XCTAssertEqual(app.customization.retainedInstructionsDraft?.instructions, "Unsaved instructions")
        XCTAssertEqual(app.conversation?.instructions, "", "Saving a character saves nothing else")
    }

    @MainActor func testStartingWithACharacterUsesItAndTheDefaultLanguage() throws {
        let app = app()
        app.settings.defaultLanguage = .korean
        app.openCharacterManager()
        XCTAssertEqual(app.customization.characterPresentation, .manager)
        let pip = ConversationCharacter.builtins[2]
        let id = try app.startConversation(with: pip)
        let chat = try XCTUnwrap(app.library.conversations.first { $0.id == id })
        XCTAssertEqual(app.selectedID, id)
        XCTAssertTrue(chat.hasCharacter(pip))
        XCTAssertEqual(chat.preferences.language, .korean)
        XCTAssertFalse(app.customization.isPresented)
        // Duplicating a built-in makes a new, editable character.
        app.openCharacterManager()
        app.customization.editCharacter(pip, duplicate: true)
        let copy = try XCTUnwrap(app.customization.characterDraft)
        XCTAssertNil(copy.editingID)
        XCTAssertNotEqual(copy.value.id, pip.id)
        XCTAssertFalse(copy.value.isBuiltin)
        try app.saveCharacterDraft(asNew: false)
        XCTAssertEqual(app.library.characters.map(\.name), ["Pip"])
        XCTAssertEqual(app.customization.characterPresentation, .manager, "The editor returns to the manager")
    }
}
