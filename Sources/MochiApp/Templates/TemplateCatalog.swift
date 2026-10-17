import Foundation
import MochiCore
import MochiKernel

/// How the picker and manager group templates: the built-in categories first, then the user's own.
enum TemplateSection: CaseIterable {
    case general, languagePractice, mine
    var title: String {
        switch self {
        case .general: String(localized: "Talk about anything")
        case .languagePractice: String(localized: "Practise a language")
        case .mine: String(localized: "My Templates")
        }
    }
    init(_ template: ConversationTemplate) {
        switch template.category {
        case .general?: self = .general
        case .languagePractice?: self = .languagePractice
        case nil: self = .mine
        }
    }
}

/// The templates a conversation can start from: the built-ins and the user's, which the library keeps.
/// Every change is committed whole, so a failed write leaves the catalog as it was.
@MainActor struct TemplateCatalog {
    let library: LibraryController
    /// The templates in the catalog; those in Recently Deleted are left out.
    var all: [ConversationTemplate] {
        ConversationTemplate.builtins + library.library.conversationTemplates.filter { !$0.isDeleted }
    }
    /// User templates an assistant deleted, most recently deleted first, until recovered or deleted permanently.
    var recentlyDeleted: [ConversationTemplate] {
        library.library.conversationTemplates.filter(\.isDeleted).sorted { $0.deletedAt! > $1.deletedAt! }
    }
    /// The non-empty sections, in order, holding the templates whose stored or translated title or description
    /// contains `query`.
    func sections(matching query: String) -> [(section: TemplateSection, templates: [ConversationTemplate])] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let found = all.filter { t in
            term.isEmpty
                || [t.title, t.description, t.displayTitle, t.displayDescription].contains {
                    $0.localizedCaseInsensitiveContains(term)
                }
        }
        return TemplateSection.allCases.compactMap { section in
            let templates = found.filter { TemplateSection($0) == section }
            return templates.isEmpty ? nil : (section, templates)
        }
    }
    func template(id: UUID) throws -> ConversationTemplate {
        guard let value = all.first(where: { $0.id == id }) else {
            throw AppFailure("Template not found. Keep your draft and save it as a new template.")
        }
        return value
    }
    func create(_ patch: ConversationTemplate.Patch) throws -> ConversationTemplate {
        guard library.library.conversationTemplates.count < ConversationTemplate.userLimit else {
            throw AppFailure(
                "You have 200 or more user templates. Edit or remove an existing template before adding another.")
        }
        let t = try ConversationTemplate(title: "").applying(patch, creation: true)
        var candidate = library.library
        candidate.conversationTemplates.append(t)
        try library.commit(candidate)
        return t
    }
    func update(id: UUID, revision: String, _ patch: ConversationTemplate.Patch) throws -> ConversationTemplate {
        let current = try template(id: id)
        guard !current.isBuiltin else {
            throw AppFailure("Built-in templates are read-only. Duplicate one to customize it.")
        }
        guard current.revision == revision else {
            throw AppFailure("This template changed. Your draft is kept; reload it or save as new.")
        }
        let updated = try current.applying(patch)
        if updated != current {
            var candidate = library.library
            guard let index = candidate.conversationTemplates.firstIndex(where: { $0.id == id }) else {
                throw AppFailure("Template not found. Keep your draft and save it as a new template.")
            }
            candidate.conversationTemplates[index] = updated
            try library.commit(candidate)
        }
        return updated
    }
    /// Removes a template for good, from the catalog or from Recently Deleted. Only the user does this, in Mochi.
    func delete(id: UUID, revision: String) throws {
        let current = try stored(id: id)
        guard current.revision == revision else {
            throw AppFailure("This template changed. Read it again before deleting.")
        }
        var candidate = library.library
        candidate.conversationTemplates.removeAll { $0.id == id }
        try library.commit(candidate)
    }
    /// Moves a user template to Recently Deleted, where the user can recover it: how an assistant deletes one.
    func moveToRecentlyDeleted(id: UUID, revision: String, now: Date = Date()) throws {
        let current = try template(id: id)
        guard !current.isBuiltin else { throw AppFailure("Built-in templates cannot be deleted.") }
        guard current.revision == revision else {
            throw AppFailure("This template changed. Read it again before deleting.")
        }
        try change(id) { $0.deletedAt = now }
    }
    /// Returns a template from Recently Deleted to the catalog, unchanged.
    func recover(id: UUID) throws {
        guard try stored(id: id).isDeleted else { return }
        try change(id) { $0.deletedAt = nil }
    }
    /// A user template as stored, in the catalog or in Recently Deleted.
    private func stored(id: UUID) throws -> ConversationTemplate {
        if ConversationTemplate.reservedIDs.contains(id) { throw AppFailure("Built-in templates cannot be deleted.") }
        guard let value = library.library.conversationTemplates.first(where: { $0.id == id }) else {
            throw AppFailure("Template not found. Keep your draft and save it as a new template.")
        }
        return value
    }
    private func change(_ id: UUID, _ edit: (inout ConversationTemplate) -> Void) throws {
        var candidate = library.library
        guard let index = candidate.conversationTemplates.firstIndex(where: { $0.id == id }) else {
            throw AppFailure("Template not found. Keep your draft and save it as a new template.")
        }
        edit(&candidate.conversationTemplates[index])
        try library.commit(candidate)
    }
}
