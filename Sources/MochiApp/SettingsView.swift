import MochiCore
import MochiProviders
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
                TalkingSection(settings: app.settings)
                Section("Connection") {
                    LabeledContent(
                        "Sign-in", value: app.codex.signInProblem == nil ? "Codex" : String(localized: "Not signed in"))
                    if let problem = app.codex.signInProblem {
                        Text(problem).font(.callout).foregroundStyle(.red)
                    }
                    Text("Sign in through Codex on this Mac, then check the connection here.").font(.callout)
                        .foregroundStyle(.secondary)
                    TextModelPicker(app: app)
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
                        "Checking the connection sends a short text request. In press to send, recordings are sent only when you finish a voice message, choose Transcribe for a recorded thought, or choose to translate a recorded thought."
                    )
                    Text(
                        "Hands-free, audio stays on your Mac until it hears speech. From just before that until Mochi judges your turn has ended, pauses included, the audio is sent to OpenAI. Hands-free practice attempts are judged on your Mac and stay there."
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

/// The Codex model for text requests, from the list Codex keeps for this account.
struct TextModelPicker: View {
    @Bindable var app: AppModel

    var body: some View {
        let models = app.codex.models
        if models.isEmpty {
            if app.codex.signInProblem == nil {
                Text("Codex has not listed any models yet. Use Codex once, then reopen Settings.").font(.callout)
                    .foregroundStyle(.secondary)
            }
        } else {
            let lightest = CodexModel.resolve(selected: nil, in: models)
            Picker("Text model", selection: Bindable(app.settings).textModel) {
                Text("Automatic · \(lightest?.name ?? "")").tag("")
                ForEach(models) { Text($0.name).tag($0.slug) }
                if !app.settings.textModel.isEmpty && !models.contains(where: { $0.slug == app.settings.textModel }) {
                    Text("\(app.settings.textModel) (not available)").tag(app.settings.textModel)
                }
            }
            Text(
                "Used for Help Me Say This. Automatic picks the last model Codex lists, normally the lightest. If it fails, Mochi uses the voice model."
            ).font(.callout).foregroundStyle(.secondary)
            if let model = app.textModel, !model.efforts.isEmpty {
                let automatic = model.lightestEffort ?? ""
                Picker("Reasoning effort", selection: Bindable(app.settings).textEffort) {
                    Text("Automatic · \(automatic.capitalized)").tag("")
                    ForEach(model.efforts, id: \.self) { Text(verbatim: $0.capitalized).tag($0) }
                }
                Text("How much the model thinks before it answers. Lower is faster, and these requests need little.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

/// How the learner hands a spoken turn to Mochi.
struct TalkingSection: View {
    @Bindable var settings: PreferencesStore

    var body: some View {
        Section("Talking") {
            Picker("Talking mode", selection: $settings.talkingMode) {
                Text("Press to send").tag(TalkingMode.pressToSend)
                Text("Hands-free").tag(TalkingMode.handsFree)
            }
            if settings.talkingMode == .pressToSend {
                Toggle("Start listening after Mochi replies", isOn: $settings.listenAfterReply)
                Text("Press the microphone to start a voice message and press again to send it.").font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Picker("How long Mochi waits for you to finish", selection: $settings.listeningPatience) {
                    Text("Patient").tag(ListeningPatience.patient)
                    Text("Balanced").tag(ListeningPatience.balanced)
                    Text("Quick").tag(ListeningPatience.quick)
                }
                Picker("Stop listening after silence", selection: $settings.listeningSilenceLimit) {
                    ForEach(ListeningSilenceLimit.allCases, id: \.self) { limit in
                        Text("\(limit.rawValue) min").tag(limit)
                    }
                }
                Text(
                    "Mochi keeps listening, sends each turn when you finish, and stops speaking when you talk over her. Help Me Say This thoughts are still recorded with a press."
                ).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}
