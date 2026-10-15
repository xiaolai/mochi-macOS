import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Records one action's shortcut: click, then type it. Escape cancels; Delete removes the shortcut.
/// Only keys typed in this recorder's own window count; another window's keys or leaving the window cancel.
struct ShortcutRecorder: View {
    let action: ShortcutAction
    @Bindable var app: AppModel
    @State private var monitor: Any?
    @State private var resignObserver: NSObjectProtocol?
    @State private var message: String?

    private var current: Shortcut? { app.settings.shortcuts[action] }
    private var recording: Bool { app.shortcuts.recordingAction == action }

    var body: some View {
        LabeledContent(action.title) {
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 6) {
                    Button {
                        recording ? stop() : start()
                    } label: {
                        Group {
                            if recording {
                                Text("Type Shortcut…")
                            } else if let current {
                                Text(verbatim: current.display).monospaced()
                            } else {
                                Text("Record Shortcut")
                            }
                        }.frame(minWidth: 130)
                    }
                    .accessibilityIdentifier("shortcut-\(action.rawValue)")
                    if current != nil && !recording {
                        Button {
                            message = nil
                            app.setShortcut(nil, for: action)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                        .help("Remove Shortcut").accessibilityLabel("Remove Shortcut")
                    }
                }
                if let problem = message ?? app.shortcuts.problems[action] {
                    Text(problem).font(.caption).foregroundStyle(.red).multilineTextAlignment(.trailing)
                }
            }
        }
        // Another row taking over ends this one's listening without touching the shared state it now owns.
        .onChange(of: app.shortcuts.recordingAction) { _, owner in if owner != action { release() } }
        .onDisappear(perform: stop)
    }

    private func start() {
        message = nil
        guard let window = NSApp?.keyWindow else { return }
        app.shortcuts.recordingAction = action
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Another row may have taken over before this monitor is removed; its keys are not this row's.
            guard app.shortcuts.recordingAction == action else {
                release()
                return event
            }
            guard event.window === window else {
                stop()
                return event
            }
            handle(event)
            return nil
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { _ in MainActor.assumeIsolated { stop() } }
    }

    private func handle(_ event: NSEvent) {
        let modifiers = Shortcut.Modifiers(event.modifierFlags)
        if modifiers.isEmpty && event.keyCode == UInt16(kVK_Escape) {
            message = nil
            stop()
        } else if modifiers.isEmpty
            && (event.keyCode == UInt16(kVK_Delete) || event.keyCode == UInt16(kVK_ForwardDelete))
        {
            message = nil
            app.setShortcut(nil, for: action)
            stop()
        } else {
            let shortcut = Shortcut(keyCode: event.keyCode, modifiers: modifiers)
            if let conflict = app.shortcuts.conflict(shortcut, for: action) {
                // Keep listening, so the next attempt needs no extra click.
                message = conflict
            } else {
                message = nil
                app.setShortcut(shortcut, for: action)
                stop()
            }
        }
    }

    /// Ends this row's recording and, if it still owns recording, turns the shortcuts back on.
    private func stop() {
        release()
        if app.shortcuts.recordingAction == action { app.shortcuts.recordingAction = nil }
    }

    /// Stops listening and clears a conflict message, which describes an attempt that no longer applies.
    private func release() {
        message = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
    }
}

struct DesktopPetSettingsView: View {
    @Bindable var app: AppModel

    var body: some View {
        Form {
            Section("Desktop Mochi") {
                Toggle("Show Mochi on the desktop", isOn: $app.petVisible)
                    .accessibilityIdentifier("desktop-pet-toggle")
                Toggle("Eyes follow the pointer", isOn: Bindable(app.settings).petFollowsPointer)
                    .disabled(!app.petVisible)
                Toggle("Show the message bar under Mochi", isOn: $app.petBarVisible)
                    .accessibilityIdentifier("desktop-pet-bar-toggle")
                    .disabled(!app.petVisible)
                Text(
                    "Mochi follows the conversation: she listens while you record, thinks while a reply is prepared, and talks while it plays. Click her to start or finish a voice message, drag her to move her, and Control-click her for more. The message bar under her types or talks to the open conversation."
                ).font(.callout).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
}

/// The shortcuts that work in every app, whether or not Mochi is on the desktop.
struct KeyboardShortcutsSection: View {
    @Bindable var app: AppModel

    var body: some View {
        Section("Keyboard Shortcuts") {
            ForEach(ShortcutAction.allCases) { action in ShortcutRecorder(action: action, app: app) }
            Button("Reset to Defaults") {
                for action in ShortcutAction.allCases { app.setShortcut(action.defaultShortcut, for: action) }
            }.disabled(app.settings.shortcuts == ShortcutAction.defaults)
            Text(
                "These shortcuts work in every app, except Send Now, which works while Mochi is in front. Press Talk to Mochi once to start a voice message and again to send it, or hold it down while you speak and let go to send. Hands-free, Talk to Mochi starts listening."
            ).font(.callout).foregroundStyle(.secondary)
            if !app.shortcuts.enabled {
                Text("Shortcuts are saved but stay off in the preview.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
