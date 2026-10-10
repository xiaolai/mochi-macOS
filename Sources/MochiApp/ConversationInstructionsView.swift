import SwiftUI
import MochiCore

struct ConversationInstructionsView: View {
    @ObservedObject var app: AppModel
    let id: UUID
    @State private var saveError: String?
    @State private var instructions = ""
    @State private var characterName: String?
    @State private var preferences = ConversationPreferences()
    private var validationError: String? {
        do { if instructions != app.library.conversations.first(where:{ $0.id == id })?.instructions { try MochiTools.validateInstructions(instructions) }; try ConversationTemplate.validateName(characterName); try preferences.validate(); return nil }
        catch { return (error as? AppFailure)?.message ?? "Review these settings." }
    }
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            Text("Conversation Instructions").font(.title2).fontWeight(.semibold)
            Text(app.library.conversations.first(where:{ $0.id == id })?.title ?? "").foregroundStyle(.secondary).lineLimit(1)
            Text("Tell \(MochiTools.boundedText(characterName ?? "Mochi",characters:80,bytes:1024)) how you want to practise. These settings apply to future replies.").font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment:.leading,spacing:12) {
                    ConversationSettingsFields(instructions:$instructions,characterName:$characterName,preferences:$preferences)
                }
            }
            if let error = saveError ?? validationError { Text(error).font(.callout).foregroundStyle(.red) }
            HStack {
                Button("Reset to Defaults") { instructions = ""; characterName = nil; preferences = ConversationPreferences() }
                Button("Save as Template…") {
                    app.saveConversationAsTemplate(id,draft:ConversationSettingsDraft(id:id,instructions:instructions,characterName:characterName,preferences:preferences))
                }.disabled(app.busy)
                Spacer()
                Button("Cancel") { app.instructionsID = nil; app.retainedInstructionsDraft = nil }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    let existingError = app.error
                    if app.setConversationInstructions(id,instructions:instructions,preferences:preferences,characterName:characterName) { app.instructionsID = nil; app.retainedInstructionsDraft = nil }
                    else { saveError = app.error }
                    app.error = existingError
                }.keyboardShortcut(.defaultAction).disabled(validationError != nil || app.busy)
            }
        }.padding(24).frame(width:560,height:540)
        .onAppear {
            if let draft = app.retainedInstructionsDraft, draft.id == id {
                instructions = draft.instructions; characterName = draft.characterName; preferences = draft.preferences
            } else if let chat = app.library.conversations.first(where:{ $0.id == id }) {
                instructions = chat.instructions; characterName = chat.characterName; preferences = chat.preferences
            }
        }
    }
}
