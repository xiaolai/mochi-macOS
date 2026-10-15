import AppKit
import MochiKernel
import SwiftUI

/// Close and ⌘Q retain the workspace; Quit Mochi Completely terminates.
@MainActor final class TrayController: NSObject, NSWindowDelegate, NSMenuDelegate {
    /// The workspace window's scene.
    static let workspaceWindowID = "main"
    private(set) var statusItem: NSStatusItem?
    private(set) var window: NSWindow?
    /// SwiftUI's action that creates the workspace window, which the app's commands provide once SwiftUI builds them.
    var openWorkspace: (() -> Void)? {
        didSet { if openPending { openWorkspaceIfUnopened() } }
    }
    /// A request to open the workspace that arrived before SwiftUI provided the action.
    private var openPending = false
    /// Takes SwiftUI's action for opening windows, the only way to create the workspace window.
    func adopt(_ openWindow: OpenWindowAction) {
        openWorkspace = { openWindow(id: Self.workspaceWindowID) }
    }
    private(set) var menu: NSMenu?
    /// Set by install(), which creates the status item the menu is shown from.
    var presentMenu: (NSMenu, NSEvent, NSView) -> Void = { _, _, _ in }
    private weak var previousDelegate: NSWindowDelegate?
    private weak var model: AppModel?
    private(set) var petItem: NSMenuItem?
    /// Told when the workspace window is ordered out or shown here, which posts no notification of its own.
    var visibilityChanged: (() -> Void)?

