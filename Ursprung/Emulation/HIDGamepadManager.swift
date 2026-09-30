// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import IOKit.hid
import Observation

/// A gamepad read directly through IOKit, for pads the GameController
/// framework does not support (for example 8BitDo pads in D-input mode).
@Observable
final class HIDGamepad: Identifiable {
    /// Vendors whose pads the GameController framework handles itself
    /// (Nintendo, Sony, Microsoft). Reading them here would double the input.
    static let gameControllerVendors: Set<Int> = [0x057E, 0x054C, 0x045E]
    private static let batteryUsage = HIDUsage(page: 0x06, usage: 0x20)

    let id: UInt64
    let name: String
    let vendorID: Int
    let productID: Int
    let defaultMapping: HIDGamepadMapping
    var mapping: HIDGamepadMapping {
        didSet { HIDGamepadMapping.store(mapping == defaultMapping ? nil : mapping, forKey: deviceKey) }
    }
    private(set) var batteryLevel: Int?

    @ObservationIgnored let device: IOHIDDevice
    @ObservationIgnored private(set) var snapshot: HIDGamepadSnapshot
    @ObservationIgnored private var batteryRange: HIDElementInfo?

    /// Mappings are stored per model, so identical pads share one layout.
    var deviceKey: String { String(format: "%04x:%04x", vendorID, productID) }

    var isHandledByGameController: Bool { Self.gameControllerVendors.contains(vendorID) }

    init(device: IOHIDDevice) {
        self.device = device
        func property<T>(_ key: String) -> T? { IOHIDDeviceGetProperty(device, key as CFString) as? T }
        vendorID = property(kIOHIDVendorIDKey) ?? 0
        productID = property(kIOHIDProductIDKey) ?? 0
        name = property(kIOHIDProductKey) ?? String(localized: "Gamepad")
        var entryID: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &entryID)
        id = entryID

        var elements: [HIDUsage: HIDElementInfo] = [:]
        var values: [HIDUsage: Int] = [:]
        var battery: HIDElementInfo?
        let deviceElements = IOHIDDeviceCopyMatchingElements(device, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement] ?? []
        for element in deviceElements {
            let type = IOHIDElementGetType(element)
            guard [kIOHIDElementTypeInput_Button, kIOHIDElementTypeInput_Misc, kIOHIDElementTypeInput_Axis].contains(type) else { continue }
            let usage = HIDUsage(page: IOHIDElementGetUsagePage(element), usage: IOHIDElementGetUsage(element))
            var info = HIDElementInfo(min: IOHIDElementGetLogicalMin(element), max: IOHIDElementGetLogicalMax(element))
            if info.max < info.min, IOHIDElementGetReportSize(element) < 32 {
                // Unsigned ranges that overflowed the signed descriptor field.
                info.max = (1 << IOHIDElementGetReportSize(element)) - 1
            }
            if usage == Self.batteryUsage {
                battery = info
            } else if usage.isBindable, elements[usage] == nil {
                elements[usage] = info
            } else {
                continue
            }
            // The API wants a non-optional out parameter; seed it with a placeholder.
            let placeholder = IOHIDValueCreateWithIntegerValue(kCFAllocatorDefault, element, 0, 0)
            var value = Unmanaged.passUnretained(placeholder)
            if IOHIDDeviceGetValue(device, element, &value) == kIOReturnSuccess {
                values[usage] = IOHIDValueGetIntegerValue(value.takeUnretainedValue())
            }
            withExtendedLifetime(placeholder) {}
        }
        if let battery, let raw = values.removeValue(forKey: Self.batteryUsage) {
            batteryLevel = (raw - battery.min) * 100 / battery.span
        }
        batteryRange = battery
        snapshot = HIDGamepadSnapshot(elements: elements, values: values)
        defaultMapping = .standard(for: elements.keys)
        mapping = HIDGamepadMapping.stored(forKey: String(format: "%04x:%04x", vendorID, productID)) ?? defaultMapping
    }

    var state: PadState { mapping.state(from: snapshot) }

    var isMenuPressed: Bool { snapshot.isPressed(mapping.menu) }

    /// Records a new element value. Returns false if nothing bindable changed.
    fileprivate func update(_ usage: HIDUsage, to raw: Int) -> Bool {
        if usage == Self.batteryUsage, let range = batteryRange {
            let level = (raw - range.min) * 100 / range.span
            if level != batteryLevel { batteryLevel = level }
            return false
        }
        guard snapshot.elements[usage] != nil, snapshot.values[usage] != raw else { return false }
        snapshot.values[usage] = raw
        return true
    }
}

