// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import simd

/// A logical RetroPad input that can be bound to a key.
nonisolated enum RetroInput: String, CaseIterable, Codable, Identifiable, Sendable {
    case up, down, left, right
    case a, b, x, y
    case l, r, l2, r2, l3, r3
    case start, select
    case leftStickUp, leftStickDown, leftStickLeft, leftStickRight
    case rightStickUp, rightStickDown, rightStickLeft, rightStickRight

    var id: String { rawValue }

    var title: String {
        switch self {
        case .up: String(localized: "D-Pad Up")
        case .down: String(localized: "D-Pad Down")
        case .left: String(localized: "D-Pad Left")
        case .right: String(localized: "D-Pad Right")
        case .a: "A"
        case .b: "B"
        case .x: "X"
        case .y: "Y"
        case .l: "L"
        case .r: "R"
        case .l2: "L2"
        case .r2: "R2"
        case .l3: "L3"
        case .r3: "R3"
        case .start: "Start"
        case .select: "Select"
        case .leftStickUp: String(localized: "Left Stick Up")
        case .leftStickDown: String(localized: "Left Stick Down")
        case .leftStickLeft: String(localized: "Left Stick Left")
        case .leftStickRight: String(localized: "Left Stick Right")
        case .rightStickUp: String(localized: "Right Stick Up")
        case .rightStickDown: String(localized: "Right Stick Down")
        case .rightStickLeft: String(localized: "Right Stick Left")
        case .rightStickRight: String(localized: "Right Stick Right")
        }
    }

    var button: RetroButton? {
        switch self {
        case .up: .up
        case .down: .down
        case .left: .left
        case .right: .right
        case .a: .A
        case .b: .B
        case .x: .X
        case .y: .Y
        case .l: .L
        case .r: .R
        case .l2: .L2
        case .r2: .R2
        case .l3: .L3
        case .r3: .R3
        case .start: .start
        case .select: .select
        default: nil
        }
    }

    enum Group: String, CaseIterable, Identifiable {
        case dpad, buttons, shoulders, system, leftStick, rightStick
        var id: String { rawValue }
        var title: String {
            switch self {
            case .dpad: String(localized: "D-Pad")
            case .buttons: String(localized: "Face Buttons")
            case .shoulders: String(localized: "Shoulder Buttons")
            case .system: String(localized: "Start & Select")
            case .leftStick: String(localized: "Left Analog Stick")
            case .rightStick: String(localized: "Right Analog Stick")
            }
        }
    }

    var group: Group {
        switch self {
        case .up, .down, .left, .right: .dpad
        case .a, .b, .x, .y: .buttons
        case .l, .r, .l2, .r2, .l3, .r3: .shoulders
        case .start, .select: .system
        case .leftStickUp, .leftStickDown, .leftStickLeft, .leftStickRight: .leftStick
        case .rightStickUp, .rightStickDown, .rightStickLeft, .rightStickRight: .rightStick
        }
    }
}

/// RetroPad state produced by one controller.
nonisolated struct PadState: Equatable, Sendable {
    var buttonMask: UInt32 = 0
    var leftStick: SIMD2<Float> = .zero
    var rightStick: SIMD2<Float> = .zero

    static let stickDeadZone: Float = 0.15

    mutating func set(_ button: RetroButton, _ pressed: Bool) {
        if pressed { buttonMask |= 1 << UInt32(button.rawValue) }
    }

    /// Removes stick noise around the centre and rescales the rest to 0…1.
    static func applyDeadZone(_ value: Float) -> Float {
        let magnitude = abs(value)
        guard magnitude > stickDeadZone else { return 0 }
        return copysign(min((magnitude - stickDeadZone) / (1 - stickDeadZone), 1), value)
    }
}

nonisolated struct KeyBinding: Codable, Hashable, Sendable {
    var keyCode: UInt16
    var label: String
}

/// Keyboard layout for player 1. Defaults follow RetroArch conventions.
nonisolated struct KeyboardMapping: Codable, Equatable, Sendable {
    var bindings: [RetroInput: KeyBinding]

    static let standard = KeyboardMapping(bindings: [
        .up: KeyBinding(keyCode: 126, label: "↑"),
        .down: KeyBinding(keyCode: 125, label: "↓"),
        .left: KeyBinding(keyCode: 123, label: "←"),
        .right: KeyBinding(keyCode: 124, label: "→"),
        .a: KeyBinding(keyCode: 7, label: "X"),
        .b: KeyBinding(keyCode: 6, label: "Z"),
        .x: KeyBinding(keyCode: 1, label: "S"),
        .y: KeyBinding(keyCode: 0, label: "A"),
        .l: KeyBinding(keyCode: 12, label: "Q"),
        .r: KeyBinding(keyCode: 13, label: "W"),
        .l2: KeyBinding(keyCode: 14, label: "E"),
        .r2: KeyBinding(keyCode: 15, label: "R"),
        .l3: KeyBinding(keyCode: 18, label: "1"),
        .r3: KeyBinding(keyCode: 19, label: "2"),
        .start: KeyBinding(keyCode: 36, label: "↩"),
        .select: KeyBinding(keyCode: 60, label: "⇧ right"),
        .leftStickUp: KeyBinding(keyCode: 34, label: "I"),
        .leftStickDown: KeyBinding(keyCode: 40, label: "K"),
        .leftStickLeft: KeyBinding(keyCode: 38, label: "J"),
        .leftStickRight: KeyBinding(keyCode: 37, label: "L"),
        .rightStickUp: KeyBinding(keyCode: 17, label: "T"),
        .rightStickDown: KeyBinding(keyCode: 5, label: "G"),
        .rightStickLeft: KeyBinding(keyCode: 3, label: "F"),
        .rightStickRight: KeyBinding(keyCode: 4, label: "H"),
    ])

    static var current: KeyboardMapping {
        get {
            guard let data = UserDefaults.standard.data(forKey: PrefKey.keyboardMapping),
                  let mapping = try? JSONDecoder().decode(KeyboardMapping.self, from: data) else { return .standard }
            return mapping
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: PrefKey.keyboardMapping)
        }
    }

    func input(forKeyCode keyCode: UInt16) -> [RetroInput] {
        bindings.filter { $0.value.keyCode == keyCode }.map(\.key)
    }
}

/// Keys handled by the player itself (not remappable).
nonisolated enum HotKey {
    static let escape: UInt16 = 53
    static let fastForward: UInt16 = 49 // Space
    static let quickSave: UInt16 = 120  // F2
    static let quickLoad: UInt16 = 118  // F4
    static let rewind: UInt16 = 51      // Backspace (⌫)
    static let screenshot: UInt16 = 100 // F8
    static let typing: UInt16 = 111     // F12
    static let shaderPanel: UInt16 = 97 // F6
}
