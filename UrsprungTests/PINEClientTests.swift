// SPDX-License-Identifier: GPL-3.0-or-later

import Darwin
import Foundation
import Testing
@testable import Ursprung

/// A PINE server on a Unix socket that answers like ARMSX2: one connection at
/// a time, framed requests, a result byte and the payload.
nonisolated private final class FakePINEServer: @unchecked Sendable {
    /// The reply's payload, or nil to refuse the command (0xFF).
    typealias Handler = @Sendable (_ opcode: UInt8, _ arguments: Data) -> Data?

    let socket: URL
    private let handler: Handler
    private let listener: Int32
    private let lock = NSLock()
    private var received: [(opcode: UInt8, arguments: Data)] = []
    private var isStopped = false
    private let finished = DispatchSemaphore(value: 0)

    init(socket: URL, handler: @escaping Handler) throws {
        self.socket = socket
        self.handler = handler
        listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(socket.path(percentEncoded: false).utf8CString)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in path.withUnsafeBytes { buffer.copyMemory(from: $0) } }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(listener, 4) == 0 else {
            close(listener)
            throw POSIXError(.EADDRINUSE)
        }
        Thread { [self] in run() }.start()
    }

    var requests: [(opcode: UInt8, arguments: Data)] {
        lock.withLock { received }
    }

    func stop() {
        lock.withLock { isStopped = true }
        finished.wait()
        unlink(socket.path(percentEncoded: false))
    }

    private func run() {
        while !lock.withLock({ isStopped }) {
            var descriptor = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, 20) > 0 else { continue }
            let client = accept(listener, nil, nil)
            guard client >= 0 else { continue }
            // A client that timed out has gone; writing to it must not raise SIGPIPE.
            var enabled: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
            serve(client)
            close(client)
        }
        close(listener)
        finished.signal()
    }

    private func serve(_ client: Int32) {
        while let header = read(4, from: client) {
            let size = Int(header.uint32(at: 0))
            guard size >= 5, let body = read(size - 4, from: client) else { return }
            let opcode = body[body.startIndex], arguments = Data(body.dropFirst())
            lock.withLock { received.append((opcode, arguments)) }
            let reply: Data = if let payload = handler(opcode, arguments) {
                le32(5 + payload.count) + [0] + payload
            } else {
                le32(5) + [0xFF]
            }
            _ = reply.withUnsafeBytes { write(client, $0.baseAddress, reply.count) }
        }
    }

    private func read(_ count: Int, from client: Int32) -> Data? {
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            let received = data.withUnsafeMutableBytes { Darwin.read(client, $0.baseAddress! + offset, count - offset) }
            guard received > 0 else { return nil }
            offset += received
        }
        return data
    }
}

nonisolated private func le32(_ value: Int) -> Data {
    withUnsafeBytes(of: UInt32(value).littleEndian) { Data($0) }
}

/// A PINE string: `u32` length, then the bytes with a trailing NUL.
nonisolated private func pineString(_ string: String) -> Data {
    let bytes = Array(string.utf8) + [0]
    return le32(bytes.count) + bytes
}

