import AppKit
import SwiftUI

/// Retains the workspace when Close is used; explicit Quit still terminates.
@MainActor final class TrayController: NSObject, NSWindowDelegate {
    private(set) var statusItem: NSStatusItem?
    private(set) var window: NSWindow?
    private weak var previousDelegate: NSWindowDelegate?
    private weak var model: AppModel?

    func install() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength:NSStatusItem.squareLength)
        item.button?.image = Self.icon()
        item.button?.toolTip = "Mochi"
        item.button?.setAccessibilityLabel("Mochi")
        let menu = NSMenu()
        let show = menu.addItem(withTitle:"Open Mochi",action:#selector(showWindow),keyEquivalent:"")
        show.target = self
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle:"Quit Mochi",action:#selector(quitApp),keyEquivalent:"q")
        quit.target = self
        item.menu = menu
        statusItem = item
    }

    func attach(_ window: NSWindow, model: AppModel) {
        guard self.window !== window else { return }
        self.window = window
        self.model = model
        previousDelegate = window.delegate
        window.delegate = self
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        model?.stop()
        model?.save()
        sender.orderOut(nil)
        return false
    }

    @objc func showWindow() {
        guard let window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps:true)
    }

    @objc private func quitApp() { NSApp.terminate(nil) }

    // Preserve SwiftUI's other window delegate callbacks.
    override func responds(to selector: Selector!) -> Bool {
        super.responds(to:selector) || (previousDelegate?.responds(to:selector) ?? false)
    }
    override func forwardingTarget(for selector: Selector!) -> Any? {
        if previousDelegate?.responds(to:selector) == true { return previousDelegate }
        return super.forwardingTarget(for:selector)
    }

    /// Original halo-free Mochi proportions, simplified to a menu-bar template.
    static func icon() -> NSImage {
        let image = NSImage(size:NSSize(width:20,height:18),flipped:true) { _ in
            let body = NSBezierPath()
            body.move(to:NSPoint(x:1,y:12))
            body.curve(to:NSPoint(x:10,y:2),controlPoint1:NSPoint(x:1,y:7),controlPoint2:NSPoint(x:5.5,y:2))
            body.curve(to:NSPoint(x:19,y:12),controlPoint1:NSPoint(x:14.5,y:2),controlPoint2:NSPoint(x:19,y:7))
            body.curve(to:NSPoint(x:10,y:16),controlPoint1:NSPoint(x:19,y:15),controlPoint2:NSPoint(x:16,y:16))
            body.curve(to:NSPoint(x:1,y:12),controlPoint1:NSPoint(x:4,y:16),controlPoint2:NSPoint(x:1,y:15))
            body.close()
            body.windingRule = .evenOdd
            body.appendOval(in:NSRect(x:6,y:8,width:2,height:2))
            body.appendOval(in:NSRect(x:12,y:8,width:2,height:2))
            let smile = NSBezierPath()
            smile.move(to:NSPoint(x:7,y:12))
            smile.line(to:NSPoint(x:13,y:12))
            smile.curve(to:NSPoint(x:7,y:12),controlPoint1:NSPoint(x:12.5,y:14),controlPoint2:NSPoint(x:7.5,y:14))
            smile.close()
            body.append(smile)
            NSColor.black.setFill()
            body.fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}

struct MainWindowReader: NSViewRepresentable {
    var attach: (NSWindow) -> Void
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { if let window = view.window { attach(window) } }
    }
}