/// Discovers HID gamepads and tracks their element values. Callbacks arrive
/// on the main run loop. The manager lives for the whole app session.
@Observable
final class HIDGamepadManager {
    private(set) var gamepads: [HIDGamepad] = []

    /// Called whenever a pad's input changed, or a pad started or stopped
    /// being in learning mode.
    @ObservationIgnored var onInput: (() -> Void)?
    /// Called when the menu button of `gamepad` was pressed. The receiver
    /// decides whether that pad is currently allowed to act.
    @ObservationIgnored var onMenuButton: ((HIDGamepad) -> Void)?

    @ObservationIgnored private let manager: IOHIDManager
    @ObservationIgnored private var learning: (gamepad: HIDGamepad, rest: [HIDUsage: Int], completion: (HIDBinding) -> Void)?

    init() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [[String: Int]] = [kHIDUsage_GD_GamePad, kHIDUsage_GD_Joystick, kHIDUsage_GD_MultiAxisController].map {
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: $0]
        }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context else { return }
            let hid = Unmanaged<HIDGamepadManager>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { hid.add(device) }
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            let hid = Unmanaged<HIDGamepadManager>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { hid.remove(device) }
        }, context)
        IOHIDManagerRegisterInputValueCallback(manager, { context, _, _, value in
            guard let context else { return }
            let hid = Unmanaged<HIDGamepadManager>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { hid.handle(value) }
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    /// The pad that is currently waiting for a binding, if any. Its input
    /// belongs to the mapping screen and must not reach the game.
    var learningGamepad: HIDGamepad? { learning?.gamepad }

    /// Waits for the next button press or stick movement on `gamepad` and
    /// reports it as a binding. Input is not forwarded to the game meanwhile.
    func learn(on gamepad: HIDGamepad, completion: @escaping (HIDBinding) -> Void) {
        learning = (gamepad, gamepad.snapshot.values, completion)
        onInput?() // releases whatever the pad was holding in the game
    }

    func cancelLearning() {
        guard learning != nil else { return }
        learning = nil
        onInput?() // hands the pad's current state back to the game
    }

    private func add(_ device: IOHIDDevice) {
        guard !gamepads.contains(where: { $0.device === device }) else { return }
        gamepads.append(HIDGamepad(device: device))
        onInput?()
    }

    private func remove(_ device: IOHIDDevice) {
        if learning?.gamepad.device === device { learning = nil }
        gamepads.removeAll { $0.device === device }
        onInput?()
    }

    private func handle(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let device = IOHIDElementGetDevice(element)
        guard let gamepad = gamepads.first(where: { $0.device === device }) else { return }
        let usage = HIDUsage(page: IOHIDElementGetUsagePage(element), usage: IOHIDElementGetUsage(element))
        let menuWasPressed = gamepad.isMenuPressed
        guard gamepad.update(usage, to: IOHIDValueGetIntegerValue(value)) else { return }

        if let learning, learning.gamepad === gamepad {
            if let binding = gamepad.snapshot.learnedBinding(for: usage, rest: learning.rest) {
                self.learning = nil
                learning.completion(binding)
                onInput?() // the pad is back in the game (unless the completion learns the next input)
            }
            return
        }
        if !menuWasPressed, gamepad.isMenuPressed { onMenuButton?(gamepad) }
        onInput?()
    }
}
