import MochiCore
import SwiftUI

struct PracticePane: View {
    @Bindable var app: AppModel
    @State private var normalized = false
    @State private var directEnglish = ""
    @State private var voiceDetailsOpen = false
    @State private var pitchOpen = false
    @State private var smoothPitch = true
    @FocusState private var thoughtFocused: Bool
    @State private var refocusThought = false
    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if app.help.stage == .thought {
                            meaningInput
                        } else {
                            thoughtSummary
                            if app.help.stage == .english { englishReview } else { sentencePractice }
                        }
                    }.padding(.horizontal, 24).padding(.bottom, 16).frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: app.help.recognizedThought) { _, text in
                    if text != nil { proxy.scrollTo("recognized-thought", anchor: .center) }
                }
                .onAppear {
                    if app.help.recognizedThought != nil { proxy.scrollTo("recognized-thought", anchor: .center) }
                }
            }
            activityFeedback
            if let notice = app.notice {
                Text(notice).font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.bottom, 10)
            }
            if let error = app.error {
                Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.bottom, 12)
            }
            Divider()
            footer
        }.background(Color(nsColor: .windowBackgroundColor))
            .onAppear { thoughtFocused = app.help.stage == .thought }
            .onChange(of: app.help.stage) { _, stage in thoughtFocused = stage == .thought }
            .onChange(of: app.busy) { _, busy in
                if busy {
                    refocusThought = thoughtFocused
                } else if refocusThought, app.help.stage == .thought {
                    refocusThought = false
                    DispatchQueue.main.async { thoughtFocused = true }
                }
            }
    }
    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(app.help.stage == .practice ? "Practise Your Expression" : "Help Me Say This").font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                Text("Conversation paused").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 14) {
                stage("1  Your thought", active: app.help.stage == .thought)
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                stage("2  Your Words", active: app.help.stage == .english)
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                stage("3  Optional practice", active: app.help.stage == .practice)
            }.font(.caption)
        }.padding(24)
    }
    private var activityFeedback: some View {
        VStack(alignment: .leading, spacing: 8) {
            if app.busy {
                if app.turn.activity == .recording {
                    RecordingFeedback(app: app)
                } else {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(app.help.progress ?? app.status).font(.callout)
                        Spacer()
                        Button("Cancel", action: app.cancelHelpWork)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
        .padding(.horizontal, 24).padding(.vertical, 12)
    }
    private var footer: some View {
        VStack(spacing: 8) {
            HStack {
                if app.help.stage == .thought {
                    Button("Back to Conversation", action: app.resume).keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Find the Words", action: app.translate).buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(app.busy || app.help.meaning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } else if app.help.stage == .english {
                    Button("Return to Conversation", action: app.resume).keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Listen & Practise", action: app.beginPractice).buttonStyle(.borderedProminent)
                        .disabled(app.busy || app.help.english.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } else {
                    PracticeActions(app: app)
                }
            }
            if !app.help.english.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(
                    app.help.thoughtRecording != nil && !app.help.isSavedPractice
                        ? "Returning saves the expression and removes its thought recording. Practice is optional."
                        : "Returning saves this expression to My Expressions. Practice is optional."
                )
                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(20)
    }
    private func englishEditor(_ placeholder: LocalizedStringKey, lines: ClosedRange<Int>) -> some View {
        TextField(placeholder, text: Binding(get: { app.help.english }, set: app.editEnglish), axis: .vertical)
            .font(.system(size: 18, weight: .medium)).textFieldStyle(.roundedBorder).lineLimit(lines).disabled(app.busy)
    }
    /// Reference kinds are stored in English; the ones Mochi writes are translated for display.
    static func referenceKindLabel(_ kind: String?) -> String {
        let codexVoice = " · Codex voice"
        switch kind {
        case nil: return String(localized: "Reference")
        case "Your voice": return String(localized: "Your voice")
        case "Imported reference": return String(localized: "Imported reference")
        case "Preview · illustrative contours": return String(localized: "Preview · illustrative contours")
        case let kind? where kind.hasSuffix(codexVoice):
            let voice = String(kind.dropLast(codexVoice.count))
            return String(localized: "\(voice) · Codex voice")
        case let kind?: return kind
        }
    }
    private func stage(_ label: LocalizedStringKey, active: Bool) -> some View {
        Text(label).fontWeight(active ? .semibold : .regular).foregroundStyle(active ? Color.accentColor : .secondary)
            .accessibilityAddTraits(active ? [.isSelected] : [])
    }
    private var thoughtSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("What you meant").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Edit thought", action: app.editThought).buttonStyle(.link).disabled(app.busy)
            }
            Text(app.help.meaning.isEmpty ? String(localized: "Your sentence") : app.help.meaning).font(
                .callout
            )
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }.padding(12).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }
    private var meaningInput: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What would you like to say?").font(.headline)
            Text("Type your thought in any language, or record it first.").font(.callout)
                .foregroundStyle(
                    .secondary)
            if let question = app.help.clarification {
                Label(question, systemImage: "questionmark.bubble").font(.callout).foregroundStyle(Color.accentColor)
            }
            TextField("Your thought", text: Bindable(app.help).meaning, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(3...6).disabled(app.busy).focused($thoughtFocused)
            HStack {
                if !app.help.isSavedPractice {
                    Button(action: app.recordMeaning) {
                        Label(
                            app.turn.activity == .recording ? "Finish & Review" : "Record Thought",
                            systemImage: app.turn.activity == .recording ? "stop.fill" : "mic")
                    }.disabled(app.busy && app.turn.activity != .recording)
                }
                if !app.help.english.isEmpty {
                    Button("Review the Words", action: app.reviewEnglish).disabled(app.busy)
                }
            }
            if let file = app.help.thoughtRecording {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Recorded thought · saved on this Mac").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button {
                            app.play(file)
                        } label: {
                            Label("Listen", systemImage: "play.fill")
                        }.disabled(app.busy)
                        Button("Transcribe", action: app.transcribeThought).disabled(app.busy)
                        Spacer()
                        Button("Discard recording", action: app.discardThoughtRecording).disabled(app.busy)
                    }
                    if let warning = app.recordingWarning {
                        Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                    }
                    Text(
                        "Transcribe sends this recording to OpenAI. Check the words before finding the right ones to say."
                    ).font(
                        .caption
                    ).foregroundStyle(.secondary)
                }.padding(12).background(
                    Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            }
            if let recognized = app.help.recognizedThought {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Recognized words").font(.headline)
                    Text(recognized).textSelection(.enabled)
                    Text("Your typed thought is kept. Choose how to use these words.").font(.caption).foregroundStyle(
                        .secondary)
                    HStack {
                        Button("Add to thought") { app.useRecognizedThought(replace: false) }
                        Button("Replace thought") { app.useRecognizedThought(replace: true) }
                        Button("Keep typed thought") { app.help.recognizedThought = nil }
                    }.disabled(app.busy)
                }.padding(12).background(
                    Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10)
                ).id("recognized-thought")
            }
            DisclosureGroup("I already have a sentence in \(app.languageName)") {
                HStack {
                    TextField("Sentence in \(app.languageName)", text: $directEnglish).textFieldStyle(.roundedBorder)
                        .disabled(
                            app.busy)
                    Button("Review") { app.editEnglish(directEnglish.trimmingCharacters(in: .whitespacesAndNewlines)) }
                        .disabled(app.busy || directEnglish.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }.padding(.top, 8)
            }.font(.callout)
        }
    }
    private var englishReview: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Does this say what you mean?").font(.headline)
            englishEditor("Expression in \(app.languageName)", lines: 3...6)
            Text("Edit any words that change your meaning. You can return now or practise first.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Try another wording", action: app.tryAnotherWording).disabled(
                    app.busy || app.help.meaning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(app.help.english, forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
            }
        }
    }
    private var sentencePractice: some View {
        VStack(alignment: .leading, spacing: 12) {
            englishEditor("Sentence in \(app.languageName)", lines: 2...4)
            DisclosureGroup("Example voice: \(app.settings.practiceVoiceLabel)", isExpanded: $voiceDetailsOpen) {
                VStack(alignment: .leading, spacing: 10) {
                    PracticeVoiceControls(app: app).disabled(app.busy)
                }
            }
            if app.help.expression?.reference != nil {
                Text("Saved example: \(Self.referenceKindLabel(app.help.expression?.referenceKind))").font(.caption)
                    .foregroundStyle(
                        .secondary)
            }
            HStack {
                Button {
                    if let file = app.help.expression?.reference { app.play(file) } else { app.render() }
                } label: {
                    Label(
                        app.help.expression?.reference == nil ? "Create Example" : "Play Example",
                        systemImage: app.help.expression?.reference == nil ? "waveform" : "play.fill")
                }.disabled(app.busy)
                Picker("Speed", selection: $app.slow) {
                    Text("1×").tag(false)
                    Text("0.8×").tag(true)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 100).disabled(app.busy).help("Playback speed")
                Spacer()
                Menu {
                    Button("Import Reference…", action: app.importReference).disabled(!app.canImportReference)
                    if app.help.expression?.reference != nil {
                        Button("Regenerate Example") { app.render(force: true) }
                    }
                } label: {
                    Label("Reference Options", systemImage: "ellipsis")
                }.menuStyle(.borderlessButton).fixedSize().disabled(app.busy)
            }
            if app.help.attemptCheck != .none { AttemptCheckView(app: app) }
            DisclosureGroup("Compare pitch · unscored", isExpanded: $pitchOpen) {
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 14) {
                            Label("Reference", systemImage: "minus").foregroundStyle(Color.accentColor)
                            Label("Your attempt", systemImage: "minus").foregroundStyle(.orange)
                            Spacer()
                            Text(app.demo ? "Illustrative preview" : "Unscored").foregroundStyle(.secondary)
                        }.font(.caption)
                        if !app.help.referencePitch.isEmpty || !app.help.attemptPitch.isEmpty {
                            PitchChart(
                                reference: app.help.referencePitch, attempt: app.help.attemptPitch,
                                normalized: normalized,
                                smoothed: smoothPitch
                            ).frame(height: 150)
                        } else {
                            Text("Add a reference and record an attempt to compare pitch.")
                                .foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 85)
                        }
                        HStack {
                            Text("Semitones · seconds").foregroundStyle(.secondary)
                            Spacer()
                            Toggle("Smooth curves", isOn: $smoothPitch).toggleStyle(.checkbox)
                                .help("Light display smoothing; turn off to inspect original pitch samples")
                            Toggle("Center each voice", isOn: $normalized).toggleStyle(.checkbox)
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
    @Bindable var app: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "record.circle.fill").foregroundStyle(.red)
                Text("Recording · \(app.recordingSeconds)s / 60s").monospacedDigit()
                ProgressView(value: Double(max(0, min(1, (app.recordingLevel + 60) / 60))))
                    .frame(width: 100).accessibilityLabel("Microphone input level")
                Spacer()
                Button("Cancel", action: app.cancelRecording)
            }.font(.callout)
            // The line keeps its height while hidden, so the warning never pushes the layout around.
            Text(app.recordingWarning ?? " ").font(.caption).foregroundStyle(.orange).lineLimit(1)
                .opacity(app.recordingWarning == nil ? 0 : 1).accessibilityHidden(app.recordingWarning == nil)
        }
    }
}
