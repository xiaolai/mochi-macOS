import Foundation
import MochiCore
import MochiKernel
import MochiProviders

/// The app's stored settings. Stored values that no longer validate fall back to defaults, and the log names them.
@MainActor @Observable final class PreferencesStore {
    @ObservationIgnored let defaults: UserDefaults
    /// The Model field as typed. A blank value is not stored, so the default returns after a restart.
    var modelName: String {
        didSet {
            if Self.trimmed(modelName) == nil {
                defaults.removeObject(forKey: "model")
            } else {
                defaults.set(modelName, forKey: "model")
            }
        }
    }
    /// The model services use: the typed name without surrounding spaces, or the default when it is blank.
    var effectiveModelName: String { Self.trimmed(modelName) ?? RealtimeService.defaultModel }
    /// The Codex model chosen for text requests; empty means Automatic. A name Codex no longer lists is not used.
    var textModel: String {
        didSet {
            if Self.trimmed(textModel) == nil {
                defaults.removeObject(forKey: "textModel")
            } else {
                defaults.set(textModel, forKey: "textModel")
            }
        }
    }
    /// The reasoning effort chosen for text requests; empty means Automatic. One the model lacks is not used.
    var textEffort: String {
        didSet {
            if Self.trimmed(textEffort) == nil {
                defaults.removeObject(forKey: "textEffort")
            } else {
                defaults.set(textEffort, forKey: "textEffort")
            }
        }
    }
    /// What Mochi calls the user, as typed. Empty until the user gives a name, and a blank name is not stored.
    var userName: String {
        didSet {
            if Self.trimmed(userName) == nil {
                defaults.removeObject(forKey: "userName")
            } else {
                defaults.set(userName, forKey: "userName")
            }
        }
    }
    /// The name replies use: the typed name without surrounding spaces, or nil when it is blank or unusable.
    var effectiveUserName: String? { VoiceIdentity.usable(userName) }
    var conversationVoice: String { didSet { defaults.set(conversationVoice, forKey: "conversationVoice") } }
    var builtInPracticeVoice: String { didSet { defaults.set(builtInPracticeVoice, forKey: "builtInPracticeVoice") } }
    var conversationVoiceOptions: OpenAIVoiceOptions {
        didSet { store(conversationVoiceOptions, key: "conversationVoiceOptions") }
    }
    var practiceVoiceOptions: OpenAIVoiceOptions { didSet { store(practiceVoiceOptions, key: "practiceVoiceOptions") } }
    /// Whether practice examples are converted into the learner's own voice through ElevenLabs. Off unless turned on.
    var practiceTimbreEnabled: Bool { didSet { defaults.set(practiceTimbreEnabled, forKey: "practiceTimbreEnabled") } }
    /// The ElevenLabs voice ID of the learner's own clone, as typed. The API key is in the Keychain, not here.
    var practiceTimbreVoiceID: String {
        didSet { defaults.set(practiceTimbreVoiceID, forKey: "practiceTimbreVoiceID") }
    }
    var externalControlEnabled: Bool {
        didSet { defaults.set(externalControlEnabled, forKey: "externalControlEnabled") }
    }
    /// The language new conversations start in.
    var defaultLanguage: ConversationLanguage {
        didSet { defaults.set(defaultLanguage.rawValue, forKey: "defaultLanguage") }
    }
    /// The order of the conversation list.
    var historySort: HistorySort { didSet { defaults.set(historySort.rawValue, forKey: "historySort") } }
    /// Whether Mochi sits on the desktop outside the workspace.
    var petVisible: Bool { didSet { defaults.set(petVisible, forKey: "desktopPetVisible") } }
    /// Whether the desktop Mochi's eyes follow the pointer while she is idle; off unless turned on.
    var petFollowsPointer: Bool { didSet { defaults.set(petFollowsPointer, forKey: "desktopPetFollowsPointer") } }
    /// Whether the message bar sits under the desktop Mochi; on unless turned off.
    var petBarVisible: Bool { didSet { defaults.set(petBarVisible, forKey: "desktopPetBarVisible") } }
    /// Where the desktop Mochi was left, in screen coordinates; nil until she is first moved.
    var petOrigin: CGPoint? {
        didSet {
            if let petOrigin, petOrigin.x.isFinite, petOrigin.y.isFinite {
                defaults.set([Double(petOrigin.x), Double(petOrigin.y)], forKey: "desktopPetOrigin")
            } else {
                defaults.removeObject(forKey: "desktopPetOrigin")
            }
        }
    }
    /// Shortcuts that work in every app. An action without one is absent.
    /// Stored only when it differs from the default: a removed shortcut is stored as empty data, so it stays removed,
    /// and an action left at its default follows the default. Only the actions a change touches are written.
    var shortcuts: [ShortcutAction: Shortcut] {
        didSet {
            for action in ShortcutAction.allCases where shortcuts[action] != oldValue[action] { storeShortcut(action) }
        }
    }
    /// Actions whose stored shortcut could not be read or is no longer allowed. Each stays unbound rather than taking
    /// its default keys, which another app may rely on, and its stored value is kept until the learner records or
    /// removes a shortcut for it.
    private(set) var unreadableShortcuts: Set<ShortcutAction>
    /// Records or removes one action's shortcut. Removing the shortcut of an action whose stored one was unreadable
    /// changes nothing in `shortcuts`, so its stored value is replaced here.
    func setShortcut(_ shortcut: Shortcut?, for action: ShortcutAction) {
        let unchanged = shortcuts[action] == shortcut
        shortcuts[action] = shortcut
        if unchanged && unreadableShortcuts.contains(action) { storeShortcut(action) }
    }
    private func storeShortcut(_ action: ShortcutAction) {
        unreadableShortcuts.remove(action)
        switch shortcuts[action] {
        case action.defaultShortcut: defaults.removeObject(forKey: action.preferenceKey)
        case nil: defaults.set(Data(), forKey: action.preferenceKey)
        case let shortcut?:
            do { defaults.set(try JSONEncoder().encode(shortcut), forKey: action.preferenceKey) } catch {
                MochiLog.failure(MochiLog.app, "Save preference \(action.preferenceKey)", error)
            }
        }
    }
    /// Press to send or hands-free; press to send unless the learner chooses otherwise.
    var talkingMode: TalkingMode {
        didSet {
            defaults.set(talkingMode.rawValue, forKey: "talkingMode")
            if talkingMode != oldValue { talkingModeChanged?(talkingMode) }
        }
    }
    /// Told at once when the talking mode changes, before any observer runs.
    @ObservationIgnored var talkingModeChanged: ((TalkingMode) -> Void)?
    /// In press to send, open the microphone after a reply plays, as after a greeting. Off by default.
    var listenAfterReply: Bool { didSet { defaults.set(listenAfterReply, forKey: "listenAfterReply") } }
    /// How long hands-free waits for the learner to finish a turn.
    var listeningPatience: ListeningPatience {
        didSet { defaults.set(listeningPatience.rawValue, forKey: "listeningPatience") }
    }
    /// How long hands-free stays open in silence.
    var listeningSilenceLimit: ListeningSilenceLimit {
        didSet { defaults.set(listeningSilenceLimit.rawValue, forKey: "listeningSilenceMinutes") }
    }
    var practiceVoiceLabel: String {
        // The learner's own voice replaces the built-in one, so the example is labelled by the speaker it sounds like.
        if practiceTimbreEnabled { return "Your voice" }
        return
            "\(RealtimeVoice(rawValue: builtInPracticeVoice)?.name ?? RealtimeService.defaultVoice.capitalized) · Codex voice"
    }
    /// The conversion to apply to a new practice example, or nil when the feature is off. A voice ID that does not
    /// validate throws here, before any paid request, so a bad setting never costs a sentence.
    func practiceTimbre() throws -> PracticeTimbre? {
        guard practiceTimbreEnabled else { return nil }
        return try PracticeTimbre(voiceID: practiceTimbreVoiceID)
    }
    /// The last few greeting patterns, so a new conversation does not open with the same words.
    var recentGreetings: [String] {
        get { defaults.stringArray(forKey: "voiceGreetingHistory") ?? [] }
        set { defaults.set(Array(newValue.suffix(3)), forKey: "voiceGreetingHistory") }
    }

