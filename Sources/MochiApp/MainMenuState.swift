/// When each command of the main menu can act, read from the model. The menu's buttons take their enablement from
/// here, so the rules are tested without building the menu.
@MainActor struct MainMenuState {
    let app: AppModel

    var newConversation: Bool { !app.automationModal }
    /// New from Template, Manage Templates and Manage Characters, which open the customization sheet.
    var customization: Bool { app.canOpenConversationInstructions }
    var findInConversation: Bool { app.canFindInConversation }
    var moveBetweenMatches: Bool { !app.find.matchIDs.isEmpty }
    var searchAllConversations: Bool {
        !app.practice && app.history.renameID == nil && app.history.permanentDeleteIDs.isEmpty
    }
    var manageConversations: Bool { !app.automationModal }
    /// The open conversation's actions; Rename and Delete Permanently also follow `AppModel.canBeginHistoryEdit`.
    var conversationActions: Bool { !app.practice }
    var libraryTransfer: Bool { app.libraryTransfer == nil }
    var startAgain: Bool { app.canStartAgain && !app.automationModal }
    var listening: Bool { app.listening.isOn || app.canStartListening }
    var helpMeSayThis: Bool { app.canHelp && !app.automationModal }
    /// Stop is bound to Escape, and main-menu shortcuts are matched before the key window sees the key. It is enabled
    /// only while the workspace has the keyboard and there is something to end, so everywhere else Escape reaches the
    /// focused field or sheet: the message bar closes, Settings and sheets cancel.
    var stop: Bool { app.workspaceKey && (app.find.isOpen || app.canStop) }

    /// Closes Find when it is open, otherwise stops everything Stop ends.
    func performStop() {
        guard stop else { return }
        if app.find.isOpen { app.find.close() } else { app.stop() }
    }
}
