import AppKit
import MochiCore

/// Mochi on the desktop: a small transparent window that mirrors the conversation and talks on a click.
/// She reads the app's state on every tick and owns none of it.
@MainActor final class DesktopPet: NSObject {
    static let size = NSSize(width: 96, height: 104)
    /// How far from the screen's edges she first appears.
    static let margin: CGFloat = 24
    /// A press that moves further than this is a drag, not a click.
    static let dragThreshold: CGFloat = 3
    /// She looks at the pointer only while it is moving, then goes back to breathing.
    static let gazeLinger: TimeInterval = 2
    /// One slow breath while she is idle: seconds per breath, and how much taller and wider she is at its top.
    static let breath = (period: 4.0, rise: 1.025, widen: 1.01)
    /// The system's Reduce Motion setting; replaceable so tests can turn it on.
    var reducesMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private(set) var panel: NSPanel?
    /// The message bar under her, made the first time it is shown.
    private(set) var bar: PetBar?
    private var view: PetView?
    private weak var model: AppModel?
    /// Kept here because menu items hold their target weakly.
    private var menuBuilder: MochiMenu?
    private let sprite: PetSprite
    private lazy var body = PetSprite.BodyMask(sprite)
    private var timer: Timer?
    private var pose = PetPose.idle
    private var poseStarted = Date()
    /// When she last appeared; she waves for one loop from then.
    private(set) var arrived = Date.distantPast
    private var failedUntil = Date.distantPast
    private var lastError: String?
    private var pointer = CGPoint.zero
    private var pointerMoved = Date.distantPast
    private var screensObserver: NSObjectProtocol?
    /// Pointer movement in any app, so clicks are routed as soon as the pointer moves rather than on the next tick.
    private var pointerMonitors: [Any] = []

    init(sprite: PetSprite = .shared) {
        self.sprite = sprite
        super.init()
    }

    func attach(_ model: AppModel) {
        self.model = model
        menuBuilder = MochiMenu(model: model, context: .desktopMochi)
        model.updateDesktopPet = { [weak self] in self?.update() }
        update()
    }

    /// Shows or hides her to match the preference.
    func update() {
        guard let model, model.petVisible, sprite.isLoaded else {
            hide()
            return
        }
        show(model)
    }

