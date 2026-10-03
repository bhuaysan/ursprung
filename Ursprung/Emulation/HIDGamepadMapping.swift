// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import simd

/// A HID usage (page + usage ID) identifying one control of a gamepad.
nonisolated struct HIDUsage: Hashable, Codable, Sendable {
    var page: UInt32
    var usage: UInt32

    static let buttonPage: UInt32 = 0x09
    static let genericDesktopPage: UInt32 = 0x01
    static let simulationPage: UInt32 = 0x02

    static let x = HIDUsage(page: genericDesktopPage, usage: 0x30)
    static let y = HIDUsage(page: genericDesktopPage, usage: 0x31)
    static let z = HIDUsage(page: genericDesktopPage, usage: 0x32)
    static let rx = HIDUsage(page: genericDesktopPage, usage: 0x33)
    static let ry = HIDUsage(page: genericDesktopPage, usage: 0x34)
    static let rz = HIDUsage(page: genericDesktopPage, usage: 0x35)
    static let hat = HIDUsage(page: genericDesktopPage, usage: 0x39)
    static let brake = HIDUsage(page: simulationPage, usage: 0xC4)
    static let accelerator = HIDUsage(page: simulationPage, usage: 0xC5)

    static func button(_ number: UInt32) -> HIDUsage { HIDUsage(page: buttonPage, usage: number) }

    /// Whether the usage is a control a player can bind (buttons, sticks,
    /// triggers, hat), as opposed to battery level or vendor data.
    var isBindable: Bool {
        switch page {
        case Self.buttonPage: true
        case Self.genericDesktopPage: (0x30...0x39).contains(usage)
        case Self.simulationPage: [0xBA, 0xBB, 0xC4, 0xC5].contains(usage)
        default: false
        }
    }
}

/// Logical range of an element as reported by the device.
nonisolated struct HIDElementInfo: Hashable, Sendable {
    var min: Int
    var max: Int

    var span: Int { Swift.max(max - min, 1) }
}

nonisolated enum HatDirection: String, Codable, CaseIterable, Sendable {
    case up, down, left, right

    var arrow: String {
        switch self {
        case .up: "↑"
        case .down: "↓"
        case .left: "←"
        case .right: "→"
        }
    }
}

/// What a RetroPad input is bound to on a generic HID gamepad.
nonisolated enum HIDBinding: Codable, Hashable, Sendable {
    case button(UInt32)
    /// One direction of a centred axis (stick).
    case axis(HIDUsage, positive: Bool)
    /// An axis that rests at its minimum (analog trigger).
    case trigger(HIDUsage)
    case hat(HatDirection)

    var label: String {
        switch self {
        case .button(let number):
            String(localized: "Button \(Int(number))")
        case .axis(let usage, let positive):
            String(localized: "Axis \(Self.axisName(usage))\(positive ? "+" : "−")")
        case .trigger(let usage):
            String(localized: "Axis \(Self.axisName(usage))")
        case .hat(let direction):
            String(localized: "Hat \(direction.arrow)")
        }
    }

    private static func axisName(_ usage: HIDUsage) -> String {
        switch usage {
        case .x: "X"
        case .y: "Y"
        case .z: "Z"
        case .rx: "Rx"
        case .ry: "Ry"
        case .rz: "Rz"
        case .brake: "L"
        case .accelerator: "R"
        default: String(format: "%02X", usage.usage)
        }
    }
}

