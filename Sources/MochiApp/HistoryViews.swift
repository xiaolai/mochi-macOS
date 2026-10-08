import SwiftUI
import MochiCore

struct ChatActions: View {
    @ObservedObject var app: AppModel
    var chat: Conversation
    var body: some View {
        if chat.isDeleted {
            Button("Recover Conversation") { app.restoreChats([chat.id]) }
            Button("Delete Permanently…",role:.destructive) { app.permanentDeleteIDs = [chat.id] }
        } else {
            Button("Rename…") { app.renameID = chat.id }
            Button(chat.pinned ? "Unpin" : "Pin") { app.pinChats([chat.id],pinned:!chat.pinned) }
            if chat.archived { Button("Move to Conversations") { app.restoreChats([chat.id]) } }
            else { Button("Archive") { app.archiveChats([chat.id]) } }
            Button("Move to Recently Deleted",role:.destructive) { app.deleteChats([chat.id]) }
        }
        Divider()
        Menu("Export Transcript") {
            Button("Markdown…") { app.exportChats([chat.id]) }
            Button("JSON…") { app.exportChats([chat.id],json:true) }
        }
    }
}

struct RenameChatView: View {
    @ObservedObject var app: AppModel
    var id: UUID
    @State private var title = ""
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            Text("Rename Conversation").font(.title2).fontWeight(.semibold)
            TextField("Name",text:$title).textFieldStyle(.roundedBorder).focused($focused).onSubmit(rename)
            Text("Choose a name you’ll recognise later. \(title.count)/160")
                .font(.caption).foregroundStyle(.secondary)
            if let error = app.error { Text(error).font(.callout).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { app.renameID = nil }.keyboardShortcut(.cancelAction)
                Button("Rename",action:rename).keyboardShortcut(.defaultAction).disabled(!valid)
            }
        }.padding(24).frame(width:420)
            .onAppear { title = app.library.conversations.first(where:{ $0.id == id })?.title ?? ""; focused = true }
    }
    private var valid: Bool { !title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && title.count <= 160 }
    private func rename() { if valid { app.renameChat(id,title:title) } }
}

