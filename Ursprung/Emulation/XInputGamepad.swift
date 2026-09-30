// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import IOKit
import IOUSBHost
import Observation

/// One input report of the Xbox 360 USB protocol ("XInput"), which macOS has
/// no driver for. Many third-party pads and receivers use it, for example the
/// 8BitDo 2.4 GHz dongles.
nonisolated struct XInputReport: Equatable, Sendable {
    struct Buttons: OptionSet, Sendable {
        let rawValue: UInt16
        static let up = Buttons(rawValue: 1 << 0)
        static let down = Buttons(rawValue: 1 << 1)
        static let left = Buttons(rawValue: 1 << 2)
        static let right = Buttons(rawValue: 1 << 3)
        static let start = Buttons(rawValue: 1 << 4)
        static let back = Buttons(rawValue: 1 << 5)
        static let leftThumb = Buttons(rawValue: 1 << 6)
        static let rightThumb = Buttons(rawValue: 1 << 7)
        static let leftShoulder = Buttons(rawValue: 1 << 8)
        static let rightShoulder = Buttons(rawValue: 1 << 9)
        static let guide = Buttons(rawValue: 1 << 10)
        static let a = Buttons(rawValue: 1 << 12)
        static let b = Buttons(rawValue: 1 << 13)
        static let x = Buttons(rawValue: 1 << 14)
        static let y = Buttons(rawValue: 1 << 15)
    }

    /// Trigger value above which L2/R2 count as pressed (as in XInput).
    static let triggerThreshold: UInt8 = 30

    var buttons: Buttons = []
    var leftTrigger: UInt8 = 0
    var rightTrigger: UInt8 = 0
    var leftX: Int16 = 0
    var leftY: Int16 = 0
    var rightX: Int16 = 0
    var rightY: Int16 = 0

    init() {}

    /// Parses an input report (message type 0x00, 20 bytes). Other messages,
    /// such as LED or rumble status, return nil.
    init?(bytes: some Collection<UInt8>) {
        let b = Array(bytes)
        guard b.count >= 14, b[0] == 0x00, b[1] >= 0x14 else { return nil }
        func int16(_ index: Int) -> Int16 { Int16(bitPattern: UInt16(b[index]) | UInt16(b[index + 1]) << 8) }
        buttons = Buttons(rawValue: UInt16(b[2]) | UInt16(b[3]) << 8)
        leftTrigger = b[4]
        rightTrigger = b[5]
        leftX = int16(6)
        leftY = int16(8)
        rightX = int16(10)
        rightY = int16(12)
    }

    /// Face buttons are mapped by position, like GameController pads: the
    /// bottom one (Xbox A) is RetroPad B.
    var padState: PadState {
        var state = PadState()
        state.set(.up, buttons.contains(.up))
        state.set(.down, buttons.contains(.down))
        state.set(.left, buttons.contains(.left))
        state.set(.right, buttons.contains(.right))
        state.set(.B, buttons.contains(.a))
        state.set(.A, buttons.contains(.b))
        state.set(.Y, buttons.contains(.x))
        state.set(.X, buttons.contains(.y))
        state.set(.L, buttons.contains(.leftShoulder))
        state.set(.R, buttons.contains(.rightShoulder))
        state.set(.L2, leftTrigger > Self.triggerThreshold)
        state.set(.R2, rightTrigger > Self.triggerThreshold)
        state.set(.L3, buttons.contains(.leftThumb))
        state.set(.R3, buttons.contains(.rightThumb))
        state.set(.start, buttons.contains(.start))
        state.set(.select, buttons.contains(.back))
        // XInput's Y axis points up, RetroPad's down.
        state.leftStick = SIMD2(Self.axis(leftX), -Self.axis(leftY))
        state.rightStick = SIMD2(Self.axis(rightX), -Self.axis(rightY))
        return state
    }

    private static func axis(_ raw: Int16) -> Float {
        PadState.applyDeadZone(max(Float(raw) / 32767, -1))
    }
}

