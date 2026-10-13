import AppKit
import CryptoKit
import SwiftUI

@main struct MochiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model: AppModel
    init() {
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
                WorkspaceWindowCommands(tray: delegate.tray)
                CommandGroup(replacing: .appTermination) {
                    Button("Close Window to Tray", action: delegate.tray.closeToTray).keyboardShortcut("q")
                    Button("Quit Mochi Completely", action: delegate.tray.quitApp)
                }
                CommandGroup(replacing: .newItem) {
                    Button("New Conversation", action: model.newChat).keyboardShortcut("n").disabled(
                        model.automationModal)
                    Button("New Conversation from Template…", action: model.openTemplatePicker).keyboardShortcut(
                        "n", modifiers: [.command, .shift]
                    ).disabled(!model.canOpenConversationInstructions)
                    Button("Manage Templates…", action: model.openTemplateManager).disabled(
                        !model.canOpenConversationInstructions)
                    Button("Manage Characters…", action: model.openCharacterManager).disabled(
                        !model.canOpenConversationInstructions)
                }
                CommandMenu("Conversation") {
                    Button("Find in Conversation", action: model.findInConversation).keyboardShortcut("f").disabled(
                        !model.canFindInConversation)
                    Button("Next Match") { model.find.move(1) }.keyboardShortcut("g").disabled(
                        model.find.matchIDs.isEmpty)
                    Button("Previous Match") { model.find.move(-1) }.keyboardShortcut(
                        "g", modifiers: [.command, .shift]
                    ).disabled(model.find.matchIDs.isEmpty)
                    Button("Search All Conversations") {
                        model.history.searchOpen = true
                        model.history.searchFocusRequest += 1
                    }.keyboardShortcut("f", modifiers: [.command, .shift]).disabled(
                        model.practice || model.history.renameID != nil || !model.history.permanentDeleteIDs.isEmpty)
                    Button("Manage Conversations…") { model.history.managerOpen = true }.keyboardShortcut(
                        "m", modifiers: [.command, .shift]
                    ).disabled(model.automationModal)
                    if let chat = model.conversation { ChatActions(app: model, chat: chat).disabled(model.practice) }
                    Divider()
                    Button("Export Library Backup…", action: model.exportLibraryBackup).disabled(
                        model.libraryTransfer != nil)
                    Button("Import Library Backup…", action: model.importLibraryBackup).disabled(
                        model.libraryTransfer != nil)
                    Divider()
                    Button("Start Again", action: model.startAgain).disabled(
                        !model.canStartAgain || model.automationModal)
                    Button("Help Me Say This", action: model.startHelp).keyboardShortcut(
                        "h", modifiers: [.command, .shift]
                    ).disabled(!model.canHelp || model.automationModal)
                    Button("Stop") {
                        if model.find.isOpen { model.find.close() } else { model.stop() }
                    }.keyboardShortcut(.escape, modifiers: [])
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
    func attachWindow(_ window: NSWindow, model: AppModel) {
        tray.attach(window, model: model)
        #if MOCHI_DEVELOPMENT
            instanceE2E.attach(window, tray: tray)
        #endif
        SingleInstanceController.shared.revealWorkspace = { [weak self] in self?.tray.showWindow() }
    }
    func attachModel(_ model: AppModel) {
        guard self.model !== model else { return }
        self.model = model
        model.revealWorkspace = { [weak self] in self?.tray.showWindow() }
        model.configureAutomation()
        model.configureShortcuts()
        pet.attach(model)
    }
    func runDevelopmentActions(_ model: AppModel) {
        #if MOCHI_DEVELOPMENT
            if CommandLine.arguments.contains("--tools-probe") {
                toolsProbe(model)
                return
            }
            if CommandLine.arguments.contains("--probe") {
                probe(model)
                return
            }
            if CommandLine.arguments.contains("--smoke-test") { smoke(model) }
            if CommandLine.arguments.contains("--tray-smoke-test")
                || CommandLine.arguments.contains("--single-instance-smoke-test")
            {
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
            let smoke = [
                "--smoke-test", "--tray-smoke-test", "--single-instance-smoke-test", "--tools-probe", "--probe",
            ]
            guard smoke.contains(where: CommandLine.arguments.contains) else { return }
            var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
            guard arguments["AppleLanguages"] == nil else { return }
            arguments["AppleLanguages"] = ["en"]
            UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        #endif
    }
    static var demo: Bool {
        #if MOCHI_DEVELOPMENT
            return [
                "--preview", "--smoke-test", "--tray-smoke-test", "--single-instance-smoke-test", "--tools-probe",
                "--probe",
            ].contains { CommandLine.arguments.contains($0) }
        #else
            return false
        #endif
    }
}
