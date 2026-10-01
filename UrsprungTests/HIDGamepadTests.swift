// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import Ursprung

@Suite("HID gamepads")
struct HIDGamepadTests {
    /// Elements reported by an 8BitDo Ultimate 2C Wireless in Bluetooth mode.
    static let eightBitDo: [HIDUsage: HIDElementInfo] = {
        var elements: [HIDUsage: HIDElementInfo] = [.hat: HIDElementInfo(min: 0, max: 7)]
        for number in 1...16 { elements[.button(UInt32(number))] = HIDElementInfo(min: 0, max: 1) }
        for axis in [HIDUsage.x, .y, .z, .rz, .brake, .accelerator] { elements[axis] = HIDElementInfo(min: 0, max: 255) }
        return elements
    }()

    static let restValues: [HIDUsage: Int] = [.hat: 8, .x: 128, .y: 128, .z: 128, .rz: 128, .brake: 0, .accelerator: 0]

    static func bit(_ button: RetroButton) -> UInt32 { 1 << UInt32(button.rawValue) }

    @Test func standardMappingForAndroidLayout() {
        let mapping = HIDGamepadMapping.standard(for: Self.eightBitDo.keys)
        #expect(mapping.bindings[.b] == .button(2))
        #expect(mapping.bindings[.a] == .button(1))
        #expect(mapping.bindings[.start] == .button(12))
        #expect(mapping.bindings[.l2] == .trigger(.brake))
        #expect(mapping.bindings[.r2] == .trigger(.accelerator))
        #expect(mapping.bindings[.up] == .hat(.up))
        #expect(mapping.bindings[.rightStickDown] == .axis(.rz, positive: true))
        #expect(mapping.menu == .button(13))
        for input in RetroInput.allCases {
            #expect(mapping.bindings[input] != nil, "\(input) is unbound")
        }
    }

    @Test func standardMappingForDirectInputLayout() {
        var elements: [HIDUsage] = (1...12).map { .button(UInt32($0)) }
        elements += [.x, .y, .rx, .ry]
        let mapping = HIDGamepadMapping.standard(for: elements)
        #expect(mapping.bindings[.b] == .button(2))
        #expect(mapping.bindings[.a] == .button(3))
        #expect(mapping.bindings[.l2] == .button(7))
        #expect(mapping.bindings[.rightStickRight] == .axis(.rx, positive: true))
        #expect(mapping.bindings[.up] == nil)
        #expect(mapping.menu == nil)
    }

    @Test func evaluatesButtonsHatSticksAndTriggers() {
        let mapping = HIDGamepadMapping.standard(for: Self.eightBitDo.keys)
        var snapshot = HIDGamepadSnapshot(elements: Self.eightBitDo, values: Self.restValues)
        #expect(mapping.state(from: snapshot) == PadState())

        snapshot.values[.button(2)] = 1
        snapshot.values[.hat] = 1 // up-right
        snapshot.values[.x] = 255
        snapshot.values[.y] = 140 // inside the dead zone
        snapshot.values[.accelerator] = 200
        snapshot.values[.brake] = 60
        let state = mapping.state(from: snapshot)
        #expect(state.buttonMask == Self.bit(.B) | Self.bit(.up) | Self.bit(.right) | Self.bit(.R2))
        #expect(state.leftStick == SIMD2(1, 0))
        #expect(state.rightStick == .zero)

        snapshot.values[.y] = 0
        #expect(mapping.state(from: snapshot).leftStick.y == -1)
    }

