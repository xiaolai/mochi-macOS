import SwiftUI
import MochiCore

struct SettingsView: View {
    @ObservedObject var app: AppModel
    @State private var openAI = ""
    @State private var eleven = ""
    @State private var saved = ""

    var body: some View {
        TabView(selection:$app.settingsTab) {
            Form {
                Section("Connection") {
                    Picker("Sign-in",selection:$app.auth) {
                        Text("OpenAI API Key").tag("api")
                        Text("Codex Sign-in").tag("codex")
                    }.disabled(app.busy)
                    if app.auth == "api" {
                        SecureField("API key",text:$openAI,prompt:Text("Enter to replace saved key"))
                        Button("Save API Key") { saveKey(openAI,name:"OPENAI_API_KEY"); openAI = "" }.disabled(openAI.isEmpty)
                    }
                    TextField("Model",text:$app.modelName).disabled(app.busy)
                    LabeledContent("Status") { Text(app.serviceStatus).foregroundStyle(.secondary) }
                    Button("Check Connection",action:app.checkConnection).disabled(app.busy)
                }
                Section {
                    Text("Checking the connection sends a short text request. Recordings are sent only when you finish a voice message or choose to translate a recorded thought.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                feedback
            }.formStyle(.grouped)
                .tabItem { Label("Conversation",systemImage:"bubble.left.and.bubble.right") }.tag("conversation")

            VoiceSettingsView(app:app)
                .tabItem { Label("Voices",systemImage:"waveform") }.tag("voices")

            Form {
                Section("Storage") {
                    LabeledContent("Conversations and recordings",value:"On this Mac")
                    LabeledContent("API keys",value:"macOS Keychain")
                    Button("Export Library Backup…",action:app.exportLibraryBackup)
                    Button("Import Library Backup…",action:app.importLibraryBackup)
                    Button("Show Data Folder…") { NSWorkspace.shared.open(app.store.root) }
                }
                Section("Privacy") {
                    Text("Conversation text, context, and submitted voice messages go to OpenAI. Reference synthesis sends text and performer audio to ElevenLabs. Practice attempts and pitch analysis stay on your Mac.")
                    Text("Library backups contain practice audio, but not voice setup recordings or provider voice profiles. Provider processing and retention follow your account settings.").foregroundStyle(.secondary)
                }
                Section("Mochi") {
                    Text("Original character and artwork © Xiaolai. Used with permission.").foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
                .tabItem { Label("Data & Privacy",systemImage:"hand.raised") }.tag("privacy")
        }
        .safeAreaInset(edge:.bottom,spacing:0) {
            Text("Mochi \(Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "Development") (build \(Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "Development"))")
                .font(.caption).foregroundStyle(.secondary)
                .textSelection(.enabled).padding(.top,8)
        }
        .padding(12)
        .frame(width:620,height:560)
    }

    @ViewBuilder private var feedback: some View {
        if !saved.isEmpty { Text(saved).font(.callout).foregroundStyle(.secondary) }
        if let error = app.error { Text(error).font(.callout).foregroundStyle(.red) }
    }

    private func saveKey(_ value: String, name: String) {
        do {
            try Credentials.save(value.trimmingCharacters(in:.whitespacesAndNewlines),name:name)
            saved = "Saved to Keychain."
        } catch { saved = error.localizedDescription }
    }
}
