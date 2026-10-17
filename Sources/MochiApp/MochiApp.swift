import AppKit
import CryptoKit
import MochiKernel
import SwiftUI

@main struct MochiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model: AppModel
    init() {
        DevelopmentLaunch.refuseInDistribution()
        DevelopmentLaunch.pinSmokeLanguage()
        Self.ignoreRestoredWindows()
        SingleInstanceController.shared.enforce()
        _model = State(
            initialValue: AppModel(
                demo: DevelopmentLaunch.demo, libraryRoot: DevelopmentLaunch.libraryRoot,
                preferences: DevelopmentLaunch.preferences))
    }
    /// Every launch opens the workspace rather than restoring the last session's windows. A session that ended with the
    /// window hidden in the menu bar restores no window, and SwiftUI then opens none, leaving nothing to show. This is
    /// the default behind Xcode's launch option to skip state restoration; it must be set before AppKit restores.
    static func ignoreRestoredWindows() {
        var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments["ApplePersistenceIgnoreState"] = true
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    }
    var body: some Scene {
        Window("Mochi", id: TrayController.workspaceWindowID) {
            WorkspaceView(app: model)
                .background(MainWindowReader { delegate.attachWindow($0, model: model) })
                .onAppear {
                    delegate.attachModel(model)
                    delegate.runDevelopmentActions(model)
                }
        }.defaultSize(width: 1040, height: 760)
            .windowToolbarStyle(.unified)
            .commands {
                let menu = MainMenuState(app: model)
                WorkspaceWindowCommands(tray: delegate.tray)
                CommandGroup(replacing: .appTermination) {
                    Button("Close Window to Tray", action: delegate.tray.closeToTray).keyboardShortcut("q")
                    Button("Quit Mochi Completely", action: delegate.tray.quitApp)
                }
                CommandGroup(replacing: .newItem) {
                    Button("New Conversation", action: model.newChat).keyboardShortcut("n").disabled(
                        !menu.newConversation)
                    Button("New Conversation from Template…", action: model.openTemplatePicker).keyboardShortcut(
                        "n", modifiers: [.command, .shift]
                    ).disabled(!menu.customization)
                    Button("Manage Templates…", action: model.openTemplateManager).disabled(!menu.customization)
                    Button("Manage Characters…", action: model.openCharacterManager).disabled(!menu.customization)
                }
                CommandMenu("Conversation") {
                    Button("Find in Conversation", action: model.findInConversation).keyboardShortcut("f").disabled(
                        !menu.findInConversation)
                    Button("Next Match") { model.find.move(1) }.keyboardShortcut("g").disabled(
                        !menu.moveBetweenMatches)
                    Button("Previous Match") { model.find.move(-1) }.keyboardShortcut(
                        "g", modifiers: [.command, .shift]
                    ).disabled(!menu.moveBetweenMatches)
                    Button("Search All Conversations") {
                        model.history.searchOpen = true
                        model.history.searchFocusRequest += 1
                    }.keyboardShortcut("f", modifiers: [.command, .shift]).disabled(!menu.searchAllConversations)
                    Button("Manage Conversations…") { model.history.managerOpen = true }.keyboardShortcut(
                        "m", modifiers: [.command, .shift]
                    ).disabled(!menu.manageConversations)
                    if let chat = model.conversation {
                        ChatActions(app: model, chat: chat).disabled(!menu.conversationActions)
                    }
                    Divider()
                    Button("Export Library Backup…", action: model.exportLibraryBackup).disabled(
                        !menu.libraryTransfer)
                    Button("Import Library Backup…", action: model.importLibraryBackup).disabled(
                        !menu.libraryTransfer)
                    Divider()
                    Button("Start Again", action: model.startAgain).disabled(!menu.startAgain)
                    Button(model.listeningMenuTitle, action: model.toggleListening).disabled(!menu.listening)
                    SendNowCommand(app: model)
                    Button("Help Me Say This", action: model.startHelp).keyboardShortcut(
                        "h", modifiers: [.command, .shift]
                    ).disabled(!menu.helpMeSayThis)
                    // Escape is the workspace window's own key (see `AppDelegate.observeEscape`), not this item's:
                    // SwiftUI can leave a command's enablement stale, and a stale Escape would do nothing or steal the
                    // key from other windows.
                    Button("Stop", action: menu.performStop).disabled(!menu.stop)
                }
            }
        Settings {
            SettingsView(app: model)
        }
    }
}
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?
    let tray = TrayController()
    let pet = DesktopPet()
    #if MOCHI_DEVELOPMENT
        private let instanceE2E = SingleInstanceE2E()
    #endif
    #if MOCHI_DEVELOPMENT
        /// Development runs perform their scripted actions once per launch.
        var ran = false
    #endif
    /// Observers that pause hands-free listening while the screen is locked or the workspace is out of sight.
    private var listeningObservers: [(NotificationCenter, NSObjectProtocol)] = []
    /// Observers that tell the model whether the workspace window has the keyboard.
    private var keyObservers: [NSObjectProtocol] = []
    /// The workspace window's Escape, which runs Stop.
    private var escapeMonitor: Any?
    func attachWindow(_ window: NSWindow, model: AppModel) {
        tray.attach(window, model: model)
        observeListeningConditions(window, model: model)
        observeKeyWindow(window, model: model)
        observeEscape(window, model: model)
        #if MOCHI_DEVELOPMENT
            instanceE2E.attach(window, tray: tray)
        #endif
        SingleInstanceController.shared.revealWorkspace = { [weak self] in self?.tray.showWindow() }
    }
    /// Escape in the workspace runs Stop when Stop can act, judged from the model as the key is pressed; otherwise,
    /// and in every other window or while an input method is composing, the key goes on to the focused view.
    private func observeEscape(_ window: NSWindow, model: AppModel) {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak window, weak model] event in
            let stopped = MainActor.assumeIsolated {
                guard let window, let model, MainMenuState.isPlainEscape(event, in: window) else { return false }
                let menu = MainMenuState(app: model)
                guard menu.stop else { return false }
                menu.performStop()
                return true
            }
            return stopped ? nil : event
        }
    }
    /// Whether the workspace has the keyboard, which Stop's Escape needs; see `MainMenuState.stop`.
    private func observeKeyWindow(_ window: NSWindow, model: AppModel) {
        for observer in keyObservers { NotificationCenter.default.removeObserver(observer) }
        model.workspaceKey = window.isKeyWindow
        keyObservers = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                [weak window, weak model] note in
                MainActor.assumeIsolated {
                    guard let window, let model, let changed = note.object as? NSWindow else { return }
                    // Another window becoming key, a sheet included, takes the keyboard from the workspace.
                    if changed === window {
                        model.workspaceKey = name == NSWindow.didBecomeKeyNotification
                    } else if name == NSWindow.didBecomeKeyNotification {
                        model.workspaceKey = false
                    }
                }
            }
        }
    }
    private func observeListeningConditions(_ window: NSWindow, model: AppModel) {
        for (center, observer) in listeningObservers { center.removeObserver(observer) }
        // Each change pauses listening at once, not on the next observation pass, so no queued audio slips through.
        let hidden = { [weak window, weak model] in
            // Closed to the menu bar, the window is ordered out: not visible, though neither hidden nor minimized.
            model?.workspaceHidden =
                NSApp.isHidden || window.map { $0.isMiniaturized || !$0.isVisible } ?? true
            model?.refreshListeningConditions()
        }
        tray.visibilityChanged = hidden
        let local = NotificationCenter.default
        let distributed = DistributedNotificationCenter.default()
        listeningObservers =
            [
                NSApplication.didHideNotification, NSApplication.didUnhideNotification,
                NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                // Posted when a window is ordered in or out, including the first time the workspace appears.
                NSWindow.didChangeOcclusionStateNotification,
            ].map { name in
                (
                    local,
                    local.addObserver(forName: name, object: nil, queue: .main) { _ in MainActor.assumeIsolated(hidden)
                    }
                )
            }
            + [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)].map { name, locked in
                (
                    distributed,
                    distributed.addObserver(forName: Notification.Name(name), object: nil, queue: .main) {
                        [weak model] _ in
                        MainActor.assumeIsolated {
                            model?.screenLocked = locked
                            model?.refreshListeningConditions()
                        }
                    }
                )
            }
    }
    func attachModel(_ model: AppModel) {
        guard self.model !== model else { return }
        self.model = model
        tray.follow(model)
        model.listeningIndicator = { [weak self] in self?.tray.showListening($0) }
        model.revealWorkspace = { [weak self] in self?.tray.showWindow() }
        model.offerWorkspace = { [weak self] in self?.tray.offerWindow() }
        model.configureAutomation()
        model.configureShortcuts()
        pet.attach(model)
    }
    func runDevelopmentActions(_ model: AppModel) {
        #if MOCHI_DEVELOPMENT
            if DevelopmentLaunch.Flag.toolsProbe.isSet {
                toolsProbe(model)
                return
            }
            if DevelopmentLaunch.Flag.probe.isSet {
                probe(model)
                return
            }
            if DevelopmentLaunch.Flag.smokeTest.isSet { smoke(model) }
            if DevelopmentLaunch.Flag.handsFreeSmokeTest.isSet {
                if DevelopmentLaunch.Flag.bargeIn.isSet { smokeBargeIn(model) } else { smokeHandsFree(model) }
            }
            if DevelopmentLaunch.Flag.traySmokeTest.isSet || DevelopmentLaunch.Flag.singleInstanceSmokeTest.isSet {
                smokeTray(model)
            }
        #endif
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        tray.install()
        // Should a launch still open no window, open it once the launch has settled and an opened window has attached.
        DispatchQueue.main.async { [tray] in tray.openWorkspaceIfUnopened() }
    }
    func applicationDidBecomeActive(_ notification: Notification) { model?.configureAutomation() }
    /// Quitting saves first; when the save fails the user chooses between keeping the window and losing the edits.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        model.notice = nil
        guard !TrayController.finishWork(model) else { return .terminateNow }
        tray.showWindow()
        let alert = NSAlert()
        alert.messageText = String(localized: "Mochi couldn’t save your library")
        alert.informativeText = model.error ?? String(localized: "Your latest changes were not saved.")
        alert.addButton(withTitle: String(localized: "Keep Mochi Open"))
        alert.addButton(withTitle: String(localized: "Quit Without Saving"))
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }
    func applicationWillTerminate(_ notification: Notification) {
        model?.automation.server?.stop()
        model?.discardTemporaryLibrary()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        tray.showWindow()
        return false
    }
}

