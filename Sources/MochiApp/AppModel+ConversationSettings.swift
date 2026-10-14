import Foundation
import MochiCore
import MochiKernel

/// A conversation's instructions, character name and preferences, and when they can be edited.
extension AppModel {
    var displayCharacterName: String { conversation?.displayCharacterName ?? "Mochi" }
    /// A conversation as the user starts one: empty, in their default language.
    func freshConversation(title: String = Conversation.untitled) -> Conversation {
        var chat = Conversation(title: title)
        chat.preferences.language = settings.defaultLanguage
        return chat
    }
    /// The open conversation's language, named in the interface's language.
    var languageName: String { (conversation?.preferences.language ?? ConversationPreferences().language).displayName }
    /// The language of the expression being practised, which keeps the language it was saved in.
    var practiceLanguageName: String { help.expression?.language?.displayName ?? languageName }
    /// The language a conversation is held in; English for one that no longer exists, as before languages.
    func language(of id: UUID) -> ConversationLanguage {
        library.conversations.first { $0.id == id }?.preferences.language ?? ConversationPreferences().language
    }
    var automationModal: Bool {
        customization.isPresented || practice || history.isEditing
    }
    var canOpenConversationInstructions: Bool { !busy && !automationModal }
    func openConversationInstructions(_ id: UUID) {
        guard canOpenConversationInstructions,
            library.conversations.contains(where: { $0.id == id && !$0.archived && !$0.isDeleted })
        else { return }
        customization.instructionsID = id
    }
    @discardableResult func setConversationInstructions(
        _ id: UUID, instructions: String, preferences: ConversationPreferences
    ) -> Bool {
        setConversationInstructions(
            id, instructions: instructions, preferences: preferences,
            characterName: library.conversations.first(where: { $0.id == id })?.characterName)
    }
    /// Saves these settings and keeps the conversation's others as they are.
    @discardableResult func setConversationInstructions(
        _ id: UUID, instructions: String, preferences: ConversationPreferences, characterName: String?
    ) -> Bool {
        guard let chat = library.conversations.first(where: { $0.id == id }) else {
            error = String(localized: "This conversation cannot be edited right now.")
            return false
        }
        var draft = ConversationSettingsDraft(chat)
        draft.instructions = instructions
        draft.preferences = preferences
        draft.characterName = characterName
        return saveConversationSettings(id, draft)
    }
    /// The settings sheet's save: only what the draft changed is written, so stored text over a limit, or a voice
    /// this version does not know, is kept unless the user edits it.
    @discardableResult func saveConversationSettings(_ id: UUID, _ draft: some ConversationSettingsHolder) -> Bool {
        do {
            guard !busy, !practice, !history.isEditing,
                let current = library.conversations.first(where: { $0.id == id && !$0.archived && !$0.isDeleted })
            else { throw AppFailure("This conversation cannot be edited right now.") }
            try updateConversationSettings(id, ConversationSettingsPatch(changing: current, to: draft))
            error = nil
            return true
        } catch {
            self.error = AppFailure.message(for: error, fallback: "Could not save conversation instructions.")
            return false
        }
    }
    /// The one path that changes a conversation's settings. Callers decide whether a change is allowed now.
    func updateConversationSettings(_ id: UUID, _ patch: ConversationSettingsPatch) throws {
        guard let index = library.conversations.firstIndex(where: { $0.id == id && !$0.archived && !$0.isDeleted })
        else { throw AppFailure("An active conversation is required.") }
        var candidate = library
        try patch.apply(to: &candidate.conversations[index])
        do { try commitLibraryCandidate(candidate) } catch {
            throw AppFailure(
                verbatim: persistenceMessage(
                    error, action: "Save conversation settings",
                    fallback: "The settings could not be saved. Nothing was changed.",
                    diskFull: "The settings could not be saved because the disk is full. Nothing was changed."),
                underlying: error)
        }
    }
}