    func install() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Self.icon()
        item.button?.toolTip = "Mochi"
        item.button?.setAccessibilityLabel("Mochi")
        let menu = NSMenu()
        let show = menu.addItem(
            withTitle: String(localized: "Open Mochi"), action: #selector(showWindow), keyEquivalent: "")
        show.target = self
        let pet = menu.addItem(
            withTitle: String(localized: "Show Desktop Mochi"), action: #selector(togglePet), keyEquivalent: "")
        pet.target = self
        petItem = pet
        menu.delegate = self
        menu.addItem(.separator())
        let quit = menu.addItem(
            withTitle: String(localized: "Quit Mochi Completely"), action: #selector(quitApp), keyEquivalent: "")
        quit.target = self
        self.menu = menu
        item.button?.target = self
        item.button?.action = #selector(clicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
        presentMenu = { [weak item] menu, _, _ in
            guard let item else { return }
            item.menu = menu
            defer { item.menu = nil }
            item.button?.performClick(nil)
        }
    }

    @objc private func clicked() {
        guard let event = NSApp.currentEvent else { return }
        handleClick(event)
    }

    func handleClick(_ event: NSEvent) {
        if event.type == .rightMouseUp || (event.type == .leftMouseUp && event.modifierFlags.contains(.control)) {
            guard let menu, let button = statusItem?.button else { return }
            presentMenu(menu, event, button)
        } else if event.type == .leftMouseUp {
            showWindow()
        }
    }

    func attach(_ window: NSWindow, model: AppModel) {
        guard self.window !== window else { return }
        // The replaced window gets its own delegate back, so its callbacks never act on the new window's state.
        if let old = self.window, old.delegate === self { old.delegate = previousDelegate }
        self.window = window
        self.model = model
        previousDelegate = window.delegate
        window.delegate = self
    }

    /// Ends in-progress work and saves. False only when a readable library could not be written.
    static func finishWork(_ model: AppModel) -> Bool {
        let saved = model.stop()
        return !model.libraryReadable || saved
    }

    /// Hiding the workspace is refused while its latest changes are unsaved, so the failure stays visible.
    private func finishWork() -> Bool {
        guard let model else { return true }
        return Self.finishWork(model)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === window else { return true }
        guard finishWork() else { return false }
        sender.orderOut(nil)
        visibilityChanged?()
        return false
    }

    @objc func closeToTray() {
        guard finishWork() else { return }
        window?.orderOut(nil)
        visibilityChanged?()
        // Hide settings and attached panels too, while retaining the status item.
        NSApp.hide(nil)
        NSApp.setActivationPolicy(.accessory)
    }

    /// Has SwiftUI create the workspace window when there is none, as after a launch that restored a session which
    /// ended with the window hidden here: AppKit restores no window, and SwiftUI then opens none of its own. The new
    /// window attaches itself. Returns whether one was asked for; without SwiftUI's action yet, the request waits.
    @discardableResult func openWorkspaceIfUnopened() -> Bool {
        openPending = false
        guard window == nil else { return false }
        guard let openWorkspace else {
            openPending = true
            MochiLog.app.error("The workspace window is not open; it opens once SwiftUI provides the action")
            return false
        }
        openWorkspace()
        return true
    }

    /// Brings the workspace in front for the user's own click or keypress: the menu bar icon and its menu, the
    /// desktop Mochi, a shortcut, or opening Mochi again.
    @objc func showWindow() { show(forced: true) }

    /// Shows the workspace for a request from another app without taking the keyboard from the app in front.
    func offerWindow() { show(forced: false) }

    /// Since macOS 14 activation is cooperative, and the system refuses Mochi's polite request even right after a
    /// click on its menu bar icon or the desktop Mochi: the click belongs to the menu bar and the non-activating
    /// panel, not to Mochi. Only a forced activation brings it in front, so it is kept for the user's own actions.
    private func show(forced: Bool) {
        let activate = forced ? { (NSApp as ForcedActivation).activateIgnoringOtherApps() } : { NSApp.activate() }
        guard let window else {
            if openWorkspaceIfUnopened() { activate() }
            return
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.unhide(nil)
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        visibilityChanged?()
        activate()
    }

    @objc func quitApp() { NSApp.terminate(nil) }

    @objc func togglePet() { model?.petVisible.toggle() }

    func menuNeedsUpdate(_ menu: NSMenu) {
        petItem?.title =
            model?.petVisible == true
            ? String(localized: "Hide Desktop Mochi") : String(localized: "Show Desktop Mochi")
    }

    // Preserve SwiftUI's other window delegate callbacks.
    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || (previousDelegate?.responds(to: selector) ?? false)
    }
    override func forwardingTarget(for selector: Selector!) -> Any? {
        if previousDelegate?.responds(to: selector) == true { return previousDelegate }
        return super.forwardingTarget(for: selector)
    }

    /// Shows in the menu bar whether hands-free listening has the microphone open.
    func showListening(_ listening: Bool) {
        guard let button = statusItem?.button, (button.image === Self.listeningIcon) != listening else { return }
        button.image = listening ? Self.listeningIcon : Self.icon()
        button.setAccessibilityLabel(listening ? String(localized: "Mochi · listening") : "Mochi")
    }
    /// The icon with a dot beside it while Mochi is listening.
    static let listeningIcon: NSImage = {
        let base = icon()
        let image = NSImage(size: NSSize(width: 24, height: 18), flipped: true) { _ in
            base.draw(in: NSRect(x: 0, y: 0, width: 20, height: 18))
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: 18, y: 1, width: 6, height: 6)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }()

    /// Mochi contour only, drawn as a template so macOS supplies the menu-bar color.
    static func icon() -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 18), flipped: true) { _ in
            let body = NSBezierPath()
            body.move(to: NSPoint(x: 1, y: 12))
            body.curve(
                to: NSPoint(x: 10, y: 2), controlPoint1: NSPoint(x: 1, y: 7), controlPoint2: NSPoint(x: 5.5, y: 2))
            body.curve(
                to: NSPoint(x: 19, y: 12), controlPoint1: NSPoint(x: 14.5, y: 2), controlPoint2: NSPoint(x: 19, y: 7))
            body.curve(
                to: NSPoint(x: 10, y: 16), controlPoint1: NSPoint(x: 19, y: 15), controlPoint2: NSPoint(x: 16, y: 16))
            body.curve(
                to: NSPoint(x: 1, y: 12), controlPoint1: NSPoint(x: 4, y: 16), controlPoint2: NSPoint(x: 1, y: 15))
            body.close()
            body.lineWidth = 1.5
            body.lineJoinStyle = .round
            NSColor.black.setStroke()
            body.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// The forced activation that macOS 14 deprecated without a replacement for it. Called through this protocol, it
/// stays in one place and the build stays free of deprecation warnings.
private protocol ForcedActivation { func activateIgnoringOtherApps() }
extension NSApplication: ForcedActivation {
    @available(macOS, deprecated: 14.0, message: "Only for the user's own click; see TrayController.show(forced:)")
    fileprivate func activateIgnoringOtherApps() { activate(ignoringOtherApps: true) }
}

struct MainWindowReader: NSViewRepresentable {
    var attach: (NSWindow) -> Void
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.titleVisibility = .hidden
            window.titlebarSeparatorStyle = .none
            window.toolbar?.displayMode = .iconOnly
            window.toolbar?.allowsUserCustomization = false
            if #available(macOS 15.0, *) { window.toolbar?.allowsDisplayModeCustomization = false }
            attach(window)
        }
    }
}
