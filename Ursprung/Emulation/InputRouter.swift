// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import GameController
import Observation
import simd

/// Merges keyboard and game controller state into RetroPad button masks and
/// analog values and forwards them to the running core.
@Observable
final class InputRouter {
    private(set) var connectedControllers: [GCController] = []

    @ObservationIgnored weak var core: LibretroCore?
    /// Whether the left stick also drives the D-pad (for digital-only systems).
    @ObservationIgnored var stickDrivesDPad = true
    @ObservationIgnored var onMenuButton: (() -> Void)?

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
            controller.extendedGamepad?.buttonHome?.pressedChangedHandler = { [weak self] _, _, pressed in
                MainActor.assumeIsolated { if pressed { self?.onMenuButton?() } }
            }
        }
        push()
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

        // Controllers → port by connection order
        for (port, controller) in connectedControllers.prefix(Int(URMaxPorts)).enumerated() {
            guard let pad = controller.extendedGamepad else { continue }
            var mask: UInt32 = 0
            func set(_ button: RetroButton, _ pressed: Bool) {
                if pressed { mask |= 1 << UInt32(button.rawValue) }
            }
            set(.up, pad.dpad.up.isPressed)
            set(.down, pad.dpad.down.isPressed)
            set(.left, pad.dpad.left.isPressed)
            set(.right, pad.dpad.right.isPressed)
            // Positional mapping: the bottom face button is RetroPad B, etc.
            set(.B, pad.buttonA.isPressed)
            set(.A, pad.buttonB.isPressed)
            set(.Y, pad.buttonX.isPressed)
            set(.X, pad.buttonY.isPressed)
            set(.L, pad.leftShoulder.isPressed)
            set(.R, pad.rightShoulder.isPressed)
            set(.L2, pad.leftTrigger.isPressed)
            set(.R2, pad.rightTrigger.isPressed)
            set(.L3, pad.leftThumbstickButton?.isPressed ?? false)
            set(.R3, pad.rightThumbstickButton?.isPressed ?? false)
            set(.start, pad.buttonMenu.isPressed)
            set(.select, pad.buttonOptions?.isPressed ?? false)

            let left = SIMD2(pad.leftThumbstick.xAxis.value, -pad.leftThumbstick.yAxis.value)
            let right = SIMD2(pad.rightThumbstick.xAxis.value, -pad.rightThumbstick.yAxis.value)
            if stickDrivesDPad {
                set(.left, left.x < -0.5)
                set(.right, left.x > 0.5)
                set(.up, left.y < -0.5)
                set(.down, left.y > 0.5)
            }
            masks[port] |= mask
            sticks[port][0] += left
            sticks[port][1] += right
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