    private func show(_ model: AppModel) {
        let panel = self.panel ?? makePanel()
        if !panel.isVisible {
            _ = body
            panel.setFrameOrigin(
                Self.origin(stored: model.settings.petOrigin, screens: Self.screens, below: reserve(model)))
            arrived = Date()
            lastError = model.error
            panel.orderFrontRegardless()
        }
        if model.petBarVisible {
            // Turning the bar on can leave her too low for it.
            keepOnScreen()
            let bar = self.bar ?? PetBar(model: model)
            self.bar = bar
            bar.attach(to: panel)
        } else {
            bar?.detach()
        }
        if timer == nil {
            let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick(Date()) }
            }
            // The common modes keep her moving while a menu is open or she is being dragged.
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        if pointerMonitors.isEmpty {
            let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
            if let global = NSEvent.addGlobalMonitorForEvents(
                matching: events,
                handler: { [weak self] _ in
                    MainActor.assumeIsolated { self?.routeClicks(at: NSEvent.mouseLocation) }
                })
            {
                pointerMonitors.append(global)
            }
            if let local = NSEvent.addLocalMonitorForEvents(
                matching: events,
                handler: { [weak self] event in
                    MainActor.assumeIsolated { self?.routeClicks(at: NSEvent.mouseLocation) }
                    return event
                })
            {
                pointerMonitors.append(local)
            }
        }
        if screensObserver == nil {
            screensObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.keepOnScreen() }
            }
        }
        tick(Date())
    }

    private func hide() {
        timer?.invalidate()
        timer = nil
        if let screensObserver { NotificationCenter.default.removeObserver(screensObserver) }
        screensObserver = nil
        for monitor in pointerMonitors { NSEvent.removeMonitor(monitor) }
        pointerMonitors = []
        bar?.detach()
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = PetPanel(
            contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        // Closing the workspace to the tray hides the app; she stays.
        panel.canHide = false
        panel.isReleasedWhenClosed = false
        panel.title = String(localized: "Desktop Mochi")
        let view = PetView(frame: NSRect(origin: .zero, size: Self.size))
        view.pet = self
        panel.contentView = view
        self.panel = panel
        self.view = view
        return panel
    }

    // MARK: Mirroring

    func tick(_ now: Date) {
        guard let model, let view else { return }
        updatePose(model, now: now)
        let mouse = NSEvent.mouseLocation
        if mouse != pointer {
            pointer = mouse
            pointerMoved = now
        }
        let cell = currentCell(now: now, mouse: mouse, gaze: model.settings.petFollowsPointer)
        currentFrame = cell
        view.show(sprite.cell(row: cell.row, column: cell.column))
        view.breathe(pose == .idle && !reducesMotion())
        routeClicks(at: mouse)
        describe(model, in: view)
    }

    private func updatePose(_ model: AppModel, now: Date) {
        if model.error != lastError {
            if model.error != nil { failedUntil = now.addingTimeInterval(PetPose.failed.cycle * 2) }
            lastError = model.error
        }
        let situation = PetSituation(
            activity: model.turn.activity, speaking: model.speaking, paused: model.audio.paused,
            greeting: model.greetingActive, failing: now < failedUntil,
            arriving: now.timeIntervalSince(arrived) < PetPose.waving.cycle,
            listening: model.listening.microphoneOpen)
        if situation.pose != pose {
            pose = situation.pose
            poseStarted = now
        }
    }

    /// The pose's current frame, or, when her eyes follow the pointer, a glance at it while she is idle and it moves.
    private func currentCell(now: Date, mouse: CGPoint, gaze following: Bool) -> (row: Int, column: Int) {
        let still = reducesMotion()
        if following, pose == .idle, !still, now.timeIntervalSince(pointerMoved) < Self.gazeLinger, let panel,
            let gaze = PetGaze.cell(dx: mouse.x - panel.frame.midX, dy: mouse.y - panel.frame.midY)
        {
            return gaze
        }
        return (pose.rawValue, still ? 0 : pose.frame(at: now.timeIntervalSince(poseStarted)))
    }

    /// Only her body takes clicks; the transparent corners of the window pass them to what is underneath.
    private func routeClicks(at mouse: CGPoint) {
        guard let panel, let view else { return }
        let local = CGPoint(x: mouse.x - panel.frame.minX, y: mouse.y - panel.frame.minY)
        let onBody = body.contains(x: local.x / panel.frame.width, y: local.y / panel.frame.height)
        panel.ignoresMouseEvents = !(onBody || view.dragging)
    }

    private func describe(_ model: AppModel, in view: PetView) {
        let description = model.error ?? model.status
        if view.toolTip != description {
            view.toolTip = description
            view.setAccessibilityValue(description)
        }
        view.setAccessibilityLabel(model.quickTalkLabel)
    }

    var currentPose: PetPose { pose }
    /// The cell drawn on the last tick.
    private(set) var currentFrame = (row: 0, column: 0)

    // MARK: Interaction

    func clicked() { model?.quickTalk() }

    func moved(to origin: CGPoint) {
        guard let panel, let model else { return }
        let placed = Self.origin(stored: origin, screens: Self.screens, below: reserve(model))
        panel.setFrameOrigin(placed)
        model.settings.petOrigin = placed
        bar?.layout()
    }

    /// Room kept under her for the message bar while it shows.
    private func reserve(_ model: AppModel) -> CGFloat { model.petBarVisible ? PetBar.reserve : 0 }

    /// Her context menu, the one the menu bar icon shows with her own settings item.
    func menu() -> NSMenu { menuBuilder?.menu() ?? NSMenu() }

    private func keepOnScreen() {
        guard let panel, panel.isVisible, let model else { return }
        panel.setFrameOrigin(Self.origin(stored: panel.frame.origin, screens: Self.screens, below: reserve(model)))
        bar?.layout()
    }

    // MARK: Placement

    static var screens: [CGRect] { NSScreen.screens.map(\.visibleFrame) }

    /// Where she sits: the stored spot kept fully on the screen that holds her centre, or the bottom right corner
    /// of the first screen when no screen holds it any more. `below` is room kept free under her, for the bar.
    static func origin(stored: CGPoint?, screens: [CGRect], below: CGFloat = 0) -> CGPoint {
        guard let first = screens.first else { return stored ?? .zero }
        if let stored, stored.x.isFinite, stored.y.isFinite,
            let screen = screens.first(where: {
                $0.contains(CGPoint(x: stored.x + size.width / 2, y: stored.y + size.height / 2))
            })
        {
            return CGPoint(
                x: min(max(stored.x, screen.minX), screen.maxX - size.width),
                y: min(max(stored.y, screen.minY + below), screen.maxY - size.height))
        }
        return CGPoint(x: first.maxX - size.width - margin, y: first.minY + margin + below)
    }
}

