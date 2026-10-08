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
    @State private var eleven = ""
    @State private var feedback: String?
    @State private var setupOpen = false
    @State private var existing: VoiceProfile?
    @State private var deleting: VoiceProfile?
    var body: some View {
        Form {
            Section("Mochi’s Conversation Voice") {
                BuiltInVoicePicker(title:"Voice",selection:$app.conversationVoice,app:app,options:app.conversationVoiceOptions)
                OpenAIVoiceOptionsView(options:$app.conversationVoiceOptions,expanded:app.demo).disabled(app.busy)
                Text("Voice changes apply to new replies. Your conversation is preserved.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Practice Examples") {
                Picker("Read examples in",selection:$app.practiceVoiceMode) {
                    Text("Built-in Voice").tag(PracticeVoiceMode.builtIn)
                    Text("My Voice").tag(PracticeVoiceMode.personal)
                }.disabled(app.busy)
                if app.practiceVoiceMode == .builtIn {
                    BuiltInVoicePicker(title:"Example voice",selection:$app.builtInPracticeVoice,app:app,options:app.practiceVoiceOptions)
                    OpenAIVoiceOptionsView(options:$app.practiceVoiceOptions).disabled(app.busy)
                    Text("Ready to use with your OpenAI connection. No voice recording or ElevenLabs account needed.").font(.caption).foregroundStyle(.secondary)
                } else {
                    if let profile = app.selectedVoiceProfile {
                        LabeledContent("Voice",value:profile.name)
                        if profile.requiresVerification { Text("Verification required in ElevenLabs.").foregroundStyle(.orange) }
                    } else { Text("Set up your voice to create personal examples.").foregroundStyle(.secondary) }
                    Picker("Pronunciation target",selection:$app.performer) {
                        ForEach(PronunciationTarget.allCases) { target in Text(target.name).tag(target.rawValue) }
                    }.disabled(app.busy)
                }
                if app.practiceVoiceMode == .personal { PersonalVoiceOptionsView(options:$app.personalVoiceOptions,expanded:app.demo).disabled(app.busy) }
                Button("Set Up My Voice…") { existing = nil; setupOpen = true }.disabled(app.busy || !app.voiceProfilesReadable)
            }
            if !app.voiceProfiles.isEmpty {
                Section("My Voice Profiles") {
                    ForEach(app.voiceProfiles) { profile in
                        HStack {
                            VStack(alignment:.leading,spacing:3) {
                                Text(profile.name)
                                Text(profile.requiresVerification ? "Verification required" : (app.clone == profile.providerID ? "Selected" : "Available"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Manage…") { existing = profile; setupOpen = true }
                            Button(role:.destructive) { deleting = profile } label: { Image(systemName:"trash") }.help("Remove voice profile")
                        }.disabled(app.busy)
                    }
                }
            }
            Section("ElevenLabs Connection") {
                SecureField("API key",text:$eleven,prompt:Text("Enter to replace saved key"))
                Button("Save API Key") {
                    do { try Credentials.save(eleven,name:"ELEVENLABS_API_KEY"); eleven = ""; feedback = "ElevenLabs connection saved." }
                    catch { feedback = error.localizedDescription }
                }.disabled(eleven.isEmpty || app.busy)
                Text("Required only for your personal voice. Samples are uploaded only after your confirmation in setup.").font(.caption).foregroundStyle(.secondary)
            }
            if let feedback { Text(feedback).font(.callout).foregroundStyle(.secondary) }
            if let error = app.error { Text(error).font(.callout).foregroundStyle(.red) }
            if app.turn.activity != .idle { Button("Stop Preview",action:app.stop) }
        }.formStyle(.grouped)
        .sheet(isPresented:$setupOpen) { VoiceSetupView(app:app,existing:existing) }
        .sheet(item:$deleting) { profile in VoiceDeleteView(app:app,profile:profile) }
    }
}
struct VoiceSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: VoiceSetupModel
    @State private var removeSamplesOpen = false
    init(app: AppModel, existing: VoiceProfile? = nil) {
        let model = VoiceSetupModel(app:app)
        if let existing { model.profile = existing; model.name = existing.name; model.step = 1 }
        _model = StateObject(wrappedValue:model)
    }
    var body: some View {
        VStack(spacing:0) {
            HStack {
                VStack(alignment:.leading,spacing:5) {
                    Text("Set Up My Voice").font(.title2).fontWeight(.semibold)
                    Text(model.busy && !model.progress.isEmpty ? model.progress : ["1 · Your recordings","2 · Pronunciation","3 · Listen and choose"][model.step]).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
            }.padding(24)
            Divider()
            ScrollView {
                VStack(alignment:.leading,spacing:18) {
                    if model.step == 0 { recordings }
                    else if model.step == 1 { pronunciation }
                    else { comparison }
                    if let error = model.error { Label(error,systemImage:"exclamationmark.triangle").font(.callout).foregroundStyle(.red).textSelection(.enabled) }
                }.frame(maxWidth:.infinity,alignment:.leading).padding(24)
            }
            Divider()
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(model.busy)
                Spacer()
                if model.step == 0 {
                    Button("Continue") { model.audio.stop(); model.playing = false; model.step = 1 }
                        .disabled(model.busy || model.recording || model.totalDuration < 60).buttonStyle(.borderedProminent)
                } else if model.step == 1 {
                    Button("Back") { model.step = 0 }.disabled(model.busy || model.profile != nil)
                    Button(model.profile == nil ? "Create Voice & Preview" : "Generate Comparison",action:model.createAndCompare)
                        .disabled(model.busy || (model.profile == nil && !model.canCreate)).buttonStyle(.borderedProminent)
                } else {
                    Button("Change Pronunciation") { model.audio.stop(); model.playing = false; model.step = 1 }.disabled(model.busy)
                    Button("Use This Voice") { model.accept(); dismiss() }
                        .disabled(model.busy || !model.heardConverted || model.convertedAudio == nil || model.profile?.ready != true || model.name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || model.name.count > 80).buttonStyle(.borderedProminent)
                }
            }.padding(20)
        }.frame(width:620,height:570).background(Color(nsColor:.windowBackgroundColor))
        .sheet(isPresented:$removeSamplesOpen) {
            VStack(alignment:.leading,spacing:16) {
                Text("Remove Setup Recordings?").font(.title2).fontWeight(.semibold)
                Text("Only the recordings stored on this Mac will be removed. Your ElevenLabs clone and saved practice examples remain.")
                HStack {
                    Button("Cancel") { removeSamplesOpen = false }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Remove Recordings",role:.destructive) { model.removeLocalSamples(); removeSamplesOpen = false }
                }
            }.padding(24).frame(width:440)
        }
        .interactiveDismissDisabled(model.busy)
        .onAppear { model.begin(); if model.app.demo { previewStep(model.app.voiceSetupPreviewStep) } }
        .onChange(of:model.app.voiceSetupPreviewStep) { _,step in if model.app.demo { previewStep(step) } }
        .onDisappear { model.close() }
    }
    private func previewStep(_ step: Int) {
        model.step = step
        if step == 2 {
            model.profile = VoiceProfile(name:"My Voice",providerID:"illustrative",createdByApp:false)
            model.sourceAudio = model.app.store.root.appendingPathComponent("illustrative-source.wav")
            model.convertedAudio = model.app.store.root.appendingPathComponent("illustrative-converted.wav")
        }
    }
    private var recordings: some View {
        VStack(alignment:.leading,spacing:14) {
            Text("Speak naturally, in a language you’re comfortable with.").font(.headline)
            Text("Aim for 1–2 minutes of clear speech in a quiet room. Use your normal voice and a consistent microphone distance.").foregroundStyle(.secondary)
            HStack {
                Button(action:model.toggleRecording) { Label(model.recording ? "Finish Recording" : "Record My Voice",systemImage:model.recording ? "stop.fill" : "mic") }
                    .disabled(model.busy || model.playing || (model.totalDuration >= 180 && !model.recording))
                Button("Import Audio…",action:model.importSamples).disabled(model.busy || model.recording)
                Spacer()
                if model.recording { Text("\(model.seconds)s").monospacedDigit(); ProgressView(value:Double(max(0,min(1,(model.meter + 60) / 60)))).frame(width:80) }
            }
            Text("\(Int(model.totalDuration)) seconds added · 60–180 seconds total").font(.caption).foregroundStyle(.secondary)
            ForEach(model.samples) { sample in
                VStack(alignment:.leading,spacing:6) {
                    HStack {
                        VStack(alignment:.leading) { Text(sample.name).lineLimit(1); Text("\(Int(sample.quality.duration)) seconds").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Button { model.play(sample.url) } label: { Image(systemName:"play.fill") }.help("Play sample")
                        Button(role:.destructive) { model.removeSample(sample) } label: { Image(systemName:"trash") }.help("Remove sample")
                    }.disabled(model.recording || model.busy)
                    ForEach(sample.quality.warnings,id:\.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                }.padding(10).background(.quaternary,in:RoundedRectangle(cornerRadius:8))
            }
            if model.playing { Button("Stop Playback") { model.audio.stop(); model.playing = false } }
            Divider()
            Text("Already have an ElevenLabs clone?").font(.headline)
            Button("Load My Account Voices",action:model.loadAccountVoices).disabled(model.busy || model.recording)
            if !model.accountVoices.isEmpty {
                Picker("Existing voice",selection:$model.chosenAccountID) {
                    Text("Choose a voice").tag("")
                    ForEach(model.accountVoices) { voice in Text(voice.name).tag(voice.id) }
                }
                Button("Use This Existing Voice",action:model.chooseExisting).disabled(model.chosenAccountID.isEmpty || model.busy)
            }
        }
    }
    private var pronunciation: some View {
        VStack(alignment:.leading,spacing:16) {
            TextField("Profile name on this Mac",text:$model.name).textFieldStyle(.roundedBorder).disabled(model.busy)
            Text("Choose the pronunciation and rhythm you want to practise.").font(.headline)
            Picker("Pronunciation target",selection:$model.target) {
                ForEach(PronunciationTarget.allCases) { target in Text(target.name).tag(target.rawValue) }
            }.pickerStyle(.radioGroup).disabled(model.busy)
            PersonalVoiceOptionsView(options:$model.options).disabled(model.busy || model.playing)
            Button("Preview Pronunciation Target",action:model.previewTarget).disabled(model.busy)
            if model.playing { Button("Stop Playback") { model.audio.stop(); model.playing = false } }
            Text("We’ll compare this speaker’s example with the same sentence converted to your voice.").foregroundStyle(.secondary)
            if model.profile == nil {
                Toggle("These recordings are my own voice. I agree to upload them to ElevenLabs to create my voice clone.",isOn:$model.consent).disabled(model.busy)
                Text("Your clone remains in your ElevenLabs account. You can remove local samples and choose provider-side deletion separately.").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Using your existing voice profile; no recordings will be uploaded.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Save Profile Name",action:model.renameProfile).disabled(model.busy)
                    if !(model.profile?.samples.isEmpty ?? true) { Button("Remove Local Recordings…") { removeSamplesOpen = true }.disabled(model.busy) }
                }
                Button("Create a Replacement from New Recordings…") {
                    model.beginReplacement()
                }.disabled(model.busy)
                Text("A replacement creates a new profile. The previous clone is kept until you explicitly remove it.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var comparison: some View {
        VStack(alignment:.leading,spacing:16) {
            Text(ReferenceSpeech.preview).font(.title3).textSelection(.enabled)
            if model.profile?.requiresVerification == true {
                Text("Complete ElevenLabs verification before generating a comparison.")
                Link("Open ElevenLabs",destination:URL(string:"https://elevenlabs.io/app/voice-lab")!)
                Button("Check Verification",action:model.checkVerification).disabled(model.busy)
            }
            if let source = model.sourceAudio {
                Button { model.play(source) } label: { Label("Pronunciation Example · \(PronunciationTarget(rawValue:model.target)?.name ?? "Target")",systemImage:"play.fill") }.disabled(model.busy || model.app.demo)
            }
            if let converted = model.convertedAudio {
                Button { model.play(converted,converted:true) } label: { Label("In My Voice · \(model.name)",systemImage:"play.fill") }.disabled(model.busy || model.app.demo)
                Text(model.heardConverted ? "Does this sound like you? Use it, or try another pronunciation target." : "Listen to the full personal example before accepting it.").foregroundStyle(.secondary)
            }
            if model.playing { Button("Stop Playback") { model.audio.stop(); model.playing = false } }
            if !model.busy && model.convertedAudio == nil && model.profile?.ready == true { Button("Retry Comparison",action:model.createAndCompare) }
            Text(model.app.demo ? "Illustrative UI preview · no voice generated" : "Voice similarity is your judgment. This preview is not a quality score.").font(.caption).foregroundStyle(.secondary)
        }
    }
}
struct VoiceDeleteView: View {
    @ObservedObject var app: AppModel
    let profile: VoiceProfile
    @Environment(\.dismiss) private var dismiss
    @State private var remote = false
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            Text("Remove \(profile.name)?").font(.title2).fontWeight(.semibold)
            Text("This removes the profile and its setup recordings from this Mac. Saved practice examples and library backups remain.")
            if profile.canDeleteRemote { Toggle("Also delete this app-created clone from ElevenLabs",isOn:$remote) }
            else { Text("The existing clone in your ElevenLabs account will be kept.").foregroundStyle(.secondary) }
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Remove Voice",role:.destructive) {
                    busy = true
                    Task {
                        do {
                            if remote { try await ElevenLabsVoices().delete(id:profile.providerID) }
                            app.removeVoiceProfile(profile)
                            let dir = app.store.root.appendingPathComponent("VoiceProfiles/\(profile.id.uuidString)")
                            try? FileManager.default.removeItem(at:dir)
                            dismiss()
                        } catch { busy = false; self.error = error.localizedDescription }
                    }
                }.disabled(busy)
            }
        }.padding(24).frame(width:460).interactiveDismissDisabled(busy)
    }
}