    @Test func learnsTheControlThatMoved() {
        var snapshot = HIDGamepadSnapshot(elements: Self.eightBitDo, values: Self.restValues)
        let rest = snapshot.values

        snapshot.values[.button(5)] = 1
        #expect(snapshot.learnedBinding(for: .button(5), rest: rest) == .button(5))

        snapshot.values[.hat] = 4
        #expect(snapshot.learnedBinding(for: .hat, rest: rest) == .hat(.down))
        snapshot.values[.hat] = 3 // diagonal is ambiguous
        #expect(snapshot.learnedBinding(for: .hat, rest: rest) == nil)

        snapshot.values[.y] = 150 // too small a movement
        #expect(snapshot.learnedBinding(for: .y, rest: rest) == nil)
        snapshot.values[.y] = 250
        #expect(snapshot.learnedBinding(for: .y, rest: rest) == .axis(.y, positive: true))
        snapshot.values[.z] = 5
        #expect(snapshot.learnedBinding(for: .z, rest: rest) == .axis(.z, positive: false))

        snapshot.values[.brake] = 255
        #expect(snapshot.learnedBinding(for: .brake, rest: rest) == .trigger(.brake))

        #expect(!HIDUsage(page: 0x06, usage: 0x20).isBindable, "Battery level must not be learnable")
    }

    @Test func assigningMovesTheControlFromItsSlot() {
        var mapping = HIDGamepadMapping.standard(for: Self.eightBitDo.keys)
        #expect(mapping.assign(.button(12), to: .input(.b)) == .input(.start))
        #expect(mapping.bindings[.b] == .button(12))
        #expect(mapping.bindings[.start] == nil)

        #expect(mapping.assign(.button(12), to: .input(.b)) == nil, "Same slot again moves nothing")
        #expect(mapping.assign(.button(12), to: .menu) == .input(.b))
        #expect(mapping.menu == .button(12))
        #expect(mapping.bindings[.b] == nil)

        #expect(mapping.assign(.button(16), to: .input(.a)) == nil, "A free control moves nothing")
        #expect(mapping.bindings[.a] == .button(16))
    }

    @Test func mappingRoundTripsThroughJSON() throws {
        var mapping = HIDGamepadMapping.standard(for: Self.eightBitDo.keys)
        mapping.bindings[.a] = .axis(.z, positive: false)
        mapping.menu = nil
        let data = try JSONEncoder().encode(mapping)
        #expect(try JSONDecoder().decode(HIDGamepadMapping.self, from: data) == mapping)
    }
}

@Suite("XInput pads")
struct XInputTests {
    static func bit(_ button: RetroButton) -> UInt32 { 1 << UInt32(button.rawValue) }

    @Test func parsesIdleReportFromEightBitDoDongle() throws {
        let bytes: [UInt8] = [0x00, 0x14, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                              0x00, 0x00, 0x00, 0x00, 0x10, 0x1C, 0x30, 0x64, 0x00, 0x10]
        let report = try #require(XInputReport(bytes: bytes))
        #expect(report == XInputReport())
        #expect(report.padState == PadState())
    }

    @Test func mapsButtonsByPositionAndFlipsYAxis() throws {
        var bytes = [UInt8](repeating: 0, count: 20)
        bytes[1] = 0x14
        bytes[2] = 0x01 | 0x10 | 0x20   // D-pad up, Start, Back
        bytes[3] = 0x10 | 0x80 | 0x04   // A (bottom), Y (top), Guide
        bytes[5] = 0xFF                 // right trigger
        bytes[6] = 0xFF; bytes[7] = 0x7F // left X = +32767
        bytes[8] = 0xFF; bytes[9] = 0x7F // left Y = +32767 (up)
        let report = try #require(XInputReport(bytes: bytes))
        #expect(report.buttons.contains(.guide))
        let state = report.padState
        #expect(state.buttonMask == Self.bit(.up) | Self.bit(.start) | Self.bit(.select) | Self.bit(.B) | Self.bit(.X) | Self.bit(.R2))
        #expect(state.leftStick == SIMD2(1, -1))
    }

    @Test func ignoresNonInputMessages() {
        #expect(XInputReport(bytes: [0x01, 0x03, 0x06]) == nil)
        #expect(XInputReport(bytes: [0x08, 0x03, 0x00]) == nil)
    }

    @Test func deadZoneKeepsSignAndRange() {
        #expect(PadState.applyDeadZone(0.1) == 0)
        #expect(PadState.applyDeadZone(-1) == -1)
        #expect(PadState.applyDeadZone(1) == 1)
        #expect(PadState.applyDeadZone(-0.575) < 0)
    }
}
