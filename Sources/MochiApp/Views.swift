import SwiftUI
import MochiCore

private enum SidebarDestination: Hashable {
    case conversation(UUID)
    case expressions
    case collection(HistoryScope)
}

struct WorkspaceView: View {
    @ObservedObject var app: AppModel
    @FocusState private var searchFocused: Bool
    @Environment(\.openSettings) private var openSettings
    private var selection: Binding<SidebarDestination?> {
        Binding(get: {
            app.showExpressions ? .expressions : app.selectedID.map(SidebarDestination.conversation)
        }, set: { destination in
            switch destination {
            case .conversation(let id): app.select(id)
            case .expressions: app.openExpressions()
            case .collection(let scope): app.showHistory(scope)
            case nil: break
            }
        })
    }

    var body: some View {
        NavigationSplitView {
            List(selection:selection) {
                Section {
                    Label { Text("My Expressions") } icon: {
                        Image(systemName:"bookmark").foregroundStyle(app.showExpressions ? Color.white : Color.accentColor)
                    }
                        .badge(app.library.expressions.count)
                        .tag(SidebarDestination.expressions)
                }
                Section {
                    ForEach(HistoryScope.allCases) { scope in
                        Label(scope.title,systemImage:scope.icon)
                            .badge(app.library.history(in:scope).count)
                            .tag(SidebarDestination.collection(scope))
                            .fontWeight(!app.showExpressions && app.historyScope == scope ? .semibold : .regular)
                    }
                }
                ForEach(historyGroups,id:\.title) { group in
                    Section(group.title) {
                        ForEach(group.chats) { chat in
                            HStack(spacing:10) {
                                Image(systemName:chat.pinned ? "pin.fill" : chat.archived ? "archivebox" : "bubble.left.and.bubble.right.fill")
                                    .font(.system(size:18)).foregroundStyle(.secondary)
                                VStack(alignment:.leading,spacing:4) {
                                    Text(chat.title).fontWeight(.medium).lineLimit(1)
                                    Text(chat.matchingMessage(app.search)?.text ?? (chat.draft.isEmpty ? chat.messages.last?.text ?? "New conversation" : "Draft: " + chat.draft))
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength:0)
                                Menu { ChatActions(app:app,chat:chat) } label: {
                                    Image(systemName:"ellipsis").frame(width:20,height:24)
                                }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                                    .help("Conversation Actions")
                                    .accessibilityLabel("Actions for \(chat.title)")
                            }.padding(.vertical,7)
                                .tag(SidebarDestination.conversation(chat.id))
                                .contextMenu { ChatActions(app:app,chat:chat) }
                        }
                    }
                }
                if app.visibleChats.isEmpty {
                    Section {
                        Text(app.search.isEmpty ? "No conversations here" : "No matching conversations")
                            .foregroundStyle(.secondary).font(.callout)
                        if !app.search.isEmpty { Button("Clear Search") { app.search = "" } }
                    }
                }

            }
            .listStyle(.sidebar)
            .searchable(text:$app.search,isPresented:$app.searchOpen,placement:.sidebar,prompt:"Search titles and messages")
            .historySearchFocus($searchFocused)
            .navigationTitle("")
            .toolbar {
                ToolbarItem(placement:.primaryAction) {
                    Button(action:app.newChat) { Label("New Conversation",systemImage:"square.and.pencil") }
                        .labelStyle(.iconOnly).help("New Conversation (⌘N)")
                }
            }
            .navigationSplitViewColumnWidth(min:190,ideal:230,max:320)
        } detail: {
            Group {
                if app.showExpressions { expressions }
                else {
                    VStack(spacing:0) {
                        transcript
                        if let error = app.error { errorBanner(error) }
                        if app.writableConversation { inputBar }
                        else if let chat = app.conversation { historyBanner(chat) }
                    }
                }
            }
            .safeAreaInset(edge:.bottom,spacing:0) {
                if let notice = app.notice, !app.practice {
                    HStack {
                        Text(notice).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button { app.notice = nil } label: { Label("Dismiss notice",systemImage:"xmark") }.labelStyle(.iconOnly).buttonStyle(.borderless)
                    }.padding(.horizontal,16).padding(.vertical,10).background(.bar)
                }
            }
            .navigationTitle("")
            .toolbar {
                if app.turn.activity == .generating {
                    ToolbarItem(placement:.primaryAction) {
                        Button(action:app.stop) { Label("Stop",systemImage:"stop.fill") }.labelStyle(.iconOnly).help("Stop (Escape)")
                    }
                }
                if #available(macOS 26.0, *) { ToolbarSpacer(.flexible,placement:.primaryAction) }
                // Older AppKit toolbars already place primary actions at the trailing edge.
                if !app.showExpressions, app.conversation != nil {
                    ToolbarItem(placement:.primaryAction) {
                        ConversationSearchControl(app:app).disabled(app.practice)
                    }
                }
            }
        }
        .sheet(isPresented:$app.managerOpen) { HistoryManagerView(app:app) }
        .sheet(isPresented:Binding(get:{app.renameID != nil && !app.managerOpen},set:{if !$0 && !app.managerOpen {app.renameID = nil}})) { if let id = app.renameID { RenameChatView(app:app,id:id) } }
        .sheet(isPresented:Binding(get:{!app.permanentDeleteIDs.isEmpty && !app.managerOpen},set:{if !$0 && !app.managerOpen {app.permanentDeleteIDs = []}})) { DeleteHistoryConfirmation(app:app) }
        .sheet(isPresented:Binding(get:{ app.practice },set:{ if !$0 && app.practice { app.resume() } })) {
            PracticePane(app:app).frame(width:640,height:app.helpStage == .practice ? 580 : 480)
        }
        .onChange(of:app.searchFocusRequest) { _,_ in if !app.managerOpen { searchFocused = true } }
        .onChange(of:app.settingsOpen) { _,show in
            if show { openSettings(); app.settingsOpen = false }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth:760,minHeight:580)
    }

