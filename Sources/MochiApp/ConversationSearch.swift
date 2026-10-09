import SwiftUI
import AppKit

struct ConversationSearchControl: View {
    @ObservedObject var app: AppModel
    var body: some View {
        if app.conversationSearchOpen {
            HStack(spacing:6) {
                ConversationSearchField(app:app).frame(width:180)
                if !app.conversationQuery.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
                    Text(app.conversationMatchIDs.isEmpty ? "No matches" : "\(min(app.conversationMatchIndex+1,app.conversationMatchIDs.count))/\(app.conversationMatchIDs.count)")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary).fixedSize()
                    Button { app.moveConversationMatch(-1) } label: { Image(systemName:"chevron.up") }
                        .help("Previous Match (⇧⌘G)").accessibilityLabel("Previous Match").disabled(app.conversationMatchIDs.isEmpty)
                    Button { app.moveConversationMatch(1) } label: { Image(systemName:"chevron.down") }
                        .help("Next Match (⌘G)").accessibilityLabel("Next Match").disabled(app.conversationMatchIDs.isEmpty)
                }
                Button(action:app.closeConversationSearch) { Image(systemName:"xmark") }
                    .help("Close Search (Escape)").accessibilityLabel("Close conversation search")
            }
        } else {
            Button(action:app.openConversationSearch) { Label("Find in Conversation",systemImage:"magnifyingglass") }
                .labelStyle(.iconOnly).help("Find in Conversation (⌘F)")
        }
    }
}

private struct ConversationSearchField: NSViewRepresentable {
    @ObservedObject var app: AppModel
    func makeCoordinator() -> Coordinator { Coordinator(app:app) }
    func makeNSView(context: Context) -> FocusableSearchField {
        let field = FocusableSearchField()
        field.placeholderString = "Search this conversation"
        field.setAccessibilityLabel("Search this conversation")
        field.sendsSearchStringImmediately = true
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.searchChanged(_:))
        return field
    }
    func updateNSView(_ field: FocusableSearchField, context: Context) {
        context.coordinator.app = app
        if field.stringValue != app.conversationQuery { field.stringValue = app.conversationQuery }
        if context.coordinator.focusRequest != app.conversationSearchFocusRequest {
            context.coordinator.focusRequest = app.conversationSearchFocusRequest
            field.wantsFocus = true
            DispatchQueue.main.async { field.focusIfNeeded() }
        }
    }
    final class FocusableSearchField: NSSearchField {
        var wantsFocus = false
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); focusIfNeeded() }
        func focusIfNeeded() {
            guard wantsFocus, let window else { return }
            wantsFocus = false; window.makeFirstResponder(self)
        }
    }
    @MainActor final class Coordinator: NSObject, NSSearchFieldDelegate {
        var app: AppModel
        var focusRequest: Int?
        init(app: AppModel) { self.app = app }
        @objc func searchChanged(_ field: NSSearchField) {
            if app.conversationQuery != field.stringValue { app.conversationQuery = field.stringValue }
        }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            app.conversationQuery = field.stringValue
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) { app.closeConversationSearch(); return true }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                app.moveConversationMatch(NSApp.currentEvent?.modifierFlags.contains(.shift) == true ? -1 : 1)
                return true
            }
            return false
        }
    }
}
