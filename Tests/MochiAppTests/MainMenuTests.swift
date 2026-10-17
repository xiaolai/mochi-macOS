import AppKit
import Carbon.HIToolbox
import MochiCore
import XCTest

@testable import MochiApp

/// When the main menu's commands can act. The menu takes every enablement from `MainMenuState`.
final class MainMenuTests: XCTestCase {
    /// A writable conversation, out of practice, with the workspace in front.
    @MainActor private func conversationApp() -> AppModel {
        let app = makeApp(demo: true)
        app.resume()
        app.newChat()
        app.workspaceKey = true
        addTeardownBlock { @MainActor in app.stop() }
        return app
    }

    @MainActor func testStopIsOffWhenNothingCanBeStopped() {
        let app = conversationApp()
        let menu = MainMenuState(app: app)
        XCTAssertFalse(app.canStop)
        XCTAssertFalse(menu.stop, "Escape must reach the focused field when there is nothing to stop")
    }

    @MainActor func testStopCoversEverythingStopEnds() {
        for activity in [Activity.generating, .playing, .recording, .requestingPermission] {
            let app = conversationApp()
            _ = app.turn.begin(activity)
            XCTAssertTrue(MainMenuState(app: app).stop, "\(activity)")
        }
        let listening = conversationApp()
        _ = listening.listening.handle(.start(now: Date(), blockers: []))
        XCTAssertTrue(listening.listening.isOn)
        XCTAssertTrue(MainMenuState(app: listening).stop, "Listening")
        let permission = conversationApp()
        permission.listeningRequest = UUID()
        XCTAssertTrue(MainMenuState(app: permission).stop, "Listening waiting for microphone permission")
        let transcribing = conversationApp()
        _ = transcribing.transcripts.begin(UUID())
        XCTAssertFalse(
            MainMenuState(app: transcribing).stop,
            "A transcription alone finishes across Stop, so there is nothing to end")
        let find = conversationApp()
        find.find.open()
        XCTAssertFalse(find.canStop)
        XCTAssertTrue(MainMenuState(app: find).stop, "Escape closes Find")
    }

    @MainActor func testStopActsOnlyWhileTheWorkspaceHasTheKeyboard() {
        let app = conversationApp()
        _ = app.turn.begin(.generating)
        app.find.open()
        // Settings, a sheet or the desktop Mochi's message bar has the keyboard.
        app.workspaceKey = false
        let menu = MainMenuState(app: app)
        XCTAssertFalse(menu.stop)
        menu.performStop()
        XCTAssertTrue(app.find.isOpen)
        XCTAssertEqual(app.turn.activity, .generating, "Escape in another window stops nothing")
        app.workspaceKey = true
        menu.performStop()
        XCTAssertFalse(app.find.isOpen, "Find closes first")
        XCTAssertEqual(app.turn.activity, .generating)
        menu.performStop()
        XCTAssertEqual(app.turn.activity, .idle)
    }

    @MainActor func testRenameAndPermanentDeletionWaitForAnyOtherSheet() throws {
        let app = conversationApp()
        let id = try XCTUnwrap(app.selectedID)
        XCTAssertTrue(app.canBeginHistoryEdit)
        app.openConversationInstructions(id)
        XCTAssertTrue(app.customization.isPresented)
        XCTAssertFalse(app.canBeginHistoryEdit, "A rename would queue unseen behind the instructions")
        app.customization.dismiss()
        app.openTemplatePicker()
        XCTAssertFalse(app.canBeginHistoryEdit, "Template picker")
        app.customization.dismiss()
        app.openCharacterManager()
        XCTAssertFalse(app.canBeginHistoryEdit, "Characters")
        app.customization.dismiss()
        XCTAssertTrue(app.canBeginHistoryEdit)
        app.history.renameID = id
        XCTAssertFalse(app.canBeginHistoryEdit, "A rename is already open")
        app.history.renameID = nil
        app.history.permanentDeleteIDs = [id]
        XCTAssertFalse(app.canBeginHistoryEdit, "A permanent deletion is already open")
        app.history.permanentDeleteIDs = []
        app.history.managerOpen = true
        XCTAssertTrue(app.canBeginHistoryEdit, "The manager shows its own rename and deletion")
        app.history.managerOpen = false
        app.turn.pause()
        XCTAssertFalse(app.canBeginHistoryEdit, "Practice")
    }

