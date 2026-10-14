import AppKit
import MochiCore
import MochiKernel
import MochiProviders

/// Help Me Say This: from a thought to English, an example to listen to, and practice attempts.
extension AppModel {
    func openExpressions() {
        find.close()
        cancelHelpWork()
        leavePractice()
        help.expression = nil
        showExpressions = true
    }
    /// Help Me Say This finds words in the language being practised; a conversation that matches the user's
    /// language has none.
    var canHelp: Bool { writableConversation && conversation?.preferences.language.isPractised == true }
    func startHelp() {
        guard canHelp else { return }
        let cancelledReply = !practice && task != nil && turn.activity == .generating
        cancelHelpWork()
        error = nil
        turn.pause()
        showExpressions = false
        help.isSavedPractice = false
        let saved = conversation?.helpDraft
        help.restoring {
            help.meaning = saved?.meaning ?? draft
            help.english = saved?.english ?? ""
            help.thoughtRecording = saved?.recording
            help.clarification = saved?.clarification
            help.recognizedThought = saved?.transcriptReview
            help.expression = saved?.expressionID.flatMap { id in library.expressions.first(where: { $0.id == id }) }
        }
        help.stage = help.english.isEmpty || help.recognizedThought != nil ? .thought : .english
        help.referencePitch = []
        help.clearAttempt()
        notice =
            cancelledReply
            ? String(localized: "Your pending reply was cancelled. You can retry it when you return.") : nil
        recordingWarning = nil
        if let recording = help.thoughtRecording { warnIfQuiet(recording) }
        persistHelpDraft()
    }
    /// Decodes the restored thought off the main actor; the warning applies only if that recording is still current.
    private func warnIfQuiet(_ recording: String) {
        let url = store.root.appendingPathComponent(recording)
        Task { [weak self] in
            let quiet = await Task.detached(priority: .utility) { () -> Bool in
                guard let samples = try? AudioFile.samples(url).samples else { return false }
                return RecordingSignal(samples: samples).isQuiet
            }.value
            guard let self, quiet, help.thoughtRecording == recording, turn.activity != .recording else { return }
            recordingWarning = String(
                localized: "This recording is very quiet. Listen before transcribing, or record it again.")
        }
    }
    /// Typing in an existing draft is written after a pause; every other change is written at once,
    /// because callers such as recording replacement delete files only after the new state is saved.
    @discardableResult func persistHelpDraft(typing: Bool = false) -> Bool {
        guard case (let ci, let draft)? = currentHelpDraft() else { return false }
        if typing, library.conversations[ci].helpDraft != nil {
            updateLibraryQuietly { $0.conversations[ci].helpDraft = draft }
            scheduleSave()
            return true
        }
        library.conversations[ci].helpDraft = draft
        return save()
    }
    /// Puts the help draft into the library without writing it, for a caller that saves once afterwards.
    func stageHelpDraft() {
        guard case (let ci, let draft)? = currentHelpDraft() else { return }
        library.conversations[ci].helpDraft = draft
    }
    /// The help draft to keep and its conversation, or nil when there is none.
    func currentHelpDraft() -> (Int, HelpDraft)? {
        guard !help.isRestoring, !help.isSavedPractice, practice, writableConversation,
            let ci = library.conversations.firstIndex(where: { $0.id == selectedID })
        else { return nil }
        var draft = HelpDraft(
            meaning: help.meaning, english: help.english, recording: help.thoughtRecording,
            expressionID: help.expression?.id)
        draft.clarification = help.clarification
        draft.transcriptReview = help.recognizedThought
        return (ci, draft)
    }
    func editThought() {
        help.stage = .thought
        error = nil
    }
    func beginPractice() {
        guard !help.english.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        ensureExpression()
        help.stage = .practice
        persistHelpDraft()
    }
    func reviewEnglish() { if !help.english.isEmpty { help.stage = .english } }
    func transcribeThought() {
        guard !busy, let recording = help.thoughtRecording else { return }
        let transcribe = speech.transcribe
        let model = settings.effectiveModelName
        let url = store.root.appendingPathComponent(recording)
        runExclusive("Transcribe thought", progress: "Transcribing your thought…") { [weak self] job in
            guard let self else { return }
            // Thoughts are spoken in any language and keep no evidence; they use today's transcription model.
            let text = try await transcribe(url, model, RealtimeService.transcriptionModel).text
            guard job.isCurrent() else { return }
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else {
                throw AppFailure("No clear speech was recognized. Your thought is saved; listen or record again.")
            }
            if help.meaning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                help.meaning = clean
            } else {
                help.recognizedThought = clean
            }
            job.finish()
            notice = String(localized: "Check the recognized thought before finding the words.")
        }
    }
    func useRecognizedThought(replace: Bool) {
        guard !busy, let recognized = help.recognizedThought else { return }
        help.meaning =
            replace || help.meaning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? recognized : help.meaning + "\n" + recognized
        help.recognizedThought = nil
        notice = String(localized: "Check your thought before finding the words.")
    }
    func discardThoughtRecording() {
        help.thoughtRecording = nil
        recordingWarning = nil
    }
    func translate() { findEnglish(alternative: false) }
    func tryAnotherWording() { findEnglish(alternative: true) }
    private func findEnglish(alternative: Bool) {
        let input = help.meaning.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, !busy, let id = selectedID else { return }
        let history = conversation?.messages ?? []
        let service = settings.conversationService()
        let requestText =
            alternative && !help.english.isEmpty
            ? "Intended thought: \(input)\nPrevious wording: \(help.english)\nOffer a different natural wording with exactly the same meaning."
            : input
        let textReply = speech.textReply
        let preferences = conversation?.preferences ?? ConversationPreferences()
        runExclusive("Find the words", progress: "Finding the words…") { [weak self] job in
            guard let self else { return }
            let result = try await textReply(
                service,
                ConversationRequest(history: history, text: requestText, help: true, preferences: preferences))
            guard job.isCurrent() else { return }
            let suggestion = try HelpSuggestion.parse(result)
            if suggestion.kind == .clarification {
                help.clarification = suggestion.text
                help.stage = .thought
            } else {
                help.english = suggestion.text.trimmingCharacters(in: .whitespacesAndNewlines)
                help.expression = PracticeExpression(
                    conversationID: id, meaning: input, english: help.english, language: language(of: id))
                help.referencePitch = []
                help.clearAttempt()
                help.clarification = nil
                help.stage = .english
            }
            help.progress = nil
            persistHelpDraft()
        }
    }
    func editEnglish(_ text: String) {
        help.english = text
        if help.expression?.english != text {
            help.expression = nil
            help.referencePitch = []
            help.clearAttempt()
        }
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && help.stage == .thought {
            help.stage = .english
        }
        persistHelpDraft()
    }
    func ensureExpression() {
        guard let id = selectedID else { return }
        if help.expression == nil {
            help.expression = PracticeExpression(
                conversationID: id, meaning: help.meaning,
                english: help.english.trimmingCharacters(in: .whitespacesAndNewlines), language: language(of: id))
        }
    }
    @discardableResult func saveExpression() -> Bool {
        ensureExpression()
        // The thought can be edited after the expression was created; save what the user now sees.
        let thought = help.meaning.trimmingCharacters(in: .whitespacesAndNewlines)
        if let current = help.expression, current.meaning != thought { help.expression?.meaning = thought }
        guard let saved = help.expression, !saved.english.isEmpty else { return false }
        help.expression?.review = library.storeExpression(saved).review
        stageHelpDraft()
        return save()
    }
    func render(force: Bool = false) {
        guard !busy, !help.english.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        ensureExpression()

        let text = help.english
        let label = settings.practiceVoiceLabel
        let root = store.root
        let referenceAudio = speech.referenceAudio
        let service = settings.practiceService()
        runExclusive("Create example", progress: "Creating your example…") { [weak self] job in
            guard let self else { return }
            let url = try await referenceAudio(text, service, root, force)
            let pitch = try await AudioFile.pitchInBackground(url)
            guard job.isCurrent() else { return }
            help.expression?.reference = url.lastPathComponent
            help.expression?.referenceKind = label
            help.referencePitch = pitch
            let saved = saveExpression()
            job.finish()
            // A failed save is already reported; the reference is not announced as ready when it was not kept.
            if saved { notice = String(localized: "Your reference is ready. Listen, then try saying it yourself.") }
        }
    }

    /// - Parameter settingsTab: the Settings tab that shows a failure; nil for a preview in a sheet, which shows
    ///   `voicePreviewFailed` itself.
    func previewBuiltIn(_ voice: String, options: OpenAIVoiceOptions? = nil, settingsTab: SettingsTab? = .voices) {
        // Previews are cached beside the library; an unreadable library folder must stay untouched.
        guard !busy, libraryReadable else { return }
        voicePreviewFailed = false
        let service = settings.practiceService(voice: voice, options: options)
        let root = store.root
        let referenceAudio = speech.referenceAudio
        previewEpoch = runExclusive(
            "Preview voice", settingsTab: settingsTab,
            onFailure: { [weak self] in self?.voicePreviewFailed = true },
            { [weak self] job in
                guard let self else { return }
                let url = try await referenceAudio(ReferenceSpeech.preview, service, root, false)
                guard job.isCurrent() else { return }
                job.finish()
                play(
                    url.lastPathComponent, afterPlaybackFailure: { [weak self] in self?.voicePreviewFailed = true },
                    settingsTab: settingsTab)
                if playbackFile == url.lastPathComponent { previewEpoch = turn.epoch }
            })
    }
    var canImportReference: Bool { !busy && !help.english.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    func importReference() {
        guard canImportReference, let source = presentPanel(.importReference) else { return }
        importReference(from: source)
    }
    func importReference(from source: URL) {
        // An expression without English cannot be saved, so the copied file would be left unreferenced.
        guard canImportReference else { return }
        ensureExpression()
        runExclusive("Import reference") { [weak self] job in
            guard let self else { return }
            let pitch = try await AudioFile.pitchInBackground(source)
            guard job.isCurrent() else { return }
            let name = LibraryStore.importedAudioName(extension: source.pathExtension)
            try FileManager.default.copyItem(at: source, to: store.root.appendingPathComponent(name))
            help.expression?.reference = name
            help.expression?.referenceKind = "Imported reference"
            help.referencePitch = pitch
            saveExpression()
        }
    }
    func resume() {
        let hadDraft = currentHelpDraft() != nil
        let draftKept = cancelHelpWork()
        let hasEnglish = !help.english.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let completed = hasEnglish && saveExpression()
        // When nothing could be saved, practice stays open with the work on screen and the save failure reported,
        // instead of closing and claiming it was saved.
        guard completed || (!hasEnglish && (draftKept || !hadDraft)) else { return }
        if completed, !help.isSavedPractice, let ci = library.conversations.firstIndex(where: { $0.id == selectedID }) {
            let saved = library.conversations[ci].helpDraft
            library.conversations[ci].helpDraft = nil
            if save() {
                help.restoring {
                    help.thoughtRecording = nil
                    help.recognizedThought = nil
                }
                removeUnreferencedRecording(saved?.recording)
            } else {
                // The draft could not be cleared: practice stays open, so Resume can be tried again.
                library.conversations[ci].helpDraft = saved
                return
            }
        }
        leavePractice()
        help.expression = nil
        notice =
            completed
            ? String(localized: "Saved to My Expressions. Say the thought in your own words when you're ready.")
            : draftKept ? String(localized: "Help draft saved.") : nil
    }
    /// Opens a saved expression for practice; false when it could not be opened.
    @discardableResult func openExpression(_ opened: PracticeExpression) -> Bool {
        guard let (item, sourceID) = practiceHome(for: opened) else { return false }
        if sourceID == selectedID { cancelHelpWork() } else { stop() }
        leavePractice()
        help.isSavedPractice = true
        selectedID = sourceID
        history.scope = .active
        history.query = ""
        draft = conversation?.draft ?? ""
        showExpressions = false
        turn.pause()
        help.restoring {
            help.expression = item
            help.english = item.english
            help.meaning = item.meaning
            help.thoughtRecording = nil
            help.recognizedThought = nil
            // Left from an earlier help draft, it would ask about another thought.
            help.clarification = nil
        }
        help.stage = .practice
        help.referencePitch = []
        help.clearAttempt()
        analyseSavedAudio(of: item)
        return true
    }
    /// The expression and the conversation to practise it in. One whose conversation is gone gets a new one, in the
    /// expression's own language, and is pointed at it; nil when that cannot be saved.
    private func practiceHome(for opened: PracticeExpression) -> (PracticeExpression, UUID)? {
        var item = opened
        guard !library.conversations.contains(where: { $0.id == item.conversationID && !$0.isDeleted && !$0.archived })
        else { return (item, item.conversationID) }
        var candidate = library
        var chat = Conversation(title: "Practice: " + String(item.english.prefix(42)))
        chat.preferences.language = item.language ?? ConversationPreferences().language
        candidate.conversations.insert(chat, at: 0)
        candidate.selectedConversationID = chat.id
        // Point the expression at its new home, so reopening it does not create yet another conversation.
        item.conversationID = chat.id
        if let index = candidate.expressions.firstIndex(where: { $0.id == item.id }) {
            candidate.expressions[index].conversationID = chat.id
        }
        guard commitHistory(candidate) else { return nil }
        return (item, chat.id)
    }
    /// Analyses the saved example and latest attempt, and checks the attempt's words. Each contour is analysed on its
    /// own, so one unreadable file does not hide the other; the first failure is reported once both are tried.
    private func analyseSavedAudio(of item: PracticeExpression) {
        let root = store.root
        let reference = item.reference
        let attempt = item.attempts.last?.file
        runExclusive("Open saved expression") { [weak self] job in
            guard let self else { return }
            var failure: Error?
            func contour(_ name: String) async -> [PitchPoint]? {
                do { return try await AudioFile.pitchInBackground(root.appendingPathComponent(name)) } catch {
                    failure = failure ?? error
                    return nil
                }
            }
            if let name = reference, let points = await contour(name) {
                guard job.isCurrent() else { return }
                help.referencePitch = points
            }
            guard job.isCurrent() else { return }
            if let name = attempt {
                if let points = await contour(name) {
                    guard job.isCurrent() else { return }
                    help.attemptPitch = points
                }
                guard job.isCurrent() else { return }
                await checkAttempt(name, of: item, job: job)
                guard job.isCurrent() else { return }
            }
            if let failure { throw failure }
        }
    }
}
