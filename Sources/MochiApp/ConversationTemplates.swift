import Foundation
import MochiCore

/// One customization sheet. Instruction drafts are retained when its content changes to save-as.
enum TemplatePresentation: String { case picker, manager, editor }
struct ConversationSettingsDraft {
    var id: UUID
    var instructions: String
    var characterName: String?
    var preferences: ConversationPreferences
}
struct TemplateEditorDraft {
    var value: ConversationTemplate
    var editingID: UUID?
    var expectedRevision: String?
}
extension AppModel {
    var displayCharacterName: String { conversation?.displayCharacterName ?? "Mochi" }
    var allTemplates: [ConversationTemplate] { ConversationTemplate.builtins + library.conversationTemplates }
    var templateCatalogRevision: String {
        // Sorted signatures avoid UI activity/locale affecting pagination.
        (try? MochiTools.signature(name:"template_catalog",arguments:["templates":allTemplates.sorted { $0.id.uuidString < $1.id.uuidString }.map { ["id":$0.id.uuidString,"revision":$0.revision] }])) ?? ""
    }
    /// Picker starts need only valid copied settings (as MCP instantiation does); editors and the manager need a writable template.
    var templateDraftIssue: String? {
        guard let draft = templateDraft else { return "Choose a template or create one." }
        do {
            if templatePresentation == .picker { _ = try draft.value.conversation() } else { try draft.value.validateForWrite() }
            return nil
        } catch { return (error as? AppFailure)?.message ?? "Review the settings." }
    }
    func template(id: UUID) throws -> ConversationTemplate {
        guard let value = allTemplates.first(where:{ $0.id == id }) else { throw AppFailure("Template not found. Keep your draft and save it as a new template.") }
        return value
    }
    func createTemplate(fields: [String:Any]) throws -> ConversationTemplate {
        guard library.conversationTemplates.count < ConversationTemplate.userLimit else { throw AppFailure("You have 200 or more user templates. Edit or remove an existing template before adding another.") }
        let t = try ConversationTemplate(title:"").applying(fields,creation:true)
        var candidate = library; candidate.conversationTemplates.append(t)
        try commitLibraryCandidate(candidate); return t
    }
    func updateTemplate(id: UUID, revision: String, fields: [String:Any]) throws -> ConversationTemplate {
        let current = try template(id:id)
        guard !current.isBuiltin else { throw AppFailure("Built-in templates are read-only. Duplicate one to customize it.") }
        guard current.revision == revision else { throw AppFailure("This template changed. Your draft is kept; reload it or save as new.") }
        let updated = try current.applying(fields)
        if updated != current {
            var candidate = library
            let index = candidate.conversationTemplates.firstIndex(where:{ $0.id == id })!
            candidate.conversationTemplates[index] = updated
            try commitLibraryCandidate(candidate)
        }
        return updated
    }
    func deleteTemplate(id: UUID, revision: String) throws {
        let current = try template(id:id)
        guard !current.isBuiltin else { throw AppFailure("Built-in templates cannot be deleted.") }
        guard current.revision == revision else { throw AppFailure("This template changed. Read it again before deleting.") }
        var candidate = library; candidate.conversationTemplates.removeAll { $0.id == id }
        try commitLibraryCandidate(candidate)
    }
    /// Creates exactly the previewed snapshot; provenance does not depend on a surviving catalog entry.
    func startTemplateSnapshot(_ snapshot: ConversationTemplate, title: String? = nil) throws -> UUID {
        guard !busy, !practice, !managerOpen, instructionsID == nil, renameID == nil, permanentDeleteIDs.isEmpty else { throw AppFailure("Finish the current activity before starting a conversation.") }
        let chat = try snapshot.conversation(title:title)
        var candidate = library; candidate.conversations.insert(chat,at:0); candidate.selectedConversationID = chat.id
        try commitLibraryCandidate(candidate)
        templatePresentation = nil; templateDraft = nil
        select(chat.id); historyScope = .active; search = ""; revealWorkspace?()
        return chat.id
    }
    func openTemplatePicker() { guard canOpenConversationInstructions else { return }; templateDraft = nil; templatePresentation = .picker }
    func openTemplateManager() { guard canOpenConversationInstructions else { return }; templateDraft = nil; templatePresentation = .manager }
    func editTemplate(_ value: ConversationTemplate?, duplicate: Bool = false) {
        templateReturnTo = templatePresentation; templateReturnDraft = templateDraft
        var t = value ?? ConversationTemplate(title:"")
        let editing = value != nil && !duplicate && !t.isBuiltin
        if !editing { t.id = UUID(); t.revision = UUID().uuidString; t.createdAt = Date(); t.updatedAt = t.createdAt }
        templateDraft = TemplateEditorDraft(value:t,editingID:editing ? t.id : nil,expectedRevision:editing ? t.revision : nil)
        templatePresentation = .editor
    }
    func saveConversationAsTemplate(_ id: UUID, draft: ConversationSettingsDraft? = nil) {
        guard !busy, !practice, !managerOpen, renameID == nil, permanentDeleteIDs.isEmpty, templatePresentation == nil, instructionsID == nil || draft?.id == instructionsID, let chat = library.conversations.first(where:{ $0.id == id && !$0.archived && !$0.isDeleted }) else { return }
        if let draft { retainedInstructionsDraft = draft }
        let t = ConversationTemplate(title:chat.title,characterName:draft?.characterName ?? chat.characterName,instructions:draft?.instructions ?? chat.instructions,preferences:draft?.preferences ?? chat.preferences)
        // A nil draft name is an intentional reset, not a request to inherit the saved name.
        var copy = t; if let draft { copy.characterName = draft.characterName }
        templateReturnTo = nil; templateReturnDraft = nil; templateDraft = TemplateEditorDraft(value:copy,editingID:nil,expectedRevision:nil); templatePresentation = .editor
    }
    /// Returning to the picker restores its customized preview; manager previews are re-selected from the live catalog.
    func closeTemplateEditor() {
        templateDraft = templateReturnTo == .picker ? templateReturnDraft : nil
        templatePresentation = templateReturnTo; templateReturnTo = nil; templateReturnDraft = nil
    }
    func executeTemplateTool(_ name: String, arguments: [String:Any]) throws -> [String:Any] {
        func result(_ fields: [String:Any]) -> [String:Any] { fields.merging(["ok":true,"revision":controlRevision,"catalog_revision":templateCatalogRevision]) { _,new in new } }
        if name == "list_conversation_templates" {
            if let expected = arguments["expected_catalog_revision"] as? String, expected != templateCatalogRevision { throw AppFailure("Template catalog changed. Restart listing from offset 0.") }
            let query = (arguments["query"] as? String ?? "").trimmingCharacters(in:.whitespacesAndNewlines)
            let origin = arguments["origin"] as? String ?? "all"
            let values = allTemplates.filter { (origin == "all" || ($0.isBuiltin ? "built_in" : "user") == origin) && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.description.localizedCaseInsensitiveContains(query)) }.sorted {
                if $0.isBuiltin != $1.isBuiltin { return $0.isBuiltin }
                if $0.title != $1.title { return $0.title.utf8.lexicographicallyPrecedes($1.title.utf8) }
                return $0.id.uuidString < $1.id.uuidString
            }
            let offset = min((arguments["offset"] as? NSNumber)?.intValue ?? 0,values.count)
            let limit = (arguments["limit"] as? NSNumber)?.intValue ?? 30
            var page: [[String:Any]] = [], index = offset
            while index < values.count && page.count < limit {
                let item = values[index].representation(includeInstructions:false)
                let candidate = result(["templates":page + [item],"next_offset":index+1])
                if try JSONSerialization.data(withJSONObject:candidate).count >= 110000 { break }
                page.append(item); index += 1
            }
            return result(["templates":page,"next_offset":index < values.count ? index as Any : NSNull()])
        }
        if name == "create_conversation_template" {
            let t = try createTemplate(fields:arguments); return result(["template":t.representation()])
        }
        guard let text = arguments["template_id"] as? String, let id = UUID(uuidString:text) else { throw AppFailure("A template ID is required.") }
        if name == "get_conversation_template" { return result(["template":try template(id:id).representation()]) }
        guard let rev = arguments["expected_template_revision"] as? String else { throw AppFailure("Read the template revision first.") }
        if name == "update_conversation_template" { return result(["template":try updateTemplate(id:id,revision:rev,fields:arguments).representation()]) }
        try deleteTemplate(id:id,revision:rev); return result(["deleted_template_id":id.uuidString])
    }
}
