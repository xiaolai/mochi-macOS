import SwiftUI
import AppKit
import MochiCore

struct VoiceTranscriptControls: View {
    @ObservedObject var app: AppModel
    let message: Message
    @State private var editing = false
    @State private var text = ""
    private var recovering: Bool { app.transcribingMessageIDs.contains(message.id) }
    var body: some View {
        Menu {
            Button("Copy transcript") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message.contextText ?? "",forType:.string)
            }.disabled(message.contextText == nil)
            if app.writableConversation {
                Button(message.contextText == nil ? "Add transcript…" : "Edit transcript…") {
                    text = message.contextText ?? ""; editing = true
                }.disabled(app.busy)
                if recovering {
                    Button("Cancel transcription") { app.cancelTranscription(message.id) }.disabled(app.busy)
                } else {
                    Button("Retry transcription") { app.retryTranscription(message.id) }.disabled(app.busy)
                }
            }
            Divider()
            if let name = message.audio {
                Button("Show recording in Finder") { NSWorkspace.shared.activateFileViewerSelecting([app.store.root.appendingPathComponent(name)]) }
            }
        } label: {
            if recovering { ProgressView().controlSize(.mini) }
            else { Image(systemName:message.contextText == nil ? "exclamationmark.bubble" : "ellipsis").frame(width:20,height:26) }
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel(recovering ? "Transcription in progress; message actions" : "Voice message actions")
        .help(recovering ? "Transcribing…" : message.contextText == nil ? "Transcript unavailable — retry or add text" : "Message actions")
        .sheet(isPresented:$editing) {
            VStack(alignment:.leading,spacing:14) {
                Text("What did you say?").font(.title2).fontWeight(.semibold)
                Text("Correct the transcript without sending another message to Mochi.").foregroundStyle(.secondary)
                TextEditor(text:$text).font(.body).frame(height:120)
                    .padding(8).overlay(RoundedRectangle(cornerRadius:8).stroke(.quaternary))
                    .accessibilityLabel("Voice message transcript")
                HStack {
                    Button("Cancel") { editing = false }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Save transcript") { app.editTranscript(message.id,text:text); editing = false }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                        .disabled(text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                }
            }.padding(24).frame(width:460)
        }
    }
}
