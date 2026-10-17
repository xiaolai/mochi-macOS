import AppKit
import MochiCore
import SwiftUI

struct VoiceTranscriptControls: View {
    @Bindable var app: AppModel
    let message: Message
    @State private var text = ""
    @State private var saveError: String?
    @FocusState private var editorFocused: Bool
    @FocusState private var menuFocused: Bool
    private var recovering: Bool { app.transcribingMessageIDs.contains(message.id) }
    var body: some View {
        Menu {
            Button("Copy transcript") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message.contextText ?? "", forType: .string)
            }.disabled(message.contextText == nil)
            if app.writableConversation {
                Button(message.contextText == nil ? "Add transcript…" : "Edit transcript…") {
                    text = message.contextText ?? ""
                    saveError = nil
                    app.transcriptEditID = message.id
                }.disabled(app.busy)
                if recovering {
                    Button("Cancel transcription") { app.cancelTranscription(message.id) }.disabled(app.busy)
                } else {
                    Button("Retry transcription") { app.retryTranscription(message.id) }.disabled(app.busy)
                }
            }
            Divider()
            SharedMessageActions(app: app, message: message)
        } label: {
            if recovering {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: message.contextText == nil ? "exclamationmark.bubble" : "ellipsis").frame(
                    width: 20, height: 26)
            }
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .focused($menuFocused)
        .focusEffectDisabled()
        .overlay {
            RoundedRectangle(cornerRadius: 6).strokeBorder(Color.white, lineWidth: 2).padding(-2)
                .opacity(menuFocused ? 1 : 0)
        }
        .accessibilityLabel(recovering ? "Transcription in progress; message actions" : "Voice message actions")
        .help(
            recovering
                ? "Transcribing…"
                : message.contextText == nil ? "Transcript unavailable — retry or add text" : "Message actions"
        )
        // The open sheet lives in the model, so hands-free listening pauses while the transcript is corrected.
        .sheet(
            isPresented: Binding(
                get: { app.transcriptEditID == message.id },
                set: { if !$0, app.transcriptEditID == message.id { app.transcriptEditID = nil } })
        ) {
            VStack(alignment: .leading, spacing: 14) {
                Text("What did you say?").font(.title2).fontWeight(.semibold)
                Text("Correct the transcript without sending another message to Mochi.").foregroundStyle(.secondary)
                TextEditor(text: $text).font(.body).padding(6).frame(height: 120).focused($editorFocused)
                    .fieldFrame(cornerRadius: 8, focused: editorFocused)
                    .accessibilityLabel("Voice message transcript")
                if let error = saveError {
                    Label(error, systemImage: "exclamationmark.triangle.fill").font(.callout)
                        .foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button("Cancel") { app.transcriptEditID = nil }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Save transcript") {
                        if app.editTranscript(message.id, text: text) {
                            app.transcriptEditID = nil
                        } else {
                            saveError = app.error ?? String(localized: "The transcript could not be saved.")
                        }
                    }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(24).frame(width: 460)
        }
    }
}

/// Recording and deletion actions shared by a message's context menu and its voice-message menu.
struct SharedMessageActions: View {
    @Bindable var app: AppModel
    let message: Message
    var body: some View {
        if let name = message.audio {
            Button("Show Recording in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([app.store.root.appendingPathComponent(name)])
            }
        }
        if app.writableConversation {
            Divider()
            Button(role: .destructive) {
                app.deleteMessage(message.id)
            } label: {
                Label("Delete Message", systemImage: "trash")
            }.disabled(!app.canDeleteMessages)
        }
    }
}
