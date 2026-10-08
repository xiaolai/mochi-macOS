import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MochiCore

struct SetupSample: Identifiable {
    let id = UUID()
    let url: URL
    let name: String
    let quality: VoiceSampleQuality
}
@MainActor final class VoiceSetupModel: ObservableObject {
    @Published var step = 0
    @Published var name = "My Voice"
    @Published var target: String
    @Published var samples: [SetupSample] = []
    @Published var consent = false
    @Published var busy = false
    @Published var recording = false
    @Published var seconds = 0
    @Published var meter: Float = -80
    @Published var error: String?
    @Published var accountVoices: [AccountVoice] = []
    @Published var chosenAccountID = ""
    @Published var profile: VoiceProfile?
    @Published var sourceAudio: URL?
    @Published var convertedAudio: URL?
    @Published var playing = false
    @Published var heardConverted = false
    @Published var progress = ""
    let app: AppModel
    let audio = AudioController()
    private(set) var profileID = UUID()
    let api: any VoiceAccountAPI
    @Published var options: PersonalVoiceOptions
    let comparisonRenderer: (RenderIdentity, URL) async throws -> (URL,URL)
    private var task: Task<Void,Never>?
    private var clock: Task<Void,Never>?
    private var closed = false
    private var temporaryRecording: URL?
    var directory: URL { app.store.root.appendingPathComponent("VoiceProfiles/\(profileID.uuidString)",isDirectory:true) }
    var totalDuration: Double { samples.reduce(0) { $0 + $1.quality.duration } }
    var canCreate: Bool { consent && totalDuration >= 60 && totalDuration <= 180 && !name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && name.count <= 80 }
    init(app: AppModel, api: any VoiceAccountAPI = ElevenLabsVoices(), comparisonRenderer: @escaping (RenderIdentity, URL) async throws -> (URL,URL) = { identity,root in
        let renderer = VoiceRenderer()
        let source = try await renderer.pronunciation(identity,root:root)
        let converted = try await renderer.render(identity,root:root)
        return (source,converted)
    }) { self.app = app; self.api = api; self.comparisonRenderer = comparisonRenderer; target = app.performer; options = app.personalVoiceOptions }
    func begin() { app.stop(); app.voiceSetupActive = true }
    private func prepare() throws { try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]) }
    func importSamples() {
        guard !busy, !recording else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.wav,.mp3,.mpeg4Audio,.aiff,.audio]; panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { do { try addSample(url) } catch { self.error = error.localizedDescription } }
    }
    func addSample(_ url: URL) throws {
        guard samples.count < 10 else { throw AppFailure("Use at most ten samples.") }
        let values = try url.resourceValues(forKeys:[.fileSizeKey,.isRegularFileKey,.isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize, size <= 10_000_000 else { throw AppFailure("Choose a regular audio file smaller than 10 MB.") }
        let existingBytes = samples.reduce(0) { $0 + ((try? $1.url.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0) }
        guard existingBytes + size <= 30_000_000 else { throw AppFailure("Use at most 30 MB of samples in total.") }
        let (decoded,rate) = try AudioFile.samples(url,maxDuration:180)
        let quality = VoiceSampleQuality(samples:decoded,rate:rate)
        guard quality.audible else { throw AppFailure("This recording is silent or too quiet to use. Check your microphone and record again.") }
        guard quality.duration >= 3, totalDuration + quality.duration <= 180 else { throw AppFailure("Use clips of at least three seconds, with no more than three minutes in total.") }
        try prepare()
        let ext = url.pathExtension.lowercased()
        guard ["wav","mp3","m4a","aiff","aif","flac"].contains(ext) else { throw AppFailure("Use WAV, MP3, M4A, AIFF or FLAC samples.") }
        let copy = directory.appendingPathComponent("sample-\(UUID().uuidString).\(ext)")
        try FileManager.default.copyItem(at:url,to:copy)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:copy.path)
        samples.append(SetupSample(url:copy,name:url.lastPathComponent,quality:quality)); error = nil
    }
    func removeSample(_ sample: SetupSample) {
        guard !busy, !recording else { return }; audio.stop(); playing = false
        try? FileManager.default.removeItem(at:sample.url); samples.removeAll {$0.id == sample.id}
    }
    func toggleRecording() {
        if recording { finishRecording(); return }
        guard !busy, !playing, totalDuration < 180 else { return }
        busy = true; error = nil
        task = Task {
            guard await audio.permission(), !Task.isCancelled, !closed else { busy = false; error = "Microphone permission is required. You can also import a recording."; return }
            do {
                try prepare()
                let url = directory.appendingPathComponent("capture-\(UUID().uuidString).wav"); temporaryRecording = url
                let limit = min(120,Int(180 - totalDuration))
                try audio.record(to:url,maxDuration:Double(limit)); seconds = 0; recording = true; busy = false
                clock = Task {
                    while !Task.isCancelled && recording {
                        try? await Task.sleep(nanoseconds:250_000_000)
                        guard !Task.isCancelled else { return }
                        meter = audio.meter
                        seconds = Int(Date().timeIntervalSince(started))
                        if !audio.isRecording || seconds >= limit { finishRecording(); return }
                    }
                }
                started = Date()
            } catch { busy = false; self.error = error.localizedDescription }
        }
    }
    private var started = Date()
    func finishRecording() {
        clock?.cancel(); clock = nil
        guard recording else { return }; recording = false
        let url = audio.stopRecording() ?? temporaryRecording; temporaryRecording = nil
        guard let url else { return }
        defer { try? FileManager.default.removeItem(at:url) }
        do { try addSample(url) } catch { self.error = error.localizedDescription }
    }
    func play(_ url: URL, converted: Bool = false) {
        guard !busy, !recording else { return }
        audio.stop(); playing = true
        do { try audio.play(url:url,failed:{ [weak self] in self?.playing = false; self?.error = "This preview could not be played. Generate it again." }) { [weak self] in
            guard let self else { return }; self.playing = false
            if converted { self.heardConverted = true }
        } } catch { playing = false; self.error = error.localizedDescription }
    }
    func loadAccountVoices() {
        guard !busy, !recording else { return }; busy = true; error = nil
        task = Task {
            do { let values = try await api.list(); guard !closed else { return }; accountVoices = values; busy = false }
            catch { busy = false; self.error = error.localizedDescription }
        }
    }
    func chooseExisting() {
        guard !busy, let voice = accountVoices.first(where:{$0.id == chosenAccountID}) else { return }
        var item = app.voiceProfiles.first(where:{$0.providerID == voice.id}) ?? VoiceProfile(name:voice.name,providerID:voice.id,createdByApp:false)
        if voice.verificationKnown { item.requiresVerification = voice.requiresVerification }
        profile = item; name = item.name; step = 1
    }
    func createAndCompare() {
        guard !busy, !recording, app.voiceProfilesReadable, profile != nil || canCreate else { return }
        audio.stop(); playing = false; busy = true; error = nil; sourceAudio = nil; convertedAudio = nil; heardConverted = false
        let selectedTarget = target
        task = Task {
            do {
                try prepare()
                if profile == nil {
                    progress = "Uploading recordings and creating your voice…"
                    let uploads = try samples.map { sample -> VoiceUpload in
                        let mime: String
                        switch sample.url.pathExtension { case "mp3": mime = "audio/mpeg"; case "m4a": mime = "audio/mp4"; case "flac": mime = "audio/flac"; case "aiff","aif": mime = "audio/aiff"; default: mime = "audio/wav" }
                        return VoiceUpload(name:sample.name,mime:mime,data:try Data(contentsOf:sample.url))
                    }
                    let result = try await api.create(name:name,samples:uploads)
                    var created = VoiceProfile(id:profileID,name:name.trimmingCharacters(in:.whitespacesAndNewlines),providerID:result.id,createdByApp:true)
                    created.samples = samples.filter { FileManager.default.fileExists(atPath:$0.url.path) }.map { $0.url.lastPathComponent }; created.requiresVerification = result.requiresVerification
                    // Keep provider ownership even if a later render fails or the window closes.
                    app.upsertVoiceProfile(created); profile = created
                }
                guard !closed, let profile else { busy = false; return }
                step = 2
                guard profile.ready else { busy = false; error = "ElevenLabs requires voice verification. Complete it in your account, then check verification here."; return }
                let identity = options.identity(text:ReferenceSpeech.preview,performer:selectedTarget,clone:profile.providerID)
                progress = "Preparing pronunciation and personal previews…"
                let result = try await comparisonRenderer(identity,directory)
                guard !closed else { return }; sourceAudio = result.0; convertedAudio = result.1; busy = false
            } catch { busy = false; self.error = error.localizedDescription }
        }
    }
    func checkVerification() {
        guard !busy, let profile else { return }; busy = true; error = nil
        task = Task {
            do {
                let voices = try await api.list()
                guard !closed, let found = voices.first(where:{$0.id == profile.providerID}) else { busy = false; error = "Voice not found in this ElevenLabs account."; return }
                guard found.verificationKnown else { busy = false; error = "ElevenLabs did not confirm verification status. Complete verification in your account and retry."; return }
                var updated = profile; updated.requiresVerification = found.requiresVerification
                app.upsertVoiceProfile(updated); self.profile = updated; busy = false
                if updated.ready { createAndCompare() } else { error = "Verification is still required in ElevenLabs." }
            } catch { busy = false; self.error = error.localizedDescription }
        }
    }
    func accept() {
        guard !busy, heardConverted, convertedAudio != nil, let profile, profile.ready else { return }
        var accepted = profile; accepted.name = name.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !accepted.name.isEmpty, accepted.name.count <= 80 else { error = "Use a profile name of 1–80 characters."; return }
        app.performer = target; app.personalVoiceOptions = options; app.acceptVoiceProfile(accepted)
    }
    func renameProfile() {
        guard !busy, var profile else { return }
        let trimmed = name.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 80 else { error = "Use a profile name of 1–80 characters."; return }
        profile.name = trimmed; self.profile = profile; app.upsertVoiceProfile(profile)
    }
    func beginReplacement() {
        guard !busy, !recording else { return }
        audio.stop(); playing = false
        if profile?.id != profileID { try? FileManager.default.removeItem(at:directory) }
        profileID = UUID(); profile = nil; samples = []; consent = false; sourceAudio = nil; convertedAudio = nil; heardConverted = false; error = nil; step = 0
    }
    func removeLocalSamples() {
        guard !busy, var profile else { return }
        let directory = app.store.root.appendingPathComponent("VoiceProfiles/\(profile.id.uuidString)")
        var remaining: [String] = []
        for name in profile.samples {
            guard name == URL(fileURLWithPath:name).lastPathComponent, !name.hasPrefix(".") else { remaining.append(name); continue }
            do {
                let file = directory.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath:file.path) { try FileManager.default.removeItem(at:file) }
            } catch { remaining.append(name) }
        }
        profile.samples = remaining; self.profile = profile; app.upsertVoiceProfile(profile)
        if !remaining.isEmpty { error = "Some recordings could not be removed. Check file permissions and retry." }
    }
    func previewTarget() {
        guard !busy, !recording else { return }; busy = true; error = nil; audio.stop(); playing = false
        let identity = options.identity(text:ReferenceSpeech.preview,performer:target,clone:"")
        task = Task {
            do { try prepare(); let url = try await VoiceRenderer().pronunciation(identity,root:directory); guard !closed else { return }; busy = false; play(url) }
            catch { busy = false; self.error = error.localizedDescription }
        }
    }
    func close() {
        closed = true; clock?.cancel(); task?.cancel(); audio.stop(); app.voiceSetupActive = false
        if profile?.id != profileID { try? FileManager.default.removeItem(at:directory) }
        if let url = temporaryRecording { try? FileManager.default.removeItem(at:url) }
    }
}
