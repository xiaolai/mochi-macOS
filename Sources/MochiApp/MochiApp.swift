import SwiftUI
import AppKit
import MochiCore

@main struct MochiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel(demo:CommandLine.arguments.contains("--preview") || CommandLine.arguments.contains("--smoke-test") || CommandLine.arguments.contains("--tray-smoke-test"))
    var body: some Scene {
        Window("Mochi",id:"main") {
            WorkspaceView(app:model)
                .background(MainWindowReader { delegate.tray.attach($0, model:model) })
                .onAppear { delegate.model = model; if CommandLine.arguments.contains("--smoke-test") { delegate.smoke(model) }; if CommandLine.arguments.contains("--tray-smoke-test") { delegate.smokeTray(model) }; if CommandLine.arguments.contains("--probe") { delegate.probe(model) } }
        }.defaultSize(width:1040,height:760)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing:.newItem) { Button("New Conversation",action:model.newChat).keyboardShortcut("n") }
            CommandMenu("Conversation") {
                Button("Search Conversations") { model.searchOpen = true; model.searchFocusRequest += 1 }.keyboardShortcut("f").disabled(model.practice || model.renameID != nil || !model.permanentDeleteIDs.isEmpty)
                Button("Manage Conversations…") { model.managerOpen = true }.keyboardShortcut("m",modifiers:[.command,.shift]).disabled(model.practice)
                if let chat = model.conversation { ChatActions(app:model,chat:chat).disabled(model.practice) }
                Divider()
                Button("Export Library Backup…",action:model.exportLibraryBackup)
                Button("Import Library Backup…",action:model.importLibraryBackup)
                Divider()
                Button("Help Me Say This",action:model.startHelp).keyboardShortcut("h",modifiers:[.command,.shift]).disabled(!model.writableConversation)
                Button("Stop",action:model.stop).keyboardShortcut(.escape,modifiers:[])
            }
        }
        Settings {
            SettingsView(app:model)
        }
    }
}
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?
    let tray = TrayController()
    private var ran = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps:true)
        tray.install()
        if CommandLine.arguments.contains("--import-environment") {
            for name in ["OPENAI_API_KEY", "ELEVENLABS_API_KEY"] {
                if let value = ProcessInfo.processInfo.environment[name], !value.isEmpty {
                    do { try Credentials.save(value,name:name); print("Credential saved to Keychain: \(name)") }
                    catch { print("Credential import failed: \(name)") }
                }
            }
        }
    }
    func applicationWillTerminate(_ notification: Notification) { model?.stop(); model?.save() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        tray.showWindow()
        return false
    }
    func smokeTray(_ model: AppModel) {
        guard !ran else { return }; ran = true
        model.turn.resume()
        Task {
            try? await Task.sleep(nanoseconds:700_000_000)
            let directory = URL(fileURLWithPath:ProcessInfo.processInfo.environment["MOCHI_EVIDENCE_DIR"] ?? "/tmp/mochi-tray-evidence")
            do {
                try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
                guard let window = tray.window else { throw CocoaError(.fileNoSuchFile) }
                var checks: [(String,Bool)] = []
                let selected = model.selectedID
                model.draft = "Tray smoke draft"
                var voice = Message(role:"user",text:"",audio:"tray-retained.wav"); voice.transcriptionState = .failed
                if let selected { model.append(voice,to:selected) }
                var recoveryStarted = false
                model.transcribeRecording = { _,_,_ in recoveryStarted = true; try? await Task.sleep(nanoseconds:100_000_000); return "Late tray transcript" }
                model.retryTranscription(voice.id)
                let startedDeadline = Date().addingTimeInterval(2)
                while !recoveryStarted && Date() < startedDeadline { try await Task.sleep(nanoseconds:1_000_000) }
                let epoch = model.turn.begin(.generating)
                window.performClose(nil)
                checks.append(("Close hides the workspace", !window.isVisible))
                checks.append(("Close cancels active work",model.turn.epoch != epoch && !model.busy))
                checks.append(("Close cancels pending transcription",recoveryStarted && model.transcribingMessageIDs.isEmpty && model.conversation?.messages.first(where: { $0.id == voice.id })?.transcriptionState == .interrupted))
                try await Task.sleep(nanoseconds:150_000_000)
                checks.append(("Late transcript cannot rewrite closed workspace",model.conversation?.messages.first(where: { $0.id == voice.id })?.text == ""))
                checks.append(("Tray remains installed",tray.statusItem?.button?.image?.isTemplate == true))
                tray.showWindow()
                checks.append(("Open restores the same workspace",window.isVisible && tray.window === window))
                checks.append(("Draft and selection survive",model.draft == "Tray smoke draft" && model.selectedID == selected))
                window.performClose(nil)
                _ = applicationShouldHandleReopen(NSApp,hasVisibleWindows:false)
                checks.append(("Dock reopen restores workspace",window.isVisible))
                checks.append(("Last window close keeps app running",!applicationShouldTerminateAfterLastWindowClosed(NSApp)))
                let icon = TrayController.icon()
                for scale in [1,2,4] {
                    let rep = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:20*scale,pixelsHigh:18*scale,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
                    rep.size = NSSize(width:20,height:18)
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:rep)
                    icon.draw(in:NSRect(x:0,y:0,width:20,height:18))
                    NSGraphicsContext.restoreGraphicsState()
                    try rep.representation(using:.png,properties:[:])!.write(to:directory.appendingPathComponent("TrayIcon-\(scale)x.png"))
                }
                let lines = checks.map { "\($0.1 ? "PASS" : "FAIL"): \($0.0)" }
                try Data((lines.joined(separator:"\n")+"\n").utf8).write(to:directory.appendingPathComponent("tray-smoke.txt"))
            } catch {
                try? Data("FAIL: \(error.localizedDescription)\n".utf8).write(to:directory.appendingPathComponent("tray-smoke.txt"))
            }
            NSApp.terminate(nil)
        }
    }
    func smoke(_ model: AppModel) {
        guard !ran else { return }; ran = true
        Task {
            try? await Task.sleep(nanoseconds:700_000_000)
            let directory = URL(fileURLWithPath:ProcessInfo.processInfo.environment["MOCHI_EVIDENCE_DIR"] ?? ProcessInfo.processInfo.environment["ENJOY_EVIDENCE_DIR"] ?? "/tmp/mochi-evidence")
            try? FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            try? FileManager.default.removeItem(at:directory.appendingPathComponent("smoke.txt"))
            var captureFailures: [String] = []
            var captureCount = 0
            let mainWindow = NSApp.windows.first(where: { $0.isVisible && !$0.isSheet && $0.parent == nil && $0.canBecomeMain && $0.frame.width >= 760 })
            @MainActor func capture(_ name: String, settings: Bool = false) {
                captureCount += 1
                let target = settings ? NSApp.windows.first(where: { $0.isVisible && $0 !== mainWindow && $0.canBecomeMain }) : mainWindow
                guard let window = target else { captureFailures.append(name); return }
                try? FileManager.default.removeItem(at:directory.appendingPathComponent(name))
                let capture = Process()
                capture.executableURL = URL(fileURLWithPath:"/usr/sbin/screencapture")
                capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), directory.appendingPathComponent(name).path]
                do {
                    try capture.run(); capture.waitUntilExit()
                    if capture.terminationStatus != 0 { captureFailures.append(name) }
                } catch { captureFailures.append(name) }

            }
            mainWindow?.attachedSheet?.makeFirstResponder(nil)
            model.practiceVoiceMode = .builtIn
            model.builtInPracticeVoice = "marin"
            capture("practice.png")
            NSApp.appearance = NSAppearance(named:.darkAqua)
            try? await Task.sleep(nanoseconds:250_000_000)
            capture("practice-dark.png")
            NSApp.appearance = NSAppearance(named:.aqua)
            if let window = mainWindow { window.setContentSize(NSSize(width:820,height:700)) }
            try? await Task.sleep(nanoseconds:300_000_000)
            capture("practice-compact.png")
            if let window = mainWindow { window.setContentSize(NSSize(width:1120,height:840)) }
            model.practiceVoiceSetupOpen = true
            try? await Task.sleep(nanoseconds:450_000_000)
            capture("voice-setup-recordings.png")
            model.voiceSetupPreviewStep = 1
            try? await Task.sleep(nanoseconds:350_000_000)
            capture("voice-setup-pronunciation.png")
            model.voiceSetupPreviewStep = 2
            try? await Task.sleep(nanoseconds:350_000_000)
            capture("voice-setup-comparison.png")
            model.practiceVoiceSetupOpen = false
            try? await Task.sleep(nanoseconds:350_000_000)
            model.resume()
            try? await Task.sleep(nanoseconds:350_000_000)
            capture("conversation.png")
            model.newChat()
            try? await Task.sleep(nanoseconds:300_000_000)
            capture("welcome.png")
            model.auth = "codex"
            model.startHelp()
            try? await Task.sleep(nanoseconds:300_000_000)
            capture("help.png")
            model.meaning = "I want to ask for a little more time to think."
            model.editEnglish("I would like a little more time to think.")
            try? await Task.sleep(nanoseconds:300_000_000)
            capture("help-english.png")
            NSApp.appearance = NSAppearance(named:.darkAqua)
            try? await Task.sleep(nanoseconds:250_000_000)
            capture("help-english-dark.png")
            NSApp.appearance = NSAppearance(named:.aqua)
            model.beginPractice()
            try? await Task.sleep(nanoseconds:300_000_000)
            capture("help-practice.png")
            model.editThought()
            let thoughtName = "thought-fixture.wav"
            try? PCM.wav(Data(repeating:0,count:144000)).write(to:model.store.root.appendingPathComponent(thoughtName))
            model.thoughtRecording = thoughtName
            model.recordingWarning = "This illustrative recording is very quiet. Listen before transcribing, or record it again."
            try? await Task.sleep(nanoseconds:300_000_000)
            capture("help-recording-review.png")
            model.recognizedThought = "I need a little more time before I can explain my idea."
            try? await Task.sleep(nanoseconds:300_000_000)
            capture("help-transcript-review.png")
            model.recognizedThought = nil
            _ = model.turn.begin(.recording); model.recordingMeaning = true; model.recordingSeconds = 3; model.recordingLevel = -54
            try? await Task.sleep(nanoseconds:250_000_000)
            capture("help-recording-feedback.png")
            model.stop()
            model.saveExpression(); model.resume()
            if let id = model.selectedID {
                try? PCM.wav(Data(repeating:0,count:144000)).write(to:model.store.root.appendingPathComponent(thoughtName))
                var failed = Message(role:"user",text:"",audio:thoughtName)
                failed.transcriptionState = .failed; failed.transcriptionError = "Your recording is saved. We couldn’t transcribe it."
                model.append(failed,to:id)
                model.append(Message(role:"assistant",text:"Take your time. What would help you decide?"),to:id)
                try? await Task.sleep(nanoseconds:300_000_000)
                capture("voice-recovery.png")
                model.auth = "codex"
                model.transcribeRecording = { _,_,_ in try await Task.sleep(nanoseconds:900_000_000); return "I would like a little more time to think." }
                model.retryTranscription(failed.id)
                try? await Task.sleep(nanoseconds:250_000_000)
                capture("voice-recovery-progress.png")
                try? await Task.sleep(nanoseconds:750_000_000)
                capture("voice-recovery-complete.png")
                let originalPlayer = model.audio.makePlayer
                model.audio.makePlayer = { _ in SmokePlaybackPlayer() }
                model.togglePlayback(thoughtName)
                model.seekPlayback(thoughtName,to:1)
                try? await Task.sleep(nanoseconds:250_000_000)
                capture("message-playback-playing.png")
                model.togglePlayback(thoughtName)
                try? await Task.sleep(nanoseconds:250_000_000)
                capture("message-playback-paused.png")
                model.seekPlayback(thoughtName,to:2)
                if !model.audio.paused || model.audio.position != 2 { captureFailures.append("Paused seek did not preserve playback state") }
                NSApp.appearance = NSAppearance(named:.darkAqua)
                try? await Task.sleep(nanoseconds:250_000_000)
                capture("message-playback-dark.png")
                NSApp.appearance = NSAppearance(named:.aqua)
                if let window = mainWindow { window.setContentSize(NSSize(width:820,height:700)) }
                try? await Task.sleep(nanoseconds:250_000_000)
                capture("message-playback-compact.png")
                if let window = mainWindow { window.setContentSize(NSSize(width:1120,height:840)) }
                model.stop(); model.audio.makePlayer = originalPlayer

                if model.conversation?.messages.first(where: { $0.id == failed.id })?.transcriptionState != .completed { captureFailures.append("Codex fixture recovery did not complete") }
            }
            model.showExpressions = true
            try? await Task.sleep(nanoseconds:300_000_000)
            capture("expressions.png")
            model.showExpressions = false
            model.showHistory(.active)
            let ids = model.library.conversations.map(\.id)
            if ids.count >= 3 {
                model.renameChat(ids[0],title:"A project I want to start")
                model.pinChats([ids[0]],pinned:true)
                model.archiveChats([ids[1]])
                model.deleteChats([ids[2]])
                model.select(ids[0]); model.draft = "I think the first step is…"
                model.search = "project"
                try? await Task.sleep(nanoseconds:350_000_000)
                capture("search.png")
                model.showHistory(.archived)
                try? await Task.sleep(nanoseconds:350_000_000)
                capture("archived.png")
                model.showHistory(.deleted)
                try? await Task.sleep(nanoseconds:350_000_000)
                capture("deleted.png")
                model.managerOpen = true
                try? await Task.sleep(nanoseconds:450_000_000)
                capture("manager.png")
                model.permanentDeleteIDs = [ids[2]]
                try? await Task.sleep(nanoseconds:350_000_000)
                capture("permanent-delete-confirmation.png")
                model.permanentDeleteIDs = []
                try? await Task.sleep(nanoseconds:250_000_000)
                model.managerOpen = false
                try? await Task.sleep(nanoseconds:350_000_000)
                model.showHistory(.active); model.renameID = ids[0]
                try? await Task.sleep(nanoseconds:450_000_000)
                capture("rename.png")
                model.renameID = nil
                if let window = mainWindow { window.setContentSize(NSSize(width:820,height:700)) }
                try? await Task.sleep(nanoseconds:350_000_000)
                capture("history-compact.png")
            }
            model.settingsOpen = true
            try? await Task.sleep(nanoseconds:500_000_000)
            capture("settings.png",settings:true)
            model.settingsTab = "voices"
            try? await Task.sleep(nanoseconds:350_000_000)
            capture("voice-settings.png",settings:true)
            model.practiceVoiceMode = .personal
            try? await Task.sleep(nanoseconds:350_000_000)
            capture("voice-settings-elevenlabs.png",settings:true)
            let passed = captureFailures.isEmpty && model.library.expressions.count >= 1 && model.turn.mode == .conversation && model.turn.owner == .none
            try? Data("Native smoke: \(passed ? "PASS" : "FAIL"). \(captureCount) native window and sheet snapshots. Capture failures: \(captureFailures.count). No network, microphone or speaker output.\n".utf8).write(to:directory.appendingPathComponent("smoke.txt"))
            NSApp.terminate(nil)
        }
    }
    func probe(_ model: AppModel) {
        guard !ran else { return }; ran = true
        Task {
            let directory = URL(fileURLWithPath:ProcessInfo.processInfo.environment["MOCHI_EVIDENCE_DIR"] ?? ProcessInfo.processInfo.environment["ENJOY_EVIDENCE_DIR"] ?? "/tmp/mochi-evidence")
            try? FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            var lines: [String] = []
            do {
                let service = RealtimeService(auth:model.auth,model:model.modelName,voice:model.conversationVoice,options:model.conversationVoiceOptions)
                let result = try await service.reply(ConversationRequest(history:[],text:"Reply with the single word ready."))
                lines.append("Realtime text: \(!result.text.isEmpty ? "PASS" : "FAIL")")
                let translation = try await service.reply(ConversationRequest(history:[],text:"我一直拖着不做，因为不知道从哪里开始。",help:true))
                lines.append("Help translation: \(!translation.text.isEmpty && translation.audio.isEmpty ? "PASS" : "FAIL")")
                let spoken = try await service.reply(ConversationRequest(history:[],text:"Say hello briefly.",spoken:true))
                lines.append("Realtime audio generation: \(!spoken.audio.isEmpty ? "PASS" : "FAIL") (not played)")
                if !spoken.audio.isEmpty {
                    let heard = try await service.reply(ConversationRequest(history:[],text:"",pcm:spoken.audio))
                    lines.append("Synthetic audio input and transcription: \(!heard.inputTranscript.isEmpty && !heard.text.isEmpty ? "PASS" : "FAIL") (no microphone)")
                }
            } catch { lines.append("Realtime: \(error.localizedDescription)") }
            if !model.clone.isEmpty {
                do {
                    let url = try await VoiceRenderer().render(model.personalVoiceOptions.identity(text:"I would like a little more time to think.",performer:model.performer,clone:model.clone),root:model.store.root)
                    let pitch = try AudioFile.pitch(url)
                    lines.append("Own-voice TTS → STS and decode: \(pitch.contains(where: { $0.hz != nil }) ? "PASS" : "FAIL") (not played)")
                } catch { lines.append("Own voice: \(error.localizedDescription)") }
            } else { lines.append("Own voice: not probed (clone ID not configured)") }
            try? Data((lines.joined(separator:"\n")+"\n").utf8).write(to:directory.appendingPathComponent("live-probe.txt"))
            NSApp.terminate(nil)
        }
    }
}

// Native layout fixtures never send sound to the speakers.
private final class SmokePlaybackPlayer: PlaybackPlayer {
    let duration: TimeInterval = 3
    var currentTime: TimeInterval = 0
    var enableRate = false
    var rate: Float = 1
    func play() -> Bool { true }
    func pause() {}
    func stop() {}
}
