import MochiCore
import SwiftUI

/// The Settings window's tabs, in the order they appear.
enum SettingsTab: Hashable { case general, voices, desktopMochi, automation, privacy, about }

struct SettingsView: View {
    @Bindable var app: AppModel

    var body: some View {
        TabView(selection: $app.settingsTab) {
            Form {
                Section("You") {
                    TextField("Your name", text: Bindable(app.settings).userName).textFieldStyle(.roundedBorder)
                    if app.settings.effectiveUserName == nil
                        && !app.settings.userName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    {
                        Text(
                            "Mochi can’t use this name. Use up to \(ConversationTemplate.nameLimit.characters) characters on one line."
                        ).font(.caption).foregroundStyle(.red)
                    }
                    Text("Mochi calls you by this name. Leave it empty and she won’t use one.").font(.callout)
                        .foregroundStyle(.secondary)
                }
                Section("New Conversations") {
                    LanguagePicker(selection: Bindable(app.settings).defaultLanguage)
                    Text("Existing conversations and templates keep their own language.").font(.callout)
                        .foregroundStyle(.secondary)
                }
                Section("Connection") {
                    LabeledContent("Sign-in", value: "Codex")
                    Text("Sign in through Codex on this Mac, then check the connection here.").font(.callout)
                        .foregroundStyle(.secondary)
                    TextField("Model", text: Bindable(app.settings).modelName).textFieldStyle(.roundedBorder).disabled(
                        app.busy
                    )
                    .onChange(of: app.settings.modelName) { app.serviceStatus = String(localized: "Not checked") }
                    LabeledContent("Status") { Text(app.serviceStatus).foregroundStyle(.secondary) }
                    Button("Check Connection", action: app.checkConnection).disabled(app.busy)
                }
                KeyboardShortcutsSection(app: app)
                feedback(.general)
            }.formStyle(.grouped)
                .tabItem { Label("General", systemImage: "gearshape") }.tag(SettingsTab.general)

            VoiceSettingsView(app: app)
                .tabItem { Label("Voices", systemImage: "waveform") }.tag(SettingsTab.voices)

            DesktopPetSettingsView(app: app)
                .tabItem { Label("Desktop Mochi", systemImage: "macwindow.on.rectangle") }.tag(SettingsTab.desktopMochi)

            AutomationSettingsView(app: app)
                .tabItem { Label("Automation", systemImage: "switch.2") }.tag(SettingsTab.automation)

            Form {
                Section("Storage") {
                    LabeledContent("Conversations and recordings", value: "On this Mac")
                    Button("Export Library Backup…", action: app.exportLibraryBackup).disabled(!canTransferLibrary)
                    Button("Import Library Backup…", action: app.importLibraryBackup).disabled(!canTransferLibrary)
                    Button("Show Data Folder…", action: app.revealDataFolder)
                    if app.canRestorePreviousLibrary {
                        Button("Restore Earlier Copy…", action: app.restorePreviousLibrary)
                        Text(
                            "Reinstates the library saved just before the unreadable one. The unreadable file is kept in the data folder."
                        ).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Privacy") {
                    Text(
                        "Conversation text, context, and voice messages go to OpenAI through your Codex sign-in. Example text is voiced by OpenAI through the same sign-in. Practice attempts, pitch analysis and word checks stay on your Mac."
                    )
                    Text(
                        "Checking the connection sends a short text request. Recordings are sent only when you finish a voice message, choose Transcribe for a recorded thought, or choose to translate a recorded thought."
                    )
                    Text(
                        "Library backups include conversations and practice audio, not sign-in credentials. Provider processing and retention follow your account settings."
                    ).foregroundStyle(.secondary)
                }
                feedback(.privacy)
                if let feedback = app.history.feedback { Text(feedback).font(.callout).foregroundStyle(.secondary) }
            }.formStyle(.grouped)
                .tabItem { Label("Data & Privacy", systemImage: "hand.raised") }.tag(SettingsTab.privacy)

            AboutSettingsView()
                .tabItem { Label("About", systemImage: "info.circle") }.tag(SettingsTab.about)
        }
        .padding(12)
        .frame(width: 620, height: 560)
    }

    private var canTransferLibrary: Bool { app.libraryReadable && app.libraryTransfer == nil }

    /// The error of an action started from this tab; errors from elsewhere belong to the window that caused them.
    @ViewBuilder private func feedback(_ tab: SettingsTab) -> some View {
        if let error = app.error, app.errorTab == tab { Text(error).font(.callout).foregroundStyle(.red) }
    }

}