/// A short folder for sockets: `sun_path` holds only 104 bytes.
private func makeSocketFolder() throws -> URL {
    let folder = URL(filePath: NSTemporaryDirectory()).appending(path: "pine-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

/// Answers like ARMSX2 running Persona 4.
nonisolated private func persona4(_ opcode: UInt8, _ arguments: Data) -> Data? {
    switch PINEClient.Opcode(rawValue: opcode) {
    case .version: pineString("ARMSX2 46c06fe7ca")
    case .title: pineString("Shin Megami Tensei - Persona 4")
    case .serial: pineString("SLES-55474")
    case .discCRC: pineString("117d1977")
    case .status: le32(1)
    case .stats: pineString(#"{"fps":50.000,"internal_fps":50.000,"frame_number":1234,"renderer":"Metal"}"#)
    case .saveState, .loadState: Data()
    case nil: nil
    }
}

@Suite("PINE remote control")
struct PINEClientTests {
    @Test func framesRequestsAndReadsReplies() async throws {
        let folder = try makeSocketFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let server = try FakePINEServer(socket: folder.appending(path: "pcsx2.sock"), handler: persona4)
        defer { server.stop() }
        let client = PINEClient(socket: server.socket)

        #expect(PINEClient.message(.saveState, arguments: [3]) == Data([6, 0, 0, 0, 0x09, 3]))
        #expect(try await client.version() == "ARMSX2 46c06fe7ca")
        #expect(try await client.title() == "Shin Megami Tensei - Persona 4")
        #expect(try await client.serial() == "SLES-55474")
        #expect(try await client.discCRC() == "117d1977")
        #expect(try await client.status() == .paused)
        let stats = try await client.stats()
        #expect(stats.frameNumber == 1234)
        #expect(stats.fps == 50)
        try await client.saveState(slot: 3)
        try await client.loadState(slot: 0)
        #expect(server.requests.suffix(2).map(\.opcode) == [0x09, 0x0A])
        #expect(server.requests.suffix(2).map(\.arguments) == [Data([3]), Data([0])])
    }

    @Test func refusedCommandsThrow() async throws {
        let folder = try makeSocketFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let server = try FakePINEServer(socket: folder.appending(path: "pcsx2.sock")) { _, _ in nil }
        defer { server.stop() }
        await #expect(throws: PINEClient.Failure.refused) { try await PINEClient(socket: server.socket).serial() }
    }

    @Test func waitsUntilTheSocketAppears() async throws {
        let folder = try makeSocketFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let socket = folder.appending(path: "pcsx2.sock.28012")
        let client = PINEClient(socket: socket)
        let ready = Task { try await client.waitUntilReady(timeout: .seconds(5), interval: .milliseconds(50)) }
        try await Task.sleep(for: .milliseconds(300))
        let server = try FakePINEServer(socket: socket, handler: persona4)
        defer { server.stop() }
        #expect(try await ready.value == "ARMSX2 46c06fe7ca")
    }

    @Test func givesUpWhenNothingAnswers() async throws {
        let folder = try makeSocketFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let client = PINEClient(socket: folder.appending(path: "pcsx2.sock"))
        await #expect(throws: PINEClient.Failure.unreachable) {
            try await client.waitUntilReady(timeout: .milliseconds(300), interval: .milliseconds(50))
        }
        // `sun_path` takes 104 bytes; a longer path cannot be reached at all.
        let long = PINEClient(socket: folder.appending(path: String(repeating: "x", count: 120)))
        await #expect(throws: PINEClient.Failure.unreachable) { try await long.version() }
    }

    @Test func aSlowReplyTimesOut() async throws {
        let folder = try makeSocketFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let server = try FakePINEServer(socket: folder.appending(path: "pcsx2.sock")) { opcode, arguments in
            Thread.sleep(forTimeInterval: 0.6)
            return persona4(opcode, arguments)
        }
        defer { server.stop() }
        let client = PINEClient(socket: server.socket, timeout: .milliseconds(200))
        await #expect(throws: PINEClient.Failure.timedOut) { try await client.version() }
    }
}

@Suite("ARMSX2 states through PINE")
struct ARMSX2ControlTests {
    private let version: UInt32 = 0x9A59_0000

    @discardableResult
    private static func writeState(_ name: String, in folder: URL, version: UInt32 = 0x9A59_0000,
                                   modified: Date? = nil) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: name)
        try? FileManager.default.removeItem(at: url)
        try makeZip(at: url, files: armsx2StateFiles(version: version), stored: true)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path(percentEncoded: false))
        }
        return url
    }

    @Test func namesSlotFilesLikeARMSX2() {
        // Ursprung's Quick Save is ARMSX2's slot 1, which its hotkeys reach.
        #expect(ARMSX2States.slotFileName(serial: "SLES-55474", crc: "117d1977", slot: 0) == "SLES-55474 (117D1977).01.p2s")
        #expect(ARMSX2States.slotFileName(serial: "SLES-55474", crc: "117d1977", slot: 1) == "SLES-55474 (117D1977).00.p2s")
        #expect(ARMSX2States.slotFileName(serial: "SLES-55474", crc: "117d1977", slot: 7) == "SLES-55474 (117D1977).07.p2s")
    }

    @Test func onlySlotFilesLoadByNumber() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.writeState("SLES-55474 (117D1977).01.p2s", in: root)
        try Self.writeState("SLES-55474 (117D1977).02 (from backup 2026-10-03 14.22.11).p2s", in: root)
        try Self.writeState("SLES-55474 (117D1977).resume.p2s", in: root)
        let states = ARMSX2States.states(in: root)
        let loadable = ([states.autosave].compactMap { $0 } + states.slots).filter(ARMSX2States.isSlotFile)
        #expect(loadable.map(\.stateURL.lastPathComponent) == ["SLES-55474 (117D1977).01.p2s"])
    }

    @Test func savesIntoTheSlotAndKeepsTheReplacedState() async throws {
        let root = try makeTemporaryDirectory()
        let socketFolder = try makeSocketFolder()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: socketFolder)
        }
        let folder = root.appending(path: "armsx2", directoryHint: .isDirectory)
        let old = try Self.writeState("SLES-55474 (117D1977).01.p2s", in: folder, modified: .now.addingTimeInterval(-600))
        let named = try #require(ARMSX2States.states(in: folder).slots.first)
        try SaveStateStore.rename(named, to: "Before the TV world",
                                  origin: ARMSX2States.context(for: named, gameFileName: "p4.iso", gameFileSize: 1))

        let fresh = try Self.writeState("fresh.p2s", in: root)
        let server = try FakePINEServer(socket: socketFolder.appending(path: "pcsx2.sock")) { opcode, arguments in
            if opcode == PINEClient.Opcode.saveState.rawValue {
                // Written after the reply, through a .part file, like ARMSX2.
                let slot = Int(arguments[arguments.startIndex])
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
                    let name = String(format: "SLES-55474 (117D1977).%02d.p2s", slot)
                    let part = folder.appending(path: name + ".x7Kq.part")
                    try? FileManager.default.copyItem(at: fresh, to: part)
                    try? FileManager.default.setAttributes([.modificationDate: Date.now], ofItemAtPath: part.path(percentEncoded: false))
                    _ = rename(part.path(percentEncoded: false), folder.appending(path: name).path(percentEncoded: false))
                }
            }
            return persona4(opcode, arguments)
        }
        defer { server.stop() }

        let saved = try await ARMSX2States.save(slot: 0, through: PINEClient(socket: server.socket), in: folder,
                                                timeout: .seconds(5))
        #expect(saved == old)
        let states = ARMSX2States.states(in: folder)
        #expect(states.slots.count == 1)
        #expect(states.slots.first?.name == nil)
        let history = ARMSX2States.history(in: folder)
        #expect(history.count == 1)
        #expect(history.first?.name == "Before the TV world")
        #expect(history.first?.slot == 0)
        #expect(server.requests.last.map { [$0.opcode] + $0.arguments } == [0x09, 1], "Quick Save is ARMSX2's slot 1")
    }

    @Test func aSaveThatDoesNotLandInTimeKeepsTheCopy() async throws {
        let root = try makeTemporaryDirectory()
        let socketFolder = try makeSocketFolder()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: socketFolder)
        }
        let folder = root.appending(path: "armsx2", directoryHint: .isDirectory)
        try Self.writeState("SLES-55474 (117D1977).01.p2s", in: folder, modified: .now.addingTimeInterval(-600))
        let quickSave = try #require(ARMSX2States.states(in: folder).slots.first)
        try SaveStateStore.rename(quickSave, to: "Keep me",
                                  origin: ARMSX2States.context(for: quickSave, gameFileName: "p4.iso", gameFileSize: 1))
        // ARMSX2 accepts the request but writes the state only after the wait.
        let fresh = try Self.writeState("fresh.p2s", in: root)
        let server = try FakePINEServer(socket: socketFolder.appending(path: "pcsx2.sock")) { opcode, arguments in
            if opcode == PINEClient.Opcode.saveState.rawValue {
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.6) {
                    let slot = folder.appending(path: "SLES-55474 (117D1977).01.p2s")
                    let part = folder.appending(path: "SLES-55474 (117D1977).01.p2s.x7Kq.part")
                    try? FileManager.default.copyItem(at: fresh, to: part)
                    try? FileManager.default.setAttributes([.modificationDate: Date.now], ofItemAtPath: part.path(percentEncoded: false))
                    _ = rename(part.path(percentEncoded: false), slot.path(percentEncoded: false))
                }
            }
            return persona4(opcode, arguments)
        }
        defer { server.stop() }

        await #expect(throws: ARMSX2ControlError.notSaved) {
            try await ARMSX2States.save(slot: 0, through: PINEClient(socket: server.socket), in: folder,
                                        timeout: .milliseconds(200))
        }
        // Until ARMSX2 writes, the slot keeps its state and name; the copy waits in the history.
        #expect(ARMSX2States.states(in: folder).slots.first?.name == "Keep me")
        #expect(ARMSX2States.history(in: folder).map(\.name) == ["Keep me"])

        try await Task.sleep(for: .seconds(1))
        let slot = try #require(ARMSX2States.states(in: folder).slots.first)
        #expect(slot.date > quickSave.date, "Written late")
        #expect(slot.name == nil)
        #expect(ARMSX2States.history(in: folder).map(\.name) == ["Keep me"], "The replaced state survived")
    }

    @Test func aRefusedSaveLeavesTheSlotAsItWas() async throws {
        let root = try makeTemporaryDirectory()
        let socketFolder = try makeSocketFolder()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: socketFolder)
        }
        let folder = root.appending(path: "armsx2", directoryHint: .isDirectory)
        try Self.writeState("SLES-55474 (117D1977).01.p2s", in: folder, modified: .now.addingTimeInterval(-600))
        let quickSave = try #require(ARMSX2States.states(in: folder).slots.first)
        try SaveStateStore.rename(quickSave, to: "Keep me",
                                  origin: ARMSX2States.context(for: quickSave, gameFileName: "p4.iso", gameFileSize: 1))
        // ARMSX2 says no to the save itself: nothing is queued.
        let server = try FakePINEServer(socket: socketFolder.appending(path: "pcsx2.sock")) { opcode, arguments in
            opcode == PINEClient.Opcode.saveState.rawValue ? nil : persona4(opcode, arguments)
        }
        defer { server.stop() }

        await #expect(throws: ARMSX2ControlError.noGame) {
            try await ARMSX2States.save(slot: 0, through: PINEClient(socket: server.socket), in: folder,
                                        timeout: .milliseconds(200))
        }
        #expect(ARMSX2States.history(in: folder).isEmpty)
        #expect(ARMSX2States.states(in: folder).slots.first?.name == "Keep me")
    }

    @Test func aCancelledSaveSendsNothing() async throws {
        let root = try makeTemporaryDirectory()
        let socketFolder = try makeSocketFolder()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: socketFolder)
        }
        let folder = root.appending(path: "armsx2", directoryHint: .isDirectory)
        try Self.writeState("SLES-55474 (117D1977).01.p2s", in: folder, modified: .now.addingTimeInterval(-600))
        let quickSave = try #require(ARMSX2States.states(in: folder).slots.first)
        try SaveStateStore.rename(quickSave, to: "Keep me",
                                  origin: ARMSX2States.context(for: quickSave, gameFileName: "p4.iso", gameFileSize: 1))
        let server = try FakePINEServer(socket: socketFolder.appending(path: "pcsx2.sock"), handler: persona4)
        defer { server.stop() }

        // The session ended before the request went out.
        let client = PINEClient(socket: server.socket)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ARMSX2States.save(slot: 0, through: client, in: folder)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!server.requests.contains { $0.opcode == PINEClient.Opcode.saveState.rawValue })
        #expect(ARMSX2States.history(in: folder).isEmpty)
        #expect(ARMSX2States.states(in: folder).slots.first?.name == "Keep me")
    }

    @Test func loadsOnlyCompatibleStatesOfTheRunningDisc() async throws {
        let root = try makeTemporaryDirectory()
        let socketFolder = try makeSocketFolder()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: socketFolder)
        }
        try Self.writeState("SLES-55474 (117D1977).02.p2s", in: root)
        try Self.writeState("SLES-55474 (117D1977).03.p2s", in: root, version: 0x9B00_0000)
        let otherDisc = try Self.writeState("SLES-55475 (0BADF00D).02.p2s", in: root)
        let server = try FakePINEServer(socket: socketFolder.appending(path: "pcsx2.sock"), handler: persona4)
        defer { server.stop() }
        let client = PINEClient(socket: server.socket)

        try await ARMSX2States.load(slot: 2, in: root, through: client, saveStateVersion: version)
        #expect(server.requests.last.map { [$0.opcode] + $0.arguments } == [0x0A, 2])
        let loads = server.requests.count

        await #expect(throws: StandaloneLaunchError.self) {
            try await ARMSX2States.load(slot: 3, in: root, through: client, saveStateVersion: version)
        }
        await #expect(throws: ARMSX2ControlError.emptySlot) {
            try await ARMSX2States.load(slot: 4, in: root, through: client, saveStateVersion: version)
        }
        await #expect(throws: ARMSX2ControlError.otherDisc) {
            try await ARMSX2States.load(slot: 2, in: root, expected: otherDisc, through: client, saveStateVersion: version)
        }
        // None of these reached ARMSX2: a state it can't read would open a dialog.
        #expect(!server.requests.dropFirst(loads).contains { $0.opcode == PINEClient.Opcode.loadState.rawValue })
    }

    @Test func explainsWhyARMSX2DidNotAct() async throws {
        let root = try makeTemporaryDirectory()
        let socketFolder = try makeSocketFolder()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: socketFolder)
        }
        // Before a game runs, ARMSX2 refuses to tell the serial.
        let server = try FakePINEServer(socket: socketFolder.appending(path: "pcsx2.sock")) { opcode, arguments in
            opcode == PINEClient.Opcode.serial.rawValue ? nil : persona4(opcode, arguments)
        }
        defer { server.stop() }
        await #expect(throws: ARMSX2ControlError.noGame) {
            try await ARMSX2States.save(slot: 1, through: PINEClient(socket: server.socket), in: root)
        }
        await #expect(throws: ARMSX2ControlError.notAnswering) {
            try await ARMSX2States.save(slot: 1, through: PINEClient(socket: socketFolder.appending(path: "gone.sock")), in: root)
        }
    }
}
