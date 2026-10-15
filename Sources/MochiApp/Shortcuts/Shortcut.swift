import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A key and its modifiers, stored as the hardware key code so it survives keyboard layout changes.
struct Shortcut: Codable, Hashable {
    struct Modifiers: OptionSet, Codable, Hashable {
        let rawValue: Int
        static let control = Modifiers(rawValue: 1 << 0)
        static let option = Modifiers(rawValue: 1 << 1)
        static let shift = Modifiers(rawValue: 1 << 2)
        static let command = Modifiers(rawValue: 1 << 3)

        init(rawValue: Int) { self.rawValue = rawValue }
        init(_ flags: NSEvent.ModifierFlags) {
            var value: Modifiers = []
            if flags.contains(.control) { value.insert(.control) }
            if flags.contains(.option) { value.insert(.option) }
            if flags.contains(.shift) { value.insert(.shift) }
            if flags.contains(.command) { value.insert(.command) }
            self = value
        }
        var carbon: UInt32 {
            var value = 0
            if contains(.control) { value |= controlKey }
            if contains(.option) { value |= optionKey }
            if contains(.shift) { value |= shiftKey }
            if contains(.command) { value |= cmdKey }
            return UInt32(value)
        }
        init(carbon: Int) {
            var value: Modifiers = []
            if carbon & controlKey != 0 { value.insert(.control) }
            if carbon & optionKey != 0 { value.insert(.option) }
            if carbon & shiftKey != 0 { value.insert(.shift) }
            if carbon & cmdKey != 0 { value.insert(.command) }
            self = value
        }
        var flags: NSEvent.ModifierFlags {
            var value: NSEvent.ModifierFlags = []
            if contains(.control) { value.insert(.control) }
            if contains(.option) { value.insert(.option) }
            if contains(.shift) { value.insert(.shift) }
            if contains(.command) { value.insert(.command) }
            return value
        }
        /// In the order macOS menus show them.
        var symbols: String {
            (contains(.control) ? "⌃" : "") + (contains(.option) ? "⌥" : "") + (contains(.shift) ? "⇧" : "")
                + (contains(.command) ? "⌘" : "")
        }
    }

    let keyCode: UInt16
    let modifiers: Modifiers

    /// Why this key cannot be a shortcut on its own merits, or nil when it can.
    /// A global shortcut fires in every app, so it needs Command, Option or Control; Shift alone would take a
    /// character away from typing.
    var problem: String? {
        if Self.modifierKeys.contains(keyCode) { return String(localized: "Press a key together with the modifiers.") }
        if modifiers.isDisjoint(with: [.command, .option, .control]) {
            return String(localized: "Use Command, Option or Control in the shortcut.")
        }
        return nil
    }

    /// As menus show it, for example ⌃⌥M.
    var display: String { modifiers.symbols + keyName }

    var keyName: String {
        if let name = Self.namedKeys[Int(keyCode)] { return name }
        return character?.uppercased() ?? "#\(keyCode)"
    }

    /// The character the key types without modifiers on the current layout, as menu key equivalents name it.
    var character: String? {
        if Self.namedKeys[Int(keyCode)] != nil { return nil }
        return KeyLayout.current()?.typed(keyCode, shift: false)?.lowercased()
    }