/// Hands the tray SwiftUI's action for opening the workspace window, the only way to create it once a launch has left
/// it unopened. The app's commands are built while it launches, before anything can ask for the window.
private struct WorkspaceWindowCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    let tray: TrayController
    var body: some Commands {
        let _ = tray.adopt(openWindow)
        EmptyCommands()
    }
}

enum DevelopmentLaunch {
    /// Every development flag starts with this, and a distribution build takes no argument that does. It recognises a
    /// development launch by the prefix alone, so it carries no flag's name: the distribution check refuses any.
    static let flagPrefix = "--"
    /// The arguments of a launch, its program first, that ask for a development session.
    static func developmentFlags(in arguments: [String]) -> [String] {
        arguments.dropFirst().filter { $0.hasPrefix(flagPrefix) }
    }
    /// A distribution build has no development sessions: it would ignore the flags and open the real library. One
    /// launched with any refuses to start, before it touches the library or the instance lock.
    static func refuseInDistribution(_ arguments: [String] = CommandLine.arguments) {
        #if !MOCHI_DEVELOPMENT
            let flags = developmentFlags(in: arguments)
            guard !flags.isEmpty else { return }
            let explanation =
                "Mochi did not start: this build has no development sessions, and it was launched with "
                + flags.joined(separator: " ")
            MochiLog.app.error("\(explanation, privacy: .public)")
            FileHandle.standardError.write(Data((explanation + "\n").utf8))
            exit(EXIT_FAILURE)
        #endif
    }
    /// The development flags this build acts on; a distribution build acts on none.
    static var flags: [String] {
        #if MOCHI_DEVELOPMENT
            Flag.allCases.map(\.rawValue)
        #else
            []
        #endif
    }
    #if MOCHI_DEVELOPMENT
        /// The development flags, each named once. Every one starts with `flagPrefix`, so a distribution build
        /// launched with it refuses to start; scripts/release_support.py refuses a binary that names one.
        enum Flag: String, CaseIterable {
            case preview = "--preview"
            case smokeTest = "--smoke-test"
            case traySmokeTest = "--tray-smoke-test"
            case singleInstanceSmokeTest = "--single-instance-smoke-test"
            case handsFreeSmokeTest = "--hands-free-smoke-test"
            case bargeIn = "--barge-in"
            case probe = "--probe"
            case toolsProbe = "--tools-probe"

