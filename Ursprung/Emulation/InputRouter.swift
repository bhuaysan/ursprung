// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import GameController
import Observation
import simd

/// A menu command from a game controller, for the pause menu and the
/// library. Positional, like the RetroPad mapping: the right face button
/// confirms, the bottom one goes back, the top one is a secondary action;
/// the shoulder buttons switch pages.
nonisolated enum MenuCommand: Equatable, Sendable {
    case up, down, left, right, confirm, back, secondary, previousPage, nextPage

    /// Commands that repeat while their button is held.
    var repeats: Bool { [.up, .down, .left, .right].contains(self) }
}

/// One controller press in the pause menu; the ID makes a repeated command a change.
nonisolated struct MenuEvent: Equatable, Sendable {
    let id: Int
    let command: MenuCommand
}

/// A connected controller as the Controls settings show it.
struct ConnectedController: Identifiable {
    enum Kind: String { case gameController = "gc", xinput, hid }

    /// Stable across reconnects (see `PortAssignment.ids`).
    let id: String
    let name: String
    let kind: Kind
    /// The player it feeds now; nil when all players are taken.
    let port: Int?
    /// The player it was given in Settings; nil for automatic.
    let fixedPort: Int?
    /// Generic HID pads have a configurable layout.
    let hidGamepad: HIDGamepad?
    let batteryLevel: Int?
}

/// Merges keyboard and game controller state into RetroPad button masks and
/// analog values and forwards them to the running core. Controllers the
/// GameController framework does not support are read through IOKit: Xbox 360
/// protocol pads over USB (XInput) and generic HID gamepads.
///
/// Controllers play as the player chosen for them in Settings, or else take
/// the free players in connection order. The keyboard always plays as player 1.
/// The active `InputProfile` remaps keys and controller buttons.
@Observable
final class InputRouter {
    private(set) var connectedControllers: [GCController] = []
    let xinput = XInputGamepadManager()
    let hid = HIDGamepadManager()

    @ObservationIgnored weak var core: LibretroCore?
    /// Whether the left stick also drives the D-pad (for digital-only systems).
    @ObservationIgnored var stickDrivesDPad = true
    @ObservationIgnored var onMenuButton: (() -> Void)? {
        didSet { xinput.onMenuButton = onMenuButton }
    }
    /// While set, controllers drive the pause menu and the core sees released pads.
    @ObservationIgnored var routesToMenu = false {
        didSet {
            // Buttons held while the menu opens do not act in it.
            menuButtons = routesToMenu ? Self.menuMask(of: padStates().map(\.state)) : 0
            push()
        }
    }
    /// The latest controller press in the pause menu.
    private(set) var menuEvent: MenuEvent?
    /// While set (the library window is key and no game runs), controllers
    /// move through the library and feed no core.
    @ObservationIgnored var routesToLibrary = false {
        didSet {
            guard routesToLibrary != oldValue else { return }
            // Buttons held when the library takes over do not act in it.
            libraryButtons = routesToLibrary ? Self.menuMask(of: padStates().map(\.state)) : 0
            updateRepeat(0)
            push()
        }
    }
    /// The latest controller press in the library; directions repeat while held.
    private(set) var libraryEvent: MenuEvent?

    /// The controls in use: the running game's, or the global ones.
    @ObservationIgnored var profile = InputProfile.global {
        didSet { pressedKeys.removeAll(); push() }
    }
    private(set) var hotkeys = HotkeyMapping.current
    /// Players chosen for controllers, by controller ID.
    private(set) var fixedPorts = PortAssignment.fixed

    /// While set, the state of every player is published in `livePorts`
    /// (the input test in Settings).
    var isMonitoring = false {
        didSet { push() }
    }
    /// The RetroPad state of each player, while monitoring.
    private(set) var livePorts: [PadState] = Array(repeating: PadState(), count: Int(URMaxPorts))

    /// HID gamepads that are not already handled by the GameController
    /// framework.
    var hidGamepads: [HIDGamepad] {
        let names = Set(connectedControllers.compactMap(\.vendorName))
        return hid.gamepads.filter { Self.isReadThroughHID(vendorID: $0.vendorID, name: $0.name, controllerNames: names) }
    }

    /// Whether a HID device is read by the HID manager rather than by the
    /// GameController framework. Input and menu events of any other device
    /// are ignored, or the same physical pad would act twice.
    static func isReadThroughHID(vendorID: Int, name: String, controllerNames: Set<String>) -> Bool {
        !HIDGamepad.gameControllerVendors.contains(vendorID) && !controllerNames.contains(name)
    }

