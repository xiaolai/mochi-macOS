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
                let epoch = model.turn.begin(.generating)
                window.performClose(nil)
                checks.append(("Close hides the workspace", !window.isVisible))
                checks.append(("Close cancels active work",model.turn.epoch != epoch && !model.busy))
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
            let mainWindow = NSApp.windows.first(where: { $0.isVisible && !$0.isSheet && $0.parent == nil && $0.canBecomeMain && $0.frame.width >= 760 })
            @MainActor func capture(_ name: String, settings: Bool = false) {
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
            model.startHelp()
            try? await Task.sleep(nanoseconds:300_000_000)
            capture("help.png")
            model.english = "I would like a little more time to think."
            model.saveExpression(); model.resume()
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
            try? Data("Native smoke: \(passed ? "PASS" : "FAIL"). Twenty native window and sheet snapshots. Capture failures: \(captureFailures.count). No network, microphone or speaker output.\n".utf8).write(to:directory.appendingPathComponent("smoke.txt"))
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
