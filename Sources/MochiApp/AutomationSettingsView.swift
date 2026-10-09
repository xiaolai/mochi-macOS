import SwiftUI
import MochiCore

struct AutomationSettingsView: View {
    @ObservedObject var app: AppModel
    @State private var copied = false
    var body: some View {
        Form {
            Section("External Assistants") {
                Toggle("Allow external assistants to control Mochi",isOn:$app.externalControlEnabled)
                LabeledContent("Status",value:app.automationStatus)
                Text("A connected assistant can read active conversations, configure a conversation, save expressions, open practice, and control playback. Recording always starts with you. The connection stays on this Mac and is available only to your macOS user.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Connect with MCP") {
                Text("Keep Mochi running, enable external control, then add this configuration to your assistant’s MCP settings.")
                    .font(.callout).foregroundStyle(.secondary)
                if !app.mcpConfigurationAvailable { Text("Build Mochi’s bundled helper, or move Mochi to Applications and reopen it before copying the configuration.").foregroundStyle(.secondary) }
                Text(app.mcpConfiguration).font(.system(.caption,design:.monospaced))
                    .textSelection(.enabled).lineLimit(nil)
                Button(copied ? "Configuration Copied" : "Copy MCP Configuration") {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(app.mcpConfiguration,forType:.string); copied = true
                }.disabled(!app.mcpConfigurationAvailable)
            }
            Section("Mochi’s Voice Commands") {
                Text("Try “save that expression” or “let’s practise that phrase.” Mochi can use learning tools within your current conversation. Your microphone remains under your control.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
}
