import AppKit
import Carbon.HIToolbox
import MochiTestSupport
import XCTest

@testable import MochiApp

/// A hot key service that records what Mochi asks of it and never touches the real keyboard.
@MainActor private final class FakeHotKeys {
    var registered: [UInt32: Shortcut] = [:]
    var refuse: [Shortcut: OSStatus] = [:]
    var reserved: Set<Shortcut> = []
    var deliver: (@MainActor (UInt32, Bool) -> Void)?
    var system: HotKeySystem {
        HotKeySystem(
            register: { [unowned self] shortcut, id in
                if let status = refuse[shortcut] { return status }
                registered[id] = shortcut
                return noErr
            },
            unregisterAll: { [unowned self] in registered = [:] },
            reserved: { [unowned self] in reserved },
            onEvent: { [unowned self] in deliver = $0 })
    }
}

final class ShortcutTests: XCTestCase {
    private let optionCommandM = Shortcut(keyCode: UInt16(kVK_ANSI_M), modifiers: [.option, .command])
    private let controlOptionSpace = Shortcut(keyCode: UInt16(kVK_Space), modifiers: [.control, .option])

    func testAGlobalShortcutNeedsCommandOptionOrControlAndARealKey() {
        XCTAssertNil(optionCommandM.problem)
        XCTAssertNil(Shortcut(keyCode: UInt16(kVK_F5), modifiers: [.control]).problem)
        XCTAssertNotNil(Shortcut(keyCode: UInt16(kVK_ANSI_M), modifiers: []).problem)
        XCTAssertNotNil(Shortcut(keyCode: UInt16(kVK_ANSI_M), modifiers: [.shift]).problem, "Shift alone types")
        XCTAssertNotNil(Shortcut(keyCode: UInt16(kVK_Command), modifiers: [.command]).problem)
    }

    func testShortcutsReadAsMenusShowThem() {
        XCTAssertEqual(controlOptionSpace.display, "⌃⌥Space")
        XCTAssertEqual(
            Shortcut(keyCode: UInt16(kVK_F5), modifiers: [.control, .option, .shift, .command]).display, "⌃⌥⇧⌘F5")
        XCTAssertEqual(Shortcut(keyCode: UInt16(kVK_UpArrow), modifiers: [.command]).display, "⌘↑")
        XCTAssertNil(controlOptionSpace.character)
    }

    func testModifiersConvertBothWaysAndSurviveStorage() throws {
        let all: Shortcut.Modifiers = [.control, .option, .shift, .command]
        XCTAssertEqual(Shortcut.Modifiers(carbon: Int(all.carbon)), all)
        XCTAssertEqual(Shortcut.Modifiers(all.flags), all)
        XCTAssertEqual(Shortcut.Modifiers([.command, .capsLock, .function]), [.command])
        let data = try JSONEncoder().encode(optionCommandM)
        XCTAssertEqual(try JSONDecoder().decode(Shortcut.self, from: data), optionCommandM)
    }

    @MainActor func testRegistersEachBindingAndReportsOnesAnotherAppHolds() {
        let keys = FakeHotKeys()
        let center = ShortcutCenter(system: keys.system, enabled: true)
        var bindings: [ShortcutAction: Shortcut] = [.talk: optionCommandM, .togglePet: controlOptionSpace]
        center.bindings = { bindings }
        keys.refuse[controlOptionSpace] = OSStatus(eventHotKeyExistsErr)
        center.apply()
        XCTAssertEqual(keys.registered, [ShortcutCenter.id(for: .talk): optionCommandM])
        XCTAssertNil(center.problems[.talk])
        XCTAssertEqual(center.problems[.togglePet], "Another app is using this shortcut. Choose a different one.")
        keys.refuse = [:]
        bindings[.togglePet] = nil
        center.apply()
        XCTAssertEqual(keys.registered.count, 1)
        XCTAssertTrue(center.problems.isEmpty, "A removed shortcut leaves no stale problem")
    }

