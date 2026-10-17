import SwiftUI

struct AutomationSettingsView: View {
    @Bindable var app: AppModel
    /// The last copy's outcome, shown on the button briefly; nil shows the copy action.
    @State private var copied: Bool?
    var body: some View {
        Form {
            Section("External Assistants") {
                Toggle("Allow external assistants to control Mochi", isOn: $app.externalControlEnabled)
                LabeledContent("Status", value: app.automation.status)
                Text(
                    "A connected assistant can read your active conversations, saved expressions, templates and characters. It can create, open, rename, archive and set up conversations; save expressions, prepare one in Help Me Say This and open practice; create, edit and delete templates, which go to Recently Deleted in Manage Templates for you to recover; and control playback. Its changes are refused while you record, Mochi replies, or an editing, template or practice panel is open. Recording always starts with you. The connection stays on this Mac and is available only to your macOS user."
                )
                .font(.callout).foregroundStyle(.secondary)
            }
            Section("Connect with MCP") {
                Text(
                    "Keep Mochi running, enable external control, then add this configuration to your assistant’s MCP settings."
                )
                .font(.callout).foregroundStyle(.secondary)
                if !AutomationController.helperAvailable {
                    Text(
                        "Build Mochi’s bundled helper, or move Mochi to Applications and reopen it before copying the configuration."
                    ).foregroundStyle(.secondary)
                }
                Text(AutomationController.clientConfiguration(socketPath: app.controlSocketPath)).font(
                    .system(.caption, design: .monospaced)
                )
                .textSelection(.enabled).lineLimit(nil)
                Button(copyLabel) {
                    NSPasteboard.general.clearContents()
                    copied = NSPasteboard.general.setString(
                        AutomationController.clientConfiguration(socketPath: app.controlSocketPath), forType: .string)
                }.disabled(!AutomationController.helperAvailable)
                    .task(id: copied) {
                        guard copied != nil else { return }
                        try? await Task.sleep(for: .seconds(2))
                        if !Task.isCancelled { copied = nil }
                    }
            }
            Section("Mochi’s Voice Commands") {
                Text(
                    "Try “save that expression” or “let’s practise that phrase.” Mochi can use learning tools within your current conversation. Your microphone remains under your control."
                )
                .font(.callout).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
    private var copyLabel: LocalizedStringKey {
        switch copied {
        case true?: "Configuration Copied"
        case false?: "Could Not Copy Configuration"
        case nil: "Copy MCP Configuration"
        }
    }
}
