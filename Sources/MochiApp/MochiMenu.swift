import AppKit

/// The menu the menu bar icon and the desktop Mochi share. It is filled again each time it opens, so every title,
/// enablement and shortcut reflects the moment it is shown.
@MainActor final class MochiMenu: NSObject {
    enum Context { case tray, desktopMochi }

    /// Longer status text is cut here, so one long error cannot make the menu as wide as the screen.
    static let statusLimit = 60

    private weak var model: AppModel?
    let context: Context

    init(model: AppModel, context: Context) {
        self.model = model
        self.context = context
        super.init()
    }

    /// A new menu, for a presentation that builds its menu when it opens.
    func menu() -> NSMenu {
        let menu = NSMenu()
        fill(menu)
        return menu
    }

    /// Replaces the menu's items with the current ones.
    func fill(_ menu: NSMenu) {
        menu.removeAllItems()
        // Enablement is set here from the model's rules; AppKit's validation would enable every targeted item.
        menu.autoenablesItems = false
        guard let model else { return }
        let description = model.error ?? model.status
        let status = menu.addItem(withTitle: Self.truncated(description), action: nil, keyEquivalent: "")
        status.isEnabled = false
        if status.title != description { status.toolTip = description }
        menu.addItem(.separator())

        // The talk item names what a click on her does now; it is left out when that would open the workspace or
        // do nothing.
        var talkTitle: String?
        if [.microphone, .pause].contains(model.quickTalkPlan) {
            talkTitle = model.quickTalkLabel
            add(model.quickTalkLabel, #selector(talk), to: menu, shortcut: .talk)
        }
        // Hands-free, the talk item already starts and stops listening.
        if talkTitle != model.listeningMenuTitle {
            add(model.listeningMenuTitle, #selector(toggleListening), to: menu, shortcut: .listen).isEnabled =
                model.listening.isOn || model.canStartListening
        }
        add(String(localized: "New Conversation"), #selector(newConversation), to: menu).isEnabled =
            !model.automationModal
        menu.addItem(.separator())

        add(String(localized: "Open Mochi"), #selector(openWorkspace), to: menu)
        switch context {
        case .tray: add(String(localized: "Settings…"), #selector(openSettings), to: menu)
        case .desktopMochi: add(String(localized: "Desktop Mochi Settings…"), #selector(openSettings), to: menu)
        }
        menu.addItem(.separator())

        add(
            model.petVisible ? String(localized: "Hide Desktop Mochi") : String(localized: "Show Desktop Mochi"),
            #selector(togglePet), to: menu, shortcut: .togglePet)
        if model.petVisible {
            add(
                model.petBarVisible ? String(localized: "Hide Message Bar") : String(localized: "Show Message Bar"),
                #selector(toggleBar), to: menu)
        }
        menu.addItem(.separator())
        // No key equivalent: ⌘Q closes the window to the tray, and this one must never be pressed by accident.
        add(String(localized: "Quit Mochi Completely"), #selector(quit), to: menu)
    }

    @discardableResult private func add(
        _ title: String, _ action: Selector, to menu: NSMenu, shortcut: ShortcutAction? = nil
    ) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        item.target = self
        if let shortcut, let model, let key = Self.keyEquivalent(for: shortcut, in: model) {
            item.keyEquivalent = key.key
            item.keyEquivalentModifierMask = key.modifiers
        }
        return item
    }

    /// A global shortcut as a key equivalent, shown for display only: these menus are never in the main menu, and
    /// the hot key does the work. A shortcut that is not installed, or that a menu cannot name exactly (a number-pad
    /// key looks like the top-row key there), shows none rather than a wrong one.
    static func keyEquivalent(for action: ShortcutAction, in model: AppModel)
        -> (key: String, modifiers: NSEvent.ModifierFlags)?
    {
        guard let shortcut = model.settings.shortcuts[action], model.shortcuts.problems[action] == nil,
            !Shortcut.keypadKeys.contains(Int(shortcut.keyCode)), let key = shortcut.keyEquivalent
        else { return nil }
        return (String(key.character), shortcut.modifiers.flags)
    }

    /// The text's first line, cut to `statusLimit`, with an ellipsis wherever anything was left out.
    static func truncated(_ text: String) -> String {
        let line = String(text.prefix { !$0.isNewline })
        if line.count > statusLimit { return String(line.prefix(statusLimit - 1)) + "…" }
        return line == text ? text : line + "…"
    }

    @objc private func talk() { model?.quickTalk() }
    @objc private func toggleListening() { model?.toggleListening() }
    @objc private func newConversation() {
        guard let model else { return }
        model.newChat()
        model.revealWorkspace?()
    }
    @objc private func openWorkspace() { model?.revealWorkspace?() }
    @objc private func openSettings() {
        guard let model else { return }
        model.revealWorkspace?()
        model.settingsTab = context == .tray ? .general : .desktopMochi
        model.settingsOpen = true
    }
    @objc private func togglePet() { model?.petVisible.toggle() }
    @objc private func toggleBar() { model?.petBarVisible.toggle() }
    @objc private func quit() { NSApp.terminate(nil) }
}
