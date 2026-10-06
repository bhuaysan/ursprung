// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import simd

/// Which controller button presses which RetroPad button. Controllers report
/// buttons by position (the bottom face button is B, as on a SNES pad); this
/// layer lets the player move them around, for every kind of controller.
/// Sticks are not remapped.
nonisolated struct ControllerMapping: Codable, Equatable, Sendable {
    /// RetroPad button → the controller button that presses it. A missing
    /// entry means the button itself; an entry of nil means nothing.
    var sources: [RetroInput: RetroInput?] = [:]

    static let standard = ControllerMapping()

    /// The RetroPad inputs that are buttons and can be remapped.
    static let buttons: [RetroInput] = RetroInput.allCases.filter { $0.button != nil }

    func source(for target: RetroInput) -> RetroInput? {
        if let entry = sources[target] { return entry }
        return target
    }

    mutating func setSource(_ source: RetroInput?, for target: RetroInput) {
        if source == target { sources[target] = nil } else { sources[target] = .some(source) }
    }

    var isStandard: Bool { sources.isEmpty }

    /// The pad state after remapping.
    func apply(to pad: PadState) -> PadState {
        guard !isStandard else { return pad }
        var result = pad
        result.buttonMask = 0
        for target in Self.buttons {
            guard let button = target.button, let source = source(for: target)?.button else { continue }
            result.set(button, pad.buttonMask & (1 << UInt32(source.rawValue)) != 0)
        }
        return result
    }
}

/// Controls for playing: the keyboard layout and the controller button
/// layout. There is one for all systems, and optionally one per system and
/// one per game; the most specific one applies.
nonisolated struct InputProfile: Codable, Equatable, Sendable {
    var keyboard: KeyboardMapping
    var controller: ControllerMapping
    /// Buttons that fire repeatedly while held (autofire), for every player.
    /// Optional so profiles saved before turbo existed still decode.
    var turboButtons: Set<RetroInput>?

    static let standard = InputProfile(keyboard: .standard, controller: .standard)

    /// The RetroPad bit mask of the turbo buttons.
    var turboMask: UInt32 {
        (turboButtons ?? []).reduce(0) { mask, input in
            input.button.map { mask | 1 << UInt32($0.rawValue) } ?? mask
        }
    }

    /// The profile for all systems.
    static var global: InputProfile {
        get {
            let controller = UserDefaults.standard.data(forKey: PrefKey.controllerMapping)
                .flatMap { try? JSONDecoder().decode(ControllerMapping.self, from: $0) } ?? .standard
            let turbo = UserDefaults.standard.data(forKey: PrefKey.turboButtons)
                .flatMap { try? JSONDecoder().decode(Set<RetroInput>.self, from: $0) }
            return InputProfile(keyboard: KeyboardMapping.current, controller: controller, turboButtons: turbo)
        }
        set {
            KeyboardMapping.current = newValue.keyboard
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue.controller), forKey: PrefKey.controllerMapping)
            let turbo = newValue.turboButtons.flatMap { $0.isEmpty ? nil : $0 }
            UserDefaults.standard.set(turbo.flatMap { try? JSONEncoder().encode($0) }, forKey: PrefKey.turboButtons)
        }
    }

    /// A system's own profile, or nil when it uses the one for all systems.
    static func system(_ systemID: String) -> InputProfile? {
        UserDefaults.standard.data(forKey: PrefKey.inputProfile(systemID)).flatMap(decode)
    }

    static func setSystem(_ profile: InputProfile?, for systemID: String) {
        UserDefaults.standard.set(profile.flatMap { try? JSONEncoder().encode($0) }, forKey: PrefKey.inputProfile(systemID))
    }

    static func decode(_ data: Data) -> InputProfile? {
        try? JSONDecoder().decode(InputProfile.self, from: data)
    }

    var encoded: Data? { try? JSONEncoder().encode(self) }

    /// The profile that applies to `game`: its own, its system's, or the global one.
    static func resolved(gameProfile: Data?, systemID: String?) -> InputProfile {
        if let data = gameProfile, let profile = decode(data) { return profile }
        if let systemID, let profile = system(systemID) { return profile }
        return global
    }
}

/// Player actions bound to keys, handled by the player rather than the game.
nonisolated enum HotkeyAction: String, CaseIterable, Codable, Identifiable, Sendable {
    case menu, fastForward, fastForwardToggle, rewind, quickSave, quickLoad, screenshot, turbo, typing, shaderPanel

    var id: String { rawValue }

    var title: String {
        switch self {
        case .menu: String(localized: "Game Menu")
        case .fastForward: String(localized: "Fast Forward (hold)")
        case .fastForwardToggle: String(localized: "Fast Forward (on/off)")
        case .rewind: String(localized: "Rewind (hold)")
        case .quickSave: String(localized: "Quick Save")
        case .quickLoad: String(localized: "Quick Load")
        case .screenshot: String(localized: "Take Screenshot")
        case .turbo: String(localized: "Turbo Buttons (on/off)")
        case .typing: String(localized: "Type on Computer Keyboard (on/off)")
        case .shaderPanel: String(localized: "Shader Panel (show/hide)")
        }
    }

    /// Hotkeys that act while held; the others act once per press.
    var isHeld: Bool { self == .fastForward || self == .rewind }
}

