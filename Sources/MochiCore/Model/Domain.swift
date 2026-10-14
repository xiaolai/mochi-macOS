import Foundation
import MochiKernel

public enum Mode: String, Codable { case conversation, practice }
public enum Activity: String { case idle, generating, playing, recording, requestingPermission }
public enum AudioOwner { case none, conversation, practice, playback }
public struct TurnMachine {
    public private(set) var mode: Mode = .conversation
    public private(set) var activity: Activity = .idle
    public private(set) var epoch = UUID()
    public var owner: AudioOwner {
        activity == .playing
            ? .playback : activity == .recording ? (mode == .practice ? .practice : .conversation) : .none
    }
    public init() {}
    @discardableResult public mutating func begin(_ activity: Activity) -> UUID {
        epoch = UUID()
        self.activity = activity
        return epoch
    }
    public mutating func finish(_ token: UUID) -> Bool {
        guard token == epoch else { return false }
        activity = .idle
        return true
    }
    public mutating func pause() {
        mode = .practice
        _ = begin(.idle)
    }
    public mutating func resume() {
        mode = .conversation
        _ = begin(.idle)
    }
    public mutating func stop() { _ = begin(.idle) }
    public mutating func startRecording() -> Bool {
        guard activity == .idle else { return false }
        _ = begin(.recording)
        return true
    }
}
public struct Message: Codable, Identifiable, Equatable {
    public var id = UUID()
    public var role: String
    public var text: String
    public var audio: String?
    public var speakerName: String?
    public var date = Date()
    public var transcriptionState: TranscriptionState?
    public var transcriptionError: String?
    /// For a voice message: how it is transcribed. Set when recorded and never changed.
    public var recording: RecordingMetadata?
    /// The transcriber's confidence in `text`; nil when it has none, or the text was edited or typed.
    public var transcriptEvidence: TranscriptEvidence?
    /// True for a Start Again request, so a retried reply keeps the conversation's opening; nil otherwise.
    public var startsAgain: Bool?
    public init(role: String, text: String, audio: String? = nil, speakerName: String? = nil) {
        self.role = role
        self.text = text
        self.audio = audio
        self.speakerName = speakerName
    }
    public var contextText: String? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !isLegacyLabel else { return nil }
        return text
    }
    public var displayText: String {
        contextText ?? (role == "user" && audio != nil ? String(localized: "Voice recording") : text)
    }
    private static let legacyLabels = ["Voice message (transcript unavailable)", "Voice message · awaiting transcript"]
    /// A placeholder an early version stored as the text of a voice message it could not transcribe. Those versions
    /// stored no transcription state, recording details or evidence, so a message with any of them is a real
    /// transcript, even one that reads like a label.
    private var isLegacyLabel: Bool {
        role == "user" && audio != nil && transcriptionState == nil && recording == nil && transcriptEvidence == nil
            && Self.legacyLabels.contains(text)
    }
    private enum CodingKeys: String, CodingKey {
        case id, role, text, audio, date, transcriptionState, transcriptionError, speakerName, recording
        case transcriptEvidence, startsAgain
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        role = try c.decode(String.self, forKey: .role)
        text = try c.decode(String.self, forKey: .text)
        audio = try c.decodeIfPresent(String.self, forKey: .audio)
        speakerName = try c.decodeIfPresent(String.self, forKey: .speakerName)
        date = try c.decode(Date.self, forKey: .date)
        transcriptionState = try c.decodeIfPresent(TranscriptionState.self, forKey: .transcriptionState)
        transcriptionError = try c.decodeIfPresent(String.self, forKey: .transcriptionError)
        recording = try c.decodeIfPresent(RecordingMetadata.self, forKey: .recording)
        transcriptEvidence = try c.decodeIfPresent(TranscriptEvidence.self, forKey: .transcriptEvidence)
        startsAgain = try c.decodeIfPresent(Bool.self, forKey: .startsAgain)
        if isLegacyLabel {
            transcriptionState = text.contains("awaiting") ? .interrupted : .failed
            text = ""
        }
    }
}
public struct Conversation: Codable, Identifiable {
    public var id = UUID()
    public var title: String
    public var messages: [Message] = []
    public var date = Date()
    public var pinned = false
    public var archived = false
    public var deletedAt: Date?
    public var wasArchivedBeforeDeletion = false
    public var customTitle = false
    public var draft = ""
    public var helpDraft: HelpDraft?
    public var instructions = ""
    public var preferences = ConversationPreferences()
    public var characterName: String?
    /// How the companion comes across; empty for Mochi's own manner.
    public var personality = ""
    /// What the companion says first when the user starts talking; empty for a standard greeting.
    public var greeting = ""
    /// Lines the user can send with one click.
    public var phrases: [String] = []
    public var sourceTemplateID: UUID?
    public var sourceTemplateRevision: String?
    public var characterNameNeedsReview: Bool {
        characterName != nil && (try? ConversationTemplate.validateName(characterName)) == nil
    }
    public var displayCharacterName: String { characterNameNeedsReview ? "Companion" : characterName ?? "Mochi" }
    /// Nothing has happened here yet. Its language is not counted: a new conversation starts in the user's default
    /// language, and reusing it takes the default again.
    public var isPristine: Bool {
        var settings = preferences
        settings.language = ConversationPreferences().language
        return messages.isEmpty && !customTitle && instructions.isEmpty && draft.isEmpty && helpDraft == nil
            && settings == ConversationPreferences() && characterName == nil && personality.isEmpty
            && greeting.isEmpty && phrases.isEmpty && sourceTemplateID == nil && sourceTemplateRevision == nil
    }
    public var voiceIntroduced = false
    /// Whether the companion speaks a greeting before the first recording: only in a conversation that has not
    /// started, so a conversation begun by typing is never greeted midway.
    public var greetsBeforeRecording: Bool { messages.isEmpty && !voiceIntroduced }
    public var isDeleted: Bool { deletedAt != nil }
    public var updatedAt: Date { messages.last?.date ?? date }
    /// The stored title of an untitled conversation. It stays English on disk: older libraries are read by comparing to it.
    public static let untitled = "A new conversation"
    public init(title: String = Conversation.untitled) { self.title = title }
    /// The title as shown: an untitled conversation reads in the app's language.
    public var displayTitle: String {
        !customTitle && title == Self.untitled ? String(localized: "A new conversation") : title
    }
    private enum CodingKeys: String, CodingKey {
        case id, title, messages, date, pinned, archived, deletedAt, wasArchivedBeforeDeletion, customTitle, draft,
            helpDraft, voiceIntroduced, instructions, preferences, characterName, sourceTemplateID,
            sourceTemplateRevision, personality, greeting, phrases
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        messages = try c.decode([Message].self, forKey: .messages)
        date = try c.decode(Date.self, forKey: .date)
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        archived = try c.decodeIfPresent(Bool.self, forKey: .archived) ?? false
        deletedAt = try c.decodeIfPresent(Date.self, forKey: .deletedAt)
        wasArchivedBeforeDeletion = try c.decodeIfPresent(Bool.self, forKey: .wasArchivedBeforeDeletion) ?? false
        customTitle =
            try c.decodeIfPresent(Bool.self, forKey: .customTitle)
            ?? (title != Self.untitled && messages.isEmpty)
        draft = try c.decodeIfPresent(String.self, forKey: .draft) ?? ""
        helpDraft = try c.decodeIfPresent(HelpDraft.self, forKey: .helpDraft)
        characterName = try c.decodeIfPresent(String.self, forKey: .characterName)
        personality = try c.decodeIfPresent(String.self, forKey: .personality) ?? ""
        greeting = try c.decodeIfPresent(String.self, forKey: .greeting) ?? ""
        phrases = try c.decodeIfPresent([String].self, forKey: .phrases) ?? []
        sourceTemplateID = try c.decodeIfPresent(UUID.self, forKey: .sourceTemplateID)
        sourceTemplateRevision = try c.decodeIfPresent(String.self, forKey: .sourceTemplateRevision)
        instructions = try c.decodeIfPresent(String.self, forKey: .instructions) ?? ""
        preferences =
            try c.decodeIfPresent(ConversationPreferences.self, forKey: .preferences) ?? ConversationPreferences()
        voiceIntroduced =
            try c.decodeIfPresent(Bool.self, forKey: .voiceIntroduced)
            ?? messages.contains { $0.role == "user" && $0.audio != nil }
    }
}
public struct Attempt: Codable, Identifiable {
    public var id = UUID()
    public var file: String
    public var date = Date()
    public init(file: String) { self.file = file }
}
public struct PracticeExpression: Codable, Identifiable {
    public var id = UUID()
    public var conversationID: UUID
    public var meaning: String
    /// The expression in the language practised; named for the English-only expressions saved before languages.
    public var english: String
    /// The language of `english`; nil for expressions saved before languages existed, which are English.
    public var language: ConversationLanguage?
    public var reference: String?
    public var referenceKind: String = "Your voice"
    public var attempts: [Attempt] = []
    public var date = Date()
    /// Spoken review; nil until the expression is enrolled.
    public var review: ReviewState?
    public init(conversationID: UUID, meaning: String, english: String, language: ConversationLanguage) {
        self.conversationID = conversationID
        self.meaning = meaning
        self.english = english
        self.language = language
    }
}
public struct Library: Codable {
    /// The format this version of Mochi writes. Version 4 added characters and each setup's personality, greeting,
    /// phrases and voice; version 5 added review state, recording metadata and transcript evidence. Older Mochi
    /// refuses a newer format rather than dropping what it does not know.
    public static let currentVersion = 5
    public var conversationTemplates: [ConversationTemplate] = []
    /// The user's own characters; the built-in ones are defined in code.
    public var characters: [ConversationCharacter] = []
    public var version = Library.currentVersion
    public var selectedConversationID: UUID?
    public var conversations: [Conversation] = []
    public var expressions: [PracticeExpression] = []
    public init() {}
    private enum CodingKeys: String, CodingKey {
        case version, selectedConversationID, conversations, expressions, conversationTemplates, characters
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        selectedConversationID = try c.decodeIfPresent(UUID.self, forKey: .selectedConversationID)
        conversations = try c.decode([Conversation].self, forKey: .conversations)
        expressions = try c.decode([PracticeExpression].self, forKey: .expressions)
        conversationTemplates = try c.decodeIfPresent([ConversationTemplate].self, forKey: .conversationTemplates) ?? []
        characters = try c.decodeIfPresent([ConversationCharacter].self, forKey: .characters) ?? []
    }
}
extension Library {
    /// Whether any conversation has a Help draft or a transcription, which the oldest libraries could not hold.
    var usesHelpOrTranscription: Bool {
        conversations.contains(where: {
            $0.helpDraft != nil || $0.messages.contains(where: { $0.transcriptionState != nil })
        })
    }
    /// Transcriptions recorded as pending have no running job once the library is read back from disk.
    public mutating func interruptPendingTranscriptions() {
        for ci in conversations.indices {
            for mi in conversations[ci].messages.indices
            where conversations[ci].messages[mi].transcriptionState == .pending {
                conversations[ci].messages[mi].transcriptionState = .interrupted
            }
        }
    }
}
public enum TranscriptionState: String, Codable { case pending, completed, failed, timedOut, interrupted }
public struct HelpDraft: Codable {
    public var meaning: String
    public var english: String
    public var recording: String?
    public var expressionID: UUID?
    public var clarification: String?
    public var transcriptReview: String?
    public init(meaning: String = "", english: String = "", recording: String? = nil, expressionID: UUID? = nil) {
        self.meaning = meaning
        self.english = english
        self.recording = recording
        self.expressionID = expressionID
    }
}