/// A window that never takes focus, so clicking Mochi leaves the app you are typing in active.
private final class PetPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Draws the current cell and turns presses into clicks, drags and the menu.
final class PetView: NSView {
    weak var pet: DesktopPet?
    private(set) var dragging = false
    private(set) var breathing = false
    /// The cell, scaled from her feet so a breath never lifts her off the ground.
    private let cell = CALayer()
    private var pressStart: CGPoint?
    private var originAtPress: CGPoint?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        cell.contentsGravity = .resizeAspect
        cell.magnificationFilter = .trilinear
        cell.minificationFilter = .trilinear
        cell.anchorPoint = CGPoint(x: 0.5, y: 0)
        cell.bounds = bounds
        cell.position = CGPoint(x: bounds.midX, y: 0)
        // A new frame replaces the last at once; a layer's default would cross-fade them.
        cell.actions = ["contents": NSNull()]
        layer?.addSublayer(cell)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { nil }

    func show(_ image: CGImage?) {
        guard let image, (cell.contents as AnyObject?) !== image else { return }
        cell.contents = image
    }

    /// Starts or stops one slow breath after another. Core Animation runs it, so it stays smooth between ticks.
    func breathe(_ on: Bool) {
        guard on != breathing else { return }
        breathing = on
        guard on else {
            cell.removeAnimation(forKey: "breath")
            return
        }
        let breath = CABasicAnimation(keyPath: "transform")
        breath.fromValue = CATransform3DIdentity
        breath.toValue = CATransform3DMakeScale(DesktopPet.breath.widen, DesktopPet.breath.rise, 1)
        breath.duration = DesktopPet.breath.period / 2
        breath.autoreverses = true
        breath.repeatCount = .infinity
        breath.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        cell.add(breath, forKey: "breath")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            showMenu(event)
            return
        }
        pressStart = NSEvent.mouseLocation
        originAtPress = window?.frame.origin
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pressStart, let originAtPress, let window else { return }
        let now = NSEvent.mouseLocation
        let dx = now.x - pressStart.x
        let dy = now.y - pressStart.y
        if !dragging && (dx * dx + dy * dy).squareRoot() > DesktopPet.dragThreshold { dragging = true }
        if dragging { window.setFrameOrigin(CGPoint(x: originAtPress.x + dx, y: originAtPress.y + dy)) }
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            pressStart = nil
            originAtPress = nil
            dragging = false
        }
        guard pressStart != nil else { return }
        if dragging, let origin = window?.frame.origin {
            pet?.moved(to: origin)
        } else {
            pet?.clicked()
        }
    }

    override func rightMouseDown(with event: NSEvent) { showMenu(event) }

    private func showMenu(_ event: NSEvent) {
        guard let menu = pet?.menu() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func accessibilityPerformPress() -> Bool {
        pet?.clicked()
        return true
    }
}
