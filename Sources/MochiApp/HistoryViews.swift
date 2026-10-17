import MochiCore
import SwiftUI

struct ChatActions: View {
    @Bindable var app: AppModel
    var chat: Conversation
    var body: some View {
        if chat.isDeleted {
            Button("Recover Conversation") { app.restoreChats([chat.id]) }
            Button("Delete Permanently…", role: .destructive) { app.history.permanentDeleteIDs = [chat.id] }.disabled(
                !app.canBeginHistoryEdit)
        } else {
            Button("Save as Template…") { app.saveConversationAsTemplate(chat.id) }.disabled(
                chat.archived || !app.canOpenConversationInstructions)
            Button("Conversation Instructions…") { app.openConversationInstructions(chat.id) }.disabled(
                chat.archived || !app.canOpenConversationInstructions)
            Button("Rename…") { app.history.renameID = chat.id }.disabled(!app.canBeginHistoryEdit)
            Button(chat.pinned ? "Unpin" : "Pin") { app.pinChats([chat.id], pinned: !chat.pinned) }
            if chat.archived {
                Button("Move to Conversations") { app.restoreChats([chat.id]) }
            } else {
                Button("Archive") { app.archiveChats([chat.id]) }
            }
            Button("Move to Recently Deleted", role: .destructive) { app.deleteChats([chat.id]) }
        }
        Divider()
        Menu("Export Transcript") {
            Button("Markdown…") { app.exportChats([chat.id]) }
            Button("JSON…") { app.exportChats([chat.id], json: true) }
        }
    }
}

struct RenameChatView: View {
    @Bindable var app: AppModel
    var id: UUID
    @State private var title = ""
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename Conversation").font(.title2).fontWeight(.semibold)
            TextField("Name", text: $title).textFieldStyle(.roundedBorder).focused($focused).onSubmit(rename)
            Text("Choose a name you’ll recognise later. \(title.count)/160")
                .font(.caption).foregroundStyle(.secondary)
            if let error = app.error { Text(error).font(.callout).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { app.history.renameID = nil }.keyboardShortcut(.cancelAction)
                Button("Rename", action: rename).keyboardShortcut(.defaultAction).disabled(!valid)
            }
        }.padding(24).frame(width: 420)
            .onAppear {
                title = app.library.conversations.first(where: { $0.id == id })?.displayTitle ?? ""
                focused = true
            }
    }
    private var valid: Bool { !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && title.count <= 160 }
    private func rename() { if valid { app.renameChat(id, title: title) } }
}

struct HistoryManagerView: View {
    @Bindable var app: AppModel
    @State private var scope: HistoryScope = .active
    @State private var query = ""
    @FocusState private var queryFocused: Bool
    @State private var selection: Set<UUID> = []
    private var chats: [Conversation] { app.library.history(in: scope, query: query) }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Manage Conversations").font(.title2).fontWeight(.semibold)
                Spacer()
                Button("Done") { app.history.managerOpen = false }.keyboardShortcut(.cancelAction)
            }.padding(20)
            HStack {
                Picker("Collection", selection: $scope) { ForEach(HistoryScope.allCases) { Text($0.title).tag($0) } }
                    .labelsHidden().pickerStyle(.segmented)
                TextField("Search titles and messages", text: $query).textFieldStyle(.roundedBorder).focused(
                    $queryFocused
                ).frame(width: 220)
            }.padding(.horizontal, 20).padding(.bottom, 14)
            if scope == .deleted {
                Text("Kept until you permanently delete them. Saved expressions are kept separately.")
                    .font(.callout).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.bottom, 12)
            }
            List(selection: $selection) {
                ForEach(chats) { chat in HistoryRow(chat: chat, query: query).tag(chat.id) }
            }.listStyle(.inset)
                .overlay {
                    if chats.isEmpty {
                        ContentUnavailableView(
                            query.isEmpty ? "No \(scope.title)" : "No Results",
                            systemImage: query.isEmpty ? scope.icon : "magnifyingglass",
                            description: Text(
                                query.isEmpty
                                    ? "Conversations will appear here." : "Try a different word or clear the search."))
                    }
                }
                .contextMenu(forSelectionType: UUID.self) { ids in bulkActions(ids) }
            HStack {
                Text(selection.isEmpty ? "⌘-click or ⇧-click to select conversations" : "\(selection.count) selected")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if scope == .deleted {
                    Button("Empty Recently Deleted…", role: .destructive) {
                        app.history.permanentDeleteIDs = Set(app.library.history(in: .deleted).map(\.id))
                    }
                    .disabled(app.library.history(in: .deleted).isEmpty)
                }
            }.padding(.horizontal, 20).padding(.top, 10)
            if let error = app.error { Text(error).font(.callout).foregroundStyle(.red).padding(.horizontal, 20) }
            if let feedback = app.history.feedback {
                Text(feedback).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.top, 6)
            }
            HStack(spacing: 10) {
                HistorySelectionActions(app: app, ids: selection, scope: scope)
                Spacer()
                Menu("Export") {
                    Button("Selected as Markdown…") { app.exportChats(selection) }
                    Button("Selected as JSON…") { app.exportChats(selection, json: true) }
                }.disabled(selection.isEmpty)
            }.padding(20)
        }.frame(width: 760, height: 570)
            .onAppear { scope = app.history.scope }
            .onChange(of: app.history.searchFocusRequest) { _, _ in queryFocused = true }
            .onChange(of: scope) { _, _ in selection = [] }
            .onChange(of: chats.map(\.id)) { _, ids in selection.formIntersection(Set(ids)) }
            .sheet(
                isPresented: Binding(
                    get: { app.history.renameID != nil }, set: { if !$0 { app.history.renameID = nil } })
            ) {
                if let id = app.history.renameID { RenameChatView(app: app, id: id) }
            }
            .sheet(
                isPresented: Binding(
                    get: { !app.history.permanentDeleteIDs.isEmpty },
                    set: { if !$0 { app.history.permanentDeleteIDs = [] } })
            ) { DeleteHistoryConfirmation(app: app) }
    }
    @ViewBuilder private func bulkActions(_ ids: Set<UUID>) -> some View {
        if ids.count == 1, let chat = app.library.conversations.first(where: { ids.contains($0.id) }) {
            ChatActions(app: app, chat: chat)
        } else if !ids.isEmpty {
            HistorySelectionActions(app: app, ids: ids, scope: scope)
        }
    }
}