    /// The pad states of the HID gamepads in port order. A pad that is
    /// learning a binding keeps its port but reports a neutral state.
    static func hidStates(_ pads: [(state: PadState, isLearning: Bool)]) -> [PadState] {
        pads.map { $0.isLearning ? PadState() : $0.state }
    }

    /// Every connected controller with the player it feeds, in connection
    /// order: GameController pads, XInput, then HID.
    var controllers: [ConnectedController] {
        let gc = connectedControllers.map { (ConnectedController.Kind.gameController, $0.vendorName ?? String(localized: "Controller"), HIDGamepad?.none, Int?.none) }
        let xi = xinput.gamepads.map { (ConnectedController.Kind.xinput, $0.name, HIDGamepad?.none, Int?.none) }
        let hi = hidGamepads.map { (ConnectedController.Kind.hid, $0.name, Optional($0), $0.batteryLevel) }
        let all = gc + xi + hi
        let ids = PortAssignment.ids(for: all.map { ($0.0.rawValue, $0.1) })
        let ports = PortAssignment.resolve(ids, fixed: fixedPorts, ports: Int(URMaxPorts))
        return all.indices.map { index in
            ConnectedController(id: ids[index], name: all[index].1, kind: all[index].0, port: ports[index],
                                fixedPort: fixedPorts[ids[index]], hidGamepad: all[index].2, batteryLevel: all[index].3)
        }
    }

    /// Pad names in port order.
    var controllerNames: [String] {
        controllers.map(\.name)
    }

    @ObservationIgnored private var pressedKeys = Set<UInt16>()
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var menuButtons: UInt32 = 0
    @ObservationIgnored private var libraryButtons: UInt32 = 0
    @ObservationIgnored private var repeating: MenuCommand?
    @ObservationIgnored private var repeatTimer: Timer?
    @ObservationIgnored private var deadZone = Preferences.stickDeadZone
    @ObservationIgnored private var learning: ((RetroInput) -> Void)?
    @ObservationIgnored private var learnBaseline: UInt32 = 0
    @ObservationIgnored private var lastPorts: [String: Int?] = [:]