/// Reads one XInput interface through IOUSBHost. All USB I/O happens on a
/// private serial queue.
nonisolated final class XInputConnection: @unchecked Sendable {
    enum ConnectionError: Error { case missingEndpoint }

    private let queue = DispatchQueue(label: "Ursprung.XInput")
    private let interface: IOUSBHostInterface
    private let inPipe: IOUSBHostPipe
    private let outPipe: IOUSBHostPipe?
    private let buffer: NSMutableData
    private var lastReport: XInputReport?
    private var ledData: NSMutableData?
    private var isClosed = false

    init(service: io_service_t) throws {
        let interface = try IOUSBHostInterface(__ioService: service, options: [], queue: queue, interestHandler: nil)
        self.interface = interface
        var inAddress: UInt8?
        var outAddress: UInt8?
        let configuration = interface.configurationDescriptor
        let interfaceDescriptor = interface.interfaceDescriptor
        var endpoint = IOUSBGetNextEndpointDescriptor(configuration, interfaceDescriptor, nil)
        while let current = endpoint {
            let address = current.pointee.bEndpointAddress
            if current.pointee.bmAttributes & 0x03 == 0x03 { // interrupt
                if address & 0x80 != 0 { inAddress = inAddress ?? address } else { outAddress = outAddress ?? address }
            }
            endpoint = IOUSBGetNextEndpointDescriptor(configuration, interfaceDescriptor, UnsafePointer(OpaquePointer(current)))
        }
        guard let inAddress else {
            interface.destroy()
            throw ConnectionError.missingEndpoint
        }
        inPipe = try interface.copyPipe(withAddress: Int(inAddress))
        outPipe = try outAddress.map { try interface.copyPipe(withAddress: Int($0)) }
        buffer = try interface.ioData(withCapacity: 32)
    }

    /// Starts reading. `onReport` is called on the USB queue for every changed
    /// report, `onClose` once the device is gone.
    func start(onReport: @escaping @Sendable (XInputReport) -> Void, onClose: @escaping @Sendable () -> Void) {
        queue.async { self.read(onReport: onReport, onClose: onClose) }
    }

    /// Lights the player LED (0–3); nil turns it off.
    func setPlayer(_ index: Int?) {
        queue.async { [self] in
            guard !isClosed, let outPipe, let data = try? interface.ioData(withCapacity: 3) else { return }
            let pattern: UInt8 = index.map { 0x06 + UInt8(min($0, 3)) } ?? 0x00
            data.mutableBytes.copyMemory(from: [0x01, 0x03, pattern] as [UInt8], byteCount: 3)
            ledData = data // keeps the buffer alive while the request is pending
            try? outPipe.enqueueIORequest(with: data, completionTimeout: 0) { _, _ in }
        }
    }

    func close() {
        queue.async { [self] in
            guard !isClosed else { return }
            isClosed = true
            interface.destroy()
        }
    }

    private func read(onReport: @escaping @Sendable (XInputReport) -> Void, onClose: @escaping @Sendable () -> Void) {
        guard !isClosed else { return }
        do {
            // Interrupt pipes do not support timeouts; the request waits for data.
            try inPipe.enqueueIORequest(with: buffer, completionTimeout: 0) { [self] status, length in
                guard !isClosed else { return }
                guard status == kIOReturnSuccess else {
                    isClosed = true
                    interface.destroy()
                    onClose()
                    return
                }
                if let report = XInputReport(bytes: UnsafeRawBufferPointer(start: buffer.bytes, count: length)), report != lastReport {
                    lastReport = report
                    onReport(report)
                }
                read(onReport: onReport, onClose: onClose)
            }
        } catch {
            isClosed = true
            interface.destroy()
            onClose()
        }
    }
}

/// An XInput pad, for example an 8BitDo controller on its USB dongle.
@Observable
final class XInputGamepad: Identifiable {
    let id: UInt64
    let name: String
    @ObservationIgnored fileprivate var report = XInputReport()
    @ObservationIgnored fileprivate let connection: XInputConnection
    @ObservationIgnored fileprivate var playerIndex: Int?

    fileprivate init(id: UInt64, name: String, connection: XInputConnection) {
        self.id = id
        self.name = name
        self.connection = connection
    }

    var state: PadState { report.padState }
}

/// Finds XInput interfaces (class 0xFF, subclass 0x5D, protocol 0x01) as they
/// appear and opens them. Lives for the whole app session.
@Observable
final class XInputGamepadManager {
    private(set) var gamepads: [XInputGamepad] = []

    @ObservationIgnored var onInput: (() -> Void)?
    @ObservationIgnored var onMenuButton: (() -> Void)?
    /// Player number of the first XInput pad; GameController pads come first.
    @ObservationIgnored var firstPlayerIndex = 0 {
        didSet { updatePlayerIndicators() }
    }

    @ObservationIgnored private let notificationPort: IONotificationPortRef
    @ObservationIgnored private var iterator: io_iterator_t = 0

    init() {
        notificationPort = IONotificationPortCreate(kIOMainPortDefault)
        IONotificationPortSetDispatchQueue(notificationPort, .main)
        let matching = IOServiceMatching("IOUSBHostInterface") as NSMutableDictionary
        matching["IOPropertyMatch"] = ["bInterfaceClass": 0xFF, "bInterfaceSubClass": 0x5D, "bInterfaceProtocol": 0x01]
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOServiceAddMatchingNotification(notificationPort, kIOFirstMatchNotification, matching, { context, iterator in
            guard let context else { return }
            let manager = Unmanaged<XInputGamepadManager>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { manager.addServices(from: iterator) }
        }, context, &iterator)
        // Handles interfaces that are already present and arms the notification.
        addServices(from: iterator)
    }

    private func addServices(from iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            add(service)
            IOObjectRelease(service)
        }
    }

    private func add(_ service: io_service_t) {
        var entryID: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(service, &entryID)
        let id = entryID
        let name = IORegistryEntrySearchCFProperty(service, kIOServicePlane, "USB Product Name" as CFString, kCFAllocatorDefault,
                                                   IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)) as? String
        // Fails if another driver or app already owns the interface.
        guard let connection = try? XInputConnection(service: service) else { return }
        let gamepad = XInputGamepad(id: id, name: name ?? String(localized: "Gamepad"), connection: connection)
        gamepads.append(gamepad)
        connection.start(onReport: { [weak self] report in
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.receive(report, from: id) }
            }
        }, onClose: { [weak self] in
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.remove(id) }
            }
        })
        updatePlayerIndicators()
        onInput?()
    }

    private func receive(_ report: XInputReport, from id: UInt64) {
        guard let gamepad = gamepads.first(where: { $0.id == id }) else { return }
        let guideWasPressed = gamepad.report.buttons.contains(.guide)
        gamepad.report = report
        if !guideWasPressed, report.buttons.contains(.guide) { onMenuButton?() }
        onInput?()
    }

    private func remove(_ id: UInt64) {
        gamepads.removeAll { $0.id == id }
        updatePlayerIndicators()
        onInput?()
    }

    private func updatePlayerIndicators() {
        for (offset, gamepad) in gamepads.enumerated() {
            let index = firstPlayerIndex + offset
            let player = index < Int(URMaxPorts) ? index : nil
            if gamepad.playerIndex != player {
                gamepad.playerIndex = player
                gamepad.connection.setPlayer(player)
            }
        }
    }
}
