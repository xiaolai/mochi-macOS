import MochiCore
import XCTest

@testable import MochiApp

/// When the main menu's commands can act. The menu takes every enablement from `MainMenuState`.
final class MainMenuTests: XCTestCase {
    /// A writable conversation, out of practice.
    @MainActor private func conversationApp() -> AppModel {
        let app = makeApp(demo: true)
        app.resume()
        app.newChat()
        addTeardownBlock { @MainActor in app.stop() }
        return app
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
}
