import MochiCore
import SwiftUI

private enum SidebarDestination: Hashable {
    case conversation(UUID)
    case expressions
    case collection(HistoryScope)
}

struct WorkspaceView: View {
    @Bindable var app: AppModel
    @FocusState private var searchFocused: Bool
    @FocusState private var composerFocused: Bool
    @State private var refocusComposer = false
    @Environment(\.openSettings) private var openSettings
    private var selection: Binding<SidebarDestination?> {
        Binding(
            get: {
                app.showExpressions ? .expressions : app.selectedID.map(SidebarDestination.conversation)
            },
            set: { destination in
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
            List(selection: selection) {
                Section {
                    Label {
                        Text("My Expressions")
                    } icon: {
                        Image(systemName: "bookmark").foregroundStyle(
                            app.showExpressions ? Color.white : Color.accentColor)
                    }
                    .badge(app.library.expressions.count)
                    .tag(SidebarDestination.expressions)
                }
                Section {
                    ForEach(HistoryScope.allCases) { scope in
                        Label(scope.title, systemImage: scope.icon)
                            .badge(app.library.count(in: scope))
                            .tag(SidebarDestination.collection(scope))
                            .fontWeight(!app.showExpressions && app.history.scope == scope ? .semibold : .regular)
                    }
                }
                ForEach(historyGroups, id: \.id) { group in
                    Section {
                        ForEach(group.chats) { chat in
                            SidebarChatRow(app: app, chat: chat)
                                .tag(SidebarDestination.conversation(chat.id))
                                .contextMenu { ChatActions(app: app, chat: chat) }
                        }
                    } header: {
                        if !group.chats.isEmpty, let title = group.title { Text(title) }
                    }
                }
                Section {
                    if app.visibleChats.isEmpty {
                        Text(
                            app.history.query.isEmpty && app.history.character == nil
                                ? "No conversations here" : "No matching conversations"
                        )
                        .foregroundStyle(.secondary).font(.callout)
                        if !app.history.query.isEmpty { Button("Clear Search") { app.history.query = "" } }
                        if app.history.character != nil {
                            Button("Show All Characters") { app.history.character = nil }
                        }
                    }
                }

            }
            .listStyle(.sidebar)
            .searchable(
                text: $app.history.query, isPresented: $app.history.searchOpen, placement: .sidebar,
                prompt: "Search titles, characters and messages"
            )
            .historySearchFocus($searchFocused)
            .navigationTitle("")
            .toolbar {
                ToolbarItem(placement: .automatic) { HistoryOrderMenu(app: app) }
                ToolbarItem(placement: .primaryAction) {
                    Button(action: app.newChat) { Label("New Conversation", systemImage: "square.and.pencil") }
                        .labelStyle(.iconOnly).help("New Conversation (⌘N)")
                    Menu {
                        Button("New Conversation from Template…", action: app.openTemplatePicker)
                        Button("Manage Templates…", action: app.openTemplateManager)
                        Button("Manage Characters…", action: app.openCharacterManager)
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .menuStyle(.borderlessButton).fixedSize().help("Conversation Templates").disabled(
                        !app.canOpenConversationInstructions)
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 320)
        } detail: {
            Group {
                if app.showExpressions {
                    VStack(spacing: 0) {
                        expressions
                        if let error = app.error { errorBanner(error) }
                    }
                } else {
                    VStack(spacing: 0) {
                        transcript
                        if let progress = app.startupProgress ?? app.libraryTransfer {
                            HStack(spacing: 10) {
                                ProgressView().controlSize(.small)
                                Text(progress)
                            }
                            .font(.callout).frame(maxWidth: .infinity, alignment: .leading).padding(12).background(.bar)
                        }
                        if let error = app.error { errorBanner(error) }
                        if app.writableConversation {
                            inputBar
                        } else if let chat = app.conversation {
                            historyBanner(chat)
                        }
                    }
                }
            }
            .modifier(TitleBarScrollEdge())
            .overlay(alignment: .topTrailing) {
                if let notice = app.notice, !app.practice { NoticeCard(app: app, notice: notice) }
            }
            .navigationTitle("")
            .toolbar {
                if app.turn.activity == .generating {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            app.stop()
                        } label: {
                            Label("Stop", systemImage: "stop.fill")
                        }.labelStyle(.iconOnly).help(
                            "Stop (Escape)")
                    }
                }
                if #available(macOS 26.0, *) { ToolbarSpacer(.flexible, placement: .primaryAction) }
                // Older AppKit toolbars already place primary actions at the trailing edge.
                if !app.showExpressions, app.conversation != nil {
                    ToolbarItem(placement: .primaryAction) {
                        ConversationSearchControl(app: app).disabled(app.practice)
                    }
                }
            }
        }
        .sheet(
            isPresented: Binding(
                get: { app.customization.isPresented },
                set: { if !$0 { app.customization.dismiss() } })
        ) {
            if app.customization.characterPresentation != nil {
                CharactersView(app: app)
            } else if app.customization.templatePresentation != nil {
                ConversationTemplatesView(app: app)
            } else if let id = app.customization.instructionsID {
                ConversationInstructionsView(app: app, id: id)
            }
        }
        .sheet(isPresented: $app.history.managerOpen) { HistoryManagerView(app: app) }
        .sheet(
            isPresented: Binding(
                get: { app.history.renameID != nil && !app.history.managerOpen },
                set: { if !$0 && !app.history.managerOpen { app.history.renameID = nil } })
        ) { if let id = app.history.renameID { RenameChatView(app: app, id: id) } }
        .sheet(
            isPresented: Binding(
                get: { !app.history.permanentDeleteIDs.isEmpty && !app.history.managerOpen },
                set: { if !$0 && !app.history.managerOpen { app.history.permanentDeleteIDs = [] } })
        ) { DeleteHistoryConfirmation(app: app) }
        .sheet(isPresented: Binding(get: { app.practice }, set: { if !$0 && app.practice { app.resume() } })) {
            PracticePane(app: app).frame(width: 640, height: 580)
        }
        .onChange(of: app.history.searchFocusRequest) { _, _ in if !app.history.managerOpen { searchFocused = true } }
        .onChange(of: app.settingsOpen) { _, show in
            if show {
                openSettings()
                app.settingsOpen = false
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 760, minHeight: 580)
    }

    /// Every group is always present, empty or not. Inserting a whole section into the live
    /// sidebar table (for example Pinned, when switching to Conversations) makes SwiftUI
    /// update NSTableView reentrantly; with a fixed section list only rows change.
    private var historyGroups: [(id: String, title: LocalizedStringKey?, chats: [Conversation])] {
        let chats = app.visibleChats
        let searching = !app.history.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let listed = searching ? [] : chats
        let pinned = listed.filter { $0.pinned && app.history.scope == .active }
        let remaining = listed.filter { !($0.pinned && app.history.scope == .active) }
        let calendar = Calendar.current
        let sort = app.settings.historySort
        func rowDate(_ chat: Conversation) -> Date {
            if sort == .created { return chat.date }
            return app.history.scope == .deleted ? chat.deletedAt ?? chat.updatedAt : chat.updatedAt
        }
        // Alphabetical orders have no dates to group by: everything unpinned is one untitled section.
        guard sort == .recent || sort == .created else {
            return [
                ("search", "Search Results", searching ? chats : []), ("pinned", "Pinned", pinned),
                ("today", nil, []), ("yesterday", nil, []), ("earlier", nil, remaining),
            ]
        }
        return [
            ("search", "Search Results", searching ? chats : []),
            ("pinned", "Pinned", pinned),
            ("today", "Today", remaining.filter { calendar.isDateInToday(rowDate($0)) }),
            ("yesterday", "Yesterday", remaining.filter { calendar.isDateInYesterday(rowDate($0)) }),
            (
                "earlier", "Earlier",
                remaining.filter { !calendar.isDateInToday(rowDate($0)) && !calendar.isDateInYesterday(rowDate($0)) }
            ),
        ]
    }
    private func historyBanner(_ chat: Conversation) -> some View {
        HStack(spacing: 12) {
            Image(systemName: chat.isDeleted ? "trash" : "archivebox").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(chat.isDeleted ? "Recently Deleted" : "Archived Conversation").fontWeight(.medium)
                Text(chat.isDeleted ? "Kept until you permanently delete it." : "Move it back to continue chatting.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(chat.isDeleted ? "Recover" : "Move to Conversations") { app.restoreChats([chat.id]) }
        }.padding(16).background(.bar)
    }

    private var transcript: some View {
        let sidebarMatchID = app.conversation?.matchingMessage(app.history.query)?.id
        return Group {
            if app.conversation?.messages.isEmpty != false {
                if app.conversation == nil {
                    ContentUnavailableView(
                        "No Conversation Selected", systemImage: app.history.scope.icon,
                        description: Text("Select a conversation, or start a new one with ⌘N."))
                } else if !app.writableConversation {
                    ContentUnavailableView(
                        "No Messages", systemImage: app.history.scope.icon,
                        description: Text("This conversation is empty."))
                } else {
                    ContentUnavailableView {
                        MochiView().frame(width: 72, height: 78)
                        if let starter = app.starterTemplate {
                            Text(starter.displayTitle)
                        } else {
                            Text("A little conversation. A little practice.")
                        }
                    } description: {
                        if let starter = app.starterTemplate, !starter.displayDescription.isEmpty {
                            Text(starter.displayDescription)
                        }
                        if let chat = app.conversation, chat.greetsBeforeRecording, !chat.greeting.isEmpty {
                            Text("\(app.displayCharacterName) opens with: “\(chat.greeting)”")
                        }
                        if app.canHelp {
                            Text(
                                "Talk with \(app.displayCharacterName) in \(app.languageName). When you get stuck,\nwe’ll find the words and practise them in your own voice."
                            )
                        } else {
                            Text(
                                "Talk with \(app.displayCharacterName) in any language.\nReplies follow the language you speak."
                            )
                        }
                    }
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            ForEach(app.conversation?.messages ?? []) { message in
                                messageView(message, sidebarMatchID: sidebarMatchID).id(message.id)
                            }
                            Color.clear.frame(height: 1).id("bottom")
                        }
                        .padding(20)
                        .frame(maxWidth: 820)
                        .frame(maxWidth: .infinity)
                    }
                    .defaultScrollAnchor(.bottom)
                    .id(app.selectedID)
                    .task(id: "\(app.selectedID?.uuidString ?? "")|\(app.history.query)") {
                        await Task.yield()
                        if let id = app.find.matchID {
                            proxy.scrollTo(id, anchor: .center)
                        } else if let message = app.conversation?.matchingMessage(app.history.query) {
                            proxy.scrollTo(message.id, anchor: .center)
                        } else {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }
                    .onChange(of: app.find.matchID) { _, id in
                        if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
                    }
                    .onChange(of: app.conversation?.messages.map(\.id) ?? []) { previous, current in
                        if current.count > previous.count, current.starts(with: previous),
                            app.find.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        {
                            withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func messageView(_ message: Message, sidebarMatchID: UUID?) -> some View {
        let isUser = message.role == "user"
        return HStack(alignment: .top, spacing: 8) {
            if isUser { Spacer(minLength: 60) }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 5) {
                Text(isUser ? String(localized: "You") : (message.speakerName ?? "Mochi")).font(.caption)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 8) {
                    Text(message.displayText)
                        .font(.system(size: 15))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if isUser && message.audio != nil && message.contextText == nil {
                        Text(
                            app.transcribingMessageIDs.contains(message.id)
                                ? "Transcribing…" : "Transcript unavailable · use the message menu to retry or add text"
                        )
                        .font(.caption).opacity(0.8).frame(width: 300, alignment: .leading).fixedSize(
                            horizontal: false, vertical: true)
                    }
                    if let file = message.audio {
                        HStack(alignment: .center, spacing: 4) {
                            MessagePlayback(app: app, audio: app.audio, file: file, isUser: isUser)
                            if isUser { VoiceTranscriptControls(app: app, message: message) }
                        }
                    }
                }
                .foregroundStyle(isUser ? Color.white : Color.primary)
                .tint(isUser ? Color.white : Color.accentColor)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .contextMenu {
                    Button("Copy Message") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(message.contextText ?? "", forType: .string)
                    }.disabled(message.contextText == nil)
                    Text(message.date.formatted(date: .abbreviated, time: .shortened))
                    SharedMessageActions(app: app, message: message)
                }
                .overlay(alignment: .leading) {
                    if app.find.matchSet.contains(message.id) || sidebarMatchID == message.id {
                        RoundedRectangle(cornerRadius: 18)
                            .stroke(
                                app.find.matchID == message.id ? Color.orange : Color.accentColor,
                                lineWidth: app.find.matchID == message.id ? 3 : 1.5
                            ).padding(-3)
                    }
                }
                .background(
                    isUser ? Color.accentColor : Color.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))

            }
            if !isUser { Spacer(minLength: 60) }
        }
    }

    /// The conversation's phrases, each sent as the user's message with one click; the composer keeps its draft.
    @ViewBuilder private var phraseChips: some View {
        let phrases = app.conversation?.phrases ?? []
        if !phrases.isEmpty || app.isRolePlay {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    if app.isRolePlay {
                        Button(action: app.startAgain) {
                            Label("Start Again", systemImage: "arrow.counterclockwise")
                        }
                        .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small)
                        .disabled(!app.canStartAgain)
                        .help("Redo this scenario from the beginning; Mochi checks the details with you first")
                        #if MOCHI_DEVELOPMENT
                            .background(ClickProbe("mochi-start-again-probe"))
                        #endif
                    }
                    ForEach(Array(phrases.enumerated()), id: \.offset) { index, phrase in
                        Button {
                            app.sendPhrase(phrase)
                        } label: {
                            Text(verbatim: phrase).lineLimit(1)
                        }
                        .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small)
                        .help(Text("Send “\(phrase)”"))
                        .accessibilityLabel(Text("Send “\(phrase)”"))
                        #if MOCHI_DEVELOPMENT
                            .background(ClickProbe("mochi-phrase-chip-probe-\(index)"))
                        #endif
                    }
                }.padding(.horizontal, 2)
            }
            .disabled(!app.canSendPhrase)
            .accessibilityIdentifier("phrase-chips")
        }
    }