/// The current values of a gamepad's elements, with the logic to evaluate
/// bindings against them.
nonisolated struct HIDGamepadSnapshot: Sendable {
    var elements: [HIDUsage: HIDElementInfo]
    var values: [HIDUsage: Int] = [:]

    /// Strength of a binding between 0 (released) and 1 (fully pressed).
    func value(of binding: HIDBinding) -> Float {
        switch binding {
        case .button(let number):
            return (values[.button(number)] ?? 0) != 0 ? 1 : 0
        case .axis(let usage, let positive):
            guard let info = elements[usage], let raw = values[usage] else { return 0 }
            let centred = Float(raw - info.min) / Float(info.span) * 2 - 1
            // Raw; the input router applies the stick dead zone.
            return simd_clamp(positive ? centred : -centred, 0, 1)
        case .trigger(let usage):
            guard let info = elements[usage], let raw = values[usage] else { return 0 }
            return simd_clamp(Float(raw - info.min) / Float(info.span), 0, 1)
        case .hat(let direction):
            return hatDirections.contains(direction) ? 1 : 0
        }
    }

    func isPressed(_ binding: HIDBinding?) -> Bool {
        guard let binding else { return false }
        return value(of: binding) >= 0.5
    }

    /// Directions of the hat switch; out-of-range values mean "centred".
    var hatDirections: Set<HatDirection> {
        guard let info = elements[.hat], let raw = values[.hat] else { return [] }
        let index = raw - info.min
        switch info.max - info.min + 1 {
        case 8:
            let table: [Set<HatDirection>] = [[.up], [.up, .right], [.right], [.down, .right],
                                              [.down], [.down, .left], [.left], [.up, .left]]
            return table.indices.contains(index) ? table[index] : []
        case 4:
            let table: [Set<HatDirection>] = [[.up], [.right], [.down], [.left]]
            return table.indices.contains(index) ? table[index] : []
        default:
            return []
        }
    }

    /// The binding a player means when `usage` changed while learning,
    /// comparing against the values captured when learning began.
    func learnedBinding(for usage: HIDUsage, rest: [HIDUsage: Int]) -> HIDBinding? {
        guard usage.isBindable, let raw = values[usage] else { return nil }
        if usage.page == HIDUsage.buttonPage {
            return raw != 0 ? .button(usage.usage) : nil
        }
        if usage == .hat {
            let directions = hatDirections
            return directions.count == 1 ? directions.first.map(HIDBinding.hat) : nil
        }
        guard let info = elements[usage] else { return nil }
        let restValue = rest[usage] ?? (info.min + info.max) / 2
        let displacement = Float(raw - restValue) / Float(info.span)
        guard abs(displacement) >= 0.4 else { return nil }
        let restsAtMinimum = Float(restValue - info.min) / Float(info.span) < 0.1
        return restsAtMinimum ? .trigger(usage) : .axis(usage, positive: displacement > 0)
    }
}

