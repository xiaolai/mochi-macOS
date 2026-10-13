import Foundation
import MochiKernel

public enum HistoryScope: String, CaseIterable, Identifiable {
    case active, archived, deleted
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .active: return String(localized: "Conversations")
        case .archived: return String(localized: "Archived")
        case .deleted: return String(localized: "Recently Deleted")
        }
    }
    public var icon: String {
        switch self {
        case .active: return "bubble.left.and.bubble.right"
        case .archived: return "archivebox"
        case .deleted: return "trash"
        }
    }
}
extension Conversation {
    /// Matches the text a message shows as its content, so every search agrees on legacy voice placeholders.
    private func messageMatcher(_ query: String) -> ((Message) -> Bool)? {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return nil }
        return { $0.contextText?.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
    public func matchingMessage(_ query: String) -> Message? {
        messageMatcher(query).flatMap { messages.first(where: $0) }
    }
    /// Whether the conversation belongs in `scope` without a search.
    func isListed(in scope: HistoryScope) -> Bool {
        switch scope {
        case .active: return !isDeleted && !archived
        case .archived: return !isDeleted && archived
        case .deleted: return isDeleted
        }
    }
    public func matchingMessageIDs(_ query: String) -> [UUID] {
        messageMatcher(query).map { messages.filter($0).map(\.id) } ?? []
    }
    public func matches(_ query: String) -> Bool {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return title.range(of: query, options: options) != nil
            || displayCharacterName.range(of: query, options: options) != nil
            || matchingMessage(query) != nil
    }
}
/// How the history list is ordered. Pinned conversations lead in every order.
public enum HistorySort: String, CaseIterable, Sendable {
    /// Latest activity first; in Recently Deleted, latest deletion first.
    case recent
    /// Newest conversation first.
    case created
    /// Alphabetical by title.
    case title
    /// Alphabetical by the companion's name, then latest activity first.
    case companion
    public var title: String {
        switch self {
        case .recent: return String(localized: "Recent Activity")
        case .created: return String(localized: "Date Created")
        case .title: return String(localized: "Title")
        case .companion: return String(localized: "Character Name")
        }
    }
}
extension Library {
    /// Every companion name used in this scope, alphabetically; Mochi names conversations without a custom one.
    public func companions(in scope: HistoryScope) -> [String] {
        Set(conversations.filter { $0.isListed(in: scope) }.map(\.displayCharacterName))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    /// The number of conversations `history(in:)` would list, without sorting them.
    public func count(in scope: HistoryScope) -> Int {
        conversations.reduce(0) { $0 + ($1.isListed(in: scope) ? 1 : 0) }
    }
    /// The conversations listed in `scope`, optionally only those matching `query` or with one companion, in `sort`
    /// order. A search in Conversations also finds archived ones.
    public func history(
        in scope: HistoryScope, query: String = "", sort: HistorySort = .recent, companion: String? = nil
    ) -> [Conversation] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return conversations.filter { c in
            let included = c.isListed(in: scope) || (scope == .active && !term.isEmpty && !c.isDeleted)
            return included && (term.isEmpty || c.matches(term))
                && (companion == nil || c.displayCharacterName == companion)
        }.sorted {
            if scope == .active && $0.pinned != $1.pinned { return $0.pinned }
            let order: ComparisonResult
            switch sort {
            case .recent: order = .orderedSame
            case .created:
                order = $0.date == $1.date ? .orderedSame : $0.date > $1.date ? .orderedAscending : .orderedDescending
            case .title: order = $0.displayTitle.localizedStandardCompare($1.displayTitle)
            case .companion: order = $0.displayCharacterName.localizedStandardCompare($1.displayCharacterName)
            }
            if order != .orderedSame { return order == .orderedAscending }
            let lhs = scope == .deleted ? $0.deletedAt! : $0.updatedAt
            let rhs = scope == .deleted ? $1.deletedAt! : $1.updatedAt
            return lhs == rhs ? $0.id.uuidString < $1.id.uuidString : lhs > rhs
        }
    }
    public mutating func moveToDeleted(_ ids: Set<UUID>, now: Date = Date()) {
        for i in conversations.indices where ids.contains(conversations[i].id) && !conversations[i].isDeleted {
            conversations[i].wasArchivedBeforeDeletion = conversations[i].archived
            conversations[i].deletedAt = now
        }
    }
    public mutating func restore(_ ids: Set<UUID>) {
        for i in conversations.indices where ids.contains(conversations[i].id) {
            if conversations[i].isDeleted {
                conversations[i].deletedAt = nil
                conversations[i].archived = conversations[i].wasArchivedBeforeDeletion
            } else {
                conversations[i].archived = false
            }
        }
    }
    public var referencedAudio: Set<String> {
        Set(
            conversations.flatMap { $0.messages.compactMap(\.audio) + [$0.helpDraft?.recording].compactMap { $0 } }
                + expressions.flatMap { [$0.reference].compactMap { $0 } + $0.attempts.map(\.file) })
    }
    @discardableResult public mutating func removePermanently(_ ids: Set<UUID>) -> Set<String> {
        let before = referencedAudio
        conversations.removeAll { ids.contains($0.id) && $0.isDeleted }
        if let selectedConversationID, !conversations.contains(where: { $0.id == selectedConversationID }) {
            self.selectedConversationID = nil
        }
        return before.subtracting(referencedAudio)
    }
    public func validate() throws {
        guard Set(conversations.map(\.id)).count == conversations.count,
            Set(expressions.map(\.id)).count == expressions.count
        else { throw AppFailure("The library contains duplicate IDs.") }
        guard Set(conversationTemplates.map(\.id)).count == conversationTemplates.count,
            !conversationTemplates.contains(where: {
                $0.isBuiltin || $0.revision.isEmpty || $0.revision.utf8.count > 200
            })
        else { throw AppFailure("The library contains invalid or duplicate template IDs/revisions.") }
        guard Set(characters.map(\.id)).count == characters.count,
            !characters.contains(where: { $0.isBuiltin || $0.revision.isEmpty || $0.revision.utf8.count > 200 })
        else { throw AppFailure("The library contains invalid or duplicate character IDs/revisions.") }
        let attempts = expressions.flatMap(\.attempts)
        guard Set(attempts.map(\.id)).count == attempts.count else {
            throw AppFailure("The library contains duplicate attempt IDs.")
        }
        let messages = conversations.flatMap(\.messages)
        guard Set(messages.map(\.id)).count == messages.count else {
            throw AppFailure("The library contains duplicate message IDs.")
        }
        for chat in conversations { try chat.preferences.validate() }
        for message in messages {
            guard message.recording?.isValid ?? true else {
                throw AppFailure("The library contains invalid recording details.")
            }
            if let evidence = message.transcriptEvidence {
                guard evidence.isValid, evidence.text == message.text else {
                    throw AppFailure("The library contains transcript evidence that does not match its text.")
                }
            }
        }
        guard expressions.allSatisfy({ $0.review?.isValid ?? true }) else {
            throw AppFailure("The library contains invalid review state.")
        }
        for name in referencedAudio {
            // The v4 backups are matched by their suffix too: an older library may name a recording with that prefix.
            guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\"),
                !name.hasPrefix("."), !name.hasPrefix("library-before-character-templates-v3"),
                !(name.hasPrefix(LibraryStore.characterLibraryBackupPrefix) && name.hasSuffix(".json")),
                !(name.hasPrefix(LibraryStore.reviewLibraryBackupPrefix) && name.hasSuffix(".json")),
                !name.hasPrefix("library-unreadable-"), !LibraryStore.reservedNames.contains(name)
            else { throw AppFailure("The library contains an unsafe recording filename.") }
        }
    }
}
public enum HistoryExport {
    public static func markdown(_ chats: [Conversation]) -> String {
        chats.map { chat in
            "# \(chat.title.replacingOccurrences(of:"\n",with:" "))\n\n"
                + chat.messages.map { message in
                    "### \(message.role == "user" ? "You" : (message.speakerName ?? "Mochi")) · \(message.date.formatted(.iso8601))\n\n\(message.text)\n"
                        + (message.audio.map { "\nRecording: `\($0)` (audio is included only in a library backup).\n" }
                            ?? "")
                }.joined(separator: "\n")
        }.joined(separator: "\n---\n\n")
    }
    public static func json(_ chats: [Conversation]) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        struct Transcript: Encodable {
            let format = "mochi-transcript"
            let version = 1
            let conversations: [Conversation]
        }
        return try e.encode(Transcript(conversations: chats))
    }
}