    @MainActor func testSendNowIsNeverRegisteredAsAGlobalShortcut() {
        let keys = FakeHotKeys()
        let center = ShortcutCenter(system: keys.system, enabled: true)
        center.bindings = { ShortcutAction.defaults }
        center.menuShortcuts = { [(ShortcutAction.sendNow.title, ShortcutAction.sendNow.defaultShortcut)] }
        center.apply()
        XCTAssertEqual(
            Set(keys.registered.values),
            [ShortcutAction.talk, .togglePet, .listen].map(\.defaultShortcut).reduce(into: Set()) { $0.insert($1) })
        XCTAssertNil(keys.registered[ShortcutCenter.id(for: .sendNow)])
        XCTAssertTrue(center.problems.isEmpty, "Send Now's own menu item is not a clash")
        XCTAssertNil(center.conflict(ShortcutAction.sendNow.defaultShortcut, for: .sendNow))
        XCTAssertEqual(
            center.conflict(ShortcutAction.sendNow.defaultShortcut, for: .talk),
            "Already used for Send Now.", "A global shortcut cannot take Send Now's keys")
        // A number-pad key would also answer its top-row twin through the menu.
        let keypadOne = Shortcut(keyCode: UInt16(kVK_ANSI_Keypad1), modifiers: [.option, .command])
        XCTAssertNotNil(center.conflict(keypadOne, for: .sendNow))
        XCTAssertNil(center.conflict(keypadOne, for: .talk), "A global hot key tells the keys apart")
        // Buttons take shortcuts outside the menus too: ⌘Return sends a typed message.
        XCTAssertEqual(
            center.conflict(Shortcut(keyCode: UInt16(kVK_Return), modifiers: [.command]), for: .sendNow),
            "Mochi already uses this shortcut for Send Message.")
    }

    @MainActor func testASavedNumberPadSendNowShortcutIsReportedAndNotRegistered() {
        let keys = FakeHotKeys()
        let center = ShortcutCenter(system: keys.system, enabled: true)
        let keypadOne = Shortcut(keyCode: UInt16(kVK_ANSI_Keypad1), modifiers: [.option, .command])
        var bindings = ShortcutAction.defaults
        bindings[.sendNow] = keypadOne
        center.bindings = { bindings }
        center.menuShortcuts = { [] }
        center.apply()
        XCTAssertNotNil(center.problems[.sendNow], "Shown in Settings so the learner can choose another key")
        XCTAssertFalse(keys.registered.values.contains(keypadOne))
        XCTAssertNil(center.problems[.talk])
    }

    @MainActor func testRecordingSuspendsEveryShortcutAndRestoresThem() {
        let keys = FakeHotKeys()
        let center = ShortcutCenter(system: keys.system, enabled: true)
        center.bindings = { [.talk: self.optionCommandM] }
        var performed: [(ShortcutAction, Bool)] = []
        center.perform = { performed.append(($0, $1)) }
        center.apply()
        center.recordingAction = .togglePet
        XCTAssertTrue(keys.registered.isEmpty)
        keys.deliver?(ShortcutCenter.id(for: .talk), true)
        XCTAssertTrue(performed.isEmpty, "A key that arrives while recording is the recorder's")
        center.recordingAction = .talk
        XCTAssertTrue(keys.registered.isEmpty, "Moving to the other row keeps everything off")
        center.recordingAction = nil
        XCTAssertEqual(keys.registered.count, 1)
        keys.deliver?(ShortcutCenter.id(for: .talk), true)
        keys.deliver?(ShortcutCenter.id(for: .talk), false)
        keys.deliver?(99, true)
        XCTAssertEqual(performed.map(\.0), [.talk, .talk])
        XCTAssertEqual(performed.map(\.1), [true, false])
    }

