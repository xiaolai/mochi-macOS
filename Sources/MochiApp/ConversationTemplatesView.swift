import MochiCore
import MochiKernel
import SwiftUI

struct ConversationTemplatesView: View {
    @Bindable var app: AppModel
    @State private var query = ""
    @State private var selection: UUID?
    @FocusState private var listFocused: Bool
    @State private var error: String?
    @State private var pendingDelete: ConversationTemplate?
    private var mode: TemplatePresentation { app.customization.templatePresentation ?? .picker }
    private var draftBinding: Binding<ConversationTemplate> {
        Binding(
            get: { app.customization.templateDraft?.value ?? ConversationTemplate(title: "") },
            set: {
                app.customization.templateDraft?.value = $0
                error = nil
            })
    }
    private var validationError: String? { app.customization.templateDraftIssue }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(
                mode == .picker
                    ? "New Conversation from Template"
                    : mode == .manager
                        ? "Manage Templates"
                        : app.customization.templateDraft?.editingID == nil ? "New Template" : "Edit Template"
            ).font(.title2).fontWeight(.semibold)
            if mode != .editor {
                TextField("Search templates", text: $query).textFieldStyle(.roundedBorder)
                HStack(alignment: .top, spacing: 16) {
                    templateList
                    ScrollView { preview }.frame(maxWidth: .infinity)
                }
            } else {
                editor
            }
            // Selected recovery templates explain why Start/Save is disabled instead of failing silently.
            if let error = error ?? (mode == .editor || app.customization.templateDraft != nil ? validationError : nil)
            {
                Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            footer
        }.padding(24).frame(width: 620, height: 570)
            .confirmationDialog(
                "Delete this template? Existing conversations retain their settings.",
                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete Template", role: .destructive) {
                    guard let t = pendingDelete else { return }
                    do {
                        try app.templates.delete(id: t.id, revision: t.revision)
                        app.customization.templateDraft = nil
                        error = nil
                    } catch {
                        self.error = (error as? AppFailure)?.message ?? String(localized: "Could not delete template.")
                    }
                    pendingDelete = nil
                }
            }
    }
    private var templateList: some View {
        List(selection: $selection) {
            ForEach(app.templates.sections(matching: query), id: \.section) { group in
                Section(group.section.title) {
                    ForEach(group.templates) { row($0) }
                }
            }
            // Templates an assistant deleted wait here until the user recovers them or deletes them permanently.
            if mode == .manager, !deleted.isEmpty {
                Section("Recently Deleted") { ForEach(deleted) { row($0) } }
            }
        }.frame(width: 195).focused($listFocused)
            .onAppear {
                selection = app.customization.templateDraft?.value.id
                listFocused = true
            }
            .onChange(of: selection) { _, id in
                guard let id, app.customization.templateDraft?.value.id != id,
                    let t = (app.templates.all + app.templates.recentlyDeleted).first(where: { $0.id == id })
                else { return }
                app.customization.previewTemplate(t)
                error = nil
            }
    }
    /// Recently deleted templates whose stored or translated title or description contains the search text.
    private var deleted: [ConversationTemplate] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return app.templates.recentlyDeleted.filter { t in
            term.isEmpty
                || [t.title, t.description, t.displayTitle, t.displayDescription].contains {
                    $0.localizedCaseInsensitiveContains(term)
                }
        }
    }
    private func row(_ t: ConversationTemplate) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(t.displayTitle).fontWeight(.medium)
            Text(t.displayDescription).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }.frame(maxWidth: .infinity, alignment: .leading).tag(t.id)
    }
    @ViewBuilder private var preview: some View {
        if let draft = app.customization.templateDraft {
            VStack(alignment: .leading, spacing: 12) {
                Text(draft.value.displayTitle).font(.headline)
                Text(draft.value.displayDescription).foregroundStyle(.secondary)
                if mode == .picker {
                    ConversationSettingsFields(app: app, settings: draftBinding)
                } else {
                    TemplateSummary(app: app, template: draft.value)
                }
                if draft.value.isDeleted {
                    HStack {
                        Button("Recover") {
                            do {
                                try app.templates.recover(id: draft.value.id)
                                if let recovered = app.templates.all.first(where: { $0.id == draft.value.id }) {
                                    app.customization.previewTemplate(recovered)
                                }
                                error = nil
                            } catch {
                                self.error =
                                    (error as? AppFailure)?.message ?? String(localized: "Could not recover template.")
                            }
                        }
                        Button("Delete Permanently…", role: .destructive) { pendingDelete = draft.value }
                    }
                } else {
                    sourceStatus(draft)
                    templateActions(draft)
                }
            }
        } else {
            Text("Select a template to preview it.").foregroundStyle(.secondary)
        }
    }
    @ViewBuilder private func templateActions(_ draft: TemplateEditorDraft) -> some View {
        HStack {
            Button("Duplicate…") {
                app.customization.editTemplate(draft.value, duplicate: true)
                error = nil
            }
            if mode == .manager && !draft.value.isBuiltin {
                Button("Edit…") {
                    app.customization.editTemplate(draft.value)
                    error = nil
                }
                Button("Delete…", role: .destructive) { pendingDelete = draft.value }
            }
        }
    }
    @ViewBuilder private func sourceStatus(_ draft: TemplateEditorDraft) -> some View {
        if let source = app.templates.all.first(where: { $0.id == draft.value.id }) {
            if source.revision != draft.expectedRevision {
                Text("The source changed. Your preview is kept.").font(.caption).foregroundStyle(.orange)
                Button("Refresh from Source") {
                    app.customization.previewTemplate(source)
                    error = nil
                }
            }
        } else {
            Text("The source was deleted. You can still start from this preview.").font(.caption)
                .foregroundStyle(.orange)
        }
    }
    private var editor: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                TextField("Template title", text: draftBinding.title).textFieldStyle(.roundedBorder)
                TextField("Description", text: draftBinding.description, axis: .vertical).textFieldStyle(
                    .roundedBorder)
                ConversationSettingsFields(app: app, settings: draftBinding)
            }
        }
    }
    private var footer: some View {
        HStack {
            if mode != .editor {
                Button("New Template…") {
                    app.customization.editTemplate(nil)
                    error = nil
                }
            }
            Spacer()
            Button(mode == .manager ? "Done" : "Cancel") {
                error = nil
                if mode == .editor {
                    app.customization.closeTemplateEditor()
                } else {
                    app.customization.closeTemplates()
                }
            }.keyboardShortcut(.cancelAction)
            if mode == .picker {
                Button("Start Conversation") {
                    do {
                        if let t = app.customization.templateDraft?.value { _ = try app.startTemplateSnapshot(t) }
                    } catch {
                        self.error =
                            (error as? AppFailure)?.message ?? String(localized: "Could not start conversation.")
                    }
                }.keyboardShortcut(.defaultAction).disabled(validationError != nil || app.busy)
            } else if mode == .editor {
                if app.customization.templateDraft?.editingID != nil {
                    Button("Save as New") { save(asNew: true) }.disabled(validationError != nil)
                }
                Button("Save") { save(asNew: false) }.keyboardShortcut(.defaultAction).disabled(
                    validationError != nil)
            }
        }
    }
    private func save(asNew: Bool) {
        do {
            try app.saveTemplateDraft(asNew: asNew)
            error = nil
        } catch {
            self.error =
                (error as? AppFailure)?.message ?? String(localized: "Could not save template. Your draft is kept.")
        }
    }
}

/// A template's settings as text, for the manager's preview.
struct TemplateSummary: View {
    @Bindable var app: AppModel
    let template: ConversationTemplate
    var body: some View {
        let shown = template.withBuiltinTextTranslated()
        Text(
            template.instructions.isEmpty ? String(localized: "No additional instructions") : template.instructions
        )
        .font(.callout)
        Text(template.characterName.map { "Character: \($0)" } ?? "Character: Default").font(.caption)
        if !template.personality.isEmpty {
            Text("Personality: \(template.personality)").font(.caption).lineLimit(3)
        }
        Text(
            "Voice: \(template.preferences.voice.map { RealtimeVoice(rawValue: $0)?.name ?? $0 } ?? String(localized: "Settings voice"))"
        ).font(.caption)
        if !shown.greeting.isEmpty { Text("Greeting: \(shown.greeting)").font(.caption) }
        if !shown.phrases.isEmpty {
            Text("Phrases: \(shown.phrases.joined(separator: " · "))").font(.caption)
        }
    }
}
