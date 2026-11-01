import MochiCore
import MochiKernel
import SwiftUI

/// Manage Characters: the built-in and the user's characters, a preview, and the character editor.
struct CharactersView: View {
    @Bindable var app: AppModel
    @State private var query = ""
    @State private var selection: UUID?
    @FocusState private var listFocused: Bool
    @FocusState private var personalityFocused: Bool
    @FocusState private var descriptionFocused: Bool
    @State private var error: String?
    @State private var pendingDelete: ConversationCharacter?
    private var mode: CharacterPresentation { app.customization.characterPresentation ?? .manager }
    private var draftBinding: Binding<ConversationCharacter> {
        Binding(
            get: { app.customization.characterDraft?.value ?? ConversationCharacter(name: "") },
            set: {
                app.customization.characterDraft?.value = $0
                error = nil
            })
    }
    private var selected: ConversationCharacter? {
        selection.flatMap { id in app.characters.all.first { $0.id == id } }
    }
    private var validationError: String? {
        guard mode == .editor, let draft = app.customization.characterDraft else { return nil }
        do {
            try draft.value.validateForWrite()
            if let voice = draft.value.voice, RealtimeVoice(rawValue: voice) == nil,
                draft.editingID == nil || app.characters.all.first(where: { $0.id == draft.editingID })?.voice != voice
            {
                throw AppFailure("Choose a supported OpenAI voice.")
            }
            return nil
        } catch { return AppFailure.message(for: error, fallback: "Review the character.") }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(
                mode == .manager
                    ? "Manage Characters"
                    : app.customization.characterDraft?.editingID == nil ? "New Character" : "Edit Character"
            ).font(.title2).fontWeight(.semibold)
            if mode == .manager {
                Text(
                    "A character is who the companion is: a name, a personality and a voice. Choosing one copies it into a conversation or template, so changing it later changes neither."
                )
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                TextField("Search characters", text: $query).textFieldStyle(.roundedBorder)
                HStack(alignment: .top, spacing: 16) {
                    characterList
                    ScrollView { preview }.frame(maxWidth: .infinity)
                }
            } else {
                editor
            }
            if let error = error ?? validationError {
                Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            footer
        }.padding(24).frame(width: 620, height: 570)
            .confirmationDialog(
                "Delete this character? Conversations and templates that use it keep their own copy.",
                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete Character", role: .destructive) {
                    guard let c = pendingDelete else { return }
                    do {
                        try app.characters.delete(id: c.id, revision: c.revision)
                        selection = nil
                        error = nil
                    } catch {
                        self.error = AppFailure.message(for: error, fallback: "Could not delete character.")
                    }
                    pendingDelete = nil
                }
            }
    }
    private var characterList: some View {
        List(selection: $selection) {
            ForEach(app.characters.sections(matching: query), id: \.section) { group in
                Section(group.section.title) {
                    ForEach(group.characters) { c in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: c.name).fontWeight(.medium)
                            if !c.displayDescription.isEmpty {
                                Text(c.displayDescription).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).tag(c.id)
                    }
                }
            }
        }.frame(width: 195).focused($listFocused)
            .onAppear {
                if selection == nil { selection = ConversationCharacter.builtins.first?.id }
                listFocused = true
            }
            .onChange(of: selection) { error = nil }
    }
    @ViewBuilder private var preview: some View {
        if let c = selected {
            VStack(alignment: .leading, spacing: 10) {
                Text(verbatim: c.name).font(.headline)
                if !c.displayDescription.isEmpty { Text(c.displayDescription).foregroundStyle(.secondary) }
                Text("Personality").font(.subheadline).fontWeight(.medium)
                Text(c.personality.isEmpty ? String(localized: "Mochi’s own manner") : c.personality).font(.callout)
                    .textSelection(.enabled)
                Text(
                    "Voice: \(c.voice.map { RealtimeVoice(rawValue: $0)?.name ?? $0 } ?? String(localized: "Settings voice"))"
                ).font(.callout)
                if c.needsReview {
                    Text("This character needs review before it can be used. Edit it to fix it.").font(.caption)
                        .foregroundStyle(.orange)
                }
                HStack {
                    Button("Start Conversation") {
                        do { try app.startConversation(with: c) } catch {
                            self.error = AppFailure.message(for: error, fallback: "Could not start conversation.")
                        }
                    }.disabled(c.needsReview || app.busy)
                    Button("Duplicate…") {
                        app.customization.editCharacter(c, duplicate: true)
                        error = nil
                    }
                    if !c.isBuiltin {
                        Button("Edit…") {
                            app.customization.editCharacter(c)
                            error = nil
                        }
                        Button("Delete…", role: .destructive) { pendingDelete = c }
                    }
                }
            }
        } else {
            Text("Select a character to preview it.").foregroundStyle(.secondary)
        }
    }
    private var editor: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                TextField("Character name", text: draftBinding.name).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("character-editor-name")
                TextField("Description", text: draftBinding.description, axis: .vertical).textFieldStyle(
                    .roundedBorder
                )
                .focused($descriptionFocused).multilineReturnKeys(active: descriptionFocused)
                Text("Personality").font(.headline)
                TextEditor(text: draftBinding.personality).font(.body).padding(6).frame(height: 160)
                    .focused($personalityFocused)
                    .fieldFrame(cornerRadius: 8, focused: personalityFocused)
                    .accessibilityLabel("Personality")
                Text(
                    "How this character comes across: temperament, manner, what they enjoy. What you do together belongs in a template’s instructions."
                ).font(.caption).foregroundStyle(.secondary)
                CompanionVoicePicker(app: app, voice: draftBinding.voice)
            }.padding(.trailing, 12)
        }
    }
    private var footer: some View {
        HStack {
            if mode == .manager {
                Button("New Character…") {
                    app.customization.editCharacter(nil)
                    error = nil
                }
            }
            Spacer()
            Button(mode == .manager ? "Done" : "Cancel") {
                error = nil
                if mode == .editor {
                    app.customization.closeCharacterEditor()
                } else {
                    app.customization.closeCharacters()
                }
            }.keyboardShortcut(.cancelAction)
            if mode == .editor {
                if app.customization.characterDraft?.editingID != nil {
                    Button("Save as New Character") { save(asNew: true) }.disabled(validationError != nil)
                }
                Button("Save") { save(asNew: false) }.keyboardShortcut(.defaultAction).disabled(
                    validationError != nil)
            }
        }
    }
    private func save(asNew: Bool) {
        do {
            try app.saveCharacterDraft(asNew: asNew)
            error = nil
        } catch {
            self.error = AppFailure.message(for: error, fallback: "Could not save character. Your draft is kept.")
        }
    }
}
