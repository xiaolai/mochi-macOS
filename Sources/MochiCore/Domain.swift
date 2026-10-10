import MochiAutomation
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
    public var speakerName: String?
    public var date = Date()
    public var transcriptionState: TranscriptionState?
    public var transcriptionError: String?
    public init(role: String, text: String, audio: String? = nil, speakerName: String? = nil) { self.role = role; self.text = text; self.audio = audio; self.speakerName = speakerName }
    public var contextText: String? {
        guard !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
              !(role == "user" && audio != nil && Self.legacyLabels.contains(text)) else { return nil }
        return text
    }
    public var displayText: String { contextText ?? (role == "user" && audio != nil ? "Voice recording" : text) }
    private static let legacyLabels = ["Voice message (transcript unavailable)","Voice message · awaiting transcript"]
    private enum CodingKeys: String, CodingKey { case id,role,text,audio,date,transcriptionState,transcriptionError,speakerName }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy:CodingKeys.self)
        id = try c.decode(UUID.self,forKey:.id); role = try c.decode(String.self,forKey:.role)
        text = try c.decode(String.self,forKey:.text); audio = try c.decodeIfPresent(String.self,forKey:.audio)
        speakerName = try c.decodeIfPresent(String.self,forKey:.speakerName)
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
    public var instructions = ""
    public var preferences = ConversationPreferences()
    public var characterName: String?
    public var sourceTemplateID: UUID?
    public var sourceTemplateRevision: String?
    public var characterNameNeedsReview: Bool { characterName != nil && (try? ConversationTemplate.validateName(characterName)) == nil }
    public var displayCharacterName: String { characterNameNeedsReview ? "Companion" : characterName ?? "Mochi" }
    public var isPristine: Bool { messages.isEmpty && !customTitle && instructions.isEmpty && draft.isEmpty && helpDraft == nil && preferences == ConversationPreferences() && characterName == nil && sourceTemplateID == nil && sourceTemplateRevision == nil }
    public var voiceIntroduced = false
    public var isDeleted: Bool { deletedAt != nil }
    public var updatedAt: Date { messages.last?.date ?? date }
    public init(title: String = "A new conversation") { self.title = title }
    private enum CodingKeys: String, CodingKey { case id,title,messages,date,pinned,archived,deletedAt,wasArchivedBeforeDeletion,customTitle,draft,helpDraft,voiceIntroduced,instructions,preferences,characterName,sourceTemplateID,sourceTemplateRevision }
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
        characterName = try c.decodeIfPresent(String.self,forKey:.characterName)
        sourceTemplateID = try c.decodeIfPresent(UUID.self,forKey:.sourceTemplateID)
        sourceTemplateRevision = try c.decodeIfPresent(String.self,forKey:.sourceTemplateRevision)
        instructions = try c.decodeIfPresent(String.self,forKey:.instructions) ?? ""
        preferences = try c.decodeIfPresent(ConversationPreferences.self,forKey:.preferences) ?? ConversationPreferences()
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
    public var conversationTemplates: [ConversationTemplate] = []
    public var version = 3
    public var selectedConversationID: UUID?
    public var conversations: [Conversation] = []
    public var expressions: [PracticeExpression] = []
    public init() {}
    private enum CodingKeys: String, CodingKey { case version,selectedConversationID,conversations,expressions,conversationTemplates }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy:CodingKeys.self)
        version = try c.decode(Int.self,forKey:.version)
        selectedConversationID = try c.decodeIfPresent(UUID.self,forKey:.selectedConversationID)
        conversations = try c.decode([Conversation].self,forKey:.conversations)
        expressions = try c.decode([PracticeExpression].self,forKey:.expressions)
        conversationTemplates = try c.decodeIfPresent([ConversationTemplate].self,forKey:.conversationTemplates) ?? []
    }
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
        guard (1...3).contains(library.version) else { throw AppFailure("This library was created by a newer app. Your data has not been changed.") }
        try library.validate()
        for ci in library.conversations.indices {
            for mi in library.conversations[ci].messages.indices where library.conversations[ci].messages[mi].transcriptionState == .pending {
                library.conversations[ci].messages[mi].transcriptionState = .interrupted
            }
        }
        library.version = 3
        return library
    }
    public func cleanupOrphanedAudio(_ library: Library) throws {
        try library.validate()
        let referenced = library.referencedAudio
        for url in try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:[.isRegularFileKey,.isSymbolicLinkKey]) {
            let name = url.lastPathComponent
            guard !referenced.contains(name), name.hasSuffix(".wav"),
                  name.hasPrefix("recording-") || name.hasPrefix("reply-") else { continue }
            let stem = String(name.dropLast(4)), uuid = stem.hasPrefix("reply-") ? String(stem.dropFirst(6)) : String(stem.dropFirst(10))
            guard UUID(uuidString:uuid) != nil else { continue }
            let values = try url.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey])
            if values.isRegularFile == true && values.isSymbolicLink != true { try FileManager.default.removeItem(at:url) }
        }
    }
    public func save(_ library: Library) throws {
        try prepare()
        guard (1...3).contains(library.version) else { throw AppFailure("Unsupported library version.") }
        try library.validate()
        var library = library; library.version = 3
        if FileManager.default.fileExists(atPath:file.path) {
            let original = try Data(contentsOf:file)
            let existing = try JSONDecoder().decode(Library.self,from:original)
            guard (1...3).contains(existing.version) else { throw AppFailure("Unsupported library version; existing data was not changed.") }
            if existing.version < 3 {
                let base = root.appendingPathComponent("library-before-character-templates-v3.json")
                let backupExists = FileManager.default.fileExists(atPath:base.path)
                let backupMatches = backupExists ? try Data(contentsOf:base) == original : false
                if !backupMatches {
                    let destination = FileManager.default.fileExists(atPath:base.path) ? root.appendingPathComponent("library-before-character-templates-v3-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString).json") : base
                    try writeNewPrivateFile(original,to:destination)
                }
            }
            let instructionsBackup = root.appendingPathComponent("library-before-conversation-instructions.json")
            if !FileManager.default.fileExists(atPath:instructionsBackup.path) {
                try writeNewPrivateFile(original,to:instructionsBackup)
            }
            let featureBackup = root.appendingPathComponent("library-before-help-transcription.json")
            if library.conversations.contains(where: { $0.helpDraft != nil || $0.messages.contains(where: { $0.transcriptionState != nil }) }), !FileManager.default.fileExists(atPath:featureBackup.path) {
                try writeNewPrivateFile(original,to:featureBackup)
            }
            let backup = root.appendingPathComponent("library-v1-backup.json")
            if existing.version == 1 && !FileManager.default.fileExists(atPath:backup.path) {
                try writeNewPrivateFile(original,to:backup)
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let staging = root.appendingPathComponent(".library-write-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at:staging) }
        try encoder.encode(library).write(to:staging,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:staging.path)
        guard Darwin.rename(staging.path,file.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO) }
    }
    /// Creates a complete 0600 copy that never replaces an existing file, so a failed write cannot leave a partial or briefly readable backup under the final name.
    private func writeNewPrivateFile(_ data: Data, to destination: URL) throws {
        let staging = root.appendingPathComponent(".backup-write-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at:staging) }
        let descriptor = Darwin.open(staging.path,O_WRONLY | O_CREAT | O_EXCL,0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor:descriptor,closeOnDealloc:true)
        try handle.write(contentsOf:data); try handle.synchronize(); try handle.close()
        guard renamex_np(staging.path,destination.path,UInt32(RENAME_EXCL)) == 0 else { throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO) }
    }
}