    /// The key as a SwiftUI menu key equivalent on the current layout, or nil when the key has none.
    var keyEquivalent: KeyEquivalent? {
        switch Int(keyCode) {
        case kVK_Return: return .return
        case kVK_Escape: return .escape
        case kVK_Tab: return .tab
        case kVK_Space: return .space
        case kVK_Delete: return .delete
        case kVK_ForwardDelete: return .deleteForward
        case kVK_LeftArrow: return .leftArrow
        case kVK_RightArrow: return .rightArrow
        case kVK_UpArrow: return .upArrow
        case kVK_DownArrow: return .downArrow
        case kVK_Home: return .home
        case kVK_End: return .end
        case kVK_PageUp: return .pageUp
        case kVK_PageDown: return .pageDown
        default:
            // Function keys are named keys with no character; menus know them by their function-key code points.
            if let index = Self.functionKeys.firstIndex(of: Int(keyCode)),
                let scalar = UnicodeScalar(NSF1FunctionKey + index)
            {
                return KeyEquivalent(Character(scalar))
            }
            return character.flatMap { $0.count == 1 ? KeyEquivalent(Character($0)) : nil }
        }
    }
    /// The modifiers as SwiftUI menu modifiers.
    var eventModifiers: SwiftUI.EventModifiers {
        var value: SwiftUI.EventModifiers = []
        if modifiers.contains(.control) { value.insert(.control) }
        if modifiers.contains(.option) { value.insert(.option) }
        if modifiers.contains(.shift) { value.insert(.shift) }
        if modifiers.contains(.command) { value.insert(.command) }
        return value
    }

    /// The key a menu key equivalent names, and whether typing it needs Shift (as for ? or an upper-case letter).
    static func menuKey(_ equivalent: String, in table: KeyLayout.Table) -> (keyCode: UInt16, shift: Bool)? {
        if let scalar = equivalent.unicodeScalars.first, equivalent.unicodeScalars.count == 1,
            let code = menuNamedKeys[Int(scalar.value)]
        {
            return (UInt16(code), false)
        }
        if let code = table.plain[equivalent] { return (code, false) }
        if let code = table.shifted[equivalent] { return (code, true) }
        return nil
    }

    /// Keys with a name of their own rather than a character, which a typing table leaves out.
    static func isNamed(_ keyCode: UInt16) -> Bool { namedKeys[Int(keyCode)] != nil }

    /// Menu key equivalents for keys that type no character, by the character AppKit uses for them.
    private static let menuNamedKeys: [Int: Int] = {
        var keys: [Int: Int] = [
            0x1B: kVK_Escape, 0x0D: kVK_Return, 0x03: kVK_ANSI_KeypadEnter, 0x09: kVK_Tab, 0x20: kVK_Space,
            0x08: kVK_Delete, 0x7F: kVK_Delete, NSDeleteFunctionKey: kVK_ForwardDelete,
            NSUpArrowFunctionKey: kVK_UpArrow, NSDownArrowFunctionKey: kVK_DownArrow,
            NSLeftArrowFunctionKey: kVK_LeftArrow, NSRightArrowFunctionKey: kVK_RightArrow, NSHomeFunctionKey: kVK_Home,
            NSEndFunctionKey: kVK_End, NSPageUpFunctionKey: kVK_PageUp, NSPageDownFunctionKey: kVK_PageDown,
        ]
        for (offset, code) in functionKeys.enumerated() { keys[NSF1FunctionKey + offset] = code }
        return keys
    }()

    /// F1 to F20, in order.
    /// Number-pad keys. A menu knows a key only by its character, so these are indistinguishable there from the
    /// top-row keys with the same character.
    static let keypadKeys: Set<Int> = [
        kVK_ANSI_Keypad0, kVK_ANSI_Keypad1, kVK_ANSI_Keypad2, kVK_ANSI_Keypad3, kVK_ANSI_Keypad4, kVK_ANSI_Keypad5,
        kVK_ANSI_Keypad6, kVK_ANSI_Keypad7, kVK_ANSI_Keypad8, kVK_ANSI_Keypad9, kVK_ANSI_KeypadDecimal,
        kVK_ANSI_KeypadMultiply, kVK_ANSI_KeypadPlus, kVK_ANSI_KeypadClear, kVK_ANSI_KeypadDivide,
        kVK_ANSI_KeypadEnter, kVK_ANSI_KeypadMinus, kVK_ANSI_KeypadEquals,
    ]
    private static let functionKeys = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12,
        kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ]

    private static let modifierKeys: Set<UInt16> = Set(
        [
            kVK_Command, kVK_RightCommand, kVK_Shift, kVK_RightShift, kVK_Option, kVK_RightOption, kVK_Control,
            kVK_RightControl, kVK_CapsLock, kVK_Function,
        ].map { UInt16($0) })

    private static let namedKeys: [Int: String] = [
        kVK_Space: String(localized: "Space"), kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫",
        kVK_ForwardDelete: "⌦", kVK_Escape: "⎋", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑",
        kVK_DownArrow: "↓", kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_F1: "F1",
        kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
        kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13", kVK_F14: "F14",
        kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]
}

