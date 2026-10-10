import SwiftUI
import MochiCore

struct ConversationSettingsFields: View {
    @Binding var instructions: String
    @Binding var characterName: String?
    @Binding var preferences: ConversationPreferences
    var body: some View {
        Toggle("Use a custom character name",isOn:Binding(get:{ characterName != nil },set:{ characterName = $0 ? "Mochi" : nil }))
        if characterName != nil {
            TextField("Character name",text:Binding(get:{ characterName ?? "" },set:{ characterName = $0 }))
                .textFieldStyle(.roundedBorder).accessibilityIdentifier("character-name")
        }
        Text(characterName == nil ? "Default identity: Mochi. Instructions can override its conversational name." : "This name takes precedence over naming in instructions. Saved messages keep their original speaker name.")
            .font(.caption).foregroundStyle(.secondary)
        Text("Instructions").font(.headline)
        TextEditor(text:$instructions).font(.body).padding(6).frame(height:150)
            .background(Color(nsColor:.textBackgroundColor),in:RoundedRectangle(cornerRadius:8))
            .overlay(RoundedRectangle(cornerRadius:8).stroke(.quaternary))
            .accessibilityLabel("Conversation instructions")
        Text("\(instructions.count)/8,000 characters · \(instructions.utf8.count)/49,152 bytes")
            .font(.caption).foregroundStyle(.secondary)
        if instructions.count > 8000 || instructions.utf8.count > MochiTools.maxInstructionBytes {
            Text("The full original text is preserved. Future replies use a bounded preview. Shorten it to 8,000 characters and 48 KB to save edited text or a new template. Unchanged conversation text can be preserved when changing other settings.")
                .font(.caption).foregroundStyle(.red)
        }
        Picker("Coaching",selection:$preferences.coaching) {
            Text("Natural conversation").tag(CoachingStyle.natural)
            Text("Occasional gentle corrections").tag(CoachingStyle.gentle)
            Text("Direct corrections").tag(CoachingStyle.direct)
        }
        Toggle("Use a custom speech speed",isOn:Binding(get:{ preferences.speed != nil },set:{ preferences.speed = $0 ? 1 : nil }))
        if preferences.speed != nil {
            HStack {
                Slider(value:Binding(get:{ preferences.speed ?? 1 },set:{ preferences.speed = $0 }),in:0.25...1.5,step:0.05)
                    .accessibilityLabel("Conversation speech speed")
                Text(String(format:"%.2f×",preferences.speed ?? 1)).monospacedDigit().frame(width:60)
            }
        }
    }
}

