import AppKit
import Carbon.HIToolbox
import SwiftUI

/// What the message bar shows: the pill, or the field it opens into, and the text typed there.
@MainActor @Observable final class PetBarState {
    var expanded = false
    var text = ""
}

/// The message bar under the desktop Mochi: a pill with Type and Talk that opens into a field. It hangs from her
/// as a child window, so it moves with her, and it takes the keyboard only while its field is open.
@MainActor final class PetBar: NSObject {
    static let height: CGFloat = 32
    static let pillWidth: CGFloat = 72
    static let fieldWidth: CGFloat = 280
    /// The space between her feet and the bar.
    static let gap: CGFloat = 4
    /// Room kept under her for the bar, so placing her never pushes it off the screen.
    static let reserve = height + gap

    let state = PetBarState()
    let panel: NSPanel
    private weak var model: AppModel?

    init(model: AppModel) {
        self.model = model
        let panel = BarPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.pillWidth, height: Self.height),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.canHide = false
        panel.isReleasedWhenClosed = false
        panel.title = String(localized: "Desktop Mochi Message Bar")
        self.panel = panel
        super.init()
        panel.accepts = { [weak self] in self?.state.expanded == true }
        panel.escape = { [weak self] in self?.close() }
        let content = BarHostingView(
            rootView: PetBarView(
                app: model, bar: state, open: { [weak self] in self?.open() },
                close: { [weak self] in self?.close() }, send: { [weak self] in self?.send() }))
        panel.contentView = Self.glass(around: content)
        // A selector observer is removed with the bar; a block observer would outlive it.
        NotificationCenter.default.addObserver(
            self, selector: #selector(resignedKey), name: NSWindow.didResignKeyNotification, object: panel)
    }

    /// Clicking elsewhere puts an empty field away; typed text keeps it open to come back to.
    @objc private func resignedKey() {
        guard state.expanded, state.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        state.expanded = false
        layout()
    }

    /// A rounded glass capsule around the bar's controls.
    private static func glass(around content: NSView) -> NSView {
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = height / 2
            glass.contentView = content
            return glass
        }
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        let radius = height / 2
        let mask = NSImage(size: NSSize(width: height, height: height), flipped: false) { rect in
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
        mask.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        mask.resizingMode = .stretch
        effect.maskImage = mask
        content.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            content.topAnchor.constraint(equalTo: effect.topAnchor),
            content.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        return effect
    }

    /// Hangs the bar under her window and shows it.
    func attach(to pet: NSWindow) {
        if panel.parent !== pet {
            panel.parent?.removeChildWindow(panel)
            pet.addChildWindow(panel, ordered: .above)
        }
        layout()
        panel.orderFrontRegardless()
    }

    func detach() {
        state.expanded = false
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    /// Centres the bar under her, kept on the screen that holds her.
    func layout() {
        guard let pet = panel.parent else { return }
        let width = state.expanded ? Self.fieldWidth : Self.pillWidth
        let screen = NSScreen.screens.map(\.visibleFrame).first {
            $0.contains(CGPoint(x: pet.frame.midX, y: pet.frame.midY))
        }
        panel.setFrame(Self.frame(below: pet.frame, width: width, screen: screen), display: true)
        panel.invalidateShadow()
    }

    /// The bar's frame under a window at `pet`: centred, then moved sideways as needed to stay on `screen`.
    static func frame(below pet: CGRect, width: CGFloat, screen: CGRect?) -> CGRect {
        var x = pet.midX - width / 2
        if let screen { x = min(max(x, screen.minX), screen.maxX - width) }
        return CGRect(x: x, y: pet.minY - gap - height, width: width, height: height)
    }

    // MARK: Actions

    /// Opens the field and takes the keyboard without bringing the workspace forward.
    func open() {
        state.expanded = true
        layout()
        // Builds the field now, so it can be focused at once.
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.makeKeyAndOrderFront(nil)
        // SwiftUI focus set on appearing is ignored in a panel that never activates the app; AppKit's is not.
        if let field = panel.contentView.flatMap(Self.editableField) { panel.makeFirstResponder(field) }
    }

    /// The bar's text field: the first editable NSTextField under `view`.
    private static func editableField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable { return field }
        return view.subviews.lazy.compactMap(editableField).first
    }

