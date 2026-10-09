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
                BuiltInVoicePicker(title:"Example voice",selection:$app.builtInPracticeVoice,app:app,options:app.practiceVoiceOptions)
                OpenAIVoiceOptionsView(options:$app.practiceVoiceOptions).disabled(app.busy)
                Text("New examples use your Codex sign-in. Saved recordings keep their original voice.").font(.caption).foregroundStyle(.secondary)
            }
            if let error = app.error { Text(error).font(.callout).foregroundStyle(.red) }
            if app.turn.activity != .idle { Button("Stop Preview",action:app.stop) }
        }.formStyle(.grouped)
    }
}