    @MainActor func testSheetOpeningCommandsWaitWhileAnotherSheetIsOpen() throws {
        let app = conversationApp()
        let menu = MainMenuState(app: app)
        XCTAssertTrue(menu.newConversation)
        XCTAssertTrue(menu.customization)
        XCTAssertTrue(menu.manageConversations)
        XCTAssertTrue(menu.conversationActions)
        XCTAssertTrue(menu.searchAllConversations)
        XCTAssertTrue(menu.libraryTransfer)
        app.openConversationInstructions(try XCTUnwrap(app.selectedID))
        XCTAssertFalse(menu.newConversation)
        XCTAssertFalse(menu.customization)
        XCTAssertFalse(menu.manageConversations)
        XCTAssertFalse(menu.startAgain)
        XCTAssertFalse(menu.helpMeSayThis)
        app.customization.dismiss()
        app.turn.pause()
        XCTAssertFalse(menu.newConversation, "A new conversation would discard the practice attempt")
        XCTAssertFalse(menu.conversationActions)
        XCTAssertFalse(menu.searchAllConversations)
        XCTAssertFalse(menu.findInConversation)
    }

    @MainActor func testBusyBlocksTheCustomizationSheetButNotNewConversation() {
        let app = conversationApp()
        _ = app.turn.begin(.generating)
        let menu = MainMenuState(app: app)
        XCTAssertFalse(menu.customization)
        XCTAssertTrue(menu.newConversation)
    }

    @MainActor func testMatchesAndListeningFollowTheModel() {
        let app = conversationApp()
        let menu = MainMenuState(app: app)
        XCTAssertFalse(menu.moveBetweenMatches)
        XCTAssertEqual(menu.listening, app.listening.isOn || app.canStartListening)
    }

    @MainActor func testASettingsRequestIsTakenOnceWhetherMadeBeforeOrAfterTheWorkspaceAppears() {
        let app = conversationApp()
        XCTAssertFalse(app.takeSettingsRequest())
        // Made before the workspace view exists: the view takes it when it appears.
        app.settingsOpen = true
        XCTAssertTrue(app.takeSettingsRequest())
        XCTAssertFalse(app.settingsOpen, "Taken, so a later request changes the value again")
        XCTAssertFalse(app.takeSettingsRequest())
        app.settingsOpen = true
        XCTAssertTrue(app.takeSettingsRequest())
    }

    /// Escape runs Stop only when pressed in the workspace with no modifier; another window, a modified Escape or
    /// another key goes on to the focused view. Windows are created but never shown: this runs on a Mac in use.
    @MainActor func testOnlyAPlainEscapeInTheWorkspaceIsStopsKey() throws {
        func window() -> NSWindow {
            NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled],
                backing: .buffered, defer: false)
        }
        let workspace = window()
        let other = window()
        func key(_ code: Int, _ characters: String, _ flags: NSEvent.ModifierFlags = [], in target: NSWindow) throws
            -> NSEvent
        {
            try XCTUnwrap(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                    windowNumber: target.windowNumber, context: nil, characters: characters,
                    charactersIgnoringModifiers: characters, isARepeat: false, keyCode: UInt16(code)))
        }
        XCTAssertTrue(MainMenuState.isPlainEscape(try key(kVK_Escape, "\u{1b}", in: workspace), in: workspace))
        XCTAssertFalse(
            MainMenuState.isPlainEscape(try key(kVK_Escape, "\u{1b}", in: other), in: workspace), "Another window")
        XCTAssertFalse(
            MainMenuState.isPlainEscape(try key(kVK_Escape, "\u{1b}", .option, in: workspace), in: workspace),
            "A modified Escape")
        XCTAssertFalse(
            MainMenuState.isPlainEscape(try key(kVK_ANSI_A, "a", in: workspace), in: workspace), "Another key")
    }
}
