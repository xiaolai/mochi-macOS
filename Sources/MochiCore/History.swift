import MochiAutomation
import Foundation

public enum HistoryScope: String, CaseIterable, Identifiable {
    case active, archived, deleted
    public var id: String { rawValue }
    public var title: String { switch self { case .active: return "Conversations"; case .archived: return "Archived"; case .deleted: return "Recently Deleted" } }
    public var icon: String { switch self { case .active: return "bubble.left.and.bubble.right"; case .archived: return "archivebox"; case .deleted: return "trash" } }
}
public extension Conversation {
    func matchingMessage(_ query: String) -> Message? {
        let term = query.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !term.isEmpty else { return nil }
        return messages.first { $0.text.range(of:term,options:[.caseInsensitive,.diacriticInsensitive]) != nil }
    }
    func matchingMessageIDs(_ query: String) -> [UUID] {
        let term = query.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !term.isEmpty else { return [] }
        return messages.filter { $0.contextText?.range(of:term,options:[.caseInsensitive,.diacriticInsensitive]) != nil }.map(\.id)
    }
    func matches(_ query: String) -> Bool { title.range(of:query,options:[.caseInsensitive,.diacriticInsensitive]) != nil || matchingMessage(query) != nil }
}
public extension Library {
    func history(in scope: HistoryScope, query: String = "") -> [Conversation] {
        let term = query.trimmingCharacters(in:.whitespacesAndNewlines)
        return conversations.filter { c in
            let included: Bool
            switch scope {
            case .active: included = !c.isDeleted && (!c.archived || !term.isEmpty)
            case .archived: included = !c.isDeleted && c.archived
            case .deleted: included = c.isDeleted
            }
            return included && (term.isEmpty || c.matches(term))
        }.sorted {
            if scope == .active && $0.pinned != $1.pinned { return $0.pinned }
            let lhs = scope == .deleted ? $0.deletedAt! : $0.updatedAt
            let rhs = scope == .deleted ? $1.deletedAt! : $1.updatedAt
            return lhs == rhs ? $0.id.uuidString < $1.id.uuidString : lhs > rhs
        }
    }
    mutating func moveToDeleted(_ ids: Set<UUID>, now: Date = Date()) {
        for i in conversations.indices where ids.contains(conversations[i].id) && !conversations[i].isDeleted {
            conversations[i].wasArchivedBeforeDeletion = conversations[i].archived
            conversations[i].deletedAt = now
        }
    }
    mutating func restore(_ ids: Set<UUID>) {
        for i in conversations.indices where ids.contains(conversations[i].id) {
            if conversations[i].isDeleted { conversations[i].deletedAt = nil; conversations[i].archived = conversations[i].wasArchivedBeforeDeletion }
            else { conversations[i].archived = false }
        }
    }
    var referencedAudio: Set<String> {
        Set(conversations.flatMap { $0.messages.compactMap(\.audio) + [$0.helpDraft?.recording].compactMap { $0 } } + expressions.flatMap { [$0.reference].compactMap { $0 } + $0.attempts.map(\.file) })
    }
    @discardableResult mutating func removePermanently(_ ids: Set<UUID>) -> Set<String> {
        let before = referencedAudio
        conversations.removeAll { ids.contains($0.id) && $0.isDeleted }
        if let selectedConversationID, !conversations.contains(where: { $0.id == selectedConversationID }) { self.selectedConversationID = nil }
        return before.subtracting(referencedAudio)
    }
    func validate() throws {
        guard Set(conversations.map(\.id)).count == conversations.count, Set(expressions.map(\.id)).count == expressions.count else { throw AppFailure("The library contains duplicate IDs.") }
        guard Set(conversationTemplates.map(\.id)).count == conversationTemplates.count,
              !conversationTemplates.contains(where:{ $0.isBuiltin || $0.revision.isEmpty || $0.revision.utf8.count > 200 }) else { throw AppFailure("The library contains invalid or duplicate template IDs/revisions.") }
        let attempts = expressions.flatMap(\.attempts)
        guard Set(attempts.map(\.id)).count == attempts.count else { throw AppFailure("The library contains duplicate attempt IDs.") }
        let messages = conversations.flatMap(\.messages)
        guard Set(messages.map(\.id)).count == messages.count else { throw AppFailure("The library contains duplicate message IDs.") }
        for chat in conversations { try chat.preferences.validate() }
        for name in referencedAudio {
            guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\"), !name.hasPrefix("."), !name.hasPrefix("library-before-character-templates-v3"), !["library.json","library-v1-backup.json","library-before-help-transcription.json","library-before-conversation-instructions.json"].contains(name) else { throw AppFailure("The library contains an unsafe recording filename.") }
        }
    }
}
public enum HistoryExport {
    public static func markdown(_ chats: [Conversation]) -> String {
        chats.map { chat in
            "# \(chat.title.replacingOccurrences(of:"\n",with:" "))\n\n" + chat.messages.map { message in
                "### \(message.role == "user" ? "You" : (message.speakerName ?? "Mochi")) · \(message.date.formatted(.iso8601))\n\n\(message.text)\n" + (message.audio.map { "\nRecording: `\($0)` (audio is included only in a library backup).\n" } ?? "")
            }.joined(separator:"\n")
        }.joined(separator:"\n---\n\n")
    }
    public static func json(_ chats: [Conversation]) throws -> Data {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted,.sortedKeys]; e.dateEncodingStrategy = .iso8601
        struct Transcript: Encodable { let format = "mochi-transcript"; let version = 1; let conversations: [Conversation] }
        return try e.encode(Transcript(conversations:chats))
    }
}
public enum LibraryBackup {
    public static func write(_ library: Library, from root: URL, to package: URL) throws {
        try library.validate()
        guard !FileManager.default.fileExists(atPath:package.path) else { throw AppFailure("Choose a new backup filename; an existing backup is never overwritten.") }
        for name in library.referencedAudio { _ = try regularFile(root.appendingPathComponent(name)) }
        try FileManager.default.createDirectory(at:package,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        do {
            let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted,.sortedKeys]
            var normalized = library; normalized.version = 3
            try e.encode(normalized).write(to:package.appendingPathComponent("library.json"),options:.atomic)
            for name in library.referencedAudio { try FileManager.default.copyItem(at:root.appendingPathComponent(name),to:package.appendingPathComponent(name)) }
        } catch { try? FileManager.default.removeItem(at:package); throw error }
    }
    public static func read(_ package: URL) throws -> Library {
        _ = try regularFile(package.appendingPathComponent("library.json"))
        var library = try JSONDecoder().decode(Library.self,from:Data(contentsOf:package.appendingPathComponent("library.json")))
        guard (1...3).contains(library.version) else { throw AppFailure("This backup requires a newer app.") }
        try library.validate()
        for name in library.referencedAudio { _ = try regularFile(package.appendingPathComponent(name)) }
        library.version = 3
        return library
    }
    // Only missing IDs are imported; each imported audio name is remapped to avoid collisions.
    public static func merge(_ imported: Library, from package: URL, into local: inout Library, root: URL) throws -> Int {
        try imported.validate()
        for name in imported.referencedAudio { _ = try regularFile(package.appendingPathComponent(name)) }
        let chatIDs = Set(local.conversations.map(\.id)), expressionIDs = Set(local.expressions.map(\.id))
        var additions = Library()
        additions.conversations = imported.conversations.filter { !chatIDs.contains($0.id) }
        additions.expressions = imported.expressions.filter { !expressionIDs.contains($0.id) }
        let templateIDs = Set(local.conversationTemplates.map(\.id))
        additions.conversationTemplates = imported.conversationTemplates.filter { !templateIDs.contains($0.id) }
        let localMessageIDs = Set(local.conversations.flatMap(\.messages).map(\.id))
        guard !additions.conversations.flatMap(\.messages).contains(where:{ localMessageIDs.contains($0.id) }) else { throw AppFailure("Imported message IDs conflict with local history.") }
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        var mapping: [String:String] = [:], copied: [URL] = []
        do {
            for name in additions.referencedAudio {
                let replacement = "import-\(UUID().uuidString).\(URL(fileURLWithPath:name).pathExtension)"
                let destination = root.appendingPathComponent(replacement)
                try FileManager.default.copyItem(at:package.appendingPathComponent(name),to:destination)
                copied.append(destination); mapping[name] = replacement
            }
            for ci in additions.conversations.indices {
                if let name = additions.conversations[ci].helpDraft?.recording { additions.conversations[ci].helpDraft?.recording = mapping[name] }
                for mi in additions.conversations[ci].messages.indices {
                    if let name = additions.conversations[ci].messages[mi].audio { additions.conversations[ci].messages[mi].audio = mapping[name] }
                    if additions.conversations[ci].messages[mi].transcriptionState == .pending { additions.conversations[ci].messages[mi].transcriptionState = .interrupted }
                }
            }
            for i in additions.expressions.indices {
                if let name = additions.expressions[i].reference { additions.expressions[i].reference = mapping[name] }
                for ai in additions.expressions[i].attempts.indices { let name = additions.expressions[i].attempts[ai].file; additions.expressions[i].attempts[ai].file = mapping[name]! }
            }
            local.conversations += additions.conversations; local.expressions += additions.expressions; local.conversationTemplates += additions.conversationTemplates
            local.version = 3
            return additions.conversations.count
        } catch { for url in copied { try? FileManager.default.removeItem(at:url) }; throw error }
    }
    private static func regularFile(_ url: URL) throws -> Bool {
        let v = try url.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey])
        guard v.isRegularFile == true, v.isSymbolicLink != true else { throw AppFailure("A backup recording is missing or is not a regular file.") }
        return true
    }
}