struct ConversationTemplatesView: View {
    @ObservedObject var app: AppModel
    @State private var query = ""
    @State private var selection: UUID?
    @FocusState private var listFocused: Bool
    @State private var error: String?
    @State private var pendingDelete: ConversationTemplate?
    private var mode: TemplatePresentation { app.templatePresentation ?? .picker }
    private var values: [ConversationTemplate] { app.allTemplates.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.description.localizedCaseInsensitiveContains(query) } }
    private var draftBinding: Binding<ConversationTemplate> {
        Binding(get:{ app.templateDraft?.value ?? ConversationTemplate(title:"") },set:{ app.templateDraft?.value = $0; error = nil })
    }
    private var validationError: String? { app.templateDraftIssue }
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Text(mode == .picker ? "New Conversation from Template" : mode == .manager ? "Manage Templates" : app.templateDraft?.editingID == nil ? "New Template" : "Edit Template").font(.title2).fontWeight(.semibold)
            if mode != .editor {
                TextField("Search templates",text:$query).textFieldStyle(.roundedBorder)
                HStack(alignment:.top,spacing:16) {
                    List(selection:$selection) {
                        ForEach([true,false],id:\.self) { builtin in
                            Section(builtin ? "Built-in" : "My Templates") {
                                ForEach(values.filter { $0.isBuiltin == builtin }) { t in
                                    VStack(alignment:.leading,spacing:4) {
                                        Text(t.title).fontWeight(.medium)
                                        Text(t.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    }.frame(maxWidth:.infinity,alignment:.leading).tag(t.id)
                                }
                            }
                        }
                    }.frame(width:195).focused($listFocused)
                    .onAppear { selection = app.templateDraft?.value.id; listFocused = true }
                    .onChange(of:selection) { _,id in
                        guard let id, app.templateDraft?.value.id != id, let t = app.allTemplates.first(where:{ $0.id == id }) else { return }
                        app.templateDraft = TemplateEditorDraft(value:t,editingID:nil,expectedRevision:t.revision); error = nil
                    }
                    ScrollView {
                        if let draft = app.templateDraft {
                            VStack(alignment:.leading,spacing:12) {
                                Text(draft.value.title).font(.headline)
                                Text(draft.value.description).foregroundStyle(.secondary)
                                if mode == .picker {
                                    ConversationSettingsFields(instructions:draftBinding.instructions,characterName:draftBinding.characterName,preferences:draftBinding.preferences)
                                } else {
                                    Text(draft.value.instructions.isEmpty ? "No additional instructions" : draft.value.instructions).font(.callout)
                                    Text("Character: \(draft.value.characterName ?? "Default")").font(.caption)
                                }
                                if let source = app.allTemplates.first(where:{ $0.id == draft.value.id }) {
                                    if source.revision != draft.expectedRevision {
                                        Text("The source changed. Your preview is kept.").font(.caption).foregroundStyle(.orange)
                                        Button("Refresh from Source") { app.templateDraft = TemplateEditorDraft(value:source,editingID:nil,expectedRevision:source.revision) }
                                    }
                                } else { Text("The source was deleted. You can still start from this preview.").font(.caption).foregroundStyle(.orange) }
                                HStack {
                                    Button("Duplicate…") { app.editTemplate(draft.value,duplicate:true); error = nil }
                                    if mode == .manager && !draft.value.isBuiltin {
                                        Button("Edit…") { app.editTemplate(draft.value); error = nil }
                                        Button("Delete…",role:.destructive) { pendingDelete = draft.value }
                                    }
                                }
                            }
                        } else { Text("Select a template to preview it.").foregroundStyle(.secondary) }
                    }.frame(maxWidth:.infinity)
                }
            } else {
                ScrollView {
                    VStack(alignment:.leading,spacing:12) {
                        TextField("Template title",text:draftBinding.title).textFieldStyle(.roundedBorder)
                        TextField("Description",text:draftBinding.description,axis:.vertical).textFieldStyle(.roundedBorder)
                        ConversationSettingsFields(instructions:draftBinding.instructions,characterName:draftBinding.characterName,preferences:draftBinding.preferences)
                    }
                }
            }
            // Selected recovery templates explain why Start/Save is disabled instead of failing silently.
            if let error = error ?? (mode == .editor || app.templateDraft != nil ? validationError : nil) { Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal:false,vertical:true) }
            HStack {
                if mode != .editor { Button("New Template…") { app.editTemplate(nil); error = nil } }
                Spacer()
                Button(mode == .manager ? "Done" : "Cancel") {
                    error = nil
                    if mode == .editor { app.closeTemplateEditor() } else { app.templatePresentation = nil; app.templateDraft = nil }
                }.keyboardShortcut(.cancelAction)
                if mode == .picker {
                    Button("Start Conversation") {
                        do { if let t = app.templateDraft?.value { _ = try app.startTemplateSnapshot(t) } } catch { self.error = (error as? AppFailure)?.message ?? "Could not start conversation." }
                    }.keyboardShortcut(.defaultAction).disabled(validationError != nil || app.busy)
                } else if mode == .editor {
                    if app.templateDraft?.editingID != nil {
                        Button("Save as New") { save(asNew:true) }.disabled(validationError != nil)
                    }
                    Button("Save") { save(asNew:false) }.keyboardShortcut(.defaultAction).disabled(validationError != nil)
                }
            }
        }.padding(24).frame(width:620,height:570)
        .confirmationDialog("Delete this template? Existing conversations retain their settings.",isPresented:Binding(get:{pendingDelete != nil},set:{if !$0 { pendingDelete = nil }}),titleVisibility:.visible) {
            Button("Delete Template",role:.destructive) {
                guard let t = pendingDelete else { return }
                do { try app.deleteTemplate(id:t.id,revision:t.revision); app.templateDraft = nil } catch { self.error = (error as? AppFailure)?.message ?? "Could not delete template." }
                pendingDelete = nil
            }
        }
    }
    private func save(asNew: Bool) {
        guard let draft = app.templateDraft else { return }
        var fields: [String:Any] = ["title":draft.value.title,"description":draft.value.description,"instructions":draft.value.instructions,"coaching":draft.value.preferences.coaching.rawValue]
        if let name = draft.value.characterName { fields["character_name"] = name } else if draft.editingID != nil && !asNew { fields["clear_character_name"] = true }
        if let speed = draft.value.preferences.speed { fields["speed"] = speed } else if draft.editingID != nil && !asNew { fields["clear_speed"] = true }
        do {
            if !asNew, let id = draft.editingID, let revision = draft.expectedRevision { _ = try app.updateTemplate(id:id,revision:revision,fields:fields) }
            else { _ = try app.createTemplate(fields:fields) }
            error = nil; app.closeTemplateEditor()
        } catch { self.error = (error as? AppFailure)?.message ?? "Could not save template. Your draft is kept." }
    }
}