/// Button layout for a gamepad that the GameController framework does not
/// support. Stored per vendor/product ID.
nonisolated struct HIDGamepadMapping: Codable, Equatable, Sendable {
    var bindings: [RetroInput: HIDBinding]
    /// Opens the game menu, like the Home button on supported controllers.
    var menu: HIDBinding?

    /// A best guess from the elements the device reports. Pads with 15 or
    /// more buttons usually follow the Android/8BitDo layout, smaller ones the
    /// classic DirectInput layout. Face buttons are mapped by position, like
    /// on supported controllers: the bottom one is RetroPad B.
    static func standard(for elements: some Collection<HIDUsage>) -> HIDGamepadMapping {
        let available = Set(elements)
        let buttonCount = available.filter { $0.page == HIDUsage.buttonPage }.count
        var bindings: [RetroInput: HIDBinding] = [:]
        var menu: HIDBinding?

        func bind(_ input: RetroInput, button number: UInt32) {
            if available.contains(.button(number)) { bindings[input] = .button(number) }
        }

        if buttonCount >= 15 {
            bind(.a, button: 1); bind(.b, button: 2); bind(.x, button: 4); bind(.y, button: 5)
            bind(.l, button: 7); bind(.r, button: 8); bind(.l2, button: 9); bind(.r2, button: 10)
            bind(.select, button: 11); bind(.start, button: 12); bind(.l3, button: 14); bind(.r3, button: 15)
            if available.contains(.button(13)) { menu = .button(13) }
        } else {
            bind(.y, button: 1); bind(.b, button: 2); bind(.a, button: 3); bind(.x, button: 4)
            bind(.l, button: 5); bind(.r, button: 6); bind(.l2, button: 7); bind(.r2, button: 8)
            bind(.select, button: 9); bind(.start, button: 10); bind(.l3, button: 11); bind(.r3, button: 12)
            if available.contains(.button(13)) { menu = .button(13) }
        }
        if available.contains(.brake) { bindings[.l2] = .trigger(.brake) }
        if available.contains(.accelerator) { bindings[.r2] = .trigger(.accelerator) }

        if available.contains(.hat) {
            bindings[.up] = .hat(.up)
            bindings[.down] = .hat(.down)
            bindings[.left] = .hat(.left)
            bindings[.right] = .hat(.right)
        }

        func bindStick(x: HIDUsage, y: HIDUsage, _ left: RetroInput, _ right: RetroInput, _ up: RetroInput, _ down: RetroInput) {
            guard available.contains(x), available.contains(y) else { return }
            bindings[left] = .axis(x, positive: false)
            bindings[right] = .axis(x, positive: true)
            bindings[up] = .axis(y, positive: false)
            bindings[down] = .axis(y, positive: true)
        }
        bindStick(x: .x, y: .y, .leftStickLeft, .leftStickRight, .leftStickUp, .leftStickDown)
        if available.contains(.z), available.contains(.rz) {
            bindStick(x: .z, y: .rz, .rightStickLeft, .rightStickRight, .rightStickUp, .rightStickDown)
        } else {
            bindStick(x: .rx, y: .ry, .rightStickLeft, .rightStickRight, .rightStickUp, .rightStickDown)
        }

        return HIDGamepadMapping(bindings: bindings, menu: menu)
    }

    func state(from snapshot: HIDGamepadSnapshot) -> PadState {
        var state = PadState()
        func value(_ input: RetroInput) -> Float {
            bindings[input].map(snapshot.value(of:)) ?? 0
        }
        for (input, binding) in bindings {
            if let button = input.button { state.set(button, snapshot.isPressed(binding)) }
        }
        state.leftStick = SIMD2(value(.leftStickRight) - value(.leftStickLeft),
                                value(.leftStickDown) - value(.leftStickUp))
        state.rightStick = SIMD2(value(.rightStickRight) - value(.rightStickLeft),
                                 value(.rightStickDown) - value(.rightStickUp))
        return state
    }

    /// Something a control can be bound to: a RetroPad input or the game menu.
    nonisolated enum Slot: Hashable, Sendable {
        case input(RetroInput)
        case menu

        static let all: [Slot] = RetroInput.allCases.map(Slot.input) + [.menu]

        var title: String {
            switch self {
            case .input(let input): input.title
            case .menu: String(localized: "Game Menu")
            }
        }
    }

    subscript(slot: Slot) -> HIDBinding? {
        get {
            switch slot {
            case .input(let input): bindings[input]
            case .menu: menu
            }
        }
        set {
            switch slot {
            case .input(let input): bindings[input] = newValue
            case .menu: menu = newValue
            }
        }
    }

    /// Binds `binding` to `slot`. One control drives one slot, so a slot that
    /// had the control loses it; that slot is returned.
    @discardableResult
    mutating func assign(_ binding: HIDBinding, to slot: Slot) -> Slot? {
        let previous = Slot.all.first { $0 != slot && self[$0] == binding }
        for other in Slot.all where other != slot && self[other] == binding {
            self[other] = nil
        }
        self[slot] = binding
        return previous
    }

    static func stored(forKey key: String) -> HIDGamepadMapping? {
        guard let data = UserDefaults.standard.data(forKey: PrefKey.hidGamepadMapping(key)) else { return nil }
        return try? JSONDecoder().decode(HIDGamepadMapping.self, from: data)
    }

    static func store(_ mapping: HIDGamepadMapping?, forKey key: String) {
        UserDefaults.standard.set(mapping.flatMap { try? JSONEncoder().encode($0) }, forKey: PrefKey.hidGamepadMapping(key))
    }
}
