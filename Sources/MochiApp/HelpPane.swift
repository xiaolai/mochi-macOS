import SwiftUI
import MochiCore

struct PracticePane: View {
    @ObservedObject var app: AppModel
    @State private var normalized = false
    @State private var directEnglish = ""
    @State private var voiceDetailsOpen = false
    @State private var pitchOpen = false
    @State private var smoothPitch = true
    @FocusState private var thoughtFocused: Bool
    var body: some View {
        VStack(spacing:0) {
            VStack(alignment:.leading,spacing:12) {
                HStack {
                    Text(app.helpStage == .practice ? "Practise Your Expression" : "Help Me Say This").font(.title2).fontWeight(.semibold)
                    Spacer()
                    Text("Conversation paused").font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing:14) {
                    stage("1  Your thought",active:app.helpStage == .thought)
                    Image(systemName:"chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    stage("2  Your English",active:app.helpStage == .english)
                    Image(systemName:"chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    stage("3  Optional practice",active:app.helpStage == .practice)
                }.font(.caption)
            }.padding(24)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment:.leading,spacing:16) {
                        if app.helpStage == .thought { meaningInput }
                        else {
                            thoughtSummary
                            if app.helpStage == .english { englishReview }
                            else { sentencePractice }
                        }
                    }.padding(.horizontal,24).padding(.bottom,16).frame(maxWidth:.infinity,alignment:.leading)
                }
                .onChange(of:app.recognizedThought) { _,text in
                    if text != nil { proxy.scrollTo("recognized-thought",anchor:.center) }
                }
                .onAppear { if app.recognizedThought != nil { proxy.scrollTo("recognized-thought",anchor:.center) } }
            }
            if app.busy {
                VStack(alignment:.leading,spacing:8) {
                    if app.turn.activity == .recording {
                        RecordingFeedback(app:app)
                    } else {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text(app.helpProgress ?? app.status).font(.callout)
                            Spacer()
                            Button("Cancel",action:app.cancelHelpWork)
                        }
                    }
                }.padding(.horizontal,24).padding(.vertical,12)
            }
            if let notice = app.notice {
                Text(notice).font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth:.infinity,alignment:.leading).padding(.horizontal,24).padding(.bottom,10)
            }
            if let error = app.error {
                Label(error,systemImage:"exclamationmark.circle").font(.callout).foregroundStyle(.red)
                    .frame(maxWidth:.infinity,alignment:.leading).padding(.horizontal,24).padding(.bottom,12)
            }
            Divider()
            VStack(spacing:8) {
                HStack {
                    if app.helpStage == .thought {
                        Button("Back to Conversation",action:app.resume).keyboardShortcut(.cancelAction)
                        Spacer()
                        Button("Find the English",action:app.translate).buttonStyle(.borderedProminent)
                            .keyboardShortcut(.return,modifiers:.command)
                            .disabled(app.busy || app.meaning.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                    } else if app.helpStage == .english {
                        Button("Return to Conversation",action:app.resume).keyboardShortcut(.cancelAction)
                        Spacer()
                        Button("Listen & Practise",action:app.beginPractice).buttonStyle(.borderedProminent)
                            .disabled(app.busy || app.english.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                    } else { PracticeActions(app:app) }
                }
                if !app.english.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
                    Text(app.thoughtRecording != nil && !app.isSavedPractice ? "Returning saves the expression and removes its thought recording. Practice is optional." : "Returning saves this expression to My Expressions. Practice is optional.")
                        .font(.caption).foregroundStyle(.secondary).frame(maxWidth:.infinity,alignment:.leading)
                }
            }.padding(20)
        }.background(Color(nsColor:.windowBackgroundColor))
        .onAppear { thoughtFocused = app.helpStage == .thought }
        .onChange(of:app.helpStage) { _,stage in thoughtFocused = stage == .thought }
    }
    private func stage(_ label: String,active: Bool) -> some View {
        Text(label).fontWeight(active ? .semibold : .regular).foregroundStyle(active ? Color.accentColor : .secondary)
            .accessibilityAddTraits(active ? [.isSelected] : [])
    }
    private var thoughtSummary: some View {
        VStack(alignment:.leading,spacing:6) {
            HStack {
                Text("What you meant").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Edit thought",action:app.editThought).buttonStyle(.link).disabled(app.busy)
            }
            Text(app.meaning.isEmpty ? "Your English sentence" : app.meaning).font(.callout).textSelection(.enabled)
                .frame(maxWidth:.infinity,alignment:.leading)
        }.padding(12).background(Color(nsColor:.controlBackgroundColor),in:RoundedRectangle(cornerRadius:10))
    }
    private var meaningInput: some View {
        VStack(alignment:.leading,spacing:12) {
            Text("What would you like to say?").font(.headline)
            Text("Type your thought in Chinese or English, or record it first.").font(.callout).foregroundStyle(.secondary)
            if let question = app.helpClarification {
                Label(question,systemImage:"questionmark.bubble").font(.callout).foregroundStyle(Color.accentColor)
            }
            TextField("Your thought",text:$app.meaning,axis:.vertical)
                .textFieldStyle(.roundedBorder).lineLimit(3...6).disabled(app.busy).focused($thoughtFocused)
            HStack {
                if !app.isSavedPractice {
                    Button(action:app.recordMeaning) {
                        Label(app.turn.activity == .recording ? "Finish & Review" : "Record Thought",systemImage:app.turn.activity == .recording ? "stop.fill" : "mic")
                    }.disabled(app.busy && app.turn.activity != .recording)
                }
                if !app.english.isEmpty { Button("Review English",action:app.reviewEnglish).disabled(app.busy) }
            }
            if let file = app.thoughtRecording {
                VStack(alignment:.leading,spacing:8) {
                    Text("Recorded thought · saved on this Mac").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button { app.play(file) } label: { Label("Listen",systemImage:"play.fill") }.disabled(app.busy)
                        Button("Transcribe",action:app.transcribeThought).disabled(app.busy)
                        Spacer()
                        Button("Discard recording",action:app.discardThoughtRecording).disabled(app.busy)
                    }
                    if let warning = app.recordingWarning { Label(warning,systemImage:"exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                    Text("Transcribe sends this recording to OpenAI. Check the words before finding the English.").font(.caption).foregroundStyle(.secondary)
                }.padding(12).background(Color(nsColor:.controlBackgroundColor),in:RoundedRectangle(cornerRadius:10))
            }
            if let recognized = app.recognizedThought {
                VStack(alignment:.leading,spacing:8) {
                    Text("Recognized words").font(.headline)
                    Text(recognized).textSelection(.enabled)
                    Text("Your typed thought is kept. Choose how to use these words.").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Add to thought") { app.useRecognizedThought(replace:false) }
                        Button("Replace thought") { app.useRecognizedThought(replace:true) }
                        Button("Keep typed thought") { app.recognizedThought = nil }
                    }.disabled(app.busy)
                }.padding(12).background(Color(nsColor:.controlBackgroundColor),in:RoundedRectangle(cornerRadius:10)).id("recognized-thought")
            }
            DisclosureGroup("I already have an English sentence") {
                HStack {
                    TextField("English sentence",text:$directEnglish).textFieldStyle(.roundedBorder).disabled(app.busy)
                    Button("Review") { app.editEnglish(directEnglish.trimmingCharacters(in:.whitespacesAndNewlines)) }
                        .disabled(app.busy || directEnglish.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                }.padding(.top,8)
            }.font(.callout)
        }
    }
    private var englishReview: some View {
        VStack(alignment:.leading,spacing:12) {
            Text("Does this say what you mean?").font(.headline)
            TextField("English expression",text:Binding(get:{app.english},set:app.editEnglish),axis:.vertical)
                .font(.system(size:22,weight:.medium)).textFieldStyle(.roundedBorder).lineLimit(3...6).disabled(app.busy)
            Text("Edit any words that change your meaning. You can return now or practise first.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Try another wording",action:app.tryAnotherWording).disabled(app.busy || app.meaning.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(app.english,forType:.string) } label: { Label("Copy",systemImage:"doc.on.doc") }
            }
        }
    }
    private var sentencePractice: some View {
        VStack(alignment:.leading,spacing:12) {
            TextField("English sentence",text:Binding(get:{app.english},set:app.editEnglish),axis:.vertical)
                .font(.system(size:22,weight:.medium)).textFieldStyle(.plain).lineLimit(2...4).disabled(app.busy)
            DisclosureGroup("Example voice: \(app.practiceVoiceLabel)",isExpanded:$voiceDetailsOpen) {
                VStack(alignment:.leading,spacing:10) {
                    PracticeVoiceControls(app:app).disabled(app.busy)
                    if app.practiceProvider == .elevenLabs {
                        Button("Connection Settings…") { app.settingsTab = "voices"; app.settingsOpen = true }
                    }
                }
            }
            if app.expression?.reference != nil {
                Text("Saved example: \(app.expression?.referenceKind ?? "Reference")").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button {
                    if let file = app.expression?.reference { app.play(file) } else { app.render() }
                } label: {
                    Label(app.expression?.reference == nil ? "Create Example" : "Play Example",systemImage:app.expression?.reference == nil ? "waveform" : "play.fill")
                }.disabled(app.busy)
                Picker("Speed",selection:$app.slow) {
                    Text("1×").tag(false)
                    Text("0.8×").tag(true)
                }.pickerStyle(.segmented).labelsHidden().frame(width:100).disabled(app.busy).help("Playback speed")
                Spacer()
                Menu {
                    Button("Import Reference…",action:app.importReference)
                    if app.expression?.reference != nil { Button("Regenerate Example") { app.render(force:true) } }
                } label: { Label("Reference Options",systemImage:"ellipsis") }.menuStyle(.borderlessButton).fixedSize().disabled(app.busy)
            }
            DisclosureGroup("Compare pitch · unscored",isExpanded:$pitchOpen) {
            GroupBox {
                VStack(alignment:.leading,spacing:10) {
                    HStack(spacing:14) {
                        Label("Reference",systemImage:"minus").foregroundStyle(Color.accentColor)
                        Label("Your attempt",systemImage:"minus").foregroundStyle(.orange)
                        Spacer()
                        Text(app.demo ? "Illustrative preview" : "Unscored").foregroundStyle(.secondary)
                    }.font(.caption)
                    if !app.referencePitch.isEmpty || !app.attemptPitch.isEmpty {
                        PitchChart(reference:app.referencePitch,attempt:app.attemptPitch,normalized:normalized,smoothed:smoothPitch).frame(height:150)
                    } else {
                        Text("Add a reference and record an attempt to compare pitch.")
                            .foregroundStyle(.secondary).frame(maxWidth:.infinity,minHeight:85)
                    }
                    HStack {
                        Text("Semitones · seconds").foregroundStyle(.secondary)
                        Spacer()
                        Toggle("Smooth curves",isOn:$smoothPitch).toggleStyle(.checkbox)
                            .help("Light display smoothing; turn off to inspect original pitch samples")
                        Toggle("Center each voice",isOn:$normalized).toggleStyle(.checkbox)
                    }.font(.caption)
                }.padding(6)
            }
            Text("Contours are not word-aligned. Gaps represent unvoiced sound.")
                .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct RecordingFeedback: View {
    @ObservedObject var app: AppModel
    var body: some View {
        VStack(alignment:.leading,spacing:6) {
            HStack {
                Image(systemName:"record.circle.fill").foregroundStyle(.red)
                Text("Recording · \(app.recordingSeconds)s / 60s").monospacedDigit()
                ProgressView(value:Double(max(0,min(1,(app.recordingLevel+60)/60))))
                    .frame(width:100).accessibilityLabel("Microphone input level")
                Spacer()
                Button("Cancel",action:app.cancelRecording)
            }.font(.callout)
            if let warning = app.recordingWarning { Text(warning).font(.caption).foregroundStyle(.orange) }
        }
    }
}