private struct HistoryRow: View {
    var chat: Conversation
    var query: String
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(
                systemName: chat.isDeleted
                    ? "trash" : chat.archived ? "archivebox" : chat.pinned ? "pin.fill" : "bubble.left"
            )
            .foregroundStyle(.secondary).frame(width: 20)
            VStack(alignment: .leading, spacing: 4) {
                Text(chat.displayTitle).fontWeight(.medium).lineLimit(1)
                Text(chat.matchingMessage(query)?.text ?? chat.messages.last?.text ?? String(localized: "No messages"))
                    .foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(chat.deletedAt ?? chat.updatedAt, format: .dateTime.month(.abbreviated).day())
                    .foregroundStyle(.secondary)
                Text(chat.messages.count == 1 ? "1 message" : "\(chat.messages.count) messages").font(.caption)
                    .foregroundStyle(.secondary)
            }
        }.padding(.vertical, 5)
    }
}

/// The bulk actions shared by the manager's footer and its context menu. A search in the active collection also
/// lists archived conversations, so Archive and Move to Conversations follow what is actually selected.
struct HistorySelectionActions: View {
    @Bindable var app: AppModel
    var ids: Set<UUID>
    var scope: HistoryScope
    var body: some View {
        if scope == .deleted {
            Button("Recover") { app.restoreChats(ids) }.disabled(ids.isEmpty)
            Button("Delete Permanently…", role: .destructive) { app.history.permanentDeleteIDs = ids }.disabled(
                ids.isEmpty)
        } else {
            let targets = Self.targets(ids, in: app.library)
            if !targets.archive.isEmpty || scope != .archived {
                Button("Archive") { app.archiveChats(targets.archive) }.disabled(targets.archive.isEmpty)
            }
            if !targets.restore.isEmpty || scope == .archived {
                Button("Move to Conversations") { app.restoreChats(targets.restore) }.disabled(targets.restore.isEmpty)
            }
            Button("Move to Recently Deleted", role: .destructive) { app.deleteChats(ids) }.disabled(ids.isEmpty)
        }
    }
    /// Splits a selection of undeleted conversations into those that can be archived and those that can be restored.
    static func targets(_ ids: Set<UUID>, in library: Library) -> (archive: Set<UUID>, restore: Set<UUID>) {
        let selected = library.conversations.filter { ids.contains($0.id) && !$0.isDeleted }
        return (Set(selected.filter { !$0.archived }.map(\.id)), Set(selected.filter(\.archived).map(\.id)))
    }
}

struct DeleteHistoryConfirmation: View {
    @Bindable var app: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Delete Permanently", systemImage: "trash").font(.title2).fontWeight(.semibold)
            Text(
                app.history.permanentDeleteIDs.count == 1
                    ? "Permanently delete 1 conversation?"
                    : "Permanently delete \(app.history.permanentDeleteIDs.count) conversations?"
            ).font(.headline)
            Text(
                "This cannot be undone. Messages and unused recordings will be removed from the current library. Saved expressions and their recordings will be kept."
            )
            Text("Existing backups and provider-side data are not changed.").foregroundStyle(.secondary)
            if let error = app.error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("Cancel") { app.history.permanentDeleteIDs = [] }.keyboardShortcut(.cancelAction)
                Button("Delete Permanently", role: .destructive, action: app.permanentlyDeleteChats)
            }
        }.padding(24).frame(width: 440)
    }
}