    /// Puts the field away, keeping what was typed, and gives the keyboard back to the app that had it.
    func close() {
        state.expanded = false
        layout()
        guard panel.isKeyWindow, let pet = panel.parent else { return }
        // A panel that never activated the app lets go of the keyboard only by leaving the screen.
        pet.removeChildWindow(panel)
        panel.orderOut(nil)
        pet.addChildWindow(panel, ordered: .above)
        layout()
        panel.orderFrontRegardless()
    }

    func send() {
        guard let model, model.sendFromDesktop(state.text) else { return }
        state.text = ""
        close()
    }
}

/// Takes the keyboard only while its field is open, so a click on the pill leaves the app you are in active.
private final class BarPanel: NSPanel {
    var accepts: () -> Bool = { false }
    /// Puts the field away.
    var escape: () -> Void = {}
    override var canBecomeKey: Bool { accepts() }
    override var canBecomeMain: Bool { false }
    /// Escape puts the field away. It is taken here, before the field editor, which treats Escape as a request to
    /// complete the word; while an input method is composing, Escape belongs to the composition.
    override func sendEvent(_ event: NSEvent) {
        if PetBar.isEscape(event), (firstResponder as? NSTextView)?.hasMarkedText() != true {
            escape()
            return
        }
        super.sendEvent(event)
    }
}

extension PetBar {
    /// Escape pressed alone.
    static func isEscape(_ event: NSEvent) -> Bool {
        event.type == .keyDown && event.keyCode == UInt16(kVK_Escape) && Shortcut.Modifiers(event.modifierFlags).isEmpty
    }
}

/// Lets the first click on a button act, although the bar's window is not key.
private final class BarHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct PetBarView: View {
    @Bindable var app: AppModel
    @Bindable var bar: PetBarState
    let open: () -> Void
    let close: () -> Void
    let send: () -> Void

    var body: some View {
        Group {
            if bar.expanded { field } else { pill }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12)))
    }

    private var pill: some View {
        HStack(spacing: 0) {
            Button(action: open) {
                Image(systemName: "square.and.pencil").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .help(Text("Type a Message"))
            .accessibilityLabel(Text("Type a Message"))
            Button {
                app.quickTalk()
            } label: {
                Image(systemName: voiceSymbol).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .help(app.quickTalkLabel)
            .accessibilityLabel(app.quickTalkLabel)
            .disabled(app.quickTalkPlan == .busy)
        }
        .buttonStyle(.plain).font(.system(size: 13, weight: .medium)).foregroundStyle(.primary)
        .padding(.horizontal, 4)
    }

    /// Talk's symbol: the waveform to start, a dot while recording, and pause or play while a reply plays.
    private var voiceSymbol: String {
        if app.turn.activity == .recording { return "circle.fill" }
        if app.quickTalkPlan == .pause { return app.audio.paused ? "play.fill" : "pause.fill" }
        return "waveform"
    }

    private var field: some View {
        HStack(spacing: 6) {
            Button(action: app.newChat) {
                Image(systemName: "plus").font(.system(size: 13, weight: .medium)).frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // The main menu's rule: a new conversation would discard a practice attempt or an open edit.
            .disabled(!MainMenuState(app: app).newConversation)
            .help(Text("New Conversation"))
            .accessibilityLabel(Text("New Conversation"))
            TextField("Message \(app.displayCharacterName)", text: $bar.text)
                .textFieldStyle(.plain).font(.system(size: 13))
                .onSubmit(send)
                .accessibilityIdentifier("desktop-pet-message")
            Button(action: send) {
                Image(systemName: "arrow.up").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(canSend ? Color.accentColor : Color.secondary.opacity(0.4)))
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .help(Text("Send Message"))
            .accessibilityLabel(Text("Send Message"))
        }
        .padding(.leading, 6).padding(.trailing, 5)
    }

    private var canSend: Bool {
        !app.busy && !bar.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