/// Mochi's recordable shortcuts. Most work in every app; Send Now works only while Mochi is frontmost.
enum ShortcutAction: String, CaseIterable, Identifiable {
    // New actions go at the end: a global shortcut's hot key id is its position here.
    case talk
    case togglePet
    case listen
    case sendNow

    var id: String { rawValue }
    var title: String {
        switch self {
        case .talk: return String(localized: "Talk to Mochi")
        case .togglePet: return String(localized: "Show or Hide Desktop Mochi")
        case .listen: return String(localized: "Start or Stop Listening")
        case .sendNow: return String(localized: "Send Now")
        }
    }
    /// False for a shortcut that works only while Mochi is frontmost, through its menu item. Send Now ends a spoken
    /// turn at once, so it must never fire from another app by accident.
    var isGlobal: Bool { self != .sendNow }
    /// The preferences key; changing it forgets users' shortcuts.
    var preferenceKey: String { "shortcut.\(rawValue)" }
    /// The shortcut an action has until the user records another or removes it.
    var defaultShortcut: Shortcut {
        switch self {
        case .talk: return Shortcut(keyCode: UInt16(kVK_ANSI_M), modifiers: [.control, .option, .command])
        case .togglePet: return Shortcut(keyCode: UInt16(kVK_ANSI_H), modifiers: [.control, .option, .command])
        // Not ⌃⌥⌘L: ChatGPT's desktop app takes that one for its voice mode, and the first app to register wins.
        case .listen: return Shortcut(keyCode: UInt16(kVK_ANSI_E), modifiers: [.control, .option, .command])
        // ⌘↩ already sends typed text and translates in Help; a spoken turn and typed text can be in progress at once.
        case .sendNow: return Shortcut(keyCode: UInt16(kVK_Return), modifiers: [.option, .command])
        }
    }
    static var defaults: [ShortcutAction: Shortcut] {
        Dictionary(uniqueKeysWithValues: allCases.map { ($0, $0.defaultShortcut) })
    }
}

/// The current ASCII-capable keyboard layout, read once per use.
struct KeyLayout {
    private let data: Data

    static func current() -> KeyLayout? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
            let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        return KeyLayout(data: Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data)
    }

    /// What `keyCode` types, with or without Shift.
    func typed(_ keyCode: UInt16, shift: Bool) -> String? {
        var deadKeys: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        // UCKeyTranslate takes Carbon modifiers shifted right by 8 bits.
        let modifiers = shift ? UInt32(shiftKey >> 8) & 0xFF : 0
        let status = data.withUnsafeBytes { buffer -> OSStatus in
            guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return -1 }
            return UCKeyTranslate(
                layout, keyCode, UInt16(kUCKeyActionDisplay), modifiers, UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeys, characters.count, &length, &characters)
        }
        guard status == noErr, length > 0 else { return nil }
        let text = String(utf16CodeUnits: characters, count: length)
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    /// Which key types each character, without and with Shift; the lowest key code wins a tie.
    struct Table {
        var plain: [String: UInt16] = [:]
        var shifted: [String: UInt16] = [:]
    }

    func table() -> Table {
        var table = Table()
        for code in (0..<128).map(UInt16.init).reversed() where !Shortcut.isNamed(code) {
            if let text = typed(code, shift: false) { table.plain[text] = code }
            if let text = typed(code, shift: true) { table.shifted[text] = code }
        }
        return table
    }
}
