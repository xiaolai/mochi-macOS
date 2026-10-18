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
    /// The learner's own voices when there are several to choose from; empty once one is chosen or none is found.
    @State private var ownVoices: [OwnedVoice] = []

    var body: some View {
        Group {
            // The fields stay visible while the switch is off, so the place to paste the key is never hidden. Mochi
            // keeps the key in the Keychain itself; the learner never has to open Keychain Access.
            Toggle("Speak examples in my voice (ElevenLabs)", isOn: $settings.practiceTimbreEnabled)
            TextField("Voice ID", text: $settings.practiceTimbreVoiceID)
            SecureField(
                keySaved ? "Key saved; enter a new one to replace it" : "ElevenLabs API key", text: $keyDraft)
            HStack {
                Button("Save Key") { Task { await saveKey() } }
                    .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if keySaved {
                    Button("Find My Voice") { Task { await lookUp(automatic: false) } }
                    Button("Remove Key", role: .destructive, action: removeKey)
                }
            }
            if ownVoices.count > 1 {
                Picker("Your voice", selection: $settings.practiceTimbreVoiceID) {
                    ForEach(ownVoices, id: \.voiceID) { voice in Text(voice.name).tag(voice.voiceID) }
                }
            }
            if let keyMessage { Text(keyMessage).font(.callout).foregroundStyle(.red) }
            Text("Each example is converted by ElevenLabs. Only the example’s audio is sent.")
                .font(.caption).foregroundStyle(.secondary)
        }
        // Opening Settings with a key saved finds the learner's voice without a button press.
        .task { if keySaved { await lookUp(automatic: true) } }
    }

    private func saveKey() async {
        do {
            try ElevenLabsCredential.save(keyDraft)
            keyDraft = ""
            keySaved = true
            keyMessage = nil
            await lookUp(automatic: true)
        } catch {
            keyMessage = AppFailure.message(for: error, fallback: "Could not save the ElevenLabs key in Keychain.")
        }
    }

    private func removeKey() {
        do {
            try ElevenLabsCredential.delete()
            keySaved = false
            keyMessage = nil
            ownVoices = []
        } catch {
            keyMessage = AppFailure.message(for: error, fallback: "Could not remove the ElevenLabs key from Keychain.")
        }
    }

    /// Finds the learner's own voice with the saved key. One voice fills an empty voice ID; several are offered in a
    /// picker. An automatic lookup never replaces a voice ID already set; the Find My Voice button may.
    private func lookUp(automatic: Bool) async {
        do {
            let voices = try await OwnedVoiceList().fetch()
            switch VoiceChoice(voices) {
            case .none:
                ownVoices = []
                keyMessage = AppFailure(
                    "No voice of yours is on this ElevenLabs account. Clone your voice in ElevenLabs, then try again."
                ).message
            case .one(let voice):
                ownVoices = []
                if !automatic || settings.practiceTimbreVoiceID.isEmpty {
                    settings.practiceTimbreVoiceID = voice.voiceID
                }
                keyMessage = nil
            case .many(let list):
                ownVoices = list
                keyMessage = nil
            }
        } catch {
            keyMessage = AppFailure.message(for: error, fallback: "Could not look up your voice.")
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