    init() {
        GCController.shouldMonitorBackgroundEvents = false
        observers.append(NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshControllers() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshControllers() }
        })
        xinput.onInput = { [weak self] in self?.push() }
        hid.onInput = { [weak self] in self?.push() }
        hid.onMenuButton = { [weak self] gamepad in
            // Only pads that feed the game may open its menu.
            guard let self, hidGamepads.contains(where: { $0 === gamepad }) else { return }
            onMenuButton?()
        }
        refreshControllers()
        GCController.startWirelessControllerDiscovery {}
    }

    /// Back to the controls for all systems, e.g. after a game ends or the
    /// global controls changed.
    func reloadMapping() {
        profile = .global
    }

    /// Reloads hotkeys, dead zone and player choices from Preferences.
    func reloadSettings() {
        hotkeys = .current
        deadZone = Preferences.stickDeadZone
        fixedPorts = PortAssignment.fixed
        push()
    }

    /// Gives the controller `id` a fixed player, or nil for automatic.
    func setFixedPort(_ port: Int?, for id: String) {
        var fixed = PortAssignment.fixed
        fixed[id] = port
        PortAssignment.fixed = fixed
        fixedPorts = fixed
        push()
    }

    func reset() {
        pressedKeys.removeAll()
        push()
    }

    // MARK: Keyboard

    /// Returns true when the key is bound to a RetroPad input.
    @discardableResult
    func keyDown(_ keyCode: UInt16) -> Bool {
        guard !profile.keyboard.input(forKeyCode: keyCode).isEmpty else { return false }
        pressedKeys.insert(keyCode)
        push()
        return true
    }

    @discardableResult
    func keyUp(_ keyCode: UInt16) -> Bool {
        guard pressedKeys.remove(keyCode) != nil else { return false }
        push()
        return true
    }

    // MARK: Learning a controller button

    /// Reports the next controller button pressed on any controller, by
    /// position (before remapping). Controllers feed nothing else meanwhile.
    func learnControllerButton(_ completion: @escaping (RetroInput) -> Void) {
        learnBaseline = padStates().reduce(0) { $0 | $1.state.buttonMask }
        learning = completion
    }

    func cancelControllerLearning() {
        learning = nil
    }

    private func learn(from pads: [PadState]) {
        guard let completion = learning else { return }
        let mask = pads.reduce(0) { $0 | $1.buttonMask }
        let new = mask & ~learnBaseline
        learnBaseline = mask
        guard new != 0,
              let input = ControllerMapping.buttons.first(where: { $0.button.map { new & (1 << UInt32($0.rawValue)) != 0 } ?? false })
        else { return }
        learning = nil
        completion(input)
    }

    // MARK: Controllers

    private func refreshControllers() {
        connectedControllers = GCController.controllers().filter { $0.extendedGamepad != nil }
        for controller in connectedControllers {
            controller.extendedGamepad?.valueChangedHandler = { [weak self] _, _ in
                MainActor.assumeIsolated { self?.push() }
            }
            // Keep the Home button from opening Launchpad so it can open the game menu.
            controller.extendedGamepad?.buttonHome?.preferredSystemGestureState = .alwaysReceive
            controller.extendedGamepad?.buttonHome?.pressedChangedHandler = { [weak self] _, _, pressed in
                MainActor.assumeIsolated { if pressed { self?.onMenuButton?() } }
            }
        }
        push()
    }

    /// Positional mapping: the bottom face button is RetroPad B, etc.
    private static func state(of controller: GCController) -> PadState {
        var state = PadState()
        guard let pad = controller.extendedGamepad else { return state }
        state.set(.up, pad.dpad.up.isPressed)
        state.set(.down, pad.dpad.down.isPressed)
        state.set(.left, pad.dpad.left.isPressed)
        state.set(.right, pad.dpad.right.isPressed)
        state.set(.B, pad.buttonA.isPressed)
        state.set(.A, pad.buttonB.isPressed)
        state.set(.Y, pad.buttonX.isPressed)
        state.set(.X, pad.buttonY.isPressed)
        state.set(.L, pad.leftShoulder.isPressed)
        state.set(.R, pad.rightShoulder.isPressed)
        state.set(.L2, pad.leftTrigger.isPressed)
        state.set(.R2, pad.rightTrigger.isPressed)
        state.set(.L3, pad.leftThumbstickButton?.isPressed ?? false)
        state.set(.R3, pad.rightThumbstickButton?.isPressed ?? false)
        state.set(.start, pad.buttonMenu.isPressed)
        state.set(.select, pad.buttonOptions?.isPressed ?? false)
        state.leftStick = SIMD2(pad.leftThumbstick.xAxis.value, -pad.leftThumbstick.yAxis.value)
        state.rightStick = SIMD2(pad.rightThumbstick.xAxis.value, -pad.rightThumbstick.yAxis.value)
        return state
    }

    // MARK: Pause menu

    /// The menu buttons held on any pad. The left stick always acts as a D-pad here.
    static func menuMask(of pads: [PadState]) -> UInt32 {
        pads.reduce(0) { mask, pad in
            var pad = pad
            pad.set(.left, pad.leftStick.x < -0.5)
            pad.set(.right, pad.leftStick.x > 0.5)
            pad.set(.up, pad.leftStick.y < -0.5)
            pad.set(.down, pad.leftStick.y > 0.5)
            return mask | pad.buttonMask
        }
    }

    /// The commands for buttons pressed since `previous`, in a fixed order.
    static func menuCommands(pressed mask: UInt32, previous: UInt32) -> [MenuCommand] {
        let new = mask & ~previous
        let buttons: [(RetroButton, MenuCommand)] = [
            (.up, .up), (.down, .down), (.left, .left), (.right, .right), (.A, .confirm), (.B, .back),
            (.X, .secondary), (.L, .previousPage), (.R, .nextPage),
        ]
        return buttons.filter { new & (1 << UInt32($0.0.rawValue)) != 0 }.map(\.1)
    }

    private func routeToMenu(_ pads: [PadState]) {
        let mask = Self.menuMask(of: pads)
        for command in Self.menuCommands(pressed: mask, previous: menuButtons) {
            menuEvent = MenuEvent(id: (menuEvent?.id ?? 0) + 1, command: command)
        }
        menuButtons = mask
    }

    // MARK: Library

    /// Delay before a held direction repeats, and the interval after that.
    static let repeatDelay: TimeInterval = 0.4
    static let repeatInterval: TimeInterval = 0.09

    private func routeToLibrary(_ pads: [PadState]) {
        let mask = Self.menuMask(of: pads)
        for command in Self.menuCommands(pressed: mask, previous: libraryButtons) {
            sendLibraryEvent(command)
        }
        libraryButtons = mask
        updateRepeat(mask)
    }

    private func sendLibraryEvent(_ command: MenuCommand) {
        libraryEvent = MenuEvent(id: (libraryEvent?.id ?? 0) + 1, command: command)
    }

    /// Starts repeating the direction held in `mask`, or stops.
    private func updateRepeat(_ mask: UInt32) {
        let held = Self.menuCommands(pressed: mask, previous: 0).first(where: \.repeats)
        guard held != repeating else { return }
        repeating = held
        repeatTimer?.invalidate()
        repeatTimer = nil
        guard let held else { return }
        repeatTimer = Timer.scheduledTimer(withTimeInterval: Self.repeatDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.startRepeating(held) }
        }
    }

    private func startRepeating(_ command: MenuCommand) {
        guard repeating == command else { return }
        repeatTimer = Timer.scheduledTimer(withTimeInterval: Self.repeatInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.repeating == command, self.routesToLibrary else { return }
                self.sendLibraryEvent(command)
            }
        }
    }

    // MARK: State

    /// Every controller with its positional state and its player, in
    /// connection order.
    private func padStates() -> [(state: PadState, port: Int?)] {
        let learning = hid.learningGamepad
        let hidStates = Self.hidStates(hidGamepads.map { (state: $0.state, isLearning: $0 === learning) })
        let states = connectedControllers.map(Self.state(of:)) + xinput.gamepads.map(\.state) + hidStates
        let controllers = controllers
        updatePlayerIndicators(controllers)
        return zip(states, controllers).map { ($0, $1.port) }
    }

    /// Player lights follow the players controllers feed.
    private func updatePlayerIndicators(_ controllers: [ConnectedController]) {
        let ports = Dictionary(controllers.map { ($0.id, $0.port) }, uniquingKeysWith: { first, _ in first })
        guard ports != lastPorts else { return }
        lastPorts = ports
        for (controller, info) in zip(connectedControllers, controllers.filter { $0.kind == .gameController }) {
            controller.playerIndex = info.port.flatMap { GCControllerPlayerIndex(rawValue: $0) } ?? .indexUnset
        }
        for (gamepad, info) in zip(xinput.gamepads, controllers.filter { $0.kind == .xinput }) {
            xinput.setPlayer(info.port, for: gamepad)
        }
    }

    /// The RetroPad state of each player: keyboard and controllers, remapped
    /// by the profile, with the dead zone applied.
    private func portStates(_ pads: [(state: PadState, port: Int?)], includesKeyboard: Bool) -> [PadState] {
        var ports = [PadState](repeating: PadState(), count: Int(URMaxPorts))

        // Keyboard → player 1
        for key in pressedKeys where includesKeyboard {
            for input in profile.keyboard.input(forKeyCode: key) {
                if let button = input.button {
                    ports[0].set(button, true)
                } else {
                    switch input {
                    case .leftStickUp: ports[0].leftStick.y -= 1
                    case .leftStickDown: ports[0].leftStick.y += 1
                    case .leftStickLeft: ports[0].leftStick.x -= 1
                    case .leftStickRight: ports[0].leftStick.x += 1
                    case .rightStickUp: ports[0].rightStick.y -= 1
                    case .rightStickDown: ports[0].rightStick.y += 1
                    case .rightStickLeft: ports[0].rightStick.x -= 1
                    case .rightStickRight: ports[0].rightStick.x += 1
                    default: break
                    }
                }
            }
        }

        for (state, port) in pads {
            guard let port else { continue }
            var pad = profile.controller.apply(to: state)
            pad.leftStick = PadState.applyDeadZone(pad.leftStick, deadZone: deadZone)
            pad.rightStick = PadState.applyDeadZone(pad.rightStick, deadZone: deadZone)
            if stickDrivesDPad {
                pad.set(.left, pad.leftStick.x < -0.5)
                pad.set(.right, pad.leftStick.x > 0.5)
                pad.set(.up, pad.leftStick.y < -0.5)
                pad.set(.down, pad.leftStick.y > 0.5)
            }
            ports[port].buttonMask |= pad.buttonMask
            ports[port].leftStick += pad.leftStick
            ports[port].rightStick += pad.rightStick
        }
        for index in ports.indices {
            ports[index].leftStick = simd_clamp(ports[index].leftStick, SIMD2(repeating: -1), SIMD2(repeating: 1))
            ports[index].rightStick = simd_clamp(ports[index].rightStick, SIMD2(repeating: -1), SIMD2(repeating: 1))
        }
        return ports
    }

    private func push() {
        var pads = padStates()
        if learning != nil {
            learn(from: pads.map(\.state))
            pads = []
        }
        if routesToMenu {
            routeToMenu(pads.map(\.state))
            pads = []
        } else if routesToLibrary {
            routeToLibrary(pads.map(\.state))
            pads = []
        }
        let ports = portStates(pads, includesKeyboard: !routesToMenu && learning == nil)
        if isMonitoring, ports != livePorts { livePorts = ports }
        guard let core else { return }
        for (index, pad) in ports.enumerated() {
            core.setButtonMask(pad.buttonMask, forPort: index)
            for (stick, value) in [(AnalogStick.left, pad.leftStick), (AnalogStick.right, pad.rightStick)] {
                core.setAnalogStick(stick, x: Int16(value.x * 32767), y: Int16(value.y * 32767), forPort: index)
            }
        }
    }
}