            var isSet: Bool { CommandLine.arguments.contains(rawValue) }
            /// The scripted runs, which compare English interface text.
            static let scripted: [Flag] = [
                .smokeTest, .traySmokeTest, .singleInstanceSmokeTest, .toolsProbe, .probe, .handsFreeSmokeTest,
            ]
            /// The runs that open a throwaway preview library rather than the user's.
            static let demo: [Flag] = [.preview] + scripted
        }
    #endif
    static var libraryRoot: URL? {
        #if MOCHI_DEVELOPMENT
            if let root = ProcessInfo.processInfo.environment["MOCHI_E2E_LIBRARY_ROOT"] {
                return URL(fileURLWithPath: root)
            }
        #endif
        return nil
    }
    static var preferences: UserDefaults? {
        libraryRoot.map { UserDefaults(suiteName: preferencesSuite(forLibraryRoot: $0))! }
    }
    /// Keyed by the whole standardized path, so distinct roots never share settings.
    /// scripts/tests/single_instance_e2e.py derives the same name to delete these suites.
    static func preferencesSuite(forLibraryRoot root: URL) -> String {
        "mochi-e2e-"
            + SHA256.hash(data: Data(root.standardizedFileURL.path.utf8)).prefix(16).map {
                String(format: "%02x", $0)
            }.joined()
    }
    /// Smoke runs compare English interface text, so they run in English whatever the Mac's language, unless the
    /// launch names a language to capture translated screenshots. Must run before anything reads a localized
    /// string: the bundle fixes its language on first use.
    static func pinSmokeLanguage() {
        #if MOCHI_DEVELOPMENT
            guard Flag.scripted.contains(where: \.isSet) else { return }
            var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
            guard arguments["AppleLanguages"] == nil else { return }
            arguments["AppleLanguages"] = ["en"]
            UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        #endif
    }
    static var demo: Bool {
        #if MOCHI_DEVELOPMENT
            return Flag.demo.contains(where: \.isSet)
        #else
            return false
        #endif
    }
}

/// Send Now, with the shortcut recorded for it in Settings; it works only while Mochi is in front.
private struct SendNowCommand: View {
    let app: AppModel
    var body: some View {
        // A shortcut with a problem (a number-pad key, a clash) is not installed: the menu would answer other keys.
        if let shortcut = app.settings.shortcuts[.sendNow], let key = shortcut.keyEquivalent,
            app.shortcuts.problems[.sendNow] == nil, !Shortcut.keypadKeys.contains(Int(shortcut.keyCode))
        {
            Button(ShortcutAction.sendNow.title, action: app.sendNow).keyboardShortcut(
                key, modifiers: shortcut.eventModifiers
            ).disabled(!app.canSendNow)
        } else {
            Button(ShortcutAction.sendNow.title, action: app.sendNow).disabled(!app.canSendNow)
        }
    }
}
