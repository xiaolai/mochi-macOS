import SwiftUI
import MochiCore

struct ConversationInstructionsView: View {
    @ObservedObject var app: AppModel
    let id: UUID
    @State private var saveError: String?
    @State private var instructions = ""
    @State private var preferences = ConversationPreferences()
    @State private var customSpeed = false
    @State private var speed = 1.0
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            Text("Conversation Instructions").font(.title2).fontWeight(.semibold)
            Text(app.library.conversations.first(where:{ $0.id == id })?.title ?? "")
                .foregroundStyle(.secondary).lineLimit(1)
            Text("Tell Mochi how you want to practise in this conversation. Leave this empty to use Mochi’s defaults.")
                .font(.callout).foregroundStyle(.secondary)
            TextEditor(text:$instructions).font(.body).padding(6)
                .background(Color(nsColor:.textBackgroundColor),in:RoundedRectangle(cornerRadius:8))
                .overlay(RoundedRectangle(cornerRadius:8).stroke(.quaternary))
                .frame(height:190).accessibilityLabel("Instructions for this conversation")
            HStack {
                Text("Applies to future replies in this conversation.")
                Spacer(); Text("\(instructions.count)/8,000")
            }.font(.caption).foregroundStyle(instructions.count > 8000 ? Color.red : Color.secondary)
            if instructions.count > MochiTools.maxInstructions {
                Text("This saved prompt is longer than 8,000 characters. Its full text is preserved; replies use the first 8,000. Shorten it to save changes.").font(.caption).foregroundStyle(.secondary)
            }
            Picker("Coaching",selection:$preferences.coaching) {
                Text("Natural conversation").tag(CoachingStyle.natural)
                Text("Occasional gentle corrections").tag(CoachingStyle.gentle)
                Text("Direct corrections").tag(CoachingStyle.direct)
            }
            Toggle("Use a speech speed for this conversation",isOn:$customSpeed)
            if customSpeed {
                HStack {
                    Slider(value:$speed,in:0.25...1.5,step:0.05).accessibilityLabel("Conversation speech speed")
                    Text(String(format:"%.2f×",speed)).monospacedDigit().frame(width:60)
                }
            }
            if let error = saveError { Text(error).font(.callout).foregroundStyle(.red) }
            HStack {
                Button("Reset to Defaults") { instructions = ""; preferences = ConversationPreferences(); customSpeed = false; speed = 1 }
                Spacer()
                Button("Cancel") { app.instructionsID = nil }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    preferences.speed = customSpeed ? speed : nil
                    let existingError = app.error
                    if app.setConversationInstructions(id,instructions:instructions,preferences:preferences) { app.instructionsID = nil }
                    else { saveError = app.error }
                    app.error = existingError
                }.keyboardShortcut(.defaultAction).disabled(instructions.count > 8000 || app.busy)
            }
        }.padding(24).frame(width:560)
            .onAppear {
                if let chat = app.library.conversations.first(where:{ $0.id == id }) {
                    instructions = chat.instructions; preferences = chat.preferences
                    customSpeed = preferences.speed != nil; speed = preferences.speed ?? app.conversationVoiceOptions.speed
                }
            }
    }
}
