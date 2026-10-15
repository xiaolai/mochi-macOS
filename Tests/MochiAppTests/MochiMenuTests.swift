import AppKit
import Carbon.HIToolbox
import MochiCore
import XCTest

@testable import MochiApp

/// The menu the menu bar icon and the desktop Mochi share, built against the model without showing it.
final class MochiMenuTests: XCTestCase {
    /// The builders and models a test's menus use. Both are held weakly, by the items and the builder, as their
    /// owners in the app hold them for as long as it runs.
    private var kept: [AnyObject] = []
    override func tearDown() {
        kept = []
        super.tearDown()
    }

    @MainActor private func builder(_ app: AppModel, _ context: MochiMenu.Context) -> MochiMenu {
        let builder = MochiMenu(model: app, context: context)
        kept += [app, builder]
        return builder
    }

    /// A writable conversation, out of practice, whose first voice message records at once.
    @MainActor private func conversationApp() -> AppModel {
        let app = makeApp(demo: true)
        app.resume()
        app.newChat()
        app.petVisible = true
        return app
    }

    @MainActor private func titles(_ menu: NSMenu) -> [String] { menu.items.map(\.title) }

    @MainActor private func item(_ menu: NSMenu, _ title: String) -> NSMenuItem? {
        menu.items.first { $0.title == title }
    }

    @MainActor func testIdleConversationOffersTalkListeningAndTheRest() {
        let app = conversationApp()
        XCTAssertEqual(app.quickTalkPlan, .microphone)
        let menu = builder(app, .tray).menu()
        XCTAssertEqual(
            titles(menu),
            [
                app.status, "", app.microphoneLabel, app.listeningMenuTitle, "New Conversation", "", "Open Mochi",
                "Settings…", "", "Hide Desktop Mochi", "Hide Message Bar", "", "Quit Mochi Completely",
            ])
        XCTAssertFalse(menu.items[0].isEnabled, "The status line is information, not a command")
        XCTAssertFalse(menu.autoenablesItems)
        XCTAssertEqual(
            item(menu, app.listeningMenuTitle)?.isEnabled, app.listening.isOn || app.canStartListening,
            "Listening follows the rule of the Conversation menu's command")
        XCTAssertEqual(item(menu, "New Conversation")?.isEnabled, true)
        XCTAssertEqual(item(menu, "Quit Mochi Completely")?.keyEquivalent, "", "⌘Q closes to the tray instead")
    }

    @MainActor func testDesktopMochiOffersHerOwnSettings() {
        let menu = builder(conversationApp(), .desktopMochi).menu()
        XCTAssertNotNil(item(menu, "Desktop Mochi Settings…"))
        XCTAssertNil(item(menu, "Settings…"))
        XCTAssertNotNil(item(menu, "Quit Mochi Completely"))
    }

    @MainActor func testRecordingNamesFinishingAndTheStatusSaysSo() {
        let app = conversationApp()
        app.turn.begin(.recording)
        let menu = builder(app, .tray).menu()
        XCTAssertEqual(menu.items[0].title, MochiMenu.truncated(app.status))
        XCTAssertEqual(menu.items[2].title, "Finish Recording")
    }

    @MainActor func testPracticeLeavesTalkOut() {
        // The preview library opens in practice, where talking needs the workspace.
        let app = makeApp(demo: true)
        XCTAssertTrue(app.practice)
        let menu = builder(app, .tray).menu()
        XCTAssertEqual(menu.items[2].title, app.listeningMenuTitle)
        XCTAssertNil(item(menu, app.microphoneLabel))
    }

    @MainActor func testWhileMochiPreparesAReplyThereIsNothingToSay() {
        let app = conversationApp()
        app.turn.begin(.generating)
        XCTAssertEqual(app.quickTalkPlan, .busy)
        let menu = builder(app, .tray).menu()
        XCTAssertEqual(menu.items[0].title, MochiMenu.truncated(app.status))
        XCTAssertEqual(menu.items[2].title, app.listeningMenuTitle, "Talk is left out; listening comes first")
    }

    @MainActor func testHandsFreeTalkIsTheListeningItemOnce() {
        let app = conversationApp()
        app.settings.talkingMode = .handsFree
        XCTAssertEqual(app.microphoneLabel, app.listeningMenuTitle)
        let menu = builder(app, .tray).menu()
        XCTAssertEqual(titles(menu).filter { $0 == app.listeningMenuTitle }.count, 1)
        XCTAssertEqual(menu.items[2].title, app.listeningMenuTitle)
        XCTAssertEqual(menu.items[3].title, "New Conversation")
    }

    @MainActor func testTheMessageBarItemShowsOnlyWhileSheIsVisible() {
        let app = conversationApp()
        app.petVisible = false
        var menu = builder(app, .tray).menu()
        XCTAssertNotNil(item(menu, "Show Desktop Mochi"))
        XCTAssertNil(item(menu, "Hide Message Bar"))
        XCTAssertNil(item(menu, "Show Message Bar"))
        app.petVisible = true
        app.petBarVisible = false
        menu = builder(app, .tray).menu()
        XCTAssertNotNil(item(menu, "Hide Desktop Mochi"))
        XCTAssertNotNil(item(menu, "Show Message Bar"))
    }