    private var historyGroups: [(title:String,chats:[Conversation])] {
        let chats = app.visibleChats
        if !app.search.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { return [("Search Results",chats)] }
        var groups: [(title:String,chats:[Conversation])] = []
        let pinned = chats.filter { $0.pinned && app.historyScope == .active }
        if !pinned.isEmpty { groups.append(("Pinned",pinned)) }
        let remaining = chats.filter { !($0.pinned && app.historyScope == .active) }
        let calendar = Calendar.current
        func rowDate(_ chat: Conversation) -> Date { app.historyScope == .deleted ? chat.deletedAt ?? chat.updatedAt : chat.updatedAt }
        let buckets: [(String,(Conversation)->Bool)] = [
            ("Today",{calendar.isDateInToday(rowDate($0))}),
            ("Yesterday",{calendar.isDateInYesterday(rowDate($0))}),
            ("Earlier",{!calendar.isDateInToday(rowDate($0)) && !calendar.isDateInYesterday(rowDate($0))})
        ]
        for (title,predicate) in buckets { let rows = remaining.filter(predicate); if !rows.isEmpty { groups.append((title,rows)) } }
        return groups
    }
    private func historyBanner(_ chat: Conversation) -> some View {
        HStack(spacing:12) {
            Image(systemName:chat.isDeleted ? "trash" : "archivebox").foregroundStyle(.secondary)
            VStack(alignment:.leading,spacing:3) {
                Text(chat.isDeleted ? "Recently Deleted" : "Archived Conversation").fontWeight(.medium)
                Text(chat.isDeleted ? "Kept until you permanently delete it." : "Move it back to continue chatting.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(chat.isDeleted ? "Recover" : "Move to Conversations") { app.restoreChats([chat.id]) }
        }.padding(16).background(.bar)
    }

    private var transcript: some View {
        let sidebarMatchID = app.conversation?.matchingMessage(app.search)?.id
        return Group {
            if app.conversation?.messages.isEmpty != false {
                if app.conversation == nil {
                    ContentUnavailableView("No Conversation Selected",systemImage:app.historyScope.icon,description:Text("Select a conversation, or start a new one with ⌘N."))
                } else if !app.writableConversation {
                    ContentUnavailableView("No Messages",systemImage:app.historyScope.icon,description:Text("This conversation is empty."))
                } else {
                ContentUnavailableView {
                    MochiView().frame(width:72,height:78)
                    Text("A little conversation. A little practice.")
                } description: {
                    Text("Talk with Mochi in English. When you get stuck,\nwe’ll find the words and practise them in your own voice.")
                }
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment:.leading,spacing:16) {
                            ForEach(app.conversation?.messages ?? []) { message in messageView(message,sidebarMatchID:sidebarMatchID).id(message.id) }
                            Color.clear.frame(height:1).id("bottom")
                        }
                        .padding(20)
                        .frame(maxWidth:820)
                        .frame(maxWidth:.infinity)
                    }
                    .task(id:"\(app.selectedID?.uuidString ?? "")|\(app.search)") {
                        await Task.yield()
                        if let id = app.conversationMatchID { proxy.scrollTo(id,anchor:.center) }
                        else if let message = app.conversation?.matchingMessage(app.search) { proxy.scrollTo(message.id,anchor:.center) }
                        else { proxy.scrollTo("bottom",anchor:.bottom) }
                    }
                    .onChange(of:app.conversationMatchID) { _,id in
                        if let id { withAnimation { proxy.scrollTo(id,anchor:.center) } }
                    }
                    .onChange(of:app.conversation?.messages.count) { _,_ in
                        if app.conversationQuery.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
                            withAnimation { proxy.scrollTo("bottom",anchor:.bottom) }
                        }
                    }
                }
            }
        }
        .frame(maxWidth:.infinity,maxHeight:.infinity)
        .background(Color(nsColor:.textBackgroundColor))
    }

    private func messageView(_ message: Message, sidebarMatchID: UUID?) -> some View {
        let isUser = message.role == "user"
        return HStack(alignment:.top,spacing:8) {
            if isUser { Spacer(minLength:60) }
            VStack(alignment:isUser ? .trailing : .leading,spacing:5) {
                Text(isUser ? "You" : "Mochi").font(.caption).foregroundStyle(.secondary)
                VStack(alignment:.leading,spacing:8) {
                    Text(message.displayText)
                        .font(.system(size:15))
                        .textSelection(.enabled)
                        .fixedSize(horizontal:false,vertical:true)
                    if isUser && message.audio != nil && message.contextText == nil {
                        Text(app.transcribingMessageIDs.contains(message.id) ? "Transcribing…" : "Transcript unavailable · use the message menu to retry or add text")
                            .font(.caption).opacity(0.8).frame(maxWidth:310,alignment:.leading)
                    }
                    if let file = message.audio {
                        HStack(alignment:.center,spacing:4) {
                            MessagePlayback(app:app,audio:app.audio,file:file,isUser:isUser)
                            if isUser { VoiceTranscriptControls(app:app,message:message) }
                        }
                    }
                }
                .foregroundStyle(isUser ? Color.white : Color.primary)
                .tint(isUser ? Color.white : Color.accentColor)
                .padding(.horizontal,12).padding(.vertical,9)
                .contextMenu {
                    Button("Copy Message") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(message.text,forType:.string) }
                    Text(message.date.formatted(date:.abbreviated,time:.shortened))
                    if let name = message.audio { Button("Show Recording in Finder") { NSWorkspace.shared.activateFileViewerSelecting([app.store.root.appendingPathComponent(name)]) } }
                }
                .overlay(alignment:.leading) {
                    if app.conversationMatchSet.contains(message.id) || sidebarMatchID == message.id {
                        RoundedRectangle(cornerRadius:18)
                            .stroke(app.conversationMatchID == message.id ? Color.orange : Color.accentColor,lineWidth:app.conversationMatchID == message.id ? 3 : 1.5).padding(-3)
                    }
                }
                .background(isUser ? Color.accentColor : Color(nsColor:.controlBackgroundColor),in:RoundedRectangle(cornerRadius:18))

            }
            if !isUser { Spacer(minLength:60) }
        }
    }

    private var inputBar: some View {
        VStack(spacing:8) {
            HStack(alignment:.bottom,spacing:12) {
                Button(action:app.toggleConversationVoice) {
                    Image(systemName:app.turn.activity == .recording ? "stop.circle.fill" : "mic.fill")
                        .font(.system(size:18))
                }.buttonStyle(.borderless)
                    .help(app.microphoneLabel)
                    .accessibilityLabel(app.microphoneLabel)
                    .disabled(app.busy && app.turn.activity != .recording && !app.greetingActive)
                Button(action:app.startHelp) {
                    Image(systemName:"waveform.badge.plus").font(.system(size:18))
                }.buttonStyle(.borderless)
                    .help("Help Me Say This (⇧⌘H)")
                    .accessibilityLabel("Help Me Say This")
                    .disabled(app.turn.activity == .recording || app.turn.activity == .requestingPermission)
                TextField("Message Mochi",text:$app.draft,axis:.vertical)
                    .textFieldStyle(.plain).font(.system(size:15)).lineLimit(1...5)
                    .onSubmit { app.send() }.disabled(app.busy)
                Button(action:app.send) { Image(systemName:"arrow.up").fontWeight(.semibold) }
                    .buttonStyle(.borderedProminent).buttonBorderShape(.circle)
                    .disabled(app.busy || app.draft.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.return,modifiers:.command)
            }
            .padding(12)
            .background(Color(nsColor:.controlBackgroundColor),in:RoundedRectangle(cornerRadius:24))
            .overlay(RoundedRectangle(cornerRadius:24).strokeBorder(.quaternary,lineWidth:1))
            if app.turn.activity == .recording { RecordingFeedback(app:app) }
            HStack(spacing:5) {
                if app.turn.activity == .generating || app.turn.activity == .requestingPermission {
                    ProgressView().controlSize(.mini)
                } else { Image(systemName:app.turn.activity == .recording ? "record.circle" : "mic.slash").foregroundStyle(app.turn.activity == .recording ? .red : .secondary) }
                Text(app.status).lineLimit(1)
                Spacer(minLength:4)
                if app.demo { Text("Preview").foregroundStyle(.secondary) }
            }.font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal,16).padding(.vertical,12)
        .background(Color(nsColor:.textBackgroundColor))
    }

    private func errorBanner(_ text: String) -> some View {
        HStack(alignment:.top) {
            Image(systemName:"exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).textSelection(.enabled)
            Spacer()
            if app.canRetry { Button("Retry",action:app.retryReply) }
            Button { app.error = nil } label: { Label("Dismiss",systemImage:"xmark") }.labelStyle(.iconOnly)
        }.font(.callout).padding(12).background(.bar)
    }

    private var expressions: some View {
        Group {
            if app.library.expressions.isEmpty {
                ContentUnavailableView("No Saved Expressions",systemImage:"bookmark",description:Text("Save an expression while practising to return to it here."))
            } else {
                List {
                    ForEach(app.library.expressions) { expression in
                        HStack {
                            VStack(alignment:.leading,spacing:5) {
                                Text(expression.english).font(.body)
                                if !expression.meaning.isEmpty { Text(expression.meaning).font(.callout).foregroundStyle(.secondary) }
                                Text("\(expression.attempts.count) attempts").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Practise") { app.openExpression(expression) }
                        }.padding(.vertical,5)
                    }
                }.listStyle(.inset)
            }
        }.frame(maxWidth:.infinity,maxHeight:.infinity)
    }
}

struct PracticeActions: View {
    @ObservedObject var app: AppModel
    var body: some View {
        HStack(spacing:10) {
            Button(action:app.toggleRecord) {
                Label(app.turn.activity == .recording ? "Finish (\(app.recordingSeconds)s)" : "Record Attempt",systemImage:app.turn.activity == .recording ? "stop.fill" : "mic")
            }.disabled(app.busy && app.turn.activity != .recording)
            if let file = app.expression?.attempts.last?.file {
                Button { app.play(file) } label: { Label("Play Attempt",systemImage:"play.fill") }
                    .labelStyle(.iconOnly).help("Play Latest Attempt").disabled(app.busy)
            }
            Button { app.saveExpression(); app.notice = "Saved to My Expressions." } label: { Label("Save Expression",systemImage:"bookmark") }
                .labelStyle(.iconOnly).help("Save Expression").disabled(app.busy)
            Spacer(minLength:2)
            Button("Resume Conversation",action:app.resume).buttonStyle(.borderedProminent).keyboardShortcut(.cancelAction)
        }
    }
}
struct PitchChart: View {
    var reference: [PitchPoint]
    var attempt: [PitchPoint]
    var normalized: Bool
    var smoothed = true
    var body: some View {
        Canvas { context,size in
            let series = [reference,attempt].map { PitchContour.runs($0,smoothed:smoothed) }
            let medians = [reference,attempt].map { normalized ? PitchContour.center($0) : 0 }
            let all = series.enumerated().flatMap { index,runs in runs.flatMap { $0.map { $0.value-medians[index] } } }
            let low = (all.min() ?? 0)-2, high = max(low+8,(all.max() ?? 12)+2)
            let duration = PitchContour.duration(reference+attempt)
            let w = max(1,size.width-26), top = 6.0, h = max(1,size.height-26)
            for i in 0...3 {
                let y = top+h * Double(i)/3
                var path = Path(); path.move(to:CGPoint(x:24,y:y)); path.addLine(to:CGPoint(x:size.width,y:y))
                context.stroke(path,with:.color(.secondary.opacity(0.12)),style:StrokeStyle(lineWidth:1,dash:[3,4]))
                context.draw(Text("\(Int(high-(high-low)*Double(i)/3))").font(.system(size:8)).foregroundColor(.secondary),at:CGPoint(x:9,y:y))
            }
            for i in 0...Int(duration) { context.draw(Text("\(i)s").font(.system(size:8)).foregroundColor(.secondary),at:CGPoint(x:24+Double(i)/duration*w,y:size.height-5)) }
            for (index,runs) in series.enumerated() {
                func position(_ point: PitchContour.Point) -> CGPoint {
                    CGPoint(x:24+point.time/duration*w,y:top+h*(1-(point.value-medians[index]-low)/(high-low)))
                }
                var path = Path()
                for run in runs {
                    guard let first = run.first else { continue }
                    path.move(to:position(first))
                    if run.count == 1 {
                        let p = position(first)
                        path.addEllipse(in:CGRect(x:p.x-1,y:p.y-1,width:2,height:2))
                    } else if smoothed {
                        for curve in PitchContour.curves(run) { path.addCurve(to:position(curve.end),control1:position(curve.control1),control2:position(curve.control2)) }
                    } else {
                        for point in run.dropFirst() { path.addLine(to:position(point)) }
                    }
                }
                context.stroke(path,with:.color(index == 0 ? .accentColor : .orange),style:StrokeStyle(lineWidth:2,lineCap:.round,lineJoin:.round))
            }
        }.accessibilityLabel("Pitch contour comparison. Reference in the system accent color, your attempt in orange. Unscored.")
    }
}

private extension View {
    @ViewBuilder func historySearchFocus(_ binding: FocusState<Bool>.Binding) -> some View {
        if #available(macOS 15.0, *) { self.searchFocused(binding) }
        else { self }
    }
}