    /// - Parameters:
    ///   - importLegacy: copy settings that earlier app identities stored, without overwriting newer values.
    ///   - allowExternalControl: false for preview data, which must never be reachable from outside.
    init(_ defaults: UserDefaults, importLegacy: Bool, allowExternalControl: Bool) {
        self.defaults = defaults
        if importLegacy {
            for oldDomain in AppIdentity.legacyBundleIdentifiers {
                AppIdentity.migratePreferences(
                    into: defaults, legacy: defaults.persistentDomain(forName: oldDomain) ?? [:])
            }
        }
        func voice(_ key: String) -> String {
            guard let stored = defaults.string(forKey: key) else { return RealtimeService.defaultVoice }
            if let voice = RealtimeVoice(rawValue: stored) { return voice.rawValue }
            MochiLog.failure(
                MochiLog.app, "Stored preference \(key) names an unknown voice; using the default",
                AppFailure("Unknown voice."), level: .default)
            return RealtimeService.defaultVoice
        }
        func options(_ key: String) -> OpenAIVoiceOptions {
            guard let data = defaults.data(forKey: key) else { return OpenAIVoiceOptions() }
            do {
                let value = try JSONDecoder().decode(OpenAIVoiceOptions.self, from: data)
                try value.validate()
                return value
            } catch {
                MochiLog.failure(
                    MochiLog.app, "Stored preference \(key) was rejected; using the default", error, level: .default)
                return OpenAIVoiceOptions()
            }
        }
        modelName = defaults.string(forKey: "model").flatMap(Self.trimmed) ?? RealtimeService.defaultModel
        userName = defaults.string(forKey: "userName") ?? ""
        textModel = defaults.string(forKey: "textModel").flatMap(Self.trimmed) ?? ""
        textEffort = defaults.string(forKey: "textEffort").flatMap(Self.trimmed) ?? ""
        defaultLanguage =
            defaults.string(forKey: "defaultLanguage").flatMap(ConversationLanguage.init(rawValue:)) ?? .english
        historySort = defaults.string(forKey: "historySort").flatMap(HistorySort.init(rawValue:)) ?? .recent
        conversationVoice = voice("conversationVoice")
        builtInPracticeVoice = voice("builtInPracticeVoice")
        conversationVoiceOptions = options("conversationVoiceOptions")
        practiceVoiceOptions = options("practiceVoiceOptions")
        practiceTimbreEnabled = defaults.bool(forKey: "practiceTimbreEnabled")
        practiceTimbreVoiceID = defaults.string(forKey: "practiceTimbreVoiceID") ?? ""
        externalControlEnabled = allowExternalControl && defaults.bool(forKey: "externalControlEnabled")
        talkingMode = Self.stored(defaults, "talkingMode", TalkingMode.init(rawValue:)) ?? .pressToSend
        listenAfterReply = defaults.bool(forKey: "listenAfterReply")
        listeningPatience =
            Self.stored(defaults, "listeningPatience", ListeningPatience.init(rawValue:)) ?? .patient
        listeningSilenceLimit =
            Self.stored(
                defaults, "listeningSilenceMinutes", { (minutes: Int) in ListeningSilenceLimit(rawValue: minutes) })
            ?? .twoMinutes
        petVisible = defaults.bool(forKey: "desktopPetVisible")
        petFollowsPointer = defaults.bool(forKey: "desktopPetFollowsPointer")
        petBarVisible = defaults.object(forKey: "desktopPetBarVisible") as? Bool ?? true
        if let point = defaults.array(forKey: "desktopPetOrigin") as? [Double], point.count == 2,
            point.allSatisfy(\.isFinite)
        {
            petOrigin = CGPoint(x: point[0], y: point[1])
        } else {
            petOrigin = nil
        }
        var shortcuts = ShortcutAction.defaults
        var unreadable: Set<ShortcutAction> = []
        for action in ShortcutAction.allCases {
            guard let data = defaults.data(forKey: action.preferenceKey) else { continue }
            if data.isEmpty {
                shortcuts[action] = nil
                continue
            }
            do {
                let shortcut = try JSONDecoder().decode(Shortcut.self, from: data)
                if let problem = shortcut.problem { throw AppFailure(verbatim: problem) }
                shortcuts[action] = shortcut
            } catch {
                shortcuts[action] = nil
                unreadable.insert(action)
                MochiLog.failure(
                    MochiLog.app, "Stored preference \(action.preferenceKey) was rejected; leaving the action unbound",
                    error, level: .default)
            }
        }
        self.shortcuts = shortcuts
        unreadableShortcuts = unreadable
    }
    /// Mochi's conversation voice, optionally with one conversation's own speed and voice. A voice this version does
    /// not support is replaced by the Settings voice, so an imported choice never fails a reply.
    func conversationService(speed: Double? = nil, voice: String? = nil) -> RealtimeService {
        var options = conversationVoiceOptions
        if let speed { options.speed = speed }
        let supported = voice.flatMap(RealtimeVoice.init(rawValue:))?.rawValue
        if voice != nil, supported == nil {
            MochiLog.app.notice("A conversation's voice is not available in this version; using the Settings voice")
        }
        return RealtimeService(model: effectiveModelName, voice: supported ?? conversationVoice, options: options)
    }
    /// The service that speaks for `chat`: its own speed and voice over the Settings ones.
    func conversationService(for chat: Conversation?) -> RealtimeService {
        conversationService(speed: chat?.preferences.speed, voice: chat?.preferences.voice)
    }
    /// The name of the voice a conversation without its own voice uses.
    var conversationVoiceName: String {
        RealtimeVoice(rawValue: conversationVoice)?.name ?? RealtimeService.defaultVoice.capitalized
    }
    /// The voice for practice examples, or another voice being previewed.
    func practiceService(voice: String? = nil, options: OpenAIVoiceOptions? = nil) -> RealtimeService {
        RealtimeService(
            model: effectiveModelName, voice: voice ?? builtInPracticeVoice, options: options ?? practiceVoiceOptions)
    }
    /// A stored choice, or nil when there is none; a stored value this version does not know is logged and ignored.
    private static func stored<Raw, Value>(_ defaults: UserDefaults, _ key: String, _ make: (Raw) -> Value?) -> Value? {
        guard let raw = defaults.object(forKey: key) else { return nil }
        if let raw = raw as? Raw, let value = make(raw) { return value }
        MochiLog.failure(
            MochiLog.app, "Stored preference \(key) was rejected; using the default", AppFailure("Unknown value."),
            level: .default)
        return nil
    }
    private static func trimmed(_ value: String) -> String? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
    private func store(_ value: OpenAIVoiceOptions, key: String) {
        do { defaults.set(try JSONEncoder().encode(value), forKey: key) } catch {
            MochiLog.failure(MochiLog.app, "Save preference \(key)", error)
        }
    }
}
