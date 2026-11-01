import AppKit
import Carbon.HIToolbox
import SwiftUI

/// What Return does in the message composer: a plain Return starts a new line and Shift-Return sends.
enum ComposerReturnKey: Equatable {
    case newline, send

    /// `nil` leaves the key to the rest of the app: an input method confirms its composition with Return, ⌘Return
    /// belongs to the Send button's shortcut, and Option-Return keeps the text field's own new line.
    static func action(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, composing: Bool) -> ComposerReturnKey? {
        guard !composing, keyCode == UInt16(kVK_Return) || keyCode == UInt16(kVK_ANSI_KeypadEnter) else { return nil }
        switch modifiers.intersection([.command, .option, .control, .shift]) {
        case []: return .newline
        case .shift: return .send
        default: return nil
        }
    }
}

/// Takes Return before the composer's field editor, which would otherwise end editing rather than start a new line.
/// SwiftUI's text field offers no way to tell its editor this, and leaves it unable to see an input method's state.
struct ComposerReturnKeys: NSViewRepresentable {
    let active: Bool
    let send: () -> Void

    func makeNSView(context: Context) -> MonitorView { MonitorView() }
    func updateNSView(_ view: MonitorView, context: Context) {
        view.active = active
        view.send = send
    }

    final class MonitorView: NSView {
        var active = false
        var send: () -> Void = {}
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        /// Listens only while in a window; removal from the window is what ends the monitor.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let handled = MainActor.assumeIsolated { self?.handle(event) ?? false }
                return handled ? nil : event
            }
        }

        /// Another window can have the keyboard while SwiftUI still counts the composer as focused: a sheet's or the
        /// message bar's Return stays theirs.
        private func handle(_ event: NSEvent) -> Bool {
            guard active, let window, event.window === window, let editor = window.firstResponder as? NSTextView,
                let action = ComposerReturnKey.action(
                    keyCode: event.keyCode, modifiers: event.modifierFlags, composing: editor.hasMarkedText())
            else { return false }
            switch action {
            case .newline: editor.insertNewlineIgnoringFieldEditor(nil)
            case .send: send()
            }
            return true
        }
    }
}