    @MainActor func testPreviewsNeverTakeKeys() {
        let keys = FakeHotKeys()
        let center = ShortcutCenter(system: keys.system, enabled: false)
        center.bindings = { [.talk: self.optionCommandM] }
        center.apply()
        XCTAssertTrue(keys.registered.isEmpty)
        XCTAssertNil(keys.deliver)
        XCTAssertFalse(makeApp(demo: true).shortcuts.enabled)
    }

    @MainActor func testConflictsAreNamed() {
        let keys = FakeHotKeys()
        let center = ShortcutCenter(system: keys.system, enabled: true)
        center.bindings = { [.togglePet: self.optionCommandM] }
        let commandN = Shortcut(keyCode: UInt16(kVK_ANSI_N), modifiers: [.command])
        center.menuShortcuts = { [("New Conversation", commandN)] }
        let spotlight = Shortcut(keyCode: UInt16(kVK_Space), modifiers: [.command])
        keys.reserved = [spotlight]
        XCTAssertEqual(
            center.conflict(optionCommandM, for: .talk), "Already used for Show or Hide Desktop Mochi.")
        XCTAssertNil(center.conflict(optionCommandM, for: .togglePet), "Its own shortcut is not a conflict")
        XCTAssertEqual(center.conflict(spotlight, for: .talk), "macOS already uses this shortcut.")
        XCTAssertEqual(
            center.conflict(commandN, for: .talk), "Mochi already uses this shortcut for New Conversation.")
        XCTAssertEqual(
            center.conflict(Shortcut(keyCode: UInt16(kVK_ANSI_N), modifiers: [.shift]), for: .talk),
            "Use Command, Option or Control in the shortcut.")
        XCTAssertNil(center.conflict(controlOptionSpace, for: .talk))
    }

    @MainActor func testMenuKeyEquivalentsBecomeShortcuts() throws {
        _ = NSApplication.shared
        let saved = NSApp.mainMenu
        defer { NSApp.mainMenu = saved }
        let menu = NSMenu()
        let file = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        file.submenu = NSMenu(title: "File")
        file.submenu?.addItem(withTitle: "New Conversation", action: nil, keyEquivalent: "n")
        file.submenu?.addItem(withTitle: "From Template", action: nil, keyEquivalent: "N")
        menu.addItem(file)
        NSApp.mainMenu = menu
        let found = ShortcutCenter.mainMenuShortcuts()
        // Key codes come from the current ASCII-capable layout, which always types n somewhere.
        let table = try XCTUnwrap(KeyLayout.current()).table()
        let n = try XCTUnwrap(table.plain["n"])
        XCTAssertEqual(found.map(\.title), ["New Conversation", "From Template"])
        XCTAssertEqual(
            found.map(\.shortcut),
            [
                Shortcut(keyCode: n, modifiers: [.command]), Shortcut(keyCode: n, modifiers: [.command, .shift]),
            ])
    }

    func testMenuKeysNeedingShiftOrWithoutCharactersAreFound() throws {
        let table = try XCTUnwrap(KeyLayout.current()).table()
        let question = try XCTUnwrap(Shortcut.menuKey("?", in: table))
        XCTAssertTrue(question.shift, "? is typed with Shift on an ASCII-capable layout")
        XCTAssertEqual(KeyLayout.current()?.typed(question.keyCode, shift: true), "?")
        let capitalN = try XCTUnwrap(Shortcut.menuKey("N", in: table))
        XCTAssertEqual(capitalN.keyCode, table.plain["n"])
        XCTAssertTrue(capitalN.shift)
        XCTAssertTrue(Shortcut.menuKey("\u{1b}", in: table)! == (UInt16(kVK_Escape), false))
        let up = String(UnicodeScalar(UInt32(NSUpArrowFunctionKey))!)
        XCTAssertTrue(Shortcut.menuKey(up, in: table)! == (UInt16(kVK_UpArrow), false))
        let f5 = String(UnicodeScalar(UInt32(NSF1FunctionKey + 4))!)
        XCTAssertTrue(Shortcut.menuKey(f5, in: table)! == (UInt16(kVK_F5), false))
    }