struct HistoryManagerView: View {
    @ObservedObject var app: AppModel
    @State private var scope: HistoryScope = .active
    @State private var query = ""
    @FocusState private var queryFocused: Bool
    @State private var selection: Set<UUID> = []
    private var chats: [Conversation] { app.library.history(in:scope,query:query) }
    var body: some View {
        VStack(spacing:0) {
            HStack {
                Text("Manage Conversations").font(.title2).fontWeight(.semibold)
                Spacer()
                Button("Done") { app.managerOpen = false }.keyboardShortcut(.cancelAction)
            }.padding(20)
            HStack {
                Picker("Collection",selection:$scope) { ForEach(HistoryScope.allCases) { Text($0.title).tag($0) } }
                    .labelsHidden().pickerStyle(.segmented)
                TextField("Search titles and messages",text:$query).textFieldStyle(.roundedBorder).focused($queryFocused).frame(width:220)
            }.padding(.horizontal,20).padding(.bottom,14)
            if scope == .deleted {
                Text("Kept until you permanently delete them. Saved expressions are kept separately.")
                    .font(.callout).foregroundStyle(.secondary).padding(.horizontal,20).padding(.bottom,12)
            }
            List(selection:$selection) {
                ForEach(chats) { chat in
                    HStack(alignment:.top,spacing:12) {
                        Image(systemName:chat.isDeleted ? "trash" : chat.archived ? "archivebox" : chat.pinned ? "pin.fill" : "bubble.left")
                            .foregroundStyle(.secondary).frame(width:20)
                        VStack(alignment:.leading,spacing:4) {
                            Text(chat.title).fontWeight(.medium).lineLimit(1)
                            Text(chat.matchingMessage(query)?.text ?? chat.messages.last?.text ?? "No messages")
                                .foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        VStack(alignment:.trailing,spacing:4) {
                            Text(chat.deletedAt ?? chat.updatedAt,format:.dateTime.month(.abbreviated).day()).foregroundStyle(.secondary)
                            Text("\(chat.messages.count) \(chat.messages.count == 1 ? "message" : "messages")").font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical,5).tag(chat.id)
                }
            }.listStyle(.inset)
                .overlay { if chats.isEmpty { ContentUnavailableView(query.isEmpty ? "No \(scope.title)" : "No Results",systemImage:query.isEmpty ? scope.icon : "magnifyingglass",description:Text(query.isEmpty ? "Conversations will appear here." : "Try a different word or clear the search.")) } }
                .contextMenu(forSelectionType:UUID.self) { ids in bulkActions(ids) }
            HStack {
                Text(selection.isEmpty ? "⌘-click or ⇧-click to select conversations" : "\(selection.count) selected")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if scope == .deleted {
                    Button("Empty Recently Deleted…",role:.destructive) { app.permanentDeleteIDs = Set(app.library.history(in:.deleted).map(\.id)) }
                        .disabled(app.library.history(in:.deleted).isEmpty)
                }
            }.padding(.horizontal,20).padding(.top,10)
            if let error = app.error { Text(error).font(.callout).foregroundStyle(.red).padding(.horizontal,20) }
            if let feedback = app.historyFeedback { Text(feedback).font(.caption).foregroundStyle(.secondary).padding(.horizontal,20).padding(.top,6) }
            HStack(spacing:10) {
                if scope == .deleted {
                    Button("Recover") { app.restoreChats(selection) }.disabled(selection.isEmpty)
                    Button("Delete Permanently…",role:.destructive) { app.permanentDeleteIDs = selection }.disabled(selection.isEmpty)
                } else {
                    Button(scope == .archived ? "Move to Conversations" : "Archive") {
                        if scope == .archived { app.restoreChats(selection) } else { app.archiveChats(selection) }
                    }.disabled(selection.isEmpty)
                    Button("Move to Recently Deleted",role:.destructive) { app.deleteChats(selection) }.disabled(selection.isEmpty)
                }
                Spacer()
                Menu("Export") {
                    Button("Selected as Markdown…") { app.exportChats(selection) }
                    Button("Selected as JSON…") { app.exportChats(selection,json:true) }
                }.disabled(selection.isEmpty)
            }.padding(20)
        }.frame(width:760,height:570)
            .onAppear { scope = app.historyScope }
            .onChange(of:app.searchFocusRequest) { _,_ in queryFocused = true }
            .onChange(of:scope) { _,_ in selection = [] }
            .onChange(of:chats.map(\.id)) { _,ids in selection.formIntersection(Set(ids)) }
            .sheet(isPresented:Binding(get:{app.renameID != nil},set:{if !$0 {app.renameID = nil}})) { if let id = app.renameID { RenameChatView(app:app,id:id) } }
            .sheet(isPresented:Binding(get:{!app.permanentDeleteIDs.isEmpty},set:{if !$0 {app.permanentDeleteIDs = []}})) { DeleteHistoryConfirmation(app:app) }
    }
    @ViewBuilder private func bulkActions(_ ids: Set<UUID>) -> some View {
        if ids.count == 1, let chat = app.library.conversations.first(where:{ids.contains($0.id)}) { ChatActions(app:app,chat:chat) }
        else if !ids.isEmpty {
            if scope == .deleted {
                Button("Recover") { app.restoreChats(ids) }
                Button("Delete Permanently…",role:.destructive) { app.permanentDeleteIDs = ids }
            } else {
                Button(scope == .archived ? "Move to Conversations" : "Archive") { if scope == .archived { app.restoreChats(ids) } else { app.archiveChats(ids) } }
                Button("Move to Recently Deleted",role:.destructive) { app.deleteChats(ids) }
            }
        }
    }
}

struct DeleteHistoryConfirmation: View {
    @ObservedObject var app: AppModel
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            Label("Delete Permanently",systemImage:"trash").font(.title2).fontWeight(.semibold)
            Text("Permanently delete \(app.permanentDeleteIDs.count) \(app.permanentDeleteIDs.count == 1 ? "conversation" : "conversations")?").font(.headline)
            Text("This cannot be undone. Messages and unused recordings will be removed from the current library. Saved expressions and their recordings will be kept.")
            Text("Existing backups and provider-side data are not changed.").foregroundStyle(.secondary)
            if let error = app.error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("Cancel") { app.permanentDeleteIDs = [] }.keyboardShortcut(.cancelAction)
                Button("Delete Permanently",role:.destructive,action:app.permanentlyDeleteChats)
            }
        }.padding(24).frame(width:440)
    }
}
