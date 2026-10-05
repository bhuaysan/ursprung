// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

/// Translates Mac keys into keys of an emulated computer keyboard (libretro
/// `RETROK_*` values). Keys map by position, like scancodes: the key left
/// of Return is the same key on every layout; the typed character travels
/// along for cores that want text.
nonisolated enum EmulatedKeyboard {
    /// The libretro key for a Mac virtual key code, or nil.
    static func retroKey(forKeyCode keyCode: UInt16) -> UInt32? {
        table[keyCode]
    }

    /// RETROKMOD_* flags for the modifier keys held.
    static func modifiers(_ flags: NSEvent.ModifierFlags) -> UInt16 {
        var result: UInt16 = 0
        if flags.contains(.shift) { result |= 0x01 }
        if flags.contains(.control) { result |= 0x02 }
        if flags.contains(.option) { result |= 0x04 }
        if flags.contains(.command) { result |= 0x08 }
        if flags.contains(.capsLock) { result |= 0x20 }
        return result
    }

    /// The UTF-32 character a key event types, 0 for none (arrows, F keys).
    static func character(of event: NSEvent) -> UInt32 {
        guard let scalar = event.characters?.unicodeScalars.first,
              !(0xF700...0xF8FF).contains(scalar.value) else { return 0 } // AppKit's function key range
        return scalar.value
    }

    /// Whether a modifier key is down after a flagsChanged event for it.
    static func isModifierDown(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        switch keyCode {
        case 0x38, 0x3C: flags.contains(.shift)
        case 0x3B, 0x3E: flags.contains(.control)
        case 0x3A, 0x3D: flags.contains(.option)
        case 0x37, 0x36: flags.contains(.command)
        case 0x39: flags.contains(.capsLock)
        default: false
        }
    }

    private static let table: [UInt16: UInt32] = [
        // Letters (ANSI positions)
        0x00: 97, 0x0B: 98, 0x08: 99, 0x02: 100, 0x0E: 101, 0x03: 102, 0x05: 103, 0x04: 104, 0x22: 105,
        0x26: 106, 0x28: 107, 0x25: 108, 0x2E: 109, 0x2D: 110, 0x1F: 111, 0x23: 112, 0x0C: 113, 0x0F: 114,
        0x01: 115, 0x11: 116, 0x20: 117, 0x09: 118, 0x0D: 119, 0x07: 120, 0x10: 121, 0x06: 122,
        // Digits
        0x1D: 48, 0x12: 49, 0x13: 50, 0x14: 51, 0x15: 52, 0x17: 53, 0x16: 54, 0x1A: 55, 0x1C: 56, 0x19: 57,
        // Punctuation
        0x1B: 45, 0x18: 61, 0x21: 91, 0x1E: 93, 0x2A: 92, 0x29: 59, 0x27: 39, 0x2B: 44, 0x2F: 46, 0x2C: 47,
        0x32: 96, 0x0A: 323,
        // Editing and whitespace
        0x24: 13, 0x30: 9, 0x31: 32, 0x33: 8, 0x35: 27, 0x75: 127, 0x72: 277,
        // Navigation
        0x7E: 273, 0x7D: 274, 0x7C: 275, 0x7B: 276, 0x73: 278, 0x77: 279, 0x74: 280, 0x79: 281,
        // Function keys
        0x7A: 282, 0x78: 283, 0x63: 284, 0x76: 285, 0x60: 286, 0x61: 287, 0x62: 288, 0x64: 289, 0x65: 290,
        0x6D: 291, 0x67: 292, 0x6F: 293, 0x69: 294, 0x6B: 295, 0x71: 296,
        // Keypad
        0x52: 256, 0x53: 257, 0x54: 258, 0x55: 259, 0x56: 260, 0x57: 261, 0x58: 262, 0x59: 263, 0x5B: 264,
        0x5C: 265, 0x41: 266, 0x4B: 267, 0x43: 268, 0x4E: 269, 0x45: 270, 0x4C: 271, 0x51: 272, 0x47: 12,
        // Modifiers
        0x39: 301, 0x3C: 303, 0x38: 304, 0x3E: 305, 0x3B: 306, 0x3D: 307, 0x3A: 308, 0x36: 309, 0x37: 310,
    ]
}