nonisolated struct HotkeyMapping: Codable, Equatable, Sendable {
    var bindings: [HotkeyAction: KeyBinding]
    /// The actions the user has seen in Settings. An action added in a later
    /// version gets its default key, unless the user already uses that key;
    /// a hotkey the user cleared stays cleared. nil: the first four actions.
    var knownActions: Set<HotkeyAction>?

    static let standard = HotkeyMapping(bindings: [
        .menu: KeyBinding(keyCode: HotKey.escape, label: "esc"),
        .fastForward: KeyBinding(keyCode: HotKey.fastForward, label: String(localized: "Space")),
        .rewind: KeyBinding(keyCode: HotKey.rewind, label: "⌫"),
        .quickSave: KeyBinding(keyCode: HotKey.quickSave, label: "F2"),
        .quickLoad: KeyBinding(keyCode: HotKey.quickLoad, label: "F4"),
        .screenshot: KeyBinding(keyCode: HotKey.screenshot, label: "F8"),
        .typing: KeyBinding(keyCode: HotKey.typing, label: "F12"),
        .shaderPanel: KeyBinding(keyCode: HotKey.shaderPanel, label: "F6"),
    ], knownActions: Set(HotkeyAction.allCases))

    static var current: HotkeyMapping {
        get {
            guard let data = UserDefaults.standard.data(forKey: PrefKey.hotkeys),
                  let mapping = try? JSONDecoder().decode(HotkeyMapping.self, from: data) else { return .standard }
            return mapping.addingNewActions()
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: PrefKey.hotkeys) }
    }

    /// Gives actions this mapping does not know yet their default keys.
    func addingNewActions() -> HotkeyMapping {
        let known = knownActions ?? [.menu, .fastForward, .quickSave, .quickLoad]
        var mapping = self
        for action in HotkeyAction.allCases where !known.contains(action) {
            guard let binding = Self.standard.bindings[action],
                  !mapping.bindings.values.contains(where: { $0.keyCode == binding.keyCode }) else { continue }
            mapping.bindings[action] = binding
        }
        mapping.knownActions = Set(HotkeyAction.allCases)
        return mapping
    }

    /// The action of a key. esc always opens the game menu as well, so a
    /// rebound menu key can never lock the player in.
    func action(forKeyCode keyCode: UInt16) -> HotkeyAction? {
        if let action = bindings.first(where: { $0.value.keyCode == keyCode })?.key { return action }
        return keyCode == HotKey.escape ? .menu : nil
    }
}

/// Where controllers play. A controller can be given a fixed player; the
/// others take the remaining players in the order they connected.
nonisolated enum PortAssignment {
    /// Ports for the controllers in `ids` (connection order). `fixed` maps a
    /// controller ID to its chosen port. Controllers beyond the last port get nil.
    static func resolve(_ ids: [String], fixed: [String: Int], ports: Int) -> [Int?] {
        let fixedPorts = ids.compactMap { fixed[$0] }.filter { (0..<ports).contains($0) }
        var free = (0..<ports).filter { !fixedPorts.contains($0) }.makeIterator()
        return ids.map { id in
            if let port = fixed[id], (0..<ports).contains(port) { return port }
            return free.next()
        }
    }

    /// Stable IDs for controllers: kind and name, numbered when several of
    /// the same model are connected ("xinput:8BitDo#2").
    static func ids(for controllers: [(kind: String, name: String)]) -> [String] {
        var seen: [String: Int] = [:]
        return controllers.map { controller in
            let base = "\(controller.kind):\(controller.name)"
            seen[base, default: 0] += 1
            return "\(base)#\(seen[base]!)"
        }
    }

    static var fixed: [String: Int] {
        get { UserDefaults.standard.dictionary(forKey: PrefKey.portAssignments) as? [String: Int] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: PrefKey.portAssignments) }
    }
}

extension PadState {
    /// Removes stick noise around the centre (radially) and rescales the rest.
    static func applyDeadZone(_ stick: SIMD2<Float>, deadZone: Float) -> SIMD2<Float> {
        let magnitude = simd_length(stick)
        guard magnitude > deadZone, magnitude > 0 else { return .zero }
        let scaled = min((magnitude - deadZone) / max(1 - deadZone, 0.01), 1)
        return stick / magnitude * scaled
    }
}
