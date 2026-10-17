import AppKit
import MochiCore
import MochiKernel
import MochiProviders

struct MessageDeletionUndo {
    let conversationID: UUID
    let message: Message
    let index: Int
}

@MainActor @Observable final class AppModel {
    /// Persistence: the library value, saving, recovery and transfers.
    let libraryController: LibraryController
    var library: Library {
        get { libraryController.library }
        _modify { yield &libraryController.library }
        set { libraryController.library = newValue }
    }
    var store: LibraryStore { libraryController.store }
    var libraryRevision: UUID { libraryController.revision }
    var libraryReadable: Bool { libraryController.readable }
    var canRestorePreviousLibrary: Bool { libraryController.canRestorePrevious }
    var startupProgress: String? { libraryController.startupProgress }
    var libraryTransfer: String? { libraryController.transfer }
    var dataFolder: URL { libraryController.dataFolder }
    var hasPendingSave: Bool { libraryController.hasPendingSave }
    var saveDelay: UInt64 {
        get { libraryController.saveDelay }
        set { libraryController.saveDelay = newValue }
    }
    func updateLibraryQuietly(_ change: (inout Library) -> Void) { libraryController.updateQuietly(change) }
    @ObservationIgnored var deferredToolAction: (() -> Void)?
    @ObservationIgnored var revealWorkspace: (() -> Void)?
    /// Shows the workspace for an external assistant, leaving the keyboard with the app in front.
    @ObservationIgnored var offerWorkspace: (() -> Void)?
    /// Shows or hides the desktop Mochi to match the preference; set by the app delegate, which owns her window.
    @ObservationIgnored var updateDesktopPet: (() -> Void)?
    /// Shortcuts that work in every app.
    let shortcuts: ShortcutCenter
    /// When the Talk shortcut went down, and the recording request that press started, if any.
    @ObservationIgnored var talkPress: (time: Date, request: UUID?)?
    /// The request that started the recording now running: the turn of its microphone permission step.
    @ObservationIgnored var recordingRequest: UUID?
    /// When the microphone of `recordingRequest` opened.
    @ObservationIgnored var recordingStartedAt: Date?
    /// The reply audio playing for the first time, which an interruption may cut; nil once it ends or stops.
    @ObservationIgnored var unheardReply: String?
    /// The recording that started by itself after a reply; it is discarded if Mochi is locked or hidden meanwhile.
    @ObservationIgnored var unattendedRecording: UUID?
    /// The instructions or template sheet, and the drafts it edits.
    var customization = CustomizationSheet()
    var externalControlEnabled: Bool {
        get { settings.externalControlEnabled }
        set {
            settings.externalControlEnabled = newValue
            configureAutomation()
        }
    }
    /// The local control server and the caches that make tool calls safe to retry.
    let automation = AutomationController()
    @ObservationIgnored var allowDemoAutomation = false
    var selectedID: UUID? {
        didSet {
            guard oldValue != selectedID else { return }
            find.close()
            transcriptEditID = nil
        }
    }
    /// The voice message whose transcript the Edit Transcript sheet is correcting; listening pauses while it is open.
    var transcriptEditID: UUID?
    /// Find in the open conversation.
    let find = ConversationFind()
    var canFindInConversation: Bool {
        !practice && history.renameID == nil && history.permanentDeleteIDs.isEmpty
            && (history.managerOpen || (!showExpressions && conversation != nil))
    }
    func findInConversation() {
        guard canFindInConversation else { return }
        if history.managerOpen { history.searchFocusRequest += 1 } else { openConversationSearch() }
    }
    func openConversationSearch() {
        guard conversation != nil, !showExpressions, !practice else { return }
        find.open()
    }
    var showExpressions = false
    /// The history list and the edit in progress in its manager.
    var history = HistoryBrowser()
    var draft = "" {
        didSet {
            guard let i = library.conversations.firstIndex(where: { $0.id == selectedID }),
                library.conversations[i].draft != draft
            else { return }
            updateLibraryQuietly { $0.conversations[i].draft = draft }
            scheduleSave()
        }
    }
    /// Help Me Say This, as it is being worked on.
    let help = HelpSession()
    var recordingLevel: Float = -80
    var recordingWarning: String?
    var transcripts = TranscriptJobs()
    var transcribingMessageIDs: Set<UUID> { transcripts.messageIDs }
    @ObservationIgnored var speech: SpeechServices
    @ObservationIgnored var media: MediaServices
    @ObservationIgnored var recognition: RecognitionServices
    @ObservationIgnored var playReply: ((String) -> Void)?
    /// Writes a reply's audio file; replaceable so a failed audio write can be tested while the library still saves.
    @ObservationIgnored var writeReplyAudio: (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }
    var greetingActive = false
    @ObservationIgnored var recordingNow: () -> Date = Date.init
    @ObservationIgnored var recordingSleep: (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }
    var turn = TurnMachine() {
        didSet { if oldValue.activity != turn.activity { listeningTurnChanged(to: turn.activity) } }
    }
    /// Hands-free listening's state; the microphone follows it.
    var listening = ListeningMachine()
    /// Set when a listening session failed: the microphone button records one message at a time until listening
    /// is started again.
    var handsFreeFallback = false
    /// True while the screen is locked.
    var screenLocked = false
    /// True while the workspace is minimized, closed to the menu bar, or Mochi is hidden.
    var workspaceHidden = false
    /// True while an open or save panel covers the workspace.
    var panelOpen = false
    @ObservationIgnored var listeningServices: ListeningServices
    @ObservationIgnored let listeningRuntime = ListeningRuntime()
    /// The Start Listening request waiting for microphone permission.
    var listeningRequest: UUID?
    @ObservationIgnored var listeningNow: () -> Date = Date.init
    @ObservationIgnored var listeningSleep: (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }
    /// Writes a hands-free turn's recording; replaceable so a failed write can be tested.
    @ObservationIgnored var writeListeningTurn: (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }
    /// Shows whether the microphone is open for listening, in the menu bar; set by the app delegate.
    @ObservationIgnored var listeningIndicator: ((Bool) -> Void)?
    /// Any new error starts without a settings tab; `report(_:in:)` names the tab whose action caused it.
    var error: String? { didSet { errorTab = nil } }
    /// The Settings tab whose action set `error`, which is the only tab that shows it.
    private(set) var errorTab: SettingsTab?
    var notice: String? {
        didSet {
            if !noticeKeepsDeletionUndo { finishMessageDeletion() }
            noticeKeepsDeletionUndo = false
            scheduleNoticeDismissal()
        }
    }
    var messageDeletionUndo: MessageDeletionUndo?
    /// True only while the deletion notice itself is shown; any other notice ends the chance to undo.
    @ObservationIgnored private var noticeKeepsDeletionUndo = false
    func showMessageDeletedNotice() {
        noticeKeepsDeletionUndo = true
        notice = String(localized: "Message deleted.")
    }
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    /// The timer that will clear the current notice, so a caller can wait for it to run.
    var pendingNoticeDismissal: Task<Void, Never>? { noticeTask }
    @ObservationIgnored private var noticeRevision = UUID()
    @ObservationIgnored var noticeSleep: (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }
    private func scheduleNoticeDismissal() {
        noticeTask?.cancel()
        noticeTask = nil
        noticeRevision = UUID()
        guard notice != nil, !practice else { return }
        let revision = noticeRevision
        let sleep = noticeSleep
        let duration: UInt64 = messageDeletionUndo == nil ? 4_000_000_000 : 10_000_000_000
        noticeTask = Task { [weak self] in
            do { try await sleep(duration) } catch { return }
            guard !Task.isCancelled, let self, self.noticeRevision == revision else { return }
            self.notice = nil
        }
    }
    var playbackFile: String?
    /// The turn a voice preview owns, first while it is generated, then while it plays.
    var previewEpoch: UUID?
    /// True when the last voice preview failed; its message is in `error`. A sheet shows it beside its Preview button.
    var voicePreviewFailed = false
    var speaking = false
    var slow = false
    var settingsOpen = false
    var recordingSeconds = 0
    var recordingMeaning = false
    var serviceStatus = String(localized: "Not checked")
    /// Codex's sign-in and model list, read at launch and whenever Settings opens or the connection is checked.
    var codex = CodexStatus()
    /// The Codex check whose answer `codex` waits for; an older check that finishes later is ignored.
    @ObservationIgnored var codexCheck: UUID?
    /// The model text requests use now: the user's choice while Codex lists it, otherwise the lightest listed.
    /// The reasoning effort text requests use now: the user's choice while the model supports it, otherwise low.
    var textEffort: String? {
        textModel?.effort(selected: settings.textEffort.isEmpty ? nil : settings.textEffort)
    }
    var textModel: CodexModel? {
        codex.signInProblem == nil
            ? CodexModel.resolve(selected: settings.textModel.isEmpty ? nil : settings.textModel, in: codex.models)
            : nil
    }
    let settings: PreferencesStore
    var settingsTab = SettingsTab.general
    let audio: AudioController
    let demo: Bool
    /// A preview library created in the temporary folder for this launch, discarded on quit.
    let temporaryLibrary: Bool
    @ObservationIgnored var task: Task<Void, Never>?
    /// The job that currently owns the turn, so callers can await its end after cancelling it.
    var currentTask: Task<Void, Never>? { task }
    @ObservationIgnored var recordingClock: Task<Void, Never>?
    /// When the meter last heard sound in the current take, in seconds since it started.
    @ObservationIgnored var lastAudibleRecordingTime: Double = 0
    /// The recorder stops itself after this many seconds.
    static let recordingLimit: Double = 60
    /// How long the input must stay quiet before the take warns about it.
    static let quietWarningDelay: Double = 2
    @ObservationIgnored private var exclusiveTask: (token: UUID, task: Task<Void, Never>)?
    @ObservationIgnored var chooseFile: @MainActor (PanelRequest) -> URL? = FilePanels.choose
    /// Shows an open or save panel; hands-free listening pauses while it is up, as it does for a sheet.
    func presentPanel(_ request: PanelRequest) -> URL? {
        panelOpen = true
        refreshListeningConditions()
        defer {
            panelOpen = false
            refreshListeningConditions()
        }
        return chooseFile(request)
    }
    var conversation: Conversation? { library.conversations.first { $0.id == selectedID } }
    var writableConversation: Bool { conversation.map { !$0.archived && !$0.isDeleted } ?? false }
    var visibleChats: [Conversation] {
        library.history(
            in: history.scope, query: history.query, sort: settings.historySort, companion: history.character)
    }
    var busy: Bool { turn.activity != .idle }
    var practice: Bool { turn.mode == .practice }
    var status: String {
        switch turn.activity {
        case .recording:
            if recordingMeaning { return String(localized: "Recording your thought · finish to review") }
            return practice
                ? String(localized: "Recording your attempt · stays on this Mac")
                : String(localized: "Recording · finish to send to \(displayCharacterName)")
        case .requestingPermission: return String(localized: "Waiting for microphone permission")
        case .generating:
            if greetingActive { return String(localized: "Preparing \(displayCharacterName)’s greeting…") }
            return practice
                ? String(localized: "Preparing your expression…")
                : String(localized: "\(displayCharacterName) is thinking…")
        case .playing:
            if audio.paused { return String(localized: "Playback paused") }
            return speaking
                ? String(localized: "\(displayCharacterName) is speaking") : String(localized: "Playing your recording")
        case .idle:
            if let listeningStatus { return listeningStatus }
            return practice
                ? String(localized: "Conversation paused · microphone off")
                : String(localized: "Ready when you are · microphone off")
        }
    }
    /// - Parameter applicationSupport: where the managed library lives when `libraryRoot` is nil; tests pass a temporary folder.
    init(
        demo: Bool = false, libraryRoot: URL? = nil, preferences: UserDefaults? = nil, speech: SpeechServices? = nil,
        media: MediaServices? = nil, recognition: RecognitionServices? = nil,
        listeningServices: ListeningServices? = nil,
        applicationSupport: URL? = nil
    ) {
        InstanceEvidence.record("model-created")
        assert(!TestEnvironment.active || preferences != nil, "Tests must give AppModel isolated preferences.")
        self.demo = demo
        temporaryLibrary = demo && libraryRoot == nil
        let audio = AudioController()
        self.audio = audio
        self.media = media ?? .live(audio)
        self.speech = speech ?? .live
        self.recognition = recognition ?? .live
        self.listeningServices = listeningServices ?? .live(StreamingCapture())
        settings = PreferencesStore(
            preferences ?? (demo ? UserDefaults(suiteName: AppIdentity.bundleIdentifier + ".preview")! : .standard),
            importLegacy: !demo && libraryRoot == nil, allowExternalControl: !demo)
        // Previews and tests never take keys from other apps.
        shortcuts = ShortcutCenter(system: .live, enabled: !demo && !TestEnvironment.active)
        let support =
            applicationSupport ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let managed = !demo && libraryRoot == nil
        let root =
            libraryRoot
            ?? (demo
                ? FileManager.default.temporaryDirectory.appendingPathComponent("mochi-preview-\(UUID().uuidString)")
                : support.appendingPathComponent(AppIdentity.name))
        libraryController = LibraryController(root: root, demo: demo)
        libraryController.selection = { [weak self] in self?.selectedID }
        libraryController.report = { [weak self] in self?.error = $0 }
        libraryController.onChange = { [weak self] in self?.find.refresh() }
        find.matching = { [weak self] in self?.conversation?.matchingMessageIDs($0) ?? [] }
        help.persist = { [weak self] typing in self?.persistHelpDraft(typing: typing) ?? false }
        help.removeRecording = { [weak self] in self?.removeUnreferencedRecording($0) }
        shortcuts.bindings = { [weak self] in self?.settings.shortcuts ?? [:] }
        shortcuts.perform = { [weak self] action, pressed in self?.shortcutTriggered(action, pressed: pressed) }
        libraryController.open(managedIn: managed ? support : nil, isolated: libraryRoot != nil) { [weak self] in
            self?.libraryOpened()
        }
        // Choosing press to send ends listening at once, running or awaiting permission, so no queued audio slips out.
        settings.talkingModeChanged = { [weak self] mode in
            guard let self, mode == .pressToSend, listening.isOn || listeningRequest != nil else { return }
            stopListening()
        }
        routeSpeechThroughListening()
        observeListeningConditions()
        if !demo { refreshCodex() }
    }
    /// Asks Codex for its sign-in and reads its model list in the background; the answer lands in `codex`. Checks
    /// can overlap and finish in any order, so only the latest one's answer is kept.
    func refreshCodex() {
        let status = speech.codexStatus
        let check = UUID()
        codexCheck = check
        Task { [weak self] in
            let result = await status()
            guard let self, codexCheck == check else { return }
            codex = result
        }
    }
    /// Preview launches create a fresh library each time; remove it so previews leave nothing behind.
    func discardTemporaryLibrary() {
        guard temporaryLibrary else { return }
        try? FileManager.default.removeItem(at: store.root)
    }
    /// Selects where the user left off once the library is open, or failed to open.
    private func libraryOpened() {
        if demo {
            seedPreview()
        } else if library.conversations.isEmpty && libraryReadable {
            library.conversations = [freshConversation()]
        }
        restoreSelection()
        // A first launch writes its library at once, so the data folder never holds only caches.
        if libraryReadable && !demo && !FileManager.default.fileExists(atPath: store.file.path) { save() }
    }
    /// Selects the library's saved conversation (or the first active one), shows the list it is in, and restores its draft.
    private func restoreSelection() {
        selectedID =
            library.selectedConversationID.flatMap { id in
                library.conversations.contains(where: { $0.id == id }) ? id : nil
            } ?? library.history(in: .active).first?.id
        if let chat = conversation {
            history.scope = chat.isDeleted ? .deleted : chat.archived ? .archived : .active
        }
        draft = conversation?.draft ?? ""
    }
    @discardableResult func save() -> Bool { libraryController.save() }
    func scheduleSave() { libraryController.scheduleSave() }
    func persistenceMessage(
        _ error: Error, action: String, fallback: String.LocalizationValue, diskFull: String.LocalizationValue
    ) -> String {
        LibraryController.persistenceMessage(error, action: action, fallback: fallback, diskFull: diskFull)
    }
    func restorePreviousLibrary() {
        do {
            try libraryController.restorePrevious()
            guard libraryReadable else { return }
            error = nil
            if library.conversations.isEmpty { library.conversations = [freshConversation()] }
            restoreSelection()
            notice = String(
                localized: "Restored the earlier copy of your library. The unreadable file was kept in the data folder."
            )
        } catch {
            report(
                persistenceMessage(
                    error, action: "Restore earlier library",
                    fallback: "The earlier copy could not be restored. Nothing was changed.",
                    diskFull: "The earlier copy could not be restored because the disk is full. Nothing was changed."),
                in: .privacy)
        }
    }
    func revealDataFolder() {
        guard libraryController.revealDataFolder() else {
            report(
                String(
                    localized:
                        "The data folder could not be opened. In Finder, choose Go → Go to Folder and enter ~/Library/Application Support."
                ), in: .privacy)
            return
        }
    }
    /// False when the library could not be saved; the failure is already reported.
    @discardableResult func stop() -> Bool {
        // Playback ends first, so stopping listening has no reply left to move off the listening engine.
        let unfinishedRecording = cancelTurn()
        stopListening()
        transcripts.cancelAll()
        for ci in library.conversations.indices {
            for mi in library.conversations[ci].messages.indices
            where library.conversations[ci].messages[mi].transcriptionState == .pending {
                library.conversations[ci].messages[mi].transcriptionState = .interrupted
            }
        }
        // One write covers the interrupted transcripts and the help draft.
        stageHelpDraft()
        let saved = save()
        removeUnreferencedRecording(unfinishedRecording?.lastPathComponent)
        return saved
    }
    /// True while the turn is still the one a voice preview started; any other activity takes a new epoch.
    var previewActive: Bool { previewEpoch == turn.epoch && turn.activity != .idle }
    /// Ends a voice preview without Stop's other effects on replies, transcriptions and recordings.
    func stopPreview() {
        guard previewActive else { return }
        _ = cancelTurn()
    }
    /// Unlike Stop, leaves transcriptions running and does not force a save.
    /// Ends work in progress and keeps the help draft; returns whether a draft was saved.
    @discardableResult func cancelHelpWork() -> Bool {
        if !practice && task != nil && turn.activity == .generating {
            notice = String(localized: "Your pending reply was cancelled. You can retry it when you return.")
        }
        let recording = cancelTurn()
        let kept = persistHelpDraft()
        removeUnreferencedRecording(recording?.lastPathComponent)
        return kept
    }
    /// Ends whatever owns the turn and returns the unfinished recording, if any, for the caller to discard.
    private func cancelTurn() -> URL? {
        unheardReply = nil
        deferredToolAction = nil
        greetingActive = false
        let recording = media.stopRecording()
        task?.cancel()
        task = nil
        recordingClock?.cancel()
        recordingClock = nil
        audio.stop()
        playbackFile = nil
        speaking = false
        recordingMeaning = false
        help.progress = nil
        recordingLevel = -80
        turn.stop()
        return recording
    }
    func leavePractice() {
        if help.isSavedPractice {
            let temporary = help.thoughtRecording
            help.restoring {
                help.thoughtRecording = nil
                help.recognizedThought = nil
            }
            removeUnreferencedRecording(temporary)
        }
        help.isSavedPractice = false
        help.review = nil
        turn.resume()
    }
    /// A cancellable job that owns the turn. `isCurrent()` turns false once Stop or a newer job supersedes it;
    /// the job must then return without touching state.
    struct ExclusiveJob {
        let isCurrent: @MainActor () -> Bool
        let finish: @MainActor () -> Void
    }
    /// Runs `body` as the only active job. Finishing, cancellation and error reporting live here, so every job
    /// checks the same invariant: no state changes after the job is superseded.
    @discardableResult func runExclusive(
        _ context: String, progress: String.LocalizationValue? = nil, settingsTab: SettingsTab? = nil,
        onFailure: (@MainActor () -> Void)? = nil, _ body: @escaping @MainActor (ExclusiveJob) async throws -> Void
    ) -> UUID {
        let progress = progress.map { String(localized: $0) }
        let token = turn.begin(.generating)
        error = nil
        if let progress { help.progress = progress }
        let job = ExclusiveJob(
            isCurrent: { [weak self] in !Task.isCancelled && self?.turn.epoch == token },
            finish: { [weak self] in
                guard let self, self.turn.epoch == token else { return }
                if progress != nil { self.help.progress = nil }
                _ = self.turn.finish(token)
            })
        let handle = Task { [weak self] in
            defer { self?.releaseExclusiveTask(token) }
            do {
                try await body(job)
                if job.isCurrent() { job.finish() }
            } catch {
                guard let self, self.turn.epoch == token else { return }
                onFailure?()
                self.fail(error, token: token, context: context, settingsTab: settingsTab)
            }
        }
        task = handle
        exclusiveTask = (token, handle)
        return token
    }
    /// Clears the finished job's handle unless a newer job has already replaced it.
    private func releaseExclusiveTask(_ token: UUID) {
        guard let owned = exclusiveTask, owned.token == token else { return }
        if task == owned.task { task = nil }
        exclusiveTask = nil
    }
    /// Deletes a recording nothing refers to. A failure is logged, and shown unless `reportsFailure` is false.
    func removeUnreferencedRecording(_ name: String?, reportsFailure: Bool = true) {
        do {
            try libraryController.removeUnreferencedRecording(name, protected: messageDeletionUndo?.message.audio)
        } catch {
            MochiLog.failure(MochiLog.library, "Remove discarded recording", error, level: .info)
            guard reportsFailure else { return }
            self.error = String(
                localized: "Could not remove the discarded recording. Reveal the data folder in Settings to review it.")
        }
    }
    func fail(_ failure: Error, token: UUID, context: String = "Operation", settingsTab: SettingsTab? = nil) {
        guard turn.epoch == token else { return }
        _ = turn.finish(token)
        greetingActive = false
        speaking = false
        recordingMeaning = false
        help.progress = nil
        recordingLevel = -80
        guard !(failure is CancellationError) else { return }
        MochiLog.failure(MochiLog.app, context, failure)
        report(
            AppFailure.message(
                for: failure,
                fallback:
                    "This operation could not finish. Check the selected audio file or your connection, then retry."),
            in: settingsTab)
    }
    /// Sets the error, and the Settings tab it belongs to when a Settings action caused it.
    func report(_ message: String, in tab: SettingsTab?) {
        error = message
        errorTab = tab
    }
    private func seedPreview() {
        var chat = Conversation(title: "A thought I've been putting off")
        chat.messages = [
            Message(role: "assistant", text: "What's been on your mind today?"),
            Message(role: "user", text: "I have an idea for a small project, but I haven't started yet."),
            Message(role: "assistant", text: "What's making it hard to get started?"),
        ]
        library.conversations = [
            chat, Conversation(title: "An idea over coffee"), Conversation(title: "The book I’m reading"),
        ]
        selectedID = chat.id
        turn.pause()
        help.stage = .practice
        help.meaning = "I know what I mean. I just need the words."
        help.english = "I keep putting it off because I don't know where to start."
        var item = PracticeExpression(
            conversationID: chat.id, meaning: help.meaning, english: help.english, language: .english)
        item.referenceKind = "Preview · illustrative contours"
        help.expression = item
        help.referencePitch = (0..<180).map { i in
            let t = Double(i)
            let frequency: Double = 145 + 24 * sin(t * 0.07) + 7 * sin(t * 0.25)
            return PitchPoint(time: t * 0.025, hz: i % 37 < 4 ? nil : frequency)
        }
        help.attemptPitch = (0..<180).map { i in
            let t = Double(i)
            let frequency: Double = 151 + 16 * sin(t * 0.07 + 0.3)
            return PitchPoint(time: t * 0.027, hz: i % 39 < 5 ? nil : frequency)
        }
        let said: [(String, Double)] = [
            ("I", 0.9), ("keep", 0.9), ("putting", 0.8), ("it", 0.9), ("of", 0.7), ("because", 0.9), ("I", 0.9),
            ("don't", 0.9), ("know", 0.9), ("where", 0.3), ("to", 0.9), ("start", 0.8), ("now", 0.6),
        ]
        help.attemptCheck = .checked(
            AttemptCheck(target: help.english, recognized: said.map { RecognizedWord(text: $0.0, confidence: $0.1) }))
    }
}
