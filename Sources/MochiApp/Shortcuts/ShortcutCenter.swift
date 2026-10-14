import AppKit
import Carbon.HIToolbox
import MochiKernel

/// The system's global hot key service, replaceable so tests never take a real key.
struct HotKeySystem {
    /// Registers `shortcut` under `id`; returns the Carbon status.
    var register: @MainActor (_ shortcut: Shortcut, _ id: UInt32) -> OSStatus
    var unregisterAll: @MainActor () -> Void
    /// The shortcuts macOS itself has turned on, such as Spotlight's.
    var reserved: @MainActor () -> Set<Shortcut>
    /// Called with the registered id when its keys go down (true) and up (false).
    var onEvent: @MainActor (@escaping @MainActor (UInt32, Bool) -> Void) -> Void

    static var live: HotKeySystem {
        HotKeySystem(
            register: { CarbonHotKeys.shared.register($0, id: $1) },
            unregisterAll: { CarbonHotKeys.shared.unregisterAll() },
            reserved: { CarbonHotKeys.reserved() },
            onEvent: { CarbonHotKeys.shared.handler = $0 })
    }
}

/// Mochi's shortcuts that work in every app: what they are bound to, whether they are on, and why not.
@MainActor @Observable final class ShortcutCenter {
    /// Why an action's shortcut is not working, shown beside it in Settings.
    private(set) var problems: [ShortcutAction: String] = [:]
    /// The action whose shortcut is being recorded. Only one records at a time, and while it does nothing is
    /// registered, so the keys reach the recorder.
    var recordingAction: ShortcutAction? {
        didSet { if (oldValue == nil) != (recordingAction == nil) { apply() } }
    }
    var suspended: Bool { recordingAction != nil }
    @ObservationIgnored var bindings: @MainActor () -> [ShortcutAction: Shortcut] = { [:] }
    @ObservationIgnored var perform: @MainActor (ShortcutAction, _ pressed: Bool) -> Void = { _, _ in }
    /// Menu commands, which a global shortcut would take over while Mochi is in front.
    @ObservationIgnored var menuShortcuts: @MainActor () -> [(title: String, shortcut: Shortcut)] = {
        ShortcutCenter.mainMenuShortcuts()
    }
    @ObservationIgnored private let system: HotKeySystem
    /// Previews and tests never take keys from other apps.
    @ObservationIgnored let enabled: Bool

    init(system: HotKeySystem, enabled: Bool) {
        self.system = system
        self.enabled = enabled
        guard enabled else { return }
        system.onEvent { [weak self] id, pressed in
            guard let self, !self.suspended, let action = Self.action(for: id) else { return }
            self.perform(action, pressed)
        }
    }

    /// Registers the current bindings, replacing whatever was registered before.
    func apply() {
        guard enabled else { return }
        system.unregisterAll()
        var problems: [ShortcutAction: String] = [:]
        if !suspended {
            for (action, shortcut) in bindings() {
                // A shortcut that was free when recorded can clash later, after a layout or menu change. App-only
                // shortcuts are checked too, as one saved by an earlier version may be one menus cannot hold.
                if let conflict = conflict(shortcut, for: action) {
                    problems[action] = conflict
                    continue
                }
                guard action.isGlobal else { continue }
                let status = system.register(shortcut, Self.id(for: action))
                guard status != noErr else { continue }
                problems[action] =
                    status == eventHotKeyExistsErr
                    ? String(localized: "Another app is using this shortcut. Choose a different one.")
                    : String(localized: "This shortcut could not be turned on. Choose a different one.")
                MochiLog.failure(
                    MochiLog.app, "Register shortcut \(action.rawValue)",
                    AppFailure(verbatim: "Carbon status \(status)."),
                    level: .default)
            }
        }
        self.problems = problems
    }

    /// Why `shortcut` cannot be used for `action`, or nil when it can.
    func conflict(_ shortcut: Shortcut, for action: ShortcutAction) -> String? {
        if let problem = shortcut.problem { return problem }
        // An app-only shortcut works through its menu item, which would also answer the top-row key.
        if !action.isGlobal && Shortcut.keypadKeys.contains(Int(shortcut.keyCode)) {
            return String(
                localized: "Menus can’t tell number-pad keys from the same keys above the letters. Choose another key.")
        }
        if let other = bindings().first(where: { $0.key != action && $0.value == shortcut })?.key {
            return String(localized: "Already used for \(other.title).")
        }
        if system.reserved().contains(shortcut) { return String(localized: "macOS already uses this shortcut.") }
        // An app-only action's own menu item carries its shortcut; that is not a clash.
        if let command = Self.viewShortcuts().first(where: { $0.shortcut == shortcut }) {
            return String(localized: "Mochi already uses this shortcut for \(command.title).")
        }
        if let command = menuShortcuts().first(where: {
            $0.shortcut == shortcut && (action.isGlobal || $0.title != action.title)
        }) {
            return String(localized: "Mochi already uses this shortcut for \(command.title).")
        }
        return nil
    }