    @MainActor func testASavedShortcutThatNowClashesIsNotRegistered() {
        let keys = FakeHotKeys()
        let center = ShortcutCenter(system: keys.system, enabled: true)
        center.bindings = { [.talk: self.optionCommandM, .togglePet: self.controlOptionSpace] }
        center.menuShortcuts = { [("Minimize All", self.optionCommandM)] }
        center.apply()
        XCTAssertEqual(keys.registered, [ShortcutCenter.id(for: .togglePet): controlOptionSpace])
        XCTAssertEqual(center.problems[.talk], "Mochi already uses this shortcut for Minimize All.")
    }

    @MainActor func testShortcutsStartAtTheirDefaultsAndRemovalsStick() {
        let defaults = makePreferences()
        let talk = Shortcut(keyCode: UInt16(kVK_ANSI_M), modifiers: [.control, .option, .command])
        let pet = Shortcut(keyCode: UInt16(kVK_ANSI_H), modifiers: [.control, .option, .command])
        let listen = Shortcut(keyCode: UInt16(kVK_ANSI_E), modifiers: [.control, .option, .command])
        let sendNow = Shortcut(keyCode: UInt16(kVK_Return), modifiers: [.option, .command])
        let first = PreferencesStore(defaults, importLegacy: false, allowExternalControl: false)
        XCTAssertEqual(first.shortcuts, [.talk: talk, .togglePet: pet, .listen: listen, .sendNow: sendNow])
        XCTAssertEqual(first.shortcuts, ShortcutAction.defaults)
        first.shortcuts[.talk] = optionCommandM
        first.shortcuts[.togglePet] = nil
        let second = PreferencesStore(defaults, importLegacy: false, allowExternalControl: false)
        XCTAssertEqual(
            second.shortcuts, [.talk: optionCommandM, .listen: listen, .sendNow: sendNow],
            "A removed shortcut does not come back")
        second.shortcuts = ShortcutAction.defaults
        XCTAssertNil(defaults.object(forKey: ShortcutAction.talk.preferenceKey), "Defaults are not stored")
        XCTAssertNil(defaults.object(forKey: ShortcutAction.togglePet.preferenceKey))
        XCTAssertEqual(
            PreferencesStore(defaults, importLegacy: false, allowExternalControl: false).shortcuts,
            ShortcutAction.defaults)
    }

    @MainActor func testThePetPersistsAndBadValuesFallBack() {
        let defaults = makePreferences()
        let first = PreferencesStore(defaults, importLegacy: false, allowExternalControl: false)
        XCTAssertFalse(first.petVisible)
        XCTAssertNil(first.petOrigin)
        first.petVisible = true
        first.petOrigin = CGPoint(x: 12, y: 34)
        let second = PreferencesStore(defaults, importLegacy: false, allowExternalControl: false)
        XCTAssertTrue(second.petVisible)
        XCTAssertEqual(second.petOrigin, CGPoint(x: 12, y: 34))
        second.petOrigin = nil
        XCTAssertNil(defaults.object(forKey: "desktopPetOrigin"))
        defaults.set([1.0], forKey: "desktopPetOrigin")
        let repaired = PreferencesStore(defaults, importLegacy: false, allowExternalControl: false)
        XCTAssertNil(repaired.petOrigin)
    }

