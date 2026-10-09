import Foundation
import CryptoKit
import Darwin

public enum Mode: String, Codable { case conversation, practice }
public enum Activity: String { case idle, generating, playing, recording, requestingPermission }
public enum AudioOwner { case none, conversation, practice, playback }
public struct TurnMachine {
    public private(set) var mode: Mode = .conversation
    public private(set) var activity: Activity = .idle
    public private(set) var epoch = UUID()
    public var owner: AudioOwner { activity == .playing ? .playback : activity == .recording ? (mode == .practice ? .practice : .conversation) : .none }
    public init() {}
    @discardableResult public mutating func begin(_ activity: Activity) -> UUID { epoch = UUID(); self.activity = activity; return epoch }
    public mutating func finish(_ token: UUID) -> Bool { guard token == epoch else { return false }; activity = .idle; return true }
    public mutating func pause() { mode = .practice; _ = begin(.idle) }
    public mutating func resume() { mode = .conversation; _ = begin(.idle) }
    public mutating func stop() { _ = begin(.idle) }
    public mutating func startRecording() -> Bool { guard activity == .idle else { return false }; _ = begin(.recording); return true }
}
public struct Message: Codable, Identifiable, Equatable {
    public var id = UUID()
    public var role: String
    public var text: String
    public var audio: String?
    public var date = Date()
    public var transcriptionState: TranscriptionState?
    public var transcriptionError: String?
    public init(role: String, text: String, audio: String? = nil) { self.role = role; self.text = text; self.audio = audio }
    public var contextText: String? {
        guard !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
              !(role == "user" && audio != nil && Self.legacyLabels.contains(text)) else { return nil }
        return text
    }
    public var displayText: String { contextText ?? (role == "user" && audio != nil ? "Voice recording" : text) }
    private static let legacyLabels = ["Voice message (transcript unavailable)","Voice message · awaiting transcript"]
    private enum CodingKeys: String, CodingKey { case id,role,text,audio,date,transcriptionState,transcriptionError }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy:CodingKeys.self)
        id = try c.decode(UUID.self,forKey:.id); role = try c.decode(String.self,forKey:.role)
        text = try c.decode(String.self,forKey:.text); audio = try c.decodeIfPresent(String.self,forKey:.audio)
        date = try c.decode(Date.self,forKey:.date)
        transcriptionState = try c.decodeIfPresent(TranscriptionState.self,forKey:.transcriptionState)
        transcriptionError = try c.decodeIfPresent(String.self,forKey:.transcriptionError)
        if role == "user", audio != nil, Self.legacyLabels.contains(text) {
            transcriptionState = text.contains("awaiting") ? .interrupted : .failed; text = ""
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
    public var voiceIntroduced = false
    public var isDeleted: Bool { deletedAt != nil }
    public var updatedAt: Date { messages.last?.date ?? date }
    public init(title: String = "A new conversation") { self.title = title }
    private enum CodingKeys: String, CodingKey { case id,title,messages,date,pinned,archived,deletedAt,wasArchivedBeforeDeletion,customTitle,draft,helpDraft,voiceIntroduced }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy:CodingKeys.self)
        id = try c.decode(UUID.self,forKey:.id); title = try c.decode(String.self,forKey:.title)
        messages = try c.decode([Message].self,forKey:.messages); date = try c.decode(Date.self,forKey:.date)
        pinned = try c.decodeIfPresent(Bool.self,forKey:.pinned) ?? false
        archived = try c.decodeIfPresent(Bool.self,forKey:.archived) ?? false
        deletedAt = try c.decodeIfPresent(Date.self,forKey:.deletedAt)
        wasArchivedBeforeDeletion = try c.decodeIfPresent(Bool.self,forKey:.wasArchivedBeforeDeletion) ?? false
        customTitle = try c.decodeIfPresent(Bool.self,forKey:.customTitle) ?? (title != "A new conversation" && messages.isEmpty)
        draft = try c.decodeIfPresent(String.self,forKey:.draft) ?? ""
        helpDraft = try c.decodeIfPresent(HelpDraft.self,forKey:.helpDraft)
        voiceIntroduced = try c.decodeIfPresent(Bool.self,forKey:.voiceIntroduced) ?? messages.contains { $0.role == "user" && $0.audio != nil }
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
    public var english: String
    public var reference: String?
    public var referenceKind: String = "Your voice"
    public var attempts: [Attempt] = []
    public var date = Date()
    public init(conversationID: UUID, meaning: String, english: String) { self.conversationID = conversationID; self.meaning = meaning; self.english = english }
}
public struct Library: Codable {
    public var version = 2
    public var selectedConversationID: UUID?
    public var conversations: [Conversation] = []
    public var expressions: [PracticeExpression] = []
    public init() {}
}
public struct LibraryStore {
    public let root: URL
    public var file: URL { root.appendingPathComponent("library.json") }
    public init(root: URL) { self.root = root }
    public func prepare() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
    public func load() throws -> Library {
        guard FileManager.default.fileExists(atPath: file.path) else { return Library() }
        let data = try Data(contentsOf: file)
        var library = try JSONDecoder().decode(Library.self, from: data)
        guard (1...2).contains(library.version) else { throw AppFailure("This library was created by a newer app. Your data has not been changed.") }
        try library.validate()
        for ci in library.conversations.indices {
            for mi in library.conversations[ci].messages.indices where library.conversations[ci].messages[mi].transcriptionState == .pending {
                library.conversations[ci].messages[mi].transcriptionState = .interrupted
            }
        }
        library.version = 2
        return library
    }
    public func save(_ library: Library) throws {
        try prepare()
        try library.validate()
        if FileManager.default.fileExists(atPath:file.path) {
            let original = try Data(contentsOf:file)
            let existing = try JSONDecoder().decode(Library.self,from:original)
            guard (1...2).contains(existing.version) else { throw AppFailure("Unsupported library version; existing data was not changed.") }
            let featureBackup = root.appendingPathComponent("library-before-help-transcription.json")
            if library.conversations.contains(where: { $0.helpDraft != nil || $0.messages.contains(where: { $0.transcriptionState != nil }) }), !FileManager.default.fileExists(atPath:featureBackup.path) {
                try original.write(to:featureBackup,options:.atomic)
                try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:featureBackup.path)
            }
            let backup = root.appendingPathComponent("library-v1-backup.json")
            if existing.version == 1 && !FileManager.default.fileExists(atPath:backup.path) {
                try original.write(to:backup,options:.atomic)
                try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:backup.path)
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let staging = root.appendingPathComponent(".library-write-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at:staging) }
        try encoder.encode(library).write(to:staging,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:staging.path)
        guard Darwin.rename(staging.path,file.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO) }
    }
}
public struct RenderIdentity: Codable {
    public var text: String
    public var performer: String
    public var clone: String
    public var speed: Double = 1
    public var ttsModel = "eleven_multilingual_v2"
    public var stsModel = "eleven_multilingual_sts_v2"
    public var schema = 2
    public var stability = 0.5
    public var similarity = 0.75
    public var style = 0.0
    public var speakerBoost = true
    public var conversion = ElevenVoiceOptions()
    public var pronunciation: ElevenVoiceOptions {
        var value = ElevenVoiceOptions(); value.stability = stability; value.similarity = similarity; value.style = style; value.speakerBoost = speakerBoost; return value
    }
    public var sourceKey: String {
        var source = self; source.clone = ""; source.conversion = ElevenVoiceOptions(); source.stsModel = ""; return source.key
    }
    public init(text: String, performer: String, clone: String) { self.text = text; self.performer = performer; self.clone = clone }
    public var key: String { let e = JSONEncoder(); e.outputFormatting = .sortedKeys; return SHA256.hash(data: (try? e.encode(self)) ?? Data()).map { String(format: "%02x", $0) }.joined() }
}
public struct AppFailure: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