    private var inputBar: some View {
        VStack(spacing: 8) {
            phraseChips
            HStack(alignment: .bottom, spacing: 12) {
                Button(action: app.toggleConversationVoice) {
                    Image(
                        systemName: app.turn.activity == .recording
                            ? "stop.circle.fill" : app.listeningSymbol ?? "mic.fill"
                    )
                    .font(.system(size: 18))
                }.buttonStyle(.borderless)
                    .help(app.microphoneLabel)
                    .accessibilityLabel(app.microphoneLabel)
                    .disabled(
                        app.busy && app.turn.activity != .recording && !app.greetingActive && !app.listening.isOn)
                Button(action: app.startHelp) {
                    Image(systemName: "waveform.badge.plus").font(.system(size: 18))
                }.buttonStyle(.borderless)
                    .help(
                        app.canHelp
                            ? Text("Help Me Say This (⇧⌘H)")
                            : Text(
                                "Help Me Say This needs a language to practise. Choose one in Conversation Instructions."
                            )
                    )
                    .accessibilityLabel("Help Me Say This")
                    .disabled(
                        !app.canHelp || app.turn.activity == .recording || app.turn.activity == .requestingPermission)
                TextField("Message \(app.displayCharacterName)", text: $app.draft, axis: .vertical)
                    .accessibilityIdentifier("conversation-composer")
                    #if MOCHI_DEVELOPMENT
                        .background(ComposerGeometryProbe())
                    #endif
                    .textFieldStyle(.plain).font(.system(size: 15)).lineLimit(1...5)
                    .focused($composerFocused)
                    .onSubmit { app.send() }.disabled(app.busy)
                Button(action: app.send) { Image(systemName: "arrow.up").fontWeight(.semibold) }
                    .buttonStyle(.borderedProminent).buttonBorderShape(.circle)
                    .disabled(app.busy || app.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(12)
            .fieldFrame(cornerRadius: 24, focused: composerFocused)
            if app.turn.activity == .recording { RecordingFeedback(app: app) }
            if app.listening.isOn { SendNowButton(app: app) }
            HStack(spacing: 5) {
                if app.turn.activity == .generating || app.turn.activity == .requestingPermission {
                    ProgressView().controlSize(.mini)
                } else {
                    let open = app.turn.activity == .recording || app.listening.microphoneOpen
                    Image(systemName: app.turn.activity == .recording ? "record.circle" : open ? "ear" : "mic.slash")
                        .foregroundStyle(open ? .red : .secondary)
                }
                Text(app.status).lineLimit(1)
                Spacer(minLength: 4)
                if app.demo { Text("Preview").foregroundStyle(.secondary) }
            }.font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(Color(nsColor: .textBackgroundColor))
        .onChange(of: app.busy) { _, busy in
            if busy {
                refocusComposer = composerFocused
            } else if refocusComposer {
                refocusComposer = false
                DispatchQueue.main.async {
                    // The user may have moved into a search field while the composer was disabled.
                    let editor = (NSApp.keyWindow?.firstResponder as? NSTextView)?.delegate
                    guard !searchFocused, !(editor is NSSearchField) else { return }
                    composerFocused = true
                }
            }
        }
        .onChange(of: searchFocused) { _, focused in if focused { refocusComposer = false } }
        .animation(.easeOut(duration: 0.2), value: app.turn.activity == .recording)
    }

    private func errorBanner(_ text: String) -> some View {
        HStack(alignment: .top) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).textSelection(.enabled)
            Spacer()
            if app.canRetry { Button("Retry", action: app.retryReply) }
            Button {
                app.error = nil
            } label: {
                Label("Dismiss", systemImage: "xmark")
            }.labelStyle(.iconOnly)
        }.font(.callout).padding(12).background(.bar)
    }

    private var expressions: some View {
        Group {
            if app.library.expressions.isEmpty {
                ContentUnavailableView(
                    "No Saved Expressions", systemImage: "bookmark",
                    description: Text("Save an expression while practising to return to it here."))
            } else {
                // Due counts and labels depend on the time; the list re-reads them each minute, so they turn over at
                // midnight while it stays open.
                TimelineView(.everyMinute) { context in
                    expressionList(at: context.date)
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func expressionList(at now: Date) -> some View {
        List {
            reviewBanner(at: now)
            ForEach(app.library.expressions) { expression in
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(expression.english).font(.body)
                        if !expression.meaning.isEmpty {
                            Text(expression.meaning).font(.callout).foregroundStyle(.secondary)
                        }
                        Text(
                            "\(expression.attempts.count) attempts · \(Self.reviewLabel(expression.review, at: now))"
                        )
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Practise") { app.openExpression(expression) }
                }.padding(.vertical, 5)
            }
        }.listStyle(.inset)
    }
    private func reviewBanner(at now: Date) -> some View {
        let due = app.dueExpressionCount(at: now)
        return HStack {
            Label(
                due == 0 ? "Nothing to review today" : "Expressions to review: \(due)",
                systemImage: "clock.arrow.circlepath")
            Spacer()
            Button("Start Review", action: app.startReview).buttonStyle(.borderedProminent)
                .disabled(!app.canStartReview(at: now))
        }.padding(.vertical, 6)
    }
    /// When an expression comes up for review: due now, or the day it is due.
    static func reviewLabel(_ review: ReviewState?, at now: Date = Date()) -> String {
        guard let review, review.due > now else { return String(localized: "Due for review") }
        return String(localized: "Next review \(review.due.formatted(date: .abbreviated, time: .omitted))")
    }
}

private struct SidebarChatRow: View {
    @Bindable var app: AppModel
    var chat: Conversation
    private var selected: Bool { app.selectedID == chat.id && !app.showExpressions }
    /// The character is named when the list is ordered by character or the conversation has a character of its own.
    private var showsCharacter: Bool { app.settings.historySort == .companion || chat.characterName != nil }
    private var preview: String {
        chat.matchingMessage(app.history.query)?.text
            ?? (chat.draft.isEmpty
                ? chat.messages.last?.text ?? String(localized: "New conversation")
                : String(localized: "Draft: \(chat.draft)"))
    }
    var body: some View {
        HStack(spacing: 10) {
            Image(
                systemName: chat.pinned
                    ? "pin.fill"
                    : chat.archived ? "archivebox" : "bubble.left.and.bubble.right.fill"
            )
            .font(.system(size: 18))
            // The selected row's highlight is the accent colour, so its icon turns white to stay visible.
            .foregroundStyle(selected ? Color.white : CharacterColor.color(for: chat.displayCharacterName))
            .help(chat.displayCharacterName).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(chat.displayTitle).fontWeight(.medium).lineLimit(1)
                Text(showsCharacter ? "\(chat.displayCharacterName) · \(preview)" : preview)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Menu {
                ChatActions(app: app, chat: chat)
            } label: {
                Image(systemName: "ellipsis").frame(width: 20, height: 24)
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Conversation Actions")
                .accessibilityLabel("Actions for \(chat.displayTitle)")
        }.padding(.vertical, 7)
    }
}

/// Content scrolled under the title bar fades out beneath its controls. With the window title hidden, macOS 26 and
/// later draw no soft scroll edge while the window is key, so the hard style is the one that always shows.
private struct TitleBarScrollEdge: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) { content.scrollEdgeEffectStyle(.hard, for: .top) } else { content }
    }
}

private struct NoticeCard: View {
    @Bindable var app: AppModel
    var notice: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(notice).font(.callout).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if app.messageDeletionUndo != nil {
                Button("Undo", action: app.undoMessageDeletion)
                    .buttonStyle(.borderless).disabled(!app.canUndoMessageDeletion)
                    .accessibilityLabel("Undo Delete Message")
            }
            Button {
                app.notice = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless).foregroundStyle(.secondary)
            .help("Dismiss notice").accessibilityLabel("Dismiss notice")
        }
        .padding(12).frame(maxWidth: 360)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.secondary.opacity(0.15)) }
        .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
        .padding(16)
        .accessibilityIdentifier("conversation-notice")
    }
}

