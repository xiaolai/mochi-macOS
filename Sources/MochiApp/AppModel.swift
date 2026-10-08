import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MochiCore
enum HelpStage { case thought, english, practice }
struct ReplyCallbacks {
    let response: @MainActor (RealtimeAccumulator) throws -> Void
    let transcription: @MainActor (RealtimeAccumulator) -> Void
}

@MainActor final class AppModel: ObservableObject {
    @Published var library = Library()
    @Published var selectedID: UUID?
    @Published var showExpressions = false
    @Published var search = ""
    @Published var searchOpen = false
    @Published var searchFocusRequest = 0
    @Published var historyScope: HistoryScope = .active
    @Published var managerOpen = false
    @Published var renameID: UUID?
    @Published var permanentDeleteIDs: Set<UUID> = []
    @Published var historyFeedback: String?
    @Published var draft = "" {
        didSet {
            guard let i = library.conversations.firstIndex(where:{ $0.id == selectedID }), library.conversations[i].draft != draft else { return }
            library.conversations[i].draft = draft
            save()
        }
    }
    @Published var meaning = "" { didSet { persistHelpDraft() } }
    @Published var english = "" { didSet { persistHelpDraft() } }
    @Published var helpStage: HelpStage = .thought
    @Published var thoughtRecording: String? { didSet {
        guard !restoringHelp else { return }
        if isSavedPractice {
            if oldValue != thoughtRecording { removeUnreferencedRecording(oldValue) }
            return
        }
        if oldValue != thoughtRecording { recognizedThought = nil }
        if persistHelpDraft(), oldValue != thoughtRecording { removeUnreferencedRecording(oldValue) }
    } }
    @Published var recognizedThought: String? { didSet { persistHelpDraft() } }
    private(set) var isSavedPractice = false
    @Published var helpProgress: String?
    @Published var helpClarification: String?
    @Published var recordingLevel: Float = -80
    @Published var recordingWarning: String?
    @Published var transcribingMessageIDs: Set<UUID> = []
    var transcribeRecording: (URL,String,String) async throws -> String = { url,auth,model in
        try await RealtimeService(auth:auth,model:model).transcribe(AudioFile.pcm(url))
    }
    var findEnglishSuggestion: ((ConversationRequest) async throws -> String)?
    var conversationReply: ((ConversationRequest,ReplyCallbacks) async throws -> Void)?
    var playReply: ((String) -> Void)?
    lazy var endRecording: () -> URL? = { [weak self] in self?.audio.stopRecording() }
    var recordingNow: () -> Date = Date.init
    var recordingSleep: (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds:$0) }
    var recordingMeter: (() -> Float)?
    private var restoringHelp = false
    private var transcriptTokens: [UUID:UUID] = [:]
    private(set) var transcriptTasks: [UUID:Task<Void,Never>] = [:]
    private(set) var voiceRequests: [UUID:Task<Void,Never>] = [:]
    @Published var expression: PracticeExpression?
    @Published var turn = TurnMachine()
    @Published var error: String?
    @Published var notice: String?
    @Published var referencePitch: [PitchPoint] = []
    @Published var attemptPitch: [PitchPoint] = []
    @Published private(set) var playbackFile: String?
    @Published var speaking = false
    @Published var slow = false
    @Published var settingsOpen = false
    @Published var recordingSeconds = 0
    @Published var recordingMeaning = false
    @Published var serviceStatus = "Not checked"
    @Published var auth: String { didSet { defaults.set(auth,forKey:"auth") } }
    @Published var modelName: String { didSet { defaults.set(modelName,forKey:"model") } }
    @Published var clone: String { didSet { defaults.set(clone,forKey:"clone") } }
    @Published var performer: String { didSet { defaults.set(performer,forKey:"performer") } }
    @Published var conversationVoice: String { didSet { defaults.set(conversationVoice,forKey:"conversationVoice") } }
    @Published var builtInPracticeVoice: String { didSet { defaults.set(builtInPracticeVoice,forKey:"builtInPracticeVoice") } }
    @Published var practiceVoiceMode: PracticeVoiceMode { didSet { defaults.set(practiceVoiceMode.rawValue,forKey:"practiceVoiceMode") } }
    @Published var voiceProfiles: [VoiceProfile] { didSet { if let data = try? JSONEncoder().encode(voiceProfiles) { defaults.set(data,forKey:"voiceProfiles") } } }
    @Published var conversationVoiceOptions: OpenAIVoiceOptions { didSet { persistVoiceOptions(conversationVoiceOptions,key:"conversationVoiceOptions") } }
    @Published var practiceVoiceOptions: OpenAIVoiceOptions { didSet { persistVoiceOptions(practiceVoiceOptions,key:"practiceVoiceOptions") } }
    @Published var personalVoiceOptions: PersonalVoiceOptions { didSet { persistVoiceOptions(personalVoiceOptions,key:"personalVoiceOptions") } }
    private func persistVoiceOptions<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data,forKey:key) }
    }
    @Published var voiceSetupActive = false
    @Published var practiceVoiceSetupOpen = false
    @Published var voiceSetupPreviewStep = 0
    @Published var settingsTab = "conversation"
    var selectedVoiceProfile: VoiceProfile? { voiceProfiles.first { $0.providerID == clone } }
    var practiceVoiceLabel: String {
        if practiceVoiceMode == .builtIn { return "\(RealtimeVoice(rawValue:builtInPracticeVoice)?.name ?? "Marin") · Built-in voice" }
        return "\(selectedVoiceProfile?.name ?? "My Voice") · \(PronunciationTarget(rawValue:performer)?.name ?? "Pronunciation target")"
    }
    let store: LibraryStore
    let audio = AudioController()
    let defaults: UserDefaults
    let demo: Bool
    private var task: Task<Void,Never>?
    private(set) var recordingClock: Task<Void,Never>?
    private var libraryReadable = true
    private(set) var voiceProfilesReadable = true
    var conversation: Conversation? { library.conversations.first { $0.id == selectedID } }
    var writableConversation: Bool { conversation.map { !$0.archived && !$0.isDeleted } ?? false }
    var visibleChats: [Conversation] { library.history(in:historyScope,query:search) }
    var busy: Bool { turn.activity != .idle || voiceSetupActive }
    var practice: Bool { turn.mode == .practice }
    var status: String {
        switch turn.activity {
        case .recording: if recordingMeaning { return "Recording your thought · finish to review" }; return practice ? "Recording your attempt · stays on this Mac" : "Recording · finish to send to Mochi"
        case .requestingPermission: return "Waiting for microphone permission"
        case .generating: return practice ? "Preparing your expression…" : "Mochi is thinking…"
        case .playing: if audio.paused { return "Playback paused" }; return speaking ? "Mochi is speaking" : "Playing your recording"
        case .idle: return practice ? "Conversation paused · microphone off" : "Ready when you are · microphone off"
        }
    }
    init(demo: Bool = false, libraryRoot: URL? = nil, preferences: UserDefaults? = nil) {
        self.demo = demo
        defaults = preferences ?? (demo ? UserDefaults(suiteName:AppIdentity.bundleIdentifier + ".preview")! : .standard)
        if !demo && libraryRoot == nil {
            AppIdentity.migratePreferences(into:defaults,legacy:defaults.persistentDomain(forName:AppIdentity.legacyBundleIdentifier) ?? [:])
        }
        auth = defaults.string(forKey:"auth") ?? "api"
        modelName = defaults.string(forKey:"model") ?? "gpt-realtime"
        clone = (ProcessInfo.processInfo.environment["MOCHI_CLONE_VOICE_ID"] ?? ProcessInfo.processInfo.environment["ENJOY_CLONE_VOICE_ID"]) ?? defaults.string(forKey:"clone") ?? ""
        if let value = (ProcessInfo.processInfo.environment["MOCHI_CLONE_VOICE_ID"] ?? ProcessInfo.processInfo.environment["ENJOY_CLONE_VOICE_ID"]), !demo { defaults.set(value,forKey:"clone") }
        performer = defaults.string(forKey:"performer") ?? "ev2kMR9ZJZZsemuogS5u"
        conversationVoice = RealtimeVoice(rawValue:defaults.string(forKey:"conversationVoice") ?? "")?.rawValue ?? "marin"
        builtInPracticeVoice = RealtimeVoice(rawValue:defaults.string(forKey:"builtInPracticeVoice") ?? "")?.rawValue ?? "marin"
        let voicePreferences = defaults
        func options<T: Decodable>(_ key: String, fallback: T, validate: (T) throws -> Void) -> T {
            guard let data = voicePreferences.data(forKey:key), let value = try? JSONDecoder().decode(T.self,from:data), (try? validate(value)) != nil else { return fallback }
            return value
        }
        conversationVoiceOptions = options("conversationVoiceOptions",fallback:OpenAIVoiceOptions(),validate: { try $0.validate() })
        practiceVoiceOptions = options("practiceVoiceOptions",fallback:OpenAIVoiceOptions(),validate: { try $0.validate() })
        personalVoiceOptions = options("personalVoiceOptions",fallback:PersonalVoiceOptions(),validate: { try $0.validate() })
        let legacyClone = (ProcessInfo.processInfo.environment["MOCHI_CLONE_VOICE_ID"] ?? ProcessInfo.processInfo.environment["ENJOY_CLONE_VOICE_ID"]) ?? defaults.string(forKey:"clone") ?? ""
        practiceVoiceMode = PracticeVoiceMode(rawValue:defaults.string(forKey:"practiceVoiceMode") ?? "") ?? (legacyClone.isEmpty ? .builtIn : .personal)
        let profileData = defaults.data(forKey:"voiceProfiles")
        let decodedProfiles = profileData.flatMap { try? JSONDecoder().decode([VoiceProfile].self,from:$0) }
        voiceProfilesReadable = profileData == nil || decodedProfiles != nil
        var profiles = decodedProfiles ?? []
        if !legacyClone.isEmpty && !profiles.contains(where:{$0.providerID == legacyClone}) { profiles.append(VoiceProfile(name:"My Voice",providerID:legacyClone,createdByApp:false)) }
        voiceProfiles = profiles
        if voiceProfilesReadable, let data = try? JSONEncoder().encode(profiles) { defaults.set(data,forKey:"voiceProfiles") }
        let support = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
        var root = libraryRoot ?? (demo ? FileManager.default.temporaryDirectory.appendingPathComponent("mochi-preview-\(UUID().uuidString)") : support.appendingPathComponent(AppIdentity.name))
        if !demo && libraryRoot == nil {
            do { root = try AppIdentity.prepareDataDirectory(in:support) }
            catch { libraryReadable = false; root = support.appendingPathComponent(AppIdentity.legacyDataDirectory) }
        }
        store = LibraryStore(root:root)
        do {
            guard libraryReadable else { throw AppFailure("The existing library could not be migrated.") }
            try store.prepare(); library = try store.load()
        }
        catch { libraryReadable = false; self.error = "Your saved library could not be opened. It has not been overwritten. Reveal the data folder from Settings to recover it." }
        if demo { seedPreview() }
        else if library.conversations.isEmpty && libraryReadable { library.conversations = [Conversation()] }
        selectedID = library.selectedConversationID.flatMap { id in library.conversations.contains(where:{ $0.id == id }) ? id : nil } ?? library.history(in:.active).first?.id
        if !voiceProfilesReadable { self.error = "Saved voice profiles could not be opened. They have not been overwritten; built-in voices remain available." }
        if let chat = conversation {
            historyScope = chat.isDeleted ? .deleted : chat.archived ? .archived : .active
            draft = chat.draft
        }
    }
    @discardableResult func save() -> Bool {
        guard libraryReadable else { return false }; if demo { return true }
        library.selectedConversationID = selectedID
        do { try store.save(library); return true } catch { self.error = "Could not save your conversation. Check available disk space; keep this window open."; return false }
    }
    func stop() {
        let unfinishedRecording = endRecording()
        task?.cancel(); task = nil; recordingClock?.cancel(); recordingClock = nil
        for job in transcriptTasks.values { job.cancel() }; transcriptTasks.removeAll()
        for job in voiceRequests.values { job.cancel() }; voiceRequests.removeAll()
        transcriptTokens.removeAll(); transcribingMessageIDs.removeAll()
        for ci in library.conversations.indices {
            for mi in library.conversations[ci].messages.indices where library.conversations[ci].messages[mi].transcriptionState == .pending {
                library.conversations[ci].messages[mi].transcriptionState = .interrupted
            }
        }
        helpProgress = nil; recordingLevel = -80
        audio.stop(); playbackFile = nil; speaking = false; recordingMeaning = false; turn.stop()
        persistHelpDraft(); save()
        removeUnreferencedRecording(unfinishedRecording?.lastPathComponent)
    }
    func cancelHelpWork() {
        let recording = endRecording()
        if !practice && task != nil && turn.activity == .generating { notice = "Your pending reply was cancelled. You can retry it when you return." }
        task?.cancel()
        task = nil; recordingClock?.cancel(); recordingClock = nil
        audio.stop(); playbackFile = nil; speaking = false; recordingMeaning = false; helpProgress = nil; recordingLevel = -80; turn.stop()
        persistHelpDraft(); removeUnreferencedRecording(recording?.lastPathComponent)
    }
    func leavePractice() {
        if isSavedPractice {
            let temporary = thoughtRecording
            restoringHelp = true; thoughtRecording = nil; recognizedThought = nil; restoringHelp = false
            removeUnreferencedRecording(temporary)
        }
        isSavedPractice = false; turn.resume()
    }
    func openExpressions() {
        cancelHelpWork(); leavePractice(); expression = nil; showExpressions = true
    }
    func newChat() {
        guard libraryReadable else { return }
        if let chat = conversation, writableConversation, chat.messages.isEmpty, !chat.customTitle {
            stop(); leavePractice(); expression = nil; showExpressions = false; historyScope = .active; search = ""; return
        }
        var candidate = library
        let chat = Conversation(); candidate.conversations.insert(chat,at:0); candidate.selectedConversationID = chat.id
        guard commitHistory(candidate) else { return }
        select(chat.id); historyScope = .active; search = ""
    }
    func select(_ id: UUID) {
        guard let chat = library.conversations.first(where:{ $0.id == id }) else { return }
        stop(); leavePractice(); expression = nil; selectedID = id; showExpressions = false; draft = chat.draft; notice = nil; save()
    }
    func showHistory(_ scope: HistoryScope) {
        stop(); leavePractice(); expression = nil; showExpressions = false; historyScope = scope; search = ""
        selectedID = library.history(in:scope).first?.id
        draft = conversation?.draft ?? ""; save()
    }
    @discardableResult func commitHistory(_ candidate: Library) -> Bool {
        guard libraryReadable else { return false }
        do {
            if !demo { try store.save(candidate) }
            library = candidate; error = nil; return true
        } catch { self.error = "The history change could not be saved. Your library was not changed. Check disk space and try again."; return false }
    }
    func renameChat(_ id: UUID, title: String) {
        let value = title.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 160, let i = library.conversations.firstIndex(where:{ $0.id == id && !$0.isDeleted }) else { return }
        var candidate = library; candidate.conversations[i].title = value; candidate.conversations[i].customTitle = true
        if commitHistory(candidate) { renameID = nil }
    }
    func pinChats(_ ids: Set<UUID>, pinned: Bool) {
        var candidate = library
        for i in candidate.conversations.indices where ids.contains(candidate.conversations[i].id) && !candidate.conversations[i].isDeleted { candidate.conversations[i].pinned = pinned }
        _ = commitHistory(candidate)
    }
    func archiveChats(_ ids: Set<UUID>) {
        var candidate = library
        for i in candidate.conversations.indices where ids.contains(candidate.conversations[i].id) && !candidate.conversations[i].isDeleted { candidate.conversations[i].archived = true }
        if finishHistoryChange(candidate,affected:ids) { historyFeedback = "Conversations archived." }
    }
    func deleteChats(_ ids: Set<UUID>) {
        var candidate = library; candidate.moveToDeleted(ids)
        if finishHistoryChange(candidate,affected:ids) { historyFeedback = "Moved to Recently Deleted. You can recover them there." }
    }
    func restoreChats(_ ids: Set<UUID>) {
        var candidate = library; candidate.restore(ids)
        let selectedRestored = selectedID.flatMap { ids.contains($0) ? $0 : nil }
        guard finishHistoryChange(candidate,affected:ids) else { return }
        historyFeedback = "Conversations restored."
        if let id = selectedRestored, let chat = library.conversations.first(where:{ $0.id == id && !$0.isDeleted }) {
            historyScope = chat.archived ? .archived : .active; select(id)
        }
    }
    @discardableResult private func finishHistoryChange(_ candidate: Library, affected: Set<UUID>) -> Bool {
        var next = candidate
        if practice, selectedID.map(affected.contains) == true, let item = expression, !item.english.isEmpty {
            if let index = next.expressions.firstIndex(where:{ $0.id == item.id }) { next.expressions[index] = item }
            else { next.expressions.insert(item,at:0) }
        }
        let selectedAffected = selectedID.map(affected.contains) ?? false
        if selectedAffected { next.selectedConversationID = next.history(in:historyScope,query:search).first?.id }
        guard commitHistory(next) else { return false }
        if selectedAffected {
            stop(); leavePractice(); expression = nil; selectedID = next.selectedConversationID; draft = conversation?.draft ?? ""
        }
        historyFeedback = nil
        return true
    }
    func permanentlyDeleteChats() {
        let ids = permanentDeleteIDs
        var candidate = library; let removedAudio = candidate.removePermanently(ids)
        guard finishHistoryChange(candidate,affected:ids) else { return }
        guard !library.conversations.contains(where:{ ids.contains($0.id) && $0.isDeleted }) else { return }
        permanentDeleteIDs = []
        var failed = false
        for name in removedAudio {
            let url = store.root.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath:url.path) { do { try FileManager.default.removeItem(at:url) } catch { failed = true } }
        }
        historyFeedback = failed ? "Conversations deleted. Some unused recordings could not be removed from the data folder." : "Conversations permanently deleted. Saved expressions were kept."
    }
    func exportChats(_ ids: Set<UUID>, json: Bool = false) {
        let chats = library.conversations.filter { ids.contains($0.id) }
        guard !chats.isEmpty else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = chats.count == 1 ? "Conversation.\(json ? "json" : "md")" : "Conversations.\(json ? "json" : "md")"
        panel.allowedContentTypes = [json ? .json : UTType(filenameExtension:"md") ?? .plainText]
        panel.prompt = "Export"
        panel.message = json ? "Includes transcript, drafts and conversation metadata. For recordings, use Export Library Backup." : "Export conversation text. For recordings, use Export Library Backup."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { let data = json ? try HistoryExport.json(chats) : Data(HistoryExport.markdown(chats).utf8); try data.write(to:url,options:.atomic); historyFeedback = "Transcript exported." }
        catch { self.error = "The transcript could not be exported. Choose another location." }
    }
    func exportLibraryBackup() {
        guard libraryReadable else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Mochi-\(Date().formatted(.iso8601.year().month().day().dateSeparator(.dash))).mochilibrary"
        panel.allowedContentTypes = [UTType(exportedAs:AppIdentity.backupType,conformingTo:.package)]
        panel.prompt = "Export Backup"
        panel.message = "Includes all conversations, deleted history, drafts, saved expressions and their recordings. API keys are excluded. Choose a new filename."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try LibraryBackup.write(library,from:store.root,to:url); historyFeedback = "Library backup exported." }
        catch { self.error = "Could not export the backup. Use a new filename and check that referenced recordings are present." }
    }
    func importLibraryBackup() {
        guard libraryReadable else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.treatsFilePackagesAsDirectories = true
        panel.prompt = "Import"
        panel.message = "Choose a .mochilibrary or older .enjoylibrary backup. Missing items are added; matching IDs keep the local version."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let before = library.referencedAudio
        var candidate = library
        do {
            let imported = try LibraryBackup.read(url)
            let count = try LibraryBackup.merge(imported,from:url,into:&candidate,root:store.root)
            if commitHistory(candidate) { historyFeedback = "Imported \(count) conversations. Existing local items were kept." }
            else { for name in candidate.referencedAudio.subtracting(before) { try? FileManager.default.removeItem(at:store.root.appendingPathComponent(name)) } }
        } catch { self.error = "This backup could not be imported. It may contain missing recordings, invalid IDs, or an unsupported schema. Your history was not changed." }
    }
    func append(_ message: Message, to id: UUID) {
        guard let i = library.conversations.firstIndex(where: { $0.id == id }) else { return }
        if !library.conversations[i].customTitle && library.conversations[i].messages.isEmpty && message.role == "user" { library.conversations[i].title = String(message.text.prefix(42)) }
        library.conversations[i].messages.append(message); save()
    }
    func send() {
        let text = draft.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !text.isEmpty, !busy, !practice, writableConversation, libraryReadable, let id = selectedID else { return }
        draft = ""; notice = nil
        let history = conversation?.messages ?? []
        append(Message(role:"user",text:text),to:id)
        requestReply(history:history,text:text,pcm:nil,audioFile:nil,conversationID:id)
    }
    var canRetry: Bool {
        guard writableConversation, !busy, !practice, let last = conversation?.messages.last, last.role == "user" else { return false }
        return !transcribingMessageIDs.contains(last.id)
    }
    func retryReply() {
        guard canRetry, let chat = conversation, let last = chat.messages.last else { return }
        do {
            let pcm = try last.contextText == nil ? last.audio.map { try AudioFile.pcm(store.root.appendingPathComponent($0)) } : nil
            requestReply(history:Array(chat.messages.dropLast()),text:last.text,pcm:pcm,audioFile:last.audio,conversationID:chat.id,existingUserID:last.id)
        } catch { self.error = "The saved recording could not be read. Record a new message to continue." }
    }
    func requestReply(history: [Message], text: String, pcm: Data?, audioFile: String?, conversationID: UUID, existingUserID: UUID? = nil) {
        if let existingUserID, transcribingMessageIDs.contains(existingUserID) { return }
        var userID = existingUserID
        if pcm != nil && userID == nil {
            var message = Message(role:"user",text:"",audio:audioFile)
            message.transcriptionState = .pending; userID = message.id
            append(message,to:conversationID)
        }
        let requestID = UUID()
        if let userID, pcm != nil {
            transcriptTokens[userID] = requestID; transcribingMessageIDs.insert(userID)
            updateTranscript(userID,chatID:conversationID,text:nil,state:.pending,error:nil)
        }
        let token = turn.begin(.generating); error = nil
        let service = RealtimeService(auth:auth,model:modelName,voice:conversationVoice,options:conversationVoiceOptions)
        let voiceID = pcm == nil ? nil : userID
        let operation = Task { [weak self] in
            guard let self else { return }
            defer {
                if turn.epoch == token { task = nil }
                if let voiceID, transcriptTokens[voiceID] == requestID {
                    if library.conversations.first(where: { $0.id == conversationID })?.messages.first(where: { $0.id == voiceID })?.transcriptionState == .pending {
                        updateTranscript(voiceID,chatID:conversationID,text:nil,state:.interrupted,error:"Transcription was interrupted. Your recording is saved.")
                    }
                    transcriptTokens.removeValue(forKey:voiceID); transcribingMessageIDs.remove(voiceID)
                    voiceRequests.removeValue(forKey:voiceID)
                }
            }
            do {
                let callbacks = ReplyCallbacks(response: { [weak self] reply in
                    guard let self, !Task.isCancelled, turn.epoch == token else { return }
                    task = nil
                    var filename: String?
                    if !reply.audio.isEmpty {
                        filename = "reply-\(UUID().uuidString).wav"
                        try PCM.wav(reply.audio).write(to:store.root.appendingPathComponent(filename!))
                    }
                    append(Message(role:"assistant",text:reply.text,audio:filename),to:conversationID)
                    _ = turn.finish(token)
                    if let filename { if let playReply { playReply(filename) } else { play(filename,mochi:true) } }
                },transcription: { [weak self] reply in
                    guard let self, !Task.isCancelled, let voiceID, transcriptTokens[voiceID] == requestID else { return }
                    updateTranscript(voiceID,chatID:conversationID,text:reply.inputTranscript.isEmpty ? nil : reply.inputTranscript,state:reply.transcriptionState,error:reply.transcriptionError)
                })
                let request = ConversationRequest(history:history,text:text,pcm:pcm,spoken:audioFile != nil)
                if let conversationReply { try await conversationReply(request,callbacks) }
                else { _ = try await service.reply(request,onResponse:callbacks.response,onTranscription:callbacks.transcription) }
            } catch {
                if let voiceID, transcriptTokens[voiceID] == requestID,
                   library.conversations.first(where: { $0.id == conversationID })?.messages.first(where: { $0.id == voiceID })?.transcriptionState == .pending {
                    updateTranscript(voiceID,chatID:conversationID,text:nil,state:.interrupted,error:"Transcription was interrupted. Your recording is saved.")
                }
                fail(error,token:token)
            }
        }
        task = operation
        if let voiceID { voiceRequests[voiceID] = operation }
    }
    private func updateTranscript(_ messageID: UUID, chatID: UUID, text: String?, state: TranscriptionState, error: String?) {
        guard let ci = library.conversations.firstIndex(where: { $0.id == chatID && !$0.isDeleted && !$0.archived }),
              let mi = library.conversations[ci].messages.firstIndex(where: { $0.id == messageID }) else { return }
        if let text { library.conversations[ci].messages[mi].text = text }
        library.conversations[ci].messages[mi].transcriptionState = state
        library.conversations[ci].messages[mi].transcriptionError = error
        if let text, !text.isEmpty, !library.conversations[ci].customTitle,
           library.conversations[ci].messages.first?.id == messageID {
            library.conversations[ci].title = String(text.prefix(42))
        }
        save()
    }
    func retryTranscription(_ messageID: UUID) {
        guard writableConversation, !busy,
              let chat = conversation, let message = chat.messages.first(where: { $0.id == messageID && $0.role == "user" }), let file = message.audio,
              !transcribingMessageIDs.contains(messageID) else { return }
        let jobID = UUID(), chatID = chat.id
        transcriptTokens[messageID] = jobID; transcribingMessageIDs.insert(messageID)
        updateTranscript(messageID,chatID:chatID,text:nil,state:.pending,error:nil)
        let operation = transcribeRecording, connection = auth, model = modelName, url = store.root.appendingPathComponent(file)
        transcriptTasks[messageID] = Task { [weak self] in
            guard let self else { return }
            defer {
                if transcriptTokens[messageID] == jobID {
                    transcriptTokens.removeValue(forKey:messageID); transcribingMessageIDs.remove(messageID)
                    transcriptTasks.removeValue(forKey:messageID)
                }
            }
            do {
                let text = try await operation(url,connection,model)
                guard !Task.isCancelled, transcriptTokens[messageID] == jobID else { return }
                let clean = text.trimmingCharacters(in:.whitespacesAndNewlines)
                guard !clean.isEmpty else { throw AppFailure("No clear speech was recognized. Your recording is saved; add text or record again.") }
                updateTranscript(messageID,chatID:chatID,text:clean,state:.completed,error:nil)
            } catch {
                guard !Task.isCancelled, transcriptTokens[messageID] == jobID else { return }
                updateTranscript(messageID,chatID:chatID,text:nil,state:.failed,error:(error as? AppFailure)?.message ?? "Transcription could not finish. Your recording is saved; retry or add text.")
            }
        }
    }
    func cancelTranscription(_ messageID: UUID) {
        transcriptTasks.removeValue(forKey:messageID)?.cancel()
        voiceRequests.removeValue(forKey:messageID)?.cancel()
        transcriptTokens.removeValue(forKey:messageID); transcribingMessageIDs.remove(messageID)
        if let chatID = conversation?.id { updateTranscript(messageID,chatID:chatID,text:nil,state:.interrupted,error:nil) }
    }
    func editTranscript(_ messageID: UUID, text: String) {
        guard writableConversation, let chatID = conversation?.id else { return }
        cancelTranscription(messageID)
        let clean = text.trimmingCharacters(in:.whitespacesAndNewlines)
        updateTranscript(messageID,chatID:chatID,text:clean,state:clean.isEmpty ? .failed : .completed,error:nil)
    }
    func startHelp() {
        guard writableConversation else { return }
        let cancelledReply = !practice && task != nil && turn.activity == .generating
        cancelHelpWork(); error = nil; turn.pause(); showExpressions = false
        isSavedPractice = false
        let saved = conversation?.helpDraft
        restoringHelp = true
        meaning = saved?.meaning ?? draft; english = saved?.english ?? ""; thoughtRecording = saved?.recording
        helpClarification = saved?.clarification; recognizedThought = saved?.transcriptReview
        expression = saved?.expressionID.flatMap { id in library.expressions.first(where: { $0.id == id }) }
        restoringHelp = false
        helpStage = english.isEmpty || recognizedThought != nil ? .thought : .english
        referencePitch = []; attemptPitch = []; notice = cancelledReply ? "Your pending reply was cancelled. You can retry it when you return." : nil; recordingWarning = nil
        if let thoughtRecording, let samples = try? AudioFile.samples(store.root.appendingPathComponent(thoughtRecording)).samples {
            recordingWarning = RecordingSignal(samples:samples).isQuiet ? "This recording is very quiet. Listen before transcribing, or record it again." : nil
        }
        persistHelpDraft()
    }
    @discardableResult private func persistHelpDraft() -> Bool {
        guard !restoringHelp, !isSavedPractice, practice, writableConversation, let ci = library.conversations.firstIndex(where: { $0.id == selectedID }) else { return false }
        library.conversations[ci].helpDraft = HelpDraft(meaning:meaning,english:english,recording:thoughtRecording,expressionID:expression?.id)
        library.conversations[ci].helpDraft?.clarification = helpClarification
        library.conversations[ci].helpDraft?.transcriptReview = recognizedThought
        return save()
    }
    func editThought() { helpStage = .thought; error = nil }
    func beginPractice() {
        guard !english.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { return }
        ensureExpression(); helpStage = .practice; persistHelpDraft()
    }
    func reviewEnglish() { if !english.isEmpty { helpStage = .english } }
    func transcribeThought() {
        guard !busy, let thoughtRecording else { return }
        let token = turn.begin(.generating); error = nil; helpProgress = "Transcribing your thought…"
        let operation = transcribeRecording, connection = auth, model = modelName, url = store.root.appendingPathComponent(thoughtRecording)
        task = Task {
            do {
                let text = try await operation(url,connection,model)
                guard !Task.isCancelled, turn.epoch == token else { return }
                let clean = text.trimmingCharacters(in:.whitespacesAndNewlines)
                guard !clean.isEmpty else { throw AppFailure("No clear speech was recognized. Your thought is saved; listen or record again.") }
                if meaning.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { meaning = clean }
                else { recognizedThought = clean }
                helpProgress = nil; _ = turn.finish(token)
                notice = "Check the recognized thought before finding the English."
            } catch { fail(error,token:token) }
        }
    }
    func useRecognizedThought(replace: Bool) {
        guard !busy, let recognizedThought else { return }
        meaning = replace || meaning.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ? recognizedThought : meaning + "\n" + recognizedThought
        self.recognizedThought = nil; notice = "Check your thought before finding the English."
    }
    private func removeUnreferencedRecording(_ name: String?) {
        guard let name, !name.isEmpty, URL(fileURLWithPath:name).lastPathComponent == name,
              !library.referencedAudio.contains(name) else { return }
        let url = store.root.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath:url.path) else { return }
        do { try FileManager.default.removeItem(at:url) }
        catch { self.error = "Could not remove the discarded recording. Reveal the data folder in Settings to review it." }
    }
    func discardThoughtRecording() { thoughtRecording = nil; recordingWarning = nil }
    func cancelRecording() {
        let url = endRecording()
        cancelHelpWork()
        removeUnreferencedRecording(url?.lastPathComponent)
    }
    func translate() { findEnglish(alternative:false) }
    func tryAnotherWording() { findEnglish(alternative:true) }
    private func findEnglish(alternative: Bool) {
        let input = meaning.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !input.isEmpty, !busy, let id = selectedID else { return }
        let history = conversation?.messages ?? []
        let token = turn.begin(.generating); error = nil; helpProgress = "Finding the English…"
        let service = RealtimeService(auth:auth,model:modelName,voice:conversationVoice,options:conversationVoiceOptions)
        let requestText = alternative && !english.isEmpty ? "Intended thought: \(input)\nPrevious English wording: \(english)\nOffer a different natural wording with exactly the same meaning." : input
        task = Task {
            do {
                let request = ConversationRequest(history:history,text:requestText,help:true)
                let result: String
                if let findEnglishSuggestion { result = try await findEnglishSuggestion(request) }
                else { result = try await service.reply(request).text }
                guard !Task.isCancelled, turn.epoch == token else { return }
                let suggestion = try HelpSuggestion.parse(result)
                if suggestion.kind == .clarification {
                    helpClarification = suggestion.text; helpStage = .thought
                } else {
                    english = suggestion.text.trimmingCharacters(in:.whitespacesAndNewlines)
                    expression = PracticeExpression(conversationID:id,meaning:input,english:english)
                    helpClarification = nil; helpStage = .english
                }
                helpProgress = nil; persistHelpDraft()
                _ = turn.finish(token)
            } catch { fail(error,token:token) }
        }
    }
    func editEnglish(_ text: String) {
        english = text
        if expression?.english != text { expression = nil; referencePitch = []; attemptPitch = [] }
        if !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && helpStage == .thought { helpStage = .english }
        persistHelpDraft()
    }
    func ensureExpression() {
        guard let id = selectedID else { return }
        if expression == nil { expression = PracticeExpression(conversationID:id,meaning:meaning,english:english.trimmingCharacters(in:.whitespacesAndNewlines)) }
    }
    @discardableResult func saveExpression() -> Bool {
        ensureExpression()
        guard let expression, !expression.english.isEmpty else { return false }
        if let index = library.expressions.firstIndex(where: { $0.id == expression.id }) { library.expressions[index] = expression }
        else { library.expressions.insert(expression,at:0) }
        persistHelpDraft()
        return save()
    }
    func render(force: Bool = false, usingBuiltIn voiceOverride: String? = nil) {
        guard !busy, !english.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { return }
        ensureExpression()
        if voiceOverride == nil && practiceVoiceMode == .personal && (selectedVoiceProfile?.ready != true) {
            error = "Set up or verify your voice first, or choose a built-in practice voice."; return
        }
        let identity = personalVoiceOptions.identity(text:english,performer:performer,clone:clone)
        let mode = voiceOverride == nil ? practiceVoiceMode : .builtIn
        let label = voiceOverride.map { "\(RealtimeVoice(rawValue:$0)?.name ?? $0) · Built-in voice" } ?? practiceVoiceLabel
        let service = RealtimeService(auth:auth,model:modelName,voice:voiceOverride ?? builtInPracticeVoice,options:practiceVoiceOptions)
        let token = turn.begin(.generating); error = nil; helpProgress = "Creating your example…"
        task = Task {
            do {
                let url = mode == .personal ? try await VoiceRenderer().render(identity,root:store.root,force:force) : try await service.referenceAudio(text:identity.text,root:store.root,force:force)
                let pitch = try await Task.detached { try AudioFile.pitch(url) }.value
                guard !Task.isCancelled, turn.epoch == token else { return }
                expression?.reference = url.lastPathComponent; expression?.referenceKind = label
                referencePitch = pitch; saveExpression(); _ = turn.finish(token)
                helpProgress = nil
                notice = "Your reference is ready. Listen, then try saying it yourself."
            } catch { fail(error,token:token) }
        }
    }
    func acceptVoiceProfile(_ profile: VoiceProfile) {
        guard upsertVoiceProfile(profile), profile.ready else { return }
        clone = profile.providerID; practiceVoiceMode = .personal
    }
    @discardableResult func upsertVoiceProfile(_ profile: VoiceProfile) -> Bool {
        guard voiceProfilesReadable else { error = "Saved voice profiles could not be opened. They have not been overwritten."; return false }
        if let i = voiceProfiles.firstIndex(where:{$0.id == profile.id || $0.providerID == profile.providerID}) { voiceProfiles[i] = profile }
        else { voiceProfiles.append(profile) }
        return true
    }
    func removeVoiceProfile(_ profile: VoiceProfile) {
        guard voiceProfilesReadable else { return }
        voiceProfiles.removeAll { $0.id == profile.id }
        if clone == profile.providerID { clone = ""; practiceVoiceMode = .builtIn }
    }
    func previewBuiltIn(_ voice: String, options: OpenAIVoiceOptions? = nil) {
        guard !busy, !voiceSetupActive else { return }
        let token = turn.begin(.generating); error = nil
        let service = RealtimeService(auth:auth,model:modelName,voice:voice,options:options ?? practiceVoiceOptions)
        task = Task {
            do {
                let url = try await service.referenceAudio(text:ReferenceSpeech.preview,root:store.root)
                guard !Task.isCancelled, turn.epoch == token else { return }
                _ = turn.finish(token); play(url.lastPathComponent)
            } catch { fail(error,token:token) }
        }
    }
    func importReference() {
        guard !busy else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.audio]; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let source = panel.url else { return }
        ensureExpression()
        let token = turn.begin(.generating)
        task = Task {
            do {
                let pitch = try await Task.detached { try AudioFile.pitch(source) }.value
                guard !Task.isCancelled, turn.epoch == token else { return }
                let name = "import-\(UUID().uuidString).\(source.pathExtension)"
                try FileManager.default.copyItem(at:source,to:store.root.appendingPathComponent(name))
                expression?.reference = name; expression?.referenceKind = "Imported reference"; referencePitch = pitch
                saveExpression(); _ = turn.finish(token)
            } catch { fail(error,token:token) }
        }
    }
    func togglePlayback(_ file: String, mochi: Bool = false) {
        if playbackFile == file && turn.activity == .playing { audio.togglePause(); objectWillChange.send(); return }
        play(file,mochi:mochi)
    }
    func seekPlayback(_ file: String, to seconds: Double, mochi: Bool = false) {
        guard seconds.isFinite else { return }
        if playbackFile != file { play(file,mochi:mochi) }
        guard playbackFile == file else { return }
        audio.seek(to:seconds)
    }
    func play(_ file: String, mochi: Bool = false) {
        guard !busy || turn.activity == .playing else { return }
        audio.stop(); playbackFile = nil
        let token = turn.begin(.playing); speaking = mochi
        let finished: () -> Void = { [weak self] in
            guard let self, self.turn.epoch == token else { return }
            self.playbackFile = nil; self.speaking = false; _ = self.turn.finish(token)
        }
        do {
            try audio.play(url:store.root.appendingPathComponent(file),rate:slow && !mochi ? 0.8 : 1,
                           failed: { [weak self] in finished(); self?.error = "This recording could not be played. Try another recording." },completed:finished)
            playbackFile = file
        } catch { playbackFile = nil; fail(error,token:token) }
    }
    func recordMeaning() {
        guard !isSavedPractice else { notice = "Open Help Me Say This from the conversation to record a new thought."; return }
        beginRecording(forMeaning:true)
    }
    func toggleRecord() {
        guard practice || writableConversation else { return }; beginRecording(forMeaning:false) }
    private func beginRecording(forMeaning: Bool) {
        if turn.activity == .recording { finishRecording(); return }
        guard !busy, libraryReadable else { return }
        recordingMeaning = forMeaning
        if practice && !recordingMeaning { ensureExpression() }
        let token = turn.begin(.requestingPermission)
        task = Task {
            let allowed = await audio.permission()
            guard !Task.isCancelled, turn.epoch == token else { return }
            guard allowed else { recordingMeaning = false; _ = turn.finish(token); error = "Microphone access is off. Enable Mochi in System Settings → Privacy & Security → Microphone."; return }
            do {
                let file = store.root.appendingPathComponent("recording-\(UUID().uuidString).wav")
                try audio.record(to:file); _ = turn.finish(token); _ = turn.startRecording(); recordingSeconds = 0; recordingWarning = nil
                startRecordingFeedback(token:turn.epoch)
            } catch { fail(error,token:token) }
        }
    }
    func updateRecordingFeedback(elapsed: Double, level: Float) {
        recordingSeconds = Int(max(0,min(60,elapsed.isFinite ? elapsed : 0)))
        recordingLevel = level.isFinite ? min(0,max(-80,level)) : -80
        recordingWarning = recordingSeconds >= 1 && recordingLevel < -48 ? "Input is very quiet. Check your microphone or speak closer." : nil
    }
    func startRecordingFeedback(token: UUID) {
        recordingClock?.cancel()
        let started = recordingNow()
        recordingClock = Task {
            while !Task.isCancelled {
                do { try await recordingSleep(100_000_000) } catch { return }
                guard !Task.isCancelled, turn.epoch == token else { return }
                updateRecordingFeedback(elapsed:recordingNow().timeIntervalSince(started),level:recordingMeter?() ?? audio.meter)
                if recordingSeconds >= 60 { finishRecording(); return }
            }
        }
    }
    func finishRecording() {
        guard let url = endRecording() else { stop(); return }
        recordingClock?.cancel(); recordingClock = nil; turn.stop()
        recordingLevel = -80
        if recordingMeaning {
            recordingMeaning = false
            thoughtRecording = url.lastPathComponent
            if let samples = try? AudioFile.samples(url).samples {
                recordingWarning = RecordingSignal(samples:samples).isQuiet ? "This recording is very quiet. Listen before transcribing, or record it again." : nil
            }
            notice = "Your thought is recorded locally. Listen, then choose Transcribe."
            persistHelpDraft()
        } else if practice {
            let token = turn.begin(.generating)
            task = Task {
                do {
                    let pitch = try await Task.detached { try AudioFile.pitch(url) }.value
                    guard !Task.isCancelled, turn.epoch == token else { return }
                    expression?.attempts.append(Attempt(file:url.lastPathComponent)); attemptPitch = pitch; saveExpression(); _ = turn.finish(token)
                    notice = pitch.contains(where: { $0.hz != nil }) ? "Try comparing one phrase at a time. These contours are unscored." : "No clear voiced pitch detected. Try speaking closer to the microphone."
                } catch { fail(error,token:token) }
            }
        } else if let id = selectedID {
            do { let pcm = try AudioFile.pcm(url); requestReply(history:conversation?.messages ?? [],text:"",pcm:pcm,audioFile:url.lastPathComponent,conversationID:id) }
            catch { self.error = error.localizedDescription }
        }
    }
    func resume() {
        cancelHelpWork()
        let completed = !english.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && saveExpression()
        if completed, !isSavedPractice, let ci = library.conversations.firstIndex(where: { $0.id == selectedID }) {
            let saved = library.conversations[ci].helpDraft
            library.conversations[ci].helpDraft = nil
            if save() {
                restoringHelp = true; thoughtRecording = nil; recognizedThought = nil; restoringHelp = false
                removeUnreferencedRecording(saved?.recording)
            } else { library.conversations[ci].helpDraft = saved }
        }
        leavePractice(); expression = nil
        notice = completed ? "Saved to My Expressions. Say the thought in your own words when you're ready." : "You're back. Your help draft is saved."
    }
    func openExpression(_ item: PracticeExpression) {
        var sourceID = item.conversationID
        if !library.conversations.contains(where:{ $0.id == sourceID && !$0.isDeleted && !$0.archived }) {
            var candidate = library; let chat = Conversation(title:"Practice: " + String(item.english.prefix(42)))
            candidate.conversations.insert(chat,at:0); candidate.selectedConversationID = chat.id
            guard commitHistory(candidate) else { return }; sourceID = chat.id
        }
        if sourceID == selectedID { cancelHelpWork() } else { stop() }; leavePractice(); isSavedPractice = true; selectedID = sourceID; historyScope = .active; search = ""; draft = conversation?.draft ?? ""; showExpressions = false; turn.pause(); restoringHelp = true; expression = item; english = item.english; meaning = item.meaning; thoughtRecording = nil; recognizedThought = nil; restoringHelp = false; helpStage = .practice; referencePitch = []; attemptPitch = []
        let token = turn.begin(.generating)
        task = Task {
            do {
                if let name = item.reference { let url = store.root.appendingPathComponent(name); let points = try await Task.detached { try AudioFile.pitch(url) }.value; guard turn.epoch == token else { return }; referencePitch = points }
                if let name = item.attempts.last?.file { let url = store.root.appendingPathComponent(name); let points = try await Task.detached { try AudioFile.pitch(url) }.value; guard turn.epoch == token else { return }; attemptPitch = points }
                _ = turn.finish(token)
            } catch { fail(error,token:token) }
        }
    }
    func checkConnection() {
        guard !busy else { return }
        let token = turn.begin(.generating); serviceStatus = "Checking…"
        let service = RealtimeService(auth:auth,model:modelName,voice:conversationVoice,options:conversationVoiceOptions)
        task = Task {
            do {
                _ = try await service.reply(ConversationRequest(history:[],text:"Reply with the single word ready."))
                guard turn.epoch == token else { return }; serviceStatus = "Verified · text response received"; _ = turn.finish(token)
            } catch { guard turn.epoch == token else { return }; serviceStatus = "Not connected"; fail(error,token:token) }
        }
    }
    private func fail(_ failure: Error, token: UUID) {
        guard turn.epoch == token else { return }
        _ = turn.finish(token); speaking = false; recordingMeaning = false
        helpProgress = nil; recordingLevel = -80
        if !(failure is CancellationError) { error = (failure as? AppFailure)?.message ?? "This operation could not finish. Check the selected audio file or your connection, then retry." }
    }
    private func seedPreview() {
        var chat = Conversation(title:"A thought I've been putting off")
        chat.messages = [Message(role:"assistant",text:"What's been on your mind today?"),Message(role:"user",text:"I have an idea for a small project, but I haven't started yet."),Message(role:"assistant",text:"What's making it hard to get started?")]
        library.conversations = [chat,Conversation(title:"An idea over coffee"),Conversation(title:"The book I’m reading")]
        selectedID = chat.id; turn.pause(); helpStage = .practice; meaning = "I know what I mean. I just need the words."
        english = "I keep putting it off because I don't know where to start."
        var item = PracticeExpression(conversationID:chat.id,meaning:meaning,english:english)
        item.referenceKind = "Preview · illustrative contours"; expression = item
        referencePitch = (0..<180).map { i in
            let t = Double(i)
            let frequency: Double = 145 + 24 * sin(t * 0.07) + 7 * sin(t * 0.25)
            return PitchPoint(time:t * 0.025,hz:i % 37 < 4 ? nil : frequency)
        }
        attemptPitch = (0..<180).map { i in
            let t = Double(i)
            let frequency: Double = 151 + 16 * sin(t * 0.07 + 0.3)
            return PitchPoint(time:t * 0.027,hz:i % 39 < 5 ? nil : frequency)
        }
    }
}
