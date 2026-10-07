// SPDX-License-Identifier: GPL-3.0-or-later

import Carbon.HIToolbox
import Foundation

/// Ursprung's controls as ARMSX2 bindings (docs/STANDALONE_PLAN.md, phase 6):
/// the game's `InputProfile` becomes `[Pad1]` and `[Pad2]`, the hotkeys that
/// have a counterpart become `[Hotkeys]`. Written before every launch, so a
/// PlayStation 2 game plays with the same keys and buttons as every other.
///
/// The keyboard and the first controller (`SDL-0`) play as player 1, the
/// second controller as player 2. ARMSX2 numbers controllers in the order
/// they connected, so the player chosen for a controller in Settings does not
/// carry over. Turbo buttons and the stick as D-pad have no counterpart.
nonisolated struct ARMSX2Controls: Equatable, Sendable {
    typealias Entry = IniDocument.Entry

    var profile: InputProfile
    var hotkeys: HotkeyMapping
    var rumble: Bool
    /// The stick dead zone, 0…1.
    var deadZone: Float
    /// ARMSX2's names of the keys (`Keyboard/<name>`) by key code, for the
    /// keyboard layout in use. Keys it cannot bind are missing.
    var keyNames: [UInt16: String]

    /// PlayStation 2 buttons and the RetroPad input that presses them, by
    /// Ursprung's PlayStation layout: Cross is B, the bottom face button.
    private static let buttons: [(name: String, input: RetroInput)] = [
        ("Up", .up), ("Right", .right), ("Down", .down), ("Left", .left),
        ("Triangle", .x), ("Circle", .a), ("Cross", .b), ("Square", .y),
        ("Select", .select), ("Start", .start),
        ("L1", .l), ("L2", .l2), ("R1", .r), ("R2", .r2), ("L3", .l3), ("R3", .r3),
    ]

    /// Stick directions; controller sticks are not remapped.
    private static let sticks: [(name: String, input: RetroInput, axis: String)] = [
        ("LUp", .leftStickUp, "-LeftY"), ("LRight", .leftStickRight, "+LeftX"),
        ("LDown", .leftStickDown, "+LeftY"), ("LLeft", .leftStickLeft, "-LeftX"),
        ("RUp", .rightStickUp, "-RightY"), ("RRight", .rightStickRight, "+RightX"),
        ("RDown", .rightStickDown, "+RightY"), ("RLeft", .rightStickLeft, "-RightX"),
    ]

    /// Every key of a `[PadN]` section that holds a binding (lower case).
    /// Ursprung replaces them all; settings such as `AxisScale` stay.
    static let bindingKeys: Set<String> = Set(
        (buttons.map(\.name) + sticks.map(\.name) + ["Analog", "LargeMotor", "SmallMotor"]).map { $0.lowercased() })

    /// SDL's name for a controller button. Both name buttons by position,
    /// so the same names fit every kind of controller (S7).
    static func controllerName(_ input: RetroInput) -> String? {
        switch input {
        case .up: "DPadUp"
        case .down: "DPadDown"
        case .left: "DPadLeft"
        case .right: "DPadRight"
        case .b: "FaceSouth"
        case .a: "FaceEast"
        case .y: "FaceWest"
        case .x: "FaceNorth"
        case .l: "LeftShoulder"
        case .r: "RightShoulder"
        case .l2: "+LeftTrigger"
        case .r2: "+RightTrigger"
        case .l3: "LeftStick"
        case .r3: "RightStick"
        case .start: "Start"
        case .select: "Back"
        default: nil
        }
    }

    /// `[Pad1]` (`player` 0) or `[Pad2]`.
    func pad(player: Int) -> [Entry] {
        let controller = "SDL-\(player)"
        var entries = [Entry("Type", "DualShock2"), Entry("Deadzone", Self.decimal(deadZone))]
        for (name, input) in Self.buttons {
            if player == 0, let key = keyboardKey(for: input) { entries.append(Entry(name, key)) }
            if let source = profile.controller.source(for: input), let button = Self.controllerName(source) {
                entries.append(Entry(name, "\(controller)/\(button)"))
            }
        }
        for (name, input, axis) in Self.sticks {
            if player == 0, let key = keyboardKey(for: input) { entries.append(Entry(name, key)) }
            entries.append(Entry(name, "\(controller)/\(axis)"))
        }
        if rumble {
            entries += [Entry("LargeMotor", "\(controller)/LargeMotor"), Entry("SmallMotor", "\(controller)/SmallMotor")]
        }
        return entries
    }

    /// The key bound to `input`, unless a hotkey takes it: in Ursprung the
    /// game does not get those keys either.
    private func keyboardKey(for input: RetroInput) -> String? {
        guard let binding = profile.keyboard.bindings[input], hotkeys.action(forKeyCode: binding.keyCode) == nil,
              let name = keyNames[binding.keyCode] else { return nil }
        return "Keyboard/\(name)"
    }

    /// ARMSX2's hotkey for one of Ursprung's; nil when it has none.
    static func hotkeyName(_ action: HotkeyAction) -> String? {
        switch action {
        case .menu: "OpenPauseMenu"
        case .fastForward: "HoldTurbo"
        case .fastForwardToggle: "ToggleTurbo"
        // Ursprung's Quick Save is ARMSX2's slot 1 (`ARMSX2States.armsx2Slot`).
        case .quickSave: "SaveStateToSlot1"
        case .quickLoad: "LoadStateFromSlot1"
        case .screenshot: "Screenshot"
        case .rewind, .turbo, .typing, .shaderPanel: nil
        }
    }

    /// ARMSX2's own default hotkeys without a counterpart in Ursprung
    /// (`Pad::SetDefaultHotkeyConfig`). Its save slot keys give way to Quick
    /// Save and Quick Load; the developer tools (GS dumps, input recording)
    /// are left out.
    static let ownHotkeys: [(name: String, keys: [String])] = [
        ("ToggleFullscreen", ["Alt", "Return"]),
        ("CycleAspectRatio", ["F6"]),
        ("CycleInterlaceMode", ["F5"]),
        ("ToggleMipmapMode", ["Insert"]),
        ("ToggleSoftwareRendering", ["F9"]),
        ("ToggleOSD", ["F10"]),
        ("ZoomIn", ["Control", "Plus"]),
        ("ZoomOut", ["Control", "Minus"]),
        ("Mute", ["Control", "M"]),
        ("ToggleFrameLimit", ["F4"]),
        ("TogglePause", ["Space"]),
        ("ToggleSlowMotion", ["Shift", "Backtab"]),
    ]

    /// The `[Hotkeys]` section: Ursprung's hotkeys, then ARMSX2's own on keys
    /// that Ursprung's controls leave free.
    var hotkeyEntries: [Entry] {
        var entries: [Entry] = []
        for action in HotkeyAction.allCases {
            guard let name = Self.hotkeyName(action) else { continue }
            var bindings = hotkeys.bindings[action].flatMap { keyNames[$0.keyCode] }.map { ["Keyboard/\($0)"] } ?? []
            if action == .menu {
                // esc always opens the game menu too, and so does a controller's Home button.
                if !bindings.contains("Keyboard/Escape") { bindings.append("Keyboard/Escape") }
                bindings += ["SDL-0/Guide", "SDL-1/Guide"]
            }
            entries += bindings.map { Entry(name, $0) }
        }
        let taken = Set((entries + pad(player: 0)).map(\.value).filter { $0.hasPrefix("Keyboard/") })
        for (name, keys) in Self.ownHotkeys {
            let bindings = keys.map { "Keyboard/\($0)" }
            guard taken.isDisjoint(with: bindings) else { continue }
            entries.append(Entry(name, bindings.joined(separator: " & ")))
        }
        return entries
    }

    private static func decimal(_ value: Float) -> String {
        String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}

/// ARMSX2's names for keys. It reads keys through Qt, which names a key by
/// the character the keyboard layout gives it (on a German layout the key
/// left of X is “Y”), and stores the name from `QtKeyCodes.cpp`.
nonisolated enum ARMSX2Keys {
    /// Keys whose name does not depend on the layout. Qt does not tell left
    /// and right modifier keys apart.
    static let fixedNames: [UInt16: String] = [
        36: "Return", 48: "Tab", 49: "Space", 51: "Backspace", 53: "Escape", 117: "Delete", 114: "Help",
        115: "Home", 119: "End", 116: "PageUp", 121: "PageDown",
        123: "Left", 124: "Right", 125: "Down", 126: "Up",
        56: "Shift", 60: "Shift", 59: "Control", 62: "Control", 58: "Alt", 61: "Alt", 55: "Meta", 54: "Meta",
        57: "CapsLock",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
        76: "NumpadEnter", 71: "NumpadClear",
        82: "Numpad0", 83: "Numpad1", 84: "Numpad2", 85: "Numpad3", 86: "Numpad4",
        87: "Numpad5", 88: "Numpad6", 89: "Numpad7", 91: "Numpad8", 92: "Numpad9",
    ]

    /// Keypad keys whose character comes from the layout (“NumpadPeriod”).
    private static let keypadKeys: Set<UInt16> = [65, 67, 69, 75, 78, 81]

    /// Characters of the US layout, when the current layout cannot be read.
    static let usCharacters: [UInt16: Character] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B",
        12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 31: "O", 32: "U", 34: "I", 35: "P",
        37: "L", 38: "J", 40: "K", 45: "N", 46: "M",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 25: "9", 26: "7", 28: "8", 29: "0",
        24: "=", 27: "-", 30: "]", 33: "[", 39: "'", 41: ";", 42: "\\", 43: ",", 44: "/", 47: ".", 50: "`",
        65: ".", 67: "*", 69: "+", 75: "/", 78: "-", 81: "=",
    ]

    /// Qt's names of the characters it has a key for.
    private static let symbolNames: [Character: String] = [
        "!": "Exclam", "\"": "QuoteDbl", "#": "NumberSign", "$": "Dollar", "%": "Percent", "&": "Ampersand",
        "'": "Apostrophe", "(": "ParenLeft", ")": "ParenRight", "*": "Asterisk", "+": "Plus", ",": "Comma",
        "-": "Minus", ".": "Period", "/": "Slash", ":": "Colon", ";": "Semicolon", "<": "Less", "=": "Equal",
        ">": "Greater", "?": "Question", "@": "At", "[": "BracketLeft", "\\": "Backslash", "]": "BracketRight",
        "^": "AsciiCircum", "_": "Underscore", "`": "QuoteLeft", "{": "BraceLeft", "|": "Bar", "}": "BraceRight",
        "~": "AsciiTilde",
    ]

    /// The name of `keyCode`. `character` is what the layout types on it,
    /// nil when it types nothing (a dead key, which Qt cannot bind either).
    static func name(forKeyCode keyCode: UInt16, character: Character?) -> String? {
        if let name = fixedNames[keyCode] { return name }
        guard let name = character.flatMap(name(of:)) else { return nil }
        return keypadKeys.contains(keyCode) ? "Numpad" + name : name
    }

    /// The names of all keys for a layout's characters by key code; the US
    /// layout when there is none.
    static func names(layout characters: [UInt16: Character]) -> [UInt16: String] {
        let characters = characters.isEmpty ? usCharacters : characters
        var names: [UInt16: String] = [:]
        for keyCode in UInt16(0)..<128 {
            names[keyCode] = name(forKeyCode: keyCode, character: characters[keyCode])
        }
        return names
    }

    /// Letters by their capital (Qt's key code), digits, ASCII symbols. Keys
    /// such as “Ö” or “ß” have no name in ARMSX2 and cannot be bound there.
    static func name(of character: Character) -> String? {
        // “ß” becomes “SS”: not one key.
        let upper = character.uppercased()
        if upper.count == 1, let first = upper.first, first.isASCII, first.isLetter || first.isNumber { return upper }
        return symbolNames[character]
    }

    /// The names of all keys for the current keyboard layout. The text input
    /// APIs belong on the main thread.
    @MainActor
    static func currentLayout() -> [UInt16: String] {
        names(layout: layoutCharacters())
    }

    /// What each key types without modifiers on the current layout; dead
    /// keys type nothing.
    @MainActor
    private static func layoutCharacters() -> [UInt16: Character] {
        var source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
        if source.flatMap({ TISGetInputSourceProperty($0, kTISPropertyUnicodeKeyLayoutData) }) == nil {
            source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue()
        }
        guard let source, let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return [:] }
        let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue() as Data
        var characters: [UInt16: Character] = [:]
        data.withUnsafeBytes { bytes in
            guard let layout = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return }
            for keyCode in UInt16(0)..<128 {
                var deadKeyState: UInt32 = 0
                var length = 0
                var units = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                                            0, &deadKeyState, units.count, &length, &units)
                guard status == noErr, length > 0, deadKeyState == 0 else { continue }
                let string = String(utf16CodeUnits: units, count: length)
                guard string.count == 1, let character = string.first,
                      !character.isWhitespace, !(character.asciiValue.map { $0 < 0x20 || $0 == 0x7F } ?? false)
                else { continue }
                characters[keyCode] = character
            }
        }
        return characters
    }
}
