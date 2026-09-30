// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import GameController
import Observation
import simd

/// Merges keyboard and game controller state into RetroPad button masks and
/// analog values and forwards them to the running core. Controllers the
/// GameController framework does not support are read through IOKit: Xbox 360
/// protocol pads over USB (XInput) and generic HID gamepads. Ports are assigned
/// in that order, after the GameController pads.
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

    /// Pad names in port order.
    var controllerNames: [String] {
        connectedControllers.map { $0.vendorName ?? String(localized: "Controller") }
            + xinput.gamepads.map(\.name) + hidGamepads.map(\.name)
    }

    @ObservationIgnored private var mapping = KeyboardMapping.current
    @ObservationIgnored private var pressedKeys = Set<UInt16>()
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

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

    func reloadMapping() {
        mapping = KeyboardMapping.current
    }

    func reset() {
        pressedKeys.removeAll()
        push()
    }

    // MARK: Keyboard

    /// Returns true when the key is bound to a RetroPad input.
    @discardableResult
    func keyDown(_ keyCode: UInt16) -> Bool {
        guard !mapping.input(forKeyCode: keyCode).isEmpty else { return false }
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

    // MARK: Controllers

    private func refreshControllers() {
        connectedControllers = GCController.controllers().filter { $0.extendedGamepad != nil }
        for (index, controller) in connectedControllers.enumerated() {
            controller.playerIndex = GCControllerPlayerIndex(rawValue: min(index, 3)) ?? .indexUnset
            controller.extendedGamepad?.valueChangedHandler = { [weak self] _, _ in
                MainActor.assumeIsolated { self?.push() }
            }
            // Keep the Home button from opening Launchpad so it can open the game menu.
            controller.extendedGamepad?.buttonHome?.preferredSystemGestureState = .alwaysReceive
            controller.extendedGamepad?.buttonHome?.pressedChangedHandler = { [weak self] _, _, pressed in
                MainActor.assumeIsolated { if pressed { self?.onMenuButton?() } }
            }
        }
        xinput.firstPlayerIndex = connectedControllers.count
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

    // MARK: State

    private func push() {
        guard let core else { return }
        var masks = [UInt32](repeating: 0, count: Int(URMaxPorts))
        var sticks = [[SIMD2<Float>]](repeating: [.zero, .zero], count: Int(URMaxPorts))

        // Keyboard → port 0
        for key in pressedKeys {
            for input in mapping.input(forKeyCode: key) {
                if let button = input.button {
                    masks[0] |= 1 << UInt32(button.rawValue)
                } else {
                    switch input {
                    case .leftStickUp: sticks[0][0].y -= 1
                    case .leftStickDown: sticks[0][0].y += 1
                    case .leftStickLeft: sticks[0][0].x -= 1
                    case .leftStickRight: sticks[0][0].x += 1
                    case .rightStickUp: sticks[0][1].y -= 1
                    case .rightStickDown: sticks[0][1].y += 1
                    case .rightStickLeft: sticks[0][1].x -= 1
                    case .rightStickRight: sticks[0][1].x += 1
                    default: break
                    }
                }
            }
        }

        // Controllers → ports by kind, then connection order
        let learning = hid.learningGamepad
        let hidStates = Self.hidStates(hidGamepads.map { (state: $0.state, isLearning: $0 === learning) })
        let pads = connectedControllers.map(Self.state(of:)) + xinput.gamepads.map(\.state) + hidStates
        for (port, pad) in pads.prefix(Int(URMaxPorts)).enumerated() {
            var pad = pad
            if stickDrivesDPad {
                pad.set(.left, pad.leftStick.x < -0.5)
                pad.set(.right, pad.leftStick.x > 0.5)
                pad.set(.up, pad.leftStick.y < -0.5)
                pad.set(.down, pad.leftStick.y > 0.5)
            }
            masks[port] |= pad.buttonMask
            sticks[port][0] += pad.leftStick
            sticks[port][1] += pad.rightStick
        }

        for port in 0..<Int(URMaxPorts) {
            core.setButtonMask(masks[port], forPort: port)
            for stick in 0..<2 {
                let value = simd_clamp(sticks[port][stick], SIMD2(repeating: -1), SIMD2(repeating: 1))
                core.setAnalogStick(AnalogStick(rawValue: stick)!, x: Int16(value.x * 32767), y: Int16(value.y * 32767), forPort: port)
            }
        }
    }
}
