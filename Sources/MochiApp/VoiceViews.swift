import MochiCore
import MochiKernel
import MochiProviders
import SwiftUI

struct BuiltInVoicePicker: View {
    let title: LocalizedStringKey
    @Binding var selection: String
    @Bindable var app: AppModel
    var options: OpenAIVoiceOptions? = nil
    var body: some View {
        HStack {
            Picker(title, selection: $selection) {
                ForEach(RealtimeVoice.allCases) { voice in Text(voice.name).tag(voice.rawValue) }
            }
            Button {
                app.previewBuiltIn(selection, options: options)
            } label: {
                Label("Preview", systemImage: "play.fill")
            }
        }.disabled(app.busy)
    }
}
struct PracticeVoiceControls: View {
    @Bindable var app: AppModel
    var body: some View {
        BuiltInVoicePicker(
            title: "Example voice", selection: Bindable(app.settings).builtInPracticeVoice, app: app,
            options: app.settings.practiceVoiceOptions)
        OpenAIVoiceOptionsView(options: Bindable(app.settings).practiceVoiceOptions)
    }
}
/// Optional: practice examples in the learner's own voice, converted by ElevenLabs. Off unless turned on.
struct PracticeTimbreControls: View {
    @Bindable var settings: PreferencesStore
    @State private var keyDraft = ""
    @State private var keySaved = ElevenLabsCredential.isSaved
    @State private var keyMessage: String?

    var body: some View {
        Toggle("Speak examples in my voice (ElevenLabs)", isOn: $settings.practiceTimbreEnabled)
        if settings.practiceTimbreEnabled {
            TextField("Voice ID", text: $settings.practiceTimbreVoiceID)
            SecureField(
                keySaved ? "Key saved; enter a new one to replace it" : "ElevenLabs API key", text: $keyDraft)
            HStack {
                Button("Save Key", action: saveKey)
                    .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if keySaved { Button("Remove Key", role: .destructive, action: removeKey) }
            }
            if let keyMessage { Text(keyMessage).font(.callout).foregroundStyle(.red) }
            Text("Each example is converted by ElevenLabs. Only the example’s audio is sent.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func saveKey() {
        do {
            try ElevenLabsCredential.save(keyDraft)
            keyDraft = ""
            keySaved = true
            keyMessage = nil
        } catch {
            keyMessage = AppFailure.message(for: error, fallback: "Could not save the ElevenLabs key in Keychain.")
        }
    }

    private func removeKey() {
        do {
            try ElevenLabsCredential.delete()
            keySaved = false
            keyMessage = nil
        } catch {
            keyMessage = AppFailure.message(for: error, fallback: "Could not remove the ElevenLabs key from Keychain.")
        }
    }
}

struct VoiceSettingsView: View {
    @Bindable var app: AppModel
    var body: some View {
        Form {
            Section("Mochi’s Conversation Voice") {
                BuiltInVoicePicker(
                    title: "Voice", selection: Bindable(app.settings).conversationVoice, app: app,
                    options: app.settings.conversationVoiceOptions)
                OpenAIVoiceOptionsView(options: Bindable(app.settings).conversationVoiceOptions, expanded: app.demo)
                    .disabled(app.busy)
                Text("Voice changes apply to new replies.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Practice Examples") {
                PracticeVoiceControls(app: app).disabled(app.busy)
                Text("Saved recordings keep their original voice.").font(.caption).foregroundStyle(.secondary)
                PracticeTimbreControls(settings: app.settings).disabled(app.busy)
            }
            if let error = app.error, app.errorTab == .voices { Text(error).font(.callout).foregroundStyle(.red) }
            // Stop Preview ends only the preview's own turn; other activity keeps the main Stop.
            if app.previewActive { Button("Stop Preview") { app.stopPreview() } }
        }.formStyle(.grouped)
    }
}
