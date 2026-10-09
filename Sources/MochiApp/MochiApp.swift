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
            CommandGroup(replacing:.appTermination) {
                Button("Close Window to Tray",action:delegate.tray.closeToTray).keyboardShortcut("q")
                Button("Quit Mochi Completely",action:delegate.tray.quitApp)
            }
            CommandGroup(replacing:.newItem) { Button("New Conversation",action:model.newChat).keyboardShortcut("n") }
            CommandMenu("Conversation") {
                Button("Find in Conversation",action:model.findInConversation).keyboardShortcut("f").disabled(!model.canFindInConversation)
                Button("Next Match") { model.moveConversationMatch(1) }.keyboardShortcut("g").disabled(model.conversationMatchIDs.isEmpty)
                Button("Previous Match") { model.moveConversationMatch(-1) }.keyboardShortcut("g",modifiers:[.command,.shift]).disabled(model.conversationMatchIDs.isEmpty)
                Button("Search All Conversations") { model.searchOpen = true; model.searchFocusRequest += 1 }.keyboardShortcut("f",modifiers:[.command,.shift]).disabled(model.practice || model.renameID != nil || !model.permanentDeleteIDs.isEmpty)
                Button("Manage Conversations…") { model.managerOpen = true }.keyboardShortcut("m",modifiers:[.command,.shift]).disabled(model.practice)
                if let chat = model.conversation { ChatActions(app:model,chat:chat).disabled(model.practice) }
                Divider()
                Button("Export Library Backup…",action:model.exportLibraryBackup)
                Button("Import Library Backup…",action:model.importLibraryBackup)
                Divider()
                Button("Help Me Say This",action:model.startHelp).keyboardShortcut("h",modifiers:[.command,.shift]).disabled(!model.writableConversation)
                Button("Stop") { if model.conversationSearchOpen { model.closeConversationSearch() } else { model.stop() } }.keyboardShortcut(.escape,modifiers:[])
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
    func applicationWillTerminate(_ notification: Notification) { model?.cancelVoiceSetup?(); model?.stop(); model?.save() }
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
                func menuItems(_ menu: NSMenu) -> [NSMenuItem] {
                    menu.items.flatMap { item in [item] + (item.submenu.map(menuItems) ?? []) }
                }
                let commands = NSApp.mainMenu.map(menuItems) ?? []
                let commandQ = commands.first { $0.keyEquivalent == "q" && $0.keyEquivalentModifierMask == .command }
                checks.append(("Command-Q is Close Window to Tray",commandQ?.title == "Close Window to Tray"))
                let quit = tray.menu?.items.first { $0.title == "Quit Mochi Completely" }
                checks.append(("Tray quit has no Command-Q shortcut",quit != nil && quit?.keyEquivalent == ""))
                let playbackEpoch = model.turn.begin(.playing)
                if let commandQ, let menu = commandQ.menu {
                    menu.performActionForItem(at:menu.index(of:commandQ))
                }
                let hiddenDeadline = Date().addingTimeInterval(2)
                while !NSApp.isHidden && Date() < hiddenDeadline { try await Task.sleep(nanoseconds:1_000_000) }
                checks.append(("Command-Q hides workspace and keeps tray",!window.isVisible && NSApp.isHidden && tray.statusItem?.button != nil))
                checks.append(("Command-Q removes Dock presence",NSApp.activationPolicy() == .accessory && NSRunningApplication.current.activationPolicy == .accessory))
                checks.append(("Command-Q stops active work and preserves draft",model.turn.epoch != playbackEpoch && !model.busy && model.draft == "Tray smoke draft"))
                tray.showWindow()
                let reopenedDeadline = Date().addingTimeInterval(2)
                while (NSApp.isHidden || !window.isVisible) && Date() < reopenedDeadline { try await Task.sleep(nanoseconds:1_000_000) }
                checks.append(("Tray reopens workspace after Command-Q",window.isVisible && !NSApp.isHidden && tray.window === window))
                checks.append(("Tray reopen restores Dock presence",NSApp.activationPolicy() == .regular && NSRunningApplication.current.activationPolicy == .regular))
                checks.append(("Tray button handles clicks without an automatic menu",tray.statusItem?.menu == nil && tray.statusItem?.button?.target === tray))
                tray.closeToTray()
                let clickHiddenDeadline = Date().addingTimeInterval(2)
                while !NSApp.isHidden && Date() < clickHiddenDeadline { try await Task.sleep(nanoseconds:1_000_000) }
                let originalPresenter = tray.presentMenu
                var presented = false
                tray.presentMenu = { menu,event,button in
                    presented = menu === self.tray.menu && event.type == .rightMouseUp && button === self.tray.statusItem?.button
                }
                let rightClick = NSEvent.mouseEvent(with:.rightMouseUp,location:.zero,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:0,context:nil,eventNumber:1,clickCount:1,pressure:0)!
                tray.handleClick(rightClick)
                checks.append(("Right click presents tray menu without reopening",presented && !window.isVisible && NSApp.activationPolicy() == .accessory))
                presented = false
                tray.presentMenu = { menu,event,button in
                    presented = menu === self.tray.menu && event.modifierFlags.contains(.control) && button === self.tray.statusItem?.button
                }
                let controlClick = NSEvent.mouseEvent(with:.leftMouseUp,location:.zero,modifierFlags:[.control],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:0,context:nil,eventNumber:3,clickCount:1,pressure:0)!
                tray.handleClick(controlClick)
                checks.append(("Control-click presents menu without reopening",presented && !window.isVisible && NSApp.activationPolicy() == .accessory))
                presented = false
                let leftClick = NSEvent.mouseEvent(with:.leftMouseUp,location:.zero,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:0,context:nil,eventNumber:2,clickCount:1,pressure:0)!
                tray.handleClick(leftClick)
                let clickReopenedDeadline = Date().addingTimeInterval(2)
                while (NSApp.isHidden || !window.isVisible) && Date() < clickReopenedDeadline { try await Task.sleep(nanoseconds:1_000_000) }
                checks.append(("Left click restores window and Dock without menu",window.isVisible && !NSApp.isHidden && NSApp.activationPolicy() == .regular && !presented))
                tray.presentMenu = originalPresenter
                let setup = VoiceSetupModel(app:model)
                setup.begin(); tray.closeToTray()
                checks.append(("Command-Q closes separate voice setup",setup.closed && !model.voiceSetupActive && model.cancelVoiceSetup == nil))
                tray.showWindow()


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
            @MainActor func capture(_ name: String, settings: Bool = false, window explicitWindow: NSWindow? = nil) {
                captureCount += 1
                let target = explicitWindow ?? (settings ? NSApp.windows.first(where: { $0.isVisible && $0 !== mainWindow && $0.canBecomeMain }) : mainWindow)
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
            if mainWindow?.titleVisibility != .hidden || mainWindow?.toolbar?.displayMode != .iconOnly {
                captureFailures.append("Workspace title or toolbar display mode is incorrect")
            }
            if #available(macOS 15.0, *), mainWindow?.toolbar?.allowsDisplayModeCustomization != false {
                captureFailures.append("Toolbar display-mode customization remains enabled")
            }
            if mainWindow?.titlebarSeparatorStyle != NSTitlebarSeparatorStyle.none { captureFailures.append("Title-bar separator remains enabled") }
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
            if mainWindow?.attachedSheet != nil { captureFailures.append("Practice/voice setup left a sheet attached to the conversation") }
            capture("conversation.png")
            let toolbarStates: [(Activity,Bool,String)] = [(.generating,false,"generation"),(.playing,false,"playback"),(.recording,false,"recording"),(.requestingPermission,false,"permission"),(.idle,true,"voice-setup")]
            for (activity,setup,name) in toolbarStates {
                model.voiceSetupActive = setup
                _ = model.turn.begin(activity)
                try? await Task.sleep(nanoseconds:250_000_000)
                let hasStop = mainWindow?.toolbar?.items.contains(where: { $0.label == "Stop" }) == true
                if hasStop != (activity == .generating) { captureFailures.append("Incorrect title-bar Stop visibility: \(name)") }
                capture("titlebar-stop-\(name).png")
            }
            model.voiceSetupActive = false; model.stop()
            model.newChat()
            try? await Task.sleep(nanoseconds:300_000_000)
            capture("welcome.png")
            @MainActor func composerFrame(_ root: Any, depth: Int = 0) -> NSRect? {
                guard depth < 30, let element = root as? any NSAccessibilityProtocol else { return nil }
                if element.accessibilityIdentifier() == "conversation-composer" { return element.accessibilityFrame() }
                for child in element.accessibilityChildren() ?? [] {
                    if let frame = composerFrame(child,depth:depth+1) { return frame }
                }
                return nil
            }
            let beforeNotice = mainWindow.flatMap { composerFrame($0) }
            model.notice = "Help draft saved."
            try? await Task.sleep(nanoseconds:250_000_000)
            capture("conversation-notice.png")
            let withNotice = mainWindow.flatMap { composerFrame($0) }
            if let beforeNotice, let withNotice {
                if abs(beforeNotice.minY-withNotice.minY) > 0.5 || abs(beforeNotice.height-withNotice.height) > 0.5 {
                    captureFailures.append("Notice moved or resized the conversation composer")
                }
            } else { captureFailures.append("Could not locate the composer for notice geometry verification") }
            try? await Task.sleep(nanoseconds:4_100_000_000)
            if model.notice != nil { captureFailures.append("Conversation notice did not automatically dismiss") }
            capture("conversation-notice-dismissed.png")
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
                model.notice = nil; model.search = ""
                model.openConversationSearch(); model.conversationQuery = "time"
                try? await Task.sleep(nanoseconds:300_000_000)
                capture("conversation-search.png")
                model.moveConversationMatch(1)
                try? await Task.sleep(nanoseconds:250_000_000)
                capture("conversation-search-next.png")
                if model.conversationMatchIDs.count != 2 { captureFailures.append("Current conversation search did not find both messages") }
                model.conversationQuery = "no-such-message"
                try? await Task.sleep(nanoseconds:250_000_000)
                capture("conversation-search-empty.png")
                @MainActor func searchFields(_ view: NSView) -> [NSSearchField] {
                    (view as? NSSearchField).map { [$0] } ?? view.subviews.flatMap(searchFields)
                }
                let fields = mainWindow?.toolbar?.items.flatMap { item in item.view.map(searchFields) ?? [] } ?? []
                if let field = fields.first(where: { $0.placeholderString == "Search this conversation" }) {
                    if field.currentEditor() == nil { captureFailures.append("Conversation search did not acquire keyboard focus") }
                    field.stringValue = ""
                    if let action = field.action { NSApp.sendAction(action,to:field.target,from:field) }
                    if !model.conversationQuery.isEmpty { captureFailures.append("Native search cancel did not clear the query") }
                } else { captureFailures.append("Native conversation search field was not installed") }

                if let window = mainWindow { window.setContentSize(NSSize(width:820,height:700)) }
                model.conversationQuery = "time"
                try? await Task.sleep(nanoseconds:250_000_000)
                capture("conversation-search-compact.png")
                let escapeCommand = NSApp.mainMenu?.items.compactMap(\.submenu).flatMap(\.items).first { $0.title == "Stop" && $0.keyEquivalent == "\u{1b}" }
                let searchEpoch = model.turn.begin(.generating)
                if let command = escapeCommand, let menu = command.menu { menu.performActionForItem(at:menu.index(of:command)) }
                if escapeCommand == nil || model.conversationSearchOpen || model.turn.epoch != searchEpoch {
                    captureFailures.append("Escape must close search without cancelling a pending reply")
                }
                _ = model.turn.finish(searchEpoch)
                model.closeConversationSearch()
                if let window = mainWindow { window.setContentSize(NSSize(width:1120,height:840)) }


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
            let pitchFixture = (0..<150).map { i -> PitchPoint in
                let t = Double(i)*0.015
                let value = 7 + 3*sin(t*5) + (i.isMultiple(of:2) ? 0.45 : -0.45) + (i == 88 ? 12 : 0)
                return PitchPoint(time:t,hz:(55...65).contains(i) ? nil : 100*pow(2,value/12))
            }
            let comparison = NSWindow(contentRect:NSRect(x:0,y:0,width:680,height:460),styleMask:[.titled,.closable],backing:.buffered,defer:false)
            comparison.title = "Pitch contour · display comparison"
            comparison.isReleasedWhenClosed = false
            comparison.contentView = NSHostingView(rootView:VStack(alignment:.leading,spacing:14) {
                Text("Original samples · straight segments").font(.headline)
                PitchChart(reference:pitchFixture,attempt:[],normalized:false,smoothed:false).frame(height:150)
                Text("Light smoothing · shape-preserving cubic curves").font(.headline)
                PitchChart(reference:pitchFixture,attempt:[],normalized:false,smoothed:true).frame(height:150)
                Text("Illustrative pitch data · pauses remain gaps · original analysis stays unchanged").font(.caption).foregroundStyle(.secondary)
            }.padding(20).frame(width:680,height:460))
            comparison.center(); comparison.makeKeyAndOrderFront(nil)
            try? await Task.sleep(nanoseconds:300_000_000)
            capture("pitch-curves-comparison.png",window:comparison)
            NSApp.appearance = NSAppearance(named:.darkAqua)
            try? await Task.sleep(nanoseconds:250_000_000)
            capture("pitch-curves-comparison-dark.png",window:comparison)
            NSApp.appearance = NSAppearance(named:.aqua)
            comparison.orderOut(nil)
            model.settingsOpen = false
            model.newChat()
            let greetingPlayer = SmokePlaybackPlayer()
            model.audio.makePlayer = { _ in greetingPlayer }
            model.microphonePermission = { true }
            model.recordAudio = { _ in }
            model.renderGreeting = { _,_,root in
                let url = root.appendingPathComponent("greeting-fixture.wav")
                try PCM.wav(Data(repeating:0,count:144000)).write(to:url)
                return url
            }
            model.toggleConversationVoice()
            try? await Task.sleep(nanoseconds:350_000_000)
            if model.turn.activity != .playing || !model.greetingActive || model.conversation?.messages.count != 1 {
                captureFailures.append("Voice entry did not show its saved greeting")
            }
            capture("voice-greeting.png")
            model.togglePlayback("greeting-fixture.wav",mochi:true)
            try? await Task.sleep(nanoseconds:200_000_000)
            if !model.audio.paused { captureFailures.append("Greeting pause failed") }
            capture("voice-greeting-paused.png")
            model.audio.finishPlayback(greetingPlayer,successfully:true)
            try? await Task.sleep(nanoseconds:250_000_000)
            if model.turn.activity != .recording || model.greetingActive { captureFailures.append("Greeting did not transition to recording") }
            capture("voice-greeting-listening.png")
            model.stop()
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