    static func id(for action: ShortcutAction) -> UInt32 {
        UInt32(ShortcutAction.allCases.firstIndex(of: action)! + 1)
    }
    static func action(for id: UInt32) -> ShortcutAction? {
        let index = Int(id) - 1
        return ShortcutAction.allCases.indices.contains(index) ? ShortcutAction.allCases[index] : nil
    }

    /// Shortcuts that buttons in Mochi's windows take, outside any menu.
    static func viewShortcuts() -> [(title: String, shortcut: Shortcut)] {
        let commandReturn = Shortcut(keyCode: UInt16(kVK_Return), modifiers: [.command])
        return [
            (String(localized: "Send Message"), commandReturn), (String(localized: "Find the Words"), commandReturn),
        ]
    }

    /// The key equivalents in Mochi's menus, as shortcuts on the current keyboard layout.
    static func mainMenuShortcuts() -> [(title: String, shortcut: Shortcut)] {
        func items(_ menu: NSMenu) -> [NSMenuItem] { menu.items.flatMap { [$0] + ($0.submenu.map(items) ?? []) } }
        // NSApp is nil until the application object exists, as in a test process that never created one.
        let commands = NSApp?.mainMenu.map(items) ?? []
        let table = KeyLayout.current()?.table() ?? KeyLayout.Table()
        return commands.compactMap { item in
            guard !item.keyEquivalent.isEmpty, let key = Shortcut.menuKey(item.keyEquivalent, in: table) else {
                return nil
            }
            var modifiers = Shortcut.Modifiers(item.keyEquivalentModifierMask)
            if key.shift { modifiers.insert(.shift) }
            return (item.title, Shortcut(keyCode: key.keyCode, modifiers: modifiers))
        }
    }
}

/// Carbon's hot keys: the only global shortcut API that needs no Accessibility permission.
/// Keys are registered on, and handled from, the event dispatcher target. The application target receives hot keys
/// only while Mochi is the active app, so a shortcut would stop working once the workspace is closed.
@MainActor final class CarbonHotKeys {
    static let shared = CarbonHotKeys()
    private static let signature: OSType = 0x4D_4F_43_48  // "MOCH"
    private var registered: [EventHotKeyRef] = []
    private var installed = false
    var handler: (@MainActor (UInt32, Bool) -> Void)?

    func register(_ shortcut: Shortcut, id: UInt32) -> OSStatus {
        let status = installHandler()
        guard status == noErr else { return status }
        var reference: EventHotKeyRef?
        let result = RegisterEventHotKey(
            UInt32(shortcut.keyCode), shortcut.modifiers.carbon, EventHotKeyID(signature: Self.signature, id: id),
            GetEventDispatcherTarget(), 0, &reference)
        if result == noErr, let reference { registered.append(reference) }
        return result
    }

    func unregisterAll() {
        for reference in registered { UnregisterEventHotKey(reference) }
        registered = []
    }

    private func installHandler() -> OSStatus {
        guard !installed else { return noErr }
        let types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let status = InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, _ in
                guard let event else { return OSStatus(eventNotHandledErr) }
                var key = EventHotKeyID()
                let status = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &key)
                guard status == noErr, key.signature == CarbonHotKeys.signature else {
                    return OSStatus(eventNotHandledErr)
                }
                let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
                // Carbon delivers hot key events on the main thread.
                MainActor.assumeIsolated { CarbonHotKeys.shared.handler?(key.id, pressed) }
                return noErr
            }, types.count, types, nil, nil)
        installed = status == noErr
        return status
    }

    /// The symbolic hot keys macOS has turned on, read from the system's own list.
    static func reserved() -> Set<Shortcut> {
        var list: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&list) == noErr, let entries = list?.takeRetainedValue() as? [[String: Any]] else {
            return []
        }
        return Set(
            entries.compactMap { entry in
                guard (entry[kHISymbolicHotKeyEnabled as String] as? Bool) == true,
                    let code = entry[kHISymbolicHotKeyCode as String] as? Int,
                    let modifiers = entry[kHISymbolicHotKeyModifiers as String] as? Int,
                    (0...Int(UInt16.max)).contains(code)
                else { return nil }
                return Shortcut(keyCode: UInt16(code), modifiers: Shortcut.Modifiers(carbon: modifiers))
            })
    }
}