    /// A stored shortcut that cannot be read or is no longer allowed leaves its action unbound rather than taking the
    /// default keys, which another app may rely on, and stays stored until the learner records or removes one.
    @MainActor func testAnUnreadableShortcutLeavesItsActionUnboundAndIsKept() throws {
        let defaults = makePreferences()
        let unreadable = Data("not json".utf8)
        let modifierless = try JSONEncoder().encode(Shortcut(keyCode: UInt16(kVK_ANSI_M), modifiers: []))
        defaults.set(unreadable, forKey: ShortcutAction.talk.preferenceKey)
        defaults.set(modifierless, forKey: ShortcutAction.togglePet.preferenceKey)
        let settings = PreferencesStore(defaults, importLegacy: false, allowExternalControl: false)
        XCTAssertNil(settings.shortcuts[.talk], "An unreadable shortcut never falls back to the default")
        XCTAssertNil(settings.shortcuts[.togglePet], "Nor does one without a modifier")
        XCTAssertEqual(settings.shortcuts[.listen], ShortcutAction.listen.defaultShortcut)
        XCTAssertEqual(settings.unreadableShortcuts, [.talk, .togglePet])
        // Changing another action writes only that action's key.
        settings.setShortcut(optionCommandM, for: .listen)
        XCTAssertEqual(defaults.data(forKey: ShortcutAction.talk.preferenceKey), unreadable)
        XCTAssertEqual(defaults.data(forKey: ShortcutAction.togglePet.preferenceKey), modifierless)
        XCTAssertNil(
            defaults.object(forKey: ShortcutAction.sendNow.preferenceKey), "An unchanged default stays unstored")
        XCTAssertEqual(
            PreferencesStore(defaults, importLegacy: false, allowExternalControl: false).unreadableShortcuts,
            [.talk, .togglePet], "The problem is reported again after a relaunch")
        // Removing the shortcut, though it is already unbound, replaces the unreadable value.
        settings.setShortcut(nil, for: .talk)
        XCTAssertEqual(defaults.data(forKey: ShortcutAction.talk.preferenceKey), Data())
        settings.setShortcut(controlOptionSpace, for: .togglePet)
        XCTAssertEqual(settings.unreadableShortcuts, [])
        let reloaded = PreferencesStore(defaults, importLegacy: false, allowExternalControl: false)
        XCTAssertEqual(reloaded.unreadableShortcuts, [])
        XCTAssertEqual(
            reloaded.shortcuts,
            [.togglePet: controlOptionSpace, .listen: optionCommandM, .sendNow: ShortcutAction.sendNow.defaultShortcut])
    }

    func testDefaultShortcutsAreUsableAndDistinct() {
        for action in ShortcutAction.allCases { XCTAssertNil(action.defaultShortcut.problem, "\(action)") }
        XCTAssertEqual(Set(ShortcutAction.defaults.values).count, ShortcutAction.allCases.count)
        XCTAssertEqual(ShortcutAction.talk.defaultShortcut.display, "⌃⌥⌘M")
        XCTAssertEqual(ShortcutAction.togglePet.defaultShortcut.display, "⌃⌥⌘H")
    }

    /// The real service, with a combination nothing else uses, released before the test ends.
    @MainActor func testCarbonRegistersRefusesADuplicateAndReadsReservedShortcuts() {
        let hotKeys = CarbonHotKeys.shared
        defer { hotKeys.unregisterAll() }
        let rare = Shortcut(keyCode: UInt16(kVK_F19), modifiers: [.control, .option, .shift, .command])
        XCTAssertEqual(hotKeys.register(rare, id: 900), noErr)
        XCTAssertEqual(hotKeys.register(rare, id: 901), OSStatus(eventHotKeyExistsErr))
        hotKeys.unregisterAll()
        XCTAssertEqual(hotKeys.register(rare, id: 902), noErr, "Unregistering frees the keys")
        XCTAssertFalse(CarbonHotKeys.reserved().contains(rare))
        // Every Mac turns on some system shortcuts, such as the ones that switch Spaces or input sources.
        XCTAssertFalse(CarbonHotKeys.reserved().isEmpty)
    }

    @MainActor func testSettingAShortcutStoresAndRegistersIt() {
        let app = makeApp(demo: true)
        app.setShortcut(optionCommandM, for: .talk)
        XCTAssertEqual(app.settings.shortcuts[.talk], optionCommandM)
        app.setShortcut(nil, for: .talk)
        XCTAssertNil(app.settings.shortcuts[.talk])
        XCTAssertEqual(app.settings.shortcuts[.togglePet], ShortcutAction.togglePet.defaultShortcut)
    }
}
