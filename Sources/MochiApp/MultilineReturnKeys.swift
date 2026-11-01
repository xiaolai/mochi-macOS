import AppKit
import Carbon.HIToolbox
import SwiftUI

/// What Return does in a text field of several lines: a plain Return starts a new line, and Shift-Return or ⌘Return
/// carries out the field's action, such as sending.
enum MultilineReturnKey: Equatable {
    case newline, submit

    /// `nil` leaves the key to the rest of the app: an input method confirms its composition with Return, and
    /// Option-Return keeps the text field's own new line.
    static func action(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, composing: Bool) -> MultilineReturnKey? {
        guard !composing, keyCode == UInt16(kVK_Return) || keyCode == UInt16(kVK_ANSI_KeypadEnter) else { return nil }
        switch modifiers.intersection([.command, .option, .control, .shift]) {
        case []: return .newline
        case .shift, .command: return .submit
        default: return nil
        }
    }
}

extension View {
    /// Gives a vertical `TextField` the Return keys above while `active`, normally while it has focus. A field with no
    /// `submit` leaves Shift-Return and ⌘Return to the rest of the app.
    func multilineReturnKeys(active: Bool, submit: (() -> Void)? = nil) -> some View {
        background(MultilineReturnKeys(active: active, submit: submit))
    }
}

/// Takes Return before the field editor, which would otherwise end editing rather than start a new line. SwiftUI's text
/// field offers no way to tell its editor this, and leaves it unable to see an input method's state.
private struct MultilineReturnKeys: NSViewRepresentable {
    let active: Bool
    let submit: (() -> Void)?

    func makeNSView(context: Context) -> MonitorView { MonitorView() }
    func updateNSView(_ view: MonitorView, context: Context) {
        view.active = active
        view.submit = submit
    }

    final class MonitorView: NSView {
        var active = false
        var submit: (() -> Void)?
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

        /// Another window can have the keyboard while SwiftUI still counts the field as focused: a sheet's or the
        /// message bar's Return stays theirs.
        private func handle(_ event: NSEvent) -> Bool {
            guard active, let window, event.window === window, let editor = window.firstResponder as? NSTextView,
                let action = MultilineReturnKey.action(
                    keyCode: event.keyCode, modifiers: event.modifierFlags, composing: editor.hasMarkedText())
            else { return false }
            switch action {
            case .newline: editor.insertNewlineIgnoringFieldEditor(nil)
            case .submit:
                guard let submit else { return false }
                submit()
            }
            return true
        }
    }
}