struct PracticeActions: View {
    @Bindable var app: AppModel
    var body: some View {
        HStack(spacing: 10) {
            AttemptControls(app: app)
            Button {
                if app.saveExpression() { app.notice = "Saved to My Expressions." }
            } label: {
                Label("Save Expression", systemImage: "bookmark")
            }
            .labelStyle(.iconOnly).help("Save Expression").disabled(app.busy)
            Spacer(minLength: 2)
            Button("Resume Conversation", action: app.resume).buttonStyle(.borderedProminent).keyboardShortcut(
                .cancelAction)
        }
    }
}
/// Ends the spoken turn at once. Shown while hands-free listening is on: Mochi can judge a pause mid-sentence as the
/// end of a turn, or wait at the end of one, and this is the learner's own say (plan E5).
struct SendNowButton: View {
    @Bindable var app: AppModel
    var body: some View {
        Button(action: app.sendNow) {
            Label(ShortcutAction.sendNow.title, systemImage: "paperplane")
        }
        .controlSize(.small)
        .disabled(!app.canSendNow)
        .help(
            app.settings.shortcuts[.sendNow].map { Text("Send what you have said now (\($0.display))") }
                ?? Text("Send what you have said now")
        )
        .accessibilityIdentifier("send-now")
    }
}
/// Records an attempt and replays the latest one; shared by practice and review.
struct AttemptControls: View {
    @Bindable var app: AppModel
    var body: some View {
        let recording = app.turn.activity == .recording
        if !recording && (app.handsFree || app.listening.isOn) {
            Button(action: app.toggleRecord) {
                Label(app.listeningMenuTitle, systemImage: app.listeningSymbol ?? "ear")
            }.disabled(!app.listening.isOn && !app.canStartListening)
            if app.listening.isOn { SendNowButton(app: app) }
        } else {
            Button(action: app.toggleRecord) {
                Label(
                    recording ? "Finish (\(app.recordingSeconds)s)" : "Record Attempt",
                    systemImage: recording ? "stop.fill" : "mic")
            }.disabled(!recording && (app.busy || !app.canRecordAttempt))
        }
        if let file = app.help.expression?.attempts.last?.file {
            Button {
                app.play(file)
            } label: {
                Label("Play Attempt", systemImage: "play.fill")
            }
            .labelStyle(.iconOnly).help("Play Latest Attempt").disabled(app.busy)
        }
    }
}
/// The review footer: record and replay, then reveal, then grade.
struct ReviewActions: View {
    @Bindable var app: AppModel
    var body: some View {
        HStack(spacing: 10) {
            AttemptControls(app: app)
            Spacer(minLength: 2)
            Button("End Review", action: app.endReview).keyboardShortcut(.cancelAction)
            if app.help.review?.revealed == true {
                Button("Again") { app.gradeReview(.again) }.disabled(app.busy)
                Button("Hard") { app.gradeReview(.hard) }.disabled(app.busy)
                Button("Good") { app.gradeReview(.good) }.buttonStyle(.borderedProminent).disabled(app.busy)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Reveal", action: app.revealReview).buttonStyle(.borderedProminent).disabled(app.busy)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}
struct PitchChart: View {
    var reference: [PitchPoint]
    var attempt: [PitchPoint]
    var normalized: Bool
    var smoothed = true
    var body: some View {
        Canvas { context, size in
            let series = [reference, attempt].map { PitchContour.runs($0, smoothed: smoothed) }
            let medians = [reference, attempt].map { normalized ? PitchContour.center($0) : 0 }
            let all = series.enumerated().flatMap { index, runs in runs.flatMap { $0.map { $0.value - medians[index] } }
            }
            let low = (all.min() ?? 0) - 2
            let high = max(low + 8, (all.max() ?? 12) + 2)
            let duration = PitchContour.duration(reference + attempt)
            let w = max(1, size.width - 26)
            let top = 6.0
            let h = max(1, size.height - 26)
            for i in 0...3 {
                let y = top + h * Double(i) / 3
                var path = Path()
                path.move(to: CGPoint(x: 24, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(
                    path, with: .color(.secondary.opacity(0.12)), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                context.draw(
                    Text("\(Int(high-(high-low)*Double(i)/3))").font(.system(size: 8)).foregroundColor(.secondary),
                    at: CGPoint(x: 9, y: y))
            }
            for i in 0...Int(duration) {
                context.draw(
                    Text("\(i)s").font(.system(size: 8)).foregroundColor(.secondary),
                    at: CGPoint(x: 24 + Double(i) / duration * w, y: size.height - 5))
            }
            for (index, runs) in series.enumerated() {
                func position(_ point: PitchContour.Point) -> CGPoint {
                    CGPoint(
                        x: 24 + point.time / duration * w,
                        y: top + h * (1 - (point.value - medians[index] - low) / (high - low)))
                }
                var path = Path()
                for run in runs {
                    guard let first = run.first else { continue }
                    path.move(to: position(first))
                    if run.count == 1 {
                        let p = position(first)
                        path.addEllipse(in: CGRect(x: p.x - 1, y: p.y - 1, width: 2, height: 2))
                    } else if smoothed {
                        for curve in PitchContour.curves(run) {
                            path.addCurve(
                                to: position(curve.end), control1: position(curve.control1),
                                control2: position(curve.control2))
                        }
                    } else {
                        for point in run.dropFirst() { path.addLine(to: position(point)) }
                    }
                }
                context.stroke(
                    path, with: .color(index == 0 ? .accentColor : .orange),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
        }.accessibilityLabel(
            "Pitch contour comparison. Reference in the system accent color, your attempt in orange. Unscored.")
    }
}

extension View {
    @ViewBuilder fileprivate func historySearchFocus(_ binding: FocusState<Bool>.Binding) -> some View {
        if #available(macOS 15.0, *) { self.searchFocused(binding) } else { self }
    }
}

#if MOCHI_DEVELOPMENT
    /// Native geometry evidence independent of SwiftUI's accessibility implementation.
    struct ComposerGeometryProbe: NSViewRepresentable {
        func makeNSView(context: Context) -> NSView {
            let view = NSView()
            view.identifier = NSUserInterfaceItemIdentifier("mochi-composer-geometry-probe")
            return view
        }
        func updateNSView(_ view: NSView, context: Context) {}
    }
    /// Where a control is, so development runs can click it as a person would. Clicks pass through to the control.
    struct ClickProbe: NSViewRepresentable {
        let identifier: String
        init(_ identifier: String) { self.identifier = identifier }
        final class ProbeView: NSView {
            override func hitTest(_ point: NSPoint) -> NSView? { nil }
        }
        func makeNSView(context: Context) -> NSView {
            let view = ProbeView()
            view.identifier = NSUserInterfaceItemIdentifier(identifier)
            return view
        }
        func updateNSView(_ view: NSView, context: Context) {}
    }
#endif

/// Orders the conversation list and narrows it to one character.
private struct HistoryOrderMenu: View {
    @Bindable var app: AppModel

    var body: some View {
        Menu {
            Picker("Sort By", selection: Bindable(app.settings).historySort) {
                ForEach(HistorySort.allCases, id: \.self) { Text($0.title).tag($0) }
            }.pickerStyle(.inline)
            Picker("Character", selection: $app.history.character) {
                Text("All Characters").tag(String?.none)
                ForEach(characters, id: \.self) { Text(verbatim: $0).tag(String?.some($0)) }
            }.pickerStyle(.inline)
        } label: {
            Image(
                systemName: app.history.character == nil
                    ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
        }
        .menuIndicator(.hidden).help("Sort and Filter Conversations")
        .accessibilityLabel("Sort and Filter Conversations")
    }

    /// The characters in the listed collection, and the chosen one even when it no longer has conversations there.
    private var characters: [String] {
        let listed = app.library.companions(in: app.history.scope)
        guard let chosen = app.history.character, !listed.contains(chosen) else { return listed }
        return listed + [chosen]
    }
}
