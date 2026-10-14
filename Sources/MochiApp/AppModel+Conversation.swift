import AppKit
import MochiCore
import MochiKernel
import MochiProviders

/// The conversation itself: sending text and voice, replies, transcription and the spoken greeting.
extension AppModel {
    /// False when the conversation is gone or the library could not be saved; the save failure is already reported.
    @discardableResult func append(_ message: Message, to id: UUID) -> Bool {
        guard let i = library.conversations.firstIndex(where: { $0.id == id }) else { return false }
        if !library.conversations[i].customTitle
            && !library.conversations[i].messages.contains(where: { $0.role == "user" }) && message.role == "user"
            && !message.text.isEmpty
        {
            library.conversations[i].title = String(message.text.prefix(42))
        }
        library.conversations[i].messages.append(message)
        return save()
    }
    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        submit(text, fromComposer: true)
    }
    /// Whether a phrase can be sent now; the same conditions as Send, apart from the composer.
    var canSendPhrase: Bool { !busy && !practice && writableConversation && libraryReadable }
    /// Sends one of the conversation's phrases as the user's message, exactly as shown. The composer and its draft
    /// are left alone, whether the phrase is sent or not.
    func sendPhrase(_ phrase: String) {
        let text = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        submit(text, fromComposer: false)
    }
    /// Start Again needs something to start again from: a message the model can read. It is off while My Expressions
    /// covers the conversation, where the restart and its reply would happen out of sight.
    var canStartAgain: Bool {
        canSendPhrase && !showExpressions
            && conversation?.messages.contains { $0.role == "user" && $0.contextText != nil } == true
    }
    /// Whether the conversation was made from a role-play template, which shows Start Again as a button.
    var isRolePlay: Bool { ConversationTemplate.isRolePlay(conversation?.sourceTemplateID) }
    /// Asks to redo the conversation's exercise (plan W3). The request is the user's message, sent with the
    /// conversation's opening as well as its latest messages, so a scenario set up long ago is still there. The
    /// instructions make Mochi state the scenario and wait for the user to confirm it before beginning.
    func startAgain() {
        guard canStartAgain else { return }
        submit(String(localized: "Let's start again from the beginning."), fromComposer: false, restart: true)
    }
    /// Adds `text` as the user's message and asks for a reply. Nothing is added when the message cannot be saved.
    private func submit(_ text: String, fromComposer: Bool, restart: Bool = false) {
        guard !busy, !practice, writableConversation, libraryReadable, let id = selectedID else { return }
        if conversation?.characterNameNeedsReview == true {
            error =
                fromComposer
                ? String(
                    localized:
                        "Review the character name in Conversation Instructions before sending. Your draft is kept.")
                : String(localized: "Review the character name in Conversation Instructions before sending.")
            return
        }
        notice = nil
        let messages = conversation?.messages ?? []
        let history = restart ? RestartHistory.select(messages) : messages
        error = nil
        let typed = draft
        let before = library.conversations.first { $0.id == id }
        // Cleared first, so the save that writes the message also writes the empty composer.
        if fromComposer { draft = "" }
        var message = Message(role: "user", text: text)
        if restart { message.startsAgain = true }
        guard append(message, to: id) else {
            // Nothing is sent: the unsaved message leaves memory, so memory never holds a message the disk lacks,
            // and a typed draft returns to the composer. The save failure is already reported.
            if let before, let i = library.conversations.firstIndex(where: { $0.id == id }) {
                library.conversations[i] = before
            }
            if fromComposer { draft = typed }
            return
        }
        requestReply(history: history, text: text, pcm: nil, audioFile: nil, conversationID: id)
    }
    var canRetry: Bool {
        guard writableConversation, !busy, !practice, let last = conversation?.messages.last, last.role == "user" else {
            return false
        }
        return !transcribingMessageIDs.contains(last.id)
    }
    func retryReply() {
        guard canRetry, let chat = conversation, let last = chat.messages.last else { return }
        if chat.characterNameNeedsReview {
            error = String(localized: "Review the character name in Conversation Instructions before retrying.")
            return
        }
        do {
            let pcm =
                try last.contextText == nil
                ? last.audio.map { try AudioFile.pcm(store.root.appendingPathComponent($0)) } : nil
            // A retried Start Again keeps its opening, also after Mochi restarts.
            let earlier = Array(chat.messages.dropLast())
            requestReply(
                history: last.startsAgain == true ? RestartHistory.select(earlier) : earlier,
                text: last.text,
                pcm: pcm, audioFile: last.audio,
                conversationID: chat.id, existingUserID: last.id)
        } catch {
            self.error = String(localized: "The saved recording could not be read. Record a new message to continue.")
        }
    }
    /// Renames the recording of a voice message that could not be saved to a name Mochi never generates, so launch
    /// cleanup keeps it; returns that name, or nil when there is no such recording or it could not be renamed.
    private func keepUnsentRecording(_ name: String?) -> String? {
        guard let name, URL(fileURLWithPath: name).lastPathComponent == name else { return nil }
        let source = store.root.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: source.path) else { return nil }
        let stamp = Date().formatted(
            .verbatim(
                "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)).\(minute: .twoDigits).\(second: .twoDigits)",
                timeZone: .current, calendar: Calendar(identifier: .gregorian)))
        let kept = "Unsent voice message \(stamp) \(UUID().uuidString.prefix(8)).wav"
        do {
            try FileManager.default.moveItem(at: source, to: store.root.appendingPathComponent(kept))
            return kept
        } catch {
            MochiLog.failure(MochiLog.library, "Keep unsent recording", error, level: .info)
            return nil
        }
    }
    func requestReply(
        history: [Message], text: String, pcm: Data?, audioFile: String?, conversationID: UUID,
        existingUserID: UUID? = nil
    ) {
        if let existingUserID, transcribingMessageIDs.contains(existingUserID) { return }
        // Cleared first, so a failure to save the voice message below stays visible.
        error = nil
        var userID = existingUserID
        if pcm != nil && userID == nil {
            var message = Message(role: "user", text: "", audio: audioFile)
            message.recording = RecordingMetadata(model: RealtimeService.transcriptionModel)
            message.transcriptionState = .pending
            let before = library.conversations.first { $0.id == conversationID }
            guard append(message, to: conversationID) else {
                // Nothing is transcribed or sent, as for a typed message: the unsaved message leaves memory, so
                // memory never holds a message the disk lacks. Its recording, referenced by nothing, is kept under a
                // name launch cleanup leaves alone, so the learner can still find it.
                if let before, let i = library.conversations.firstIndex(where: { $0.id == conversationID }) {
                    library.conversations[i] = before
                }
                if let kept = keepUnsentRecording(audioFile) {
                    error = String(
                        localized:
                            "Your voice message could not be saved, so it was not sent. Its recording is kept in the data folder as “\(kept)”."
                    )
                } else {
                    error = String(
                        localized:
                            "Your voice message could not be saved, so it was not sent. Check the disk and the data folder, then record it again."
                    )
                }
                return
            }
            userID = message.id
        }
        let operationID =
            userID ?? library.conversations.first(where: { $0.id == conversationID })?.messages.last?.id ?? UUID()
        var requestID = UUID()
        if let userID, pcm != nil {
            requestID = transcripts.begin(userID)
            // A new message was saved as pending when it was added; a retried one is marked pending again here.
            if existingUserID != nil {
                updateTranscript(userID, chatID: conversationID, text: nil, state: .pending, error: nil)
            }
        }
        let token = turn.begin(.generating)
        let chat = library.conversations.first { $0.id == conversationID }
        let instructions = ConversationInstructions.bounded(chat?.instructions ?? "")
        let personality = chat?.personality ?? ""
        let preferences = chat?.preferences ?? ConversationPreferences()
        let characterName = chat?.characterName
        let userName = settings.effectiveUserName
        let speakerName = chat?.displayCharacterName ?? "Mochi"
        let service = settings.conversationService(for: chat)
        let voiceID = pcm == nil ? nil : userID
        // A voice message is transcribed with the model it was recorded with, also when its reply is retried.
        let transcriptionModel =
            userID.flatMap { id in chat?.messages.first(where: { $0.id == id })?.recording?.model }
            ?? RealtimeService.transcriptionModel
        let reply = speech.conversationReply
        let operation = Task { [weak self] in
            guard let self else { return }
            defer {
                if turn.epoch == token { task = nil }
                if let voiceID, transcripts.isCurrent(voiceID, requestID) {
                    interruptPendingTranscript(voiceID, chatID: conversationID)
                    transcripts.finish(voiceID, requestID)
                }
            }
            do {
                let callbacks = ReplyCallbacks(
                    response: { [weak self] reply in
                        guard let self, !Task.isCancelled, turn.epoch == token else { return }
                        task = nil
                        let filename = saveReply(reply, conversationID: conversationID, speakerName: speakerName)
                        _ = turn.finish(token)
                        if reply.truncated {
                            notice =
                                "\(speakerName)’s reply reached its length limit and was cut short. Ask a follow-up to continue."
                        }
                        playReplyThenDeferredAction(filename)
                    },
                    transcription: { [weak self] reply in
                        guard let self, !Task.isCancelled, let voiceID, transcripts.isCurrent(voiceID, requestID) else {
                            return
                        }
                        updateTranscript(
                            voiceID, chatID: conversationID,
                            text: reply.inputTranscript.isEmpty ? nil : reply.inputTranscript,
                            evidence: reply.inputEvidence, state: reply.transcriptionState,
                            error: reply.transcriptionError)
                    },
                    tool: { [weak self] name, args, _ in
                        guard let self, !Task.isCancelled, self.turn.epoch == token, self.selectedID == conversationID
                        else { throw CancellationError() }
                        return try self.tools.executeVoice(name, arguments: args, operationID: operationID)
                    })
                var request = ConversationRequest(
                    history: history, text: text, pcm: pcm, spoken: audioFile != nil, instructions: instructions,
                    characterName: characterName, userName: userName, preferences: preferences,
                    personality: personality)
                request.transcriptionModel = transcriptionModel
                try await reply(service, request, callbacks)
            } catch {
                // The deferred block marks a still-pending transcript as interrupted.
                if turn.epoch == token { deferredToolAction = nil }
                fail(error, token: token, context: "Conversation reply")
            }
        }
        task = operation
        if let voiceID { transcripts.attach(operation, to: voiceID) }
    }
    /// Writes the reply's audio and appends the reply; returns the audio file when one was written.
    /// The reply text is kept even when its audio cannot be written. A failed library save is reported by `save()`
    /// and is not overwritten, so the error never claims an unsaved reply was saved.
    private func saveReply(_ reply: RealtimeAccumulator, conversationID: UUID, speakerName: String) -> String? {
        var filename: String?
        var audioFailure: Error?
        if !reply.audio.isEmpty {
            let name = "reply-\(UUID().uuidString).wav"
            do {
                try writeReplyAudio(PCM.wav(reply.audio), store.root.appendingPathComponent(name))
                filename = name
            } catch { audioFailure = error }
        }
        var appended = true
        if filename != nil || !reply.text.isEmpty {
            appended = append(
                Message(role: "assistant", text: reply.text, audio: filename, speakerName: speakerName),
                to: conversationID)
        }
        guard let audioFailure, appended else { return filename }
        if reply.text.isEmpty {
            // An audio-only reply has nothing left to save once its audio is lost.
            error = persistenceMessage(
                audioFailure, action: "Save reply audio",
                fallback:
                    "\(speakerName)’s reply could not be saved because its audio file could not be written. Retry the reply.",
                diskFull:
                    "\(speakerName)’s reply could not be saved because the disk is full. Free some space, then retry the reply."
            )
        } else {
            error = persistenceMessage(
                audioFailure, action: "Save reply audio",
                fallback:
                    "\(speakerName)’s reply was saved without its audio because the audio file could not be written.",
                diskFull:
                    "\(speakerName)’s reply was saved without its audio because the disk is full. Free some space before the next reply."
            )
        }
        return filename
    }
    /// Plays the reply, then runs any tool action that waited for it.
    private func playReplyThenDeferredAction(_ filename: String?) {
        let action = deferredToolAction
        deferredToolAction = nil
        guard let filename else {
            action?()
            return
        }
        if let playReply {
            playReply(filename)
            action?()
        } else if let action {
            play(filename, mochi: true, afterPlayback: action, afterPlaybackFailure: action)
        } else {
            play(filename, mochi: true)
        }
    }
    private func interruptPendingTranscript(_ messageID: UUID, chatID: UUID) {
        guard
            library.conversations.first(where: { $0.id == chatID })?.messages.first(where: { $0.id == messageID })?
                .transcriptionState == .pending
        else { return }
        updateTranscript(
            messageID, chatID: chatID, text: nil, state: .interrupted,
            error: String(localized: "Transcription was interrupted. Your recording is saved."))
    }
    /// False when the message is gone or the library could not be saved; the save failure is already reported.
    /// A new `text` replaces the text and its evidence together: `evidence` when it is for exactly that text, else
    /// none, as for an edit. Without a new text, both stay as they are.
    @discardableResult private func updateTranscript(
        _ messageID: UUID, chatID: UUID, text: String?, evidence: TranscriptEvidence? = nil,
        state: TranscriptionState, error: String?
    ) -> Bool {
        guard let ci = library.conversations.firstIndex(where: { $0.id == chatID && !$0.isDeleted && !$0.archived }),
            let mi = library.conversations[ci].messages.firstIndex(where: { $0.id == messageID })
        else { return false }
        if let text {
            library.conversations[ci].messages[mi].text = text
            library.conversations[ci].messages[mi].transcriptEvidence = evidence?.text == text ? evidence : nil
        }
        library.conversations[ci].messages[mi].transcriptionState = state
        library.conversations[ci].messages[mi].transcriptionError = error
        if let text, !text.isEmpty, !library.conversations[ci].customTitle,
            library.conversations[ci].messages.first(where: { $0.role == "user" })?.id == messageID
        {
            library.conversations[ci].title = String(text.prefix(42))
        }
        return save()
    }
    func retryTranscription(_ messageID: UUID) {
        guard writableConversation, !busy,
            let chat = conversation,
            let message = chat.messages.first(where: { $0.id == messageID && $0.role == "user" }),
            let file = message.audio,
            !transcribingMessageIDs.contains(messageID)
        else { return }
        let jobID = transcripts.begin(messageID)
        let chatID = chat.id
        updateTranscript(messageID, chatID: chatID, text: nil, state: .pending, error: nil)
        let transcribe = speech.transcribe
        let model = settings.effectiveModelName
        let transcriptionModel = message.recording?.model ?? RealtimeService.transcriptionModel
        let url = store.root.appendingPathComponent(file)
        let job = Task { [weak self] in
            guard let self else { return }
            defer { transcripts.finish(messageID, jobID) }
            do {
                let result = try await transcribe(url, model, transcriptionModel)
                guard !Task.isCancelled, transcripts.isCurrent(messageID, jobID) else { return }
                let clean = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !clean.isEmpty else {
                    throw AppFailure(
                        "No clear speech was recognized. Your recording is saved; add text or record again.")
                }
                updateTranscript(
                    messageID, chatID: chatID, text: clean, evidence: result.evidence, state: .completed, error: nil)
            } catch {
                guard !Task.isCancelled, transcripts.isCurrent(messageID, jobID) else { return }
                MochiLog.failure(MochiLog.network, "Retry transcription", error)
                updateTranscript(
                    messageID, chatID: chatID, text: nil, state: .failed,
                    error: AppFailure.message(
                        for: error,
                        fallback: "Transcription could not finish. Your recording is saved; retry or add text."))
            }
        }
        transcripts.attach(job, to: messageID)
    }
    func cancelTranscription(_ messageID: UUID) {
        transcripts.cancel(messageID)
        if let chatID = conversation?.id {
            updateTranscript(messageID, chatID: chatID, text: nil, state: .interrupted, error: nil)
        }
    }
    /// False when the transcript could not be saved; the failure is in `error`.
    @discardableResult func editTranscript(_ messageID: UUID, text: String) -> Bool {
        guard writableConversation, let chatID = conversation?.id else { return false }
        cancelTranscription(messageID)
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return updateTranscript(
            messageID, chatID: chatID, text: clean, state: clean.isEmpty ? .failed : .completed, error: nil)
    }
    func toggleConversationVoice() {
        guard !practice, writableConversation, libraryReadable else { return }
        if turn.activity != .recording, !greetingActive, conversation?.characterNameNeedsReview == true {
            error = String(localized: "Review the character name in Conversation Instructions before recording.")
            return
        }
        if greetingActive {
            stop()
            beginRecording(forMeaning: false)
            return
        }
        guard !busy || turn.activity == .recording else { return }
        guard turn.activity != .recording, let chat = conversation, chat.greetsBeforeRecording, let id = selectedID
        else {
            beginRecording(forMeaning: false)
            return
        }
        let token = turn.begin(.requestingPermission)
        greetingActive = true
        error = nil
        let speakerName = chat.displayCharacterName
        let spoken = Greetings.spoken(
            chat.preferences.language, interface: Bundle.main.preferredLocalizations.first ?? "en")
        // The conversation's own greeting is spoken exactly as written; without one, a standard greeting is.
        let setup = chat.greeting.trimmingCharacters(in: .whitespacesAndNewlines)
        let service = settings.conversationService(for: chat)
        task = Task { [self] in
            do {
                let allowed: Bool
                allowed = await media.permission()
                guard !Task.isCancelled, turn.epoch == token else { return }
                guard allowed else {
                    throw AppFailure(
                        "Microphone access is off. Enable Mochi in System Settings → Privacy & Security → Microphone.")
                }
                // Each asynchronous stage is guarded by its epoch; Stop invalidates either stage.
                let generationToken = turn.begin(.generating)
                let recent = settings.recentGreetings
                let greeting =
                    setup.isEmpty
                    ? VoiceIdentity.namedGreeting(
                        name: speakerName, language: spoken.language, script: spoken.script, excluding: recent)
                    : (text: setup, pattern: nil)
                let text = greeting.text
                do {
                    let url = try await speech.referenceAudio(text, service, store.root, false)
                    guard !Task.isCancelled, turn.epoch == generationToken, selectedID == id,
                        !practice, writableConversation,
                        let index = library.conversations.firstIndex(where: { $0.id == id })
                    else { return }
                    library.conversations[index].messages.append(
                        Message(role: "assistant", text: text, audio: url.lastPathComponent, speakerName: speakerName))
                    library.conversations[index].voiceIntroduced = true
                    guard save() else {
                        library.conversations[index].messages.removeLast()
                        library.conversations[index].voiceIntroduced = false
                        greetingActive = false
                        _ = turn.finish(generationToken)
                        return
                    }
                    if let pattern = greeting.pattern { settings.recentGreetings = recent + [pattern] }
                    task = nil
                    _ = turn.finish(generationToken)
                    play(
                        url.lastPathComponent, mochi: true,
                        afterPlayback: { [weak self] in
                            guard let self, self.greetingActive, self.selectedID == id, !self.practice,
                                self.writableConversation
                            else { return }
                            self.greetingActive = false
                            self.beginRecording(forMeaning: false)
                        })
                } catch {
                    guard (error as? AppFailure)?.underlying is ReferenceSpeech.Mismatch else {
                        fail(error, token: generationToken, context: "Voice greeting")
                        return
                    }
                    // The practice-example wording of this failure would mislead here.
                    fail(
                        AppFailure(
                            verbatim: setup.isEmpty
                                ? String(localized: "\(speakerName)’s greeting could not be prepared. Try again.")
                                : String(
                                    localized:
                                        "\(speakerName) could not say this greeting exactly. Try again, or shorten the greeting in Conversation Instructions."
                                ), underlying: error), token: generationToken, context: "Voice greeting")
                }
            } catch { fail(error, token: token, context: "Microphone permission") }
        }
    }
    func checkConnection() {
        guard !busy else { return }
        serviceStatus = String(localized: "Checking…")
        let service = settings.conversationService()
        let textReply = speech.textReply
        runExclusive(
            "Check connection", settingsTab: .general,
            onFailure: { [weak self] in self?.serviceStatus = String(localized: "Not connected") },
            { [weak self] job in
                guard let self else { return }
                _ = try await textReply(
                    service, ConversationRequest(history: [], text: "Reply with the single word ready."))
                guard job.isCurrent() else { return }
                serviceStatus = String(localized: "Verified · text response received")
            })
    }
}
