import SwiftUI
import AppKit
import MochiCore

struct BuiltInVoicePicker: View {
    let title: String
    @Binding var selection: String
    @ObservedObject var app: AppModel
    var options: OpenAIVoiceOptions? = nil
    var body: some View {
        HStack {
            Picker(title,selection:$selection) {
                ForEach(RealtimeVoice.allCases) { voice in Text(voice.name).tag(voice.rawValue) }
            }
            Button { app.previewBuiltIn(selection,options:options) } label: { Label("Preview",systemImage:"play.fill") }.disabled(app.busy)
        }.disabled(app.busy)
    }
}
struct PracticeVoiceControls: View {
    @ObservedObject var app: AppModel
    var body: some View {
        Picker("Provider",selection:$app.practiceProvider) {
            ForEach(PracticeProvider.allCases) { Text($0.name).tag($0) }
        }
        if app.practiceProvider == .codex {
            BuiltInVoicePicker(title:"Example voice",selection:$app.builtInPracticeVoice,app:app,options:app.practiceVoiceOptions)
            OpenAIVoiceOptionsView(options:$app.practiceVoiceOptions)
        } else {
            TextField("Voice ID",text:$app.elevenLabsOptions.voiceID)
            TextField("Voice name",text:$app.elevenLabsOptions.voiceName)
            Picker("Model",selection:$app.elevenLabsOptions.model) {
                Text("Multilingual v2").tag("eleven_multilingual_v2")
                Text("Flash v2.5").tag("eleven_flash_v2_5")
            }
            HStack {
                Text("Speed")
                Slider(value:$app.elevenLabsOptions.speed,in:0.7...1.2,step:0.01)
                Text(app.elevenLabsOptions.speed,format:.number.precision(.fractionLength(2))).monospacedDigit()
            }
            Button("Preview",systemImage:"play.fill",action:app.previewElevenLabs)
            Text("Use a voice ID from your ElevenLabs account, including a cloned voice. New examples and first previews use paid credits; replay uses saved audio.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
struct ElevenLabsConnection: View {
    @ObservedObject var app: AppModel
    @State private var key = ""
    @State private var status: String?
    var body: some View {
        SecureField("ElevenLabs API key",text:$key)
        Button("Save Key in Keychain") {
            do { try ElevenLabsCredential.save(key); key = ""; status = "Key saved. Preview a voice to check the connection." }
            catch { status = "Could not save the key. Enter a valid key and try again." }
        }.disabled(key.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || app.busy)
        if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
        Text("A previously saved key is reused when generating an example. Conversation and transcription continue to use Codex.").font(.caption).foregroundStyle(.secondary)
    }
}
struct VoiceSettingsView: View {
    @ObservedObject var app: AppModel
    var body: some View {
        Form {
            Section("Mochi’s Conversation Voice") {
                BuiltInVoicePicker(title:"Voice",selection:$app.conversationVoice,app:app,options:app.conversationVoiceOptions)
                OpenAIVoiceOptionsView(options:$app.conversationVoiceOptions,expanded:app.demo).disabled(app.busy)
                Text("Voice changes apply to new replies.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Practice Examples") {
                PracticeVoiceControls(app:app).disabled(app.busy)
                Text("Saved recordings keep their original voice.").font(.caption).foregroundStyle(.secondary)
            }
            if app.practiceProvider == .elevenLabs {
                Section("ElevenLabs Connection") { ElevenLabsConnection(app:app) }
            }
            if let error = app.error { Text(error).font(.callout).foregroundStyle(.red) }
            if app.turn.activity != .idle { Button("Stop Preview",action:app.stop) }
        }.formStyle(.grouped)
    }
}