    @MainActor func testAnErrorTakesTheStatusLine() {
        let app = conversationApp()
        app.error = "The library could not be saved."
        XCTAssertEqual(builder(app, .tray).menu().items[0].title, "The library could not be saved.")
        let long = String(repeating: "word ", count: 40)
        app.error = long
        let status = builder(app, .tray).menu().items[0]
        XCTAssertEqual(status.title.count, MochiMenu.statusLimit)
        XCTAssertTrue(status.title.hasSuffix("…"))
        XCTAssertEqual(status.toolTip, long, "The whole text stays a hover away")
        XCTAssertEqual(MochiMenu.truncated("First line\nSecond line"), "First line…")
        XCTAssertEqual(MochiMenu.truncated("Short"), "Short")
    }

    @MainActor func testShortcutsShowBesideTheirItems() {
        let app = conversationApp()
        app.settings.shortcuts[.togglePet] = Shortcut(keyCode: UInt16(kVK_F5), modifiers: [.control, .option])
        app.settings.shortcuts[.talk] = Shortcut(keyCode: UInt16(kVK_ANSI_Keypad1), modifiers: [.control])
        app.settings.shortcuts[.listen] = nil
        let menu = builder(app, .tray).menu()
        let pet = item(menu, "Hide Desktop Mochi")
        XCTAssertEqual(pet?.keyEquivalent, String(Character(UnicodeScalar(NSF5FunctionKey)!)))
        XCTAssertEqual(pet?.keyEquivalentModifierMask, [.control, .option])
        XCTAssertEqual(item(menu, app.microphoneLabel)?.keyEquivalent, "", "A number-pad key would show as a wrong key")
        XCTAssertEqual(item(menu, app.listeningMenuTitle)?.keyEquivalent, "", "No shortcut, no key")
        XCTAssertEqual(item(menu, "New Conversation")?.keyEquivalent, "")
    }

    @MainActor func testNewConversationCreatesSelectsAndShowsTheWorkspace() throws {
        // The preview's open conversation has messages, so a new one is made rather than this one reused.
        let app = conversationApp()
        let before = try XCTUnwrap(app.selectedID)
        app.append(Message(role: "user", text: "Hello"), to: before)
        XCTAssertEqual(app.conversation?.isPristine, false, "A pristine conversation would be reused")
        var revealed = 0
        app.revealWorkspace = { revealed += 1 }
        let menu = builder(app, .desktopMochi).menu()
        menu.performActionForItem(at: menu.indexOfItem(withTitle: "New Conversation"))
        XCTAssertNotEqual(app.selectedID, before)
        XCTAssertEqual(app.library.conversations.first?.id, app.selectedID)
        XCTAssertEqual(revealed, 1)
    }

    @MainActor func testSettingsOpensTheTabForItsContext() {
        for (context, title, tab) in [
            (MochiMenu.Context.tray, "Settings…", SettingsTab.general),
            (.desktopMochi, "Desktop Mochi Settings…", .desktopMochi),
        ] {
            let app = conversationApp()
            app.settingsTab = .about
            var revealed = 0
            app.revealWorkspace = { revealed += 1 }
            let menu = builder(app, context).menu()
            menu.performActionForItem(at: menu.indexOfItem(withTitle: title))
            XCTAssertEqual(revealed, 1)
            XCTAssertTrue(app.settingsOpen)
            XCTAssertEqual(app.settingsTab, tab)
        }
    }

    @MainActor func testTogglesFlipThePreferences() {
        let app = conversationApp()
        let shared = builder(app, .tray)
        var menu = shared.menu()
        menu.performActionForItem(at: menu.indexOfItem(withTitle: "Hide Message Bar"))
        XCTAssertFalse(app.petBarVisible)
        menu = shared.menu()
        menu.performActionForItem(at: menu.indexOfItem(withTitle: "Show Message Bar"))
        XCTAssertTrue(app.petBarVisible)
        menu = shared.menu()
        menu.performActionForItem(at: menu.indexOfItem(withTitle: "Hide Desktop Mochi"))
        XCTAssertFalse(app.petVisible)
        menu = shared.menu()
        menu.performActionForItem(at: menu.indexOfItem(withTitle: "Show Desktop Mochi"))
        XCTAssertTrue(app.petVisible)
    }

    @MainActor func testFillingAgainReplacesTheItems() {
        let app = conversationApp()
        let shared = builder(app, .tray)
        let menu = shared.menu()
        let count = menu.items.count
        app.petVisible = false
        shared.fill(menu)
        XCTAssertEqual(menu.items.count, count - 1)
        XCTAssertNotNil(item(menu, "Show Desktop Mochi"))
    }
}
