// SPDX-License-Identifier: GPL-3.0-or-later

import Darwin
import Foundation

/// Remote control of ARMSX2 over PINE, its Unix socket (docs/STANDALONE_PLAN.md, S3).
///
/// A request is a `u32` size (counting itself), an opcode and its arguments;
/// the reply is a `u32` size, a result byte (0 done, 0xFF failed) and the
/// payload. Everything is little-endian, and strings come back as a `u32`
/// length and that many NUL-terminated bytes. ARMSX2 serves one connection at
/// a time, so every request opens its own and closes it again.
///
/// Save and load are acknowledged once ARMSX2 has queued them, not when they
/// are done; `ARMSX2States` waits for the file a save writes.
nonisolated struct PINEClient: Sendable, Hashable {
    enum Opcode: UInt8, Sendable {
        case version = 0x08
        case saveState = 0x09
        case loadState = 0x0A
        case title = 0x0B
        case serial = 0x0C
        /// The disc's CRC as eight lowercase hex digits (`MsgUUID`).
        case discCRC = 0x0D
        case status = 0x0F
        /// ARMSX2 only: performance figures as JSON.
        case stats = 0x10
    }

    enum Status: UInt32, Sendable {
        case running = 0
        case paused = 1
        case shutdown = 2
    }

    nonisolated struct Stats: Decodable, Sendable {
        let fps: Double
        /// Frames the game has drawn; above 0 once it shows something.
        let frameNumber: Int

        enum CodingKeys: String, CodingKey {
            case fps
            case frameNumber = "frame_number"
        }
    }

    enum Failure: Error, Equatable {
        /// No socket, or nothing listens on it.
        case unreachable
        case timedOut
        /// ARMSX2 refused the command, e.g. because no game runs yet.
        case refused
        case malformedReply
    }

    let socket: URL
    /// How long a request may take before it counts as unanswered.
    var timeout: Duration = .seconds(3)

    // MARK: Commands

    /// “ARMSX2 <commit>”.
    @concurrent func version() async throws -> String {
        try string(in: send(.version))
    }

    @concurrent func title() async throws -> String {
        try string(in: send(.title))
    }

    /// The running disc's serial, e.g. `SLES-55474`.
    @concurrent func serial() async throws -> String {
        try string(in: send(.serial))
    }

    /// The running disc's CRC, e.g. `117d1977`.
    @concurrent func discCRC() async throws -> String {
        try string(in: send(.discCRC))
    }

    @concurrent func status() async throws -> Status {
        let payload = try send(.status)
        guard payload.count >= 4, let status = Status(rawValue: payload.uint32(at: 0)) else { throw Failure.malformedReply }
        return status
    }

    @concurrent func stats() async throws -> Stats {
        let json = try string(in: send(.stats))
        guard let stats = try? JSONDecoder().decode(Stats.self, from: Data(json.utf8)) else { throw Failure.malformedReply }
        return stats
    }

    /// Asks ARMSX2 to save into `slot`; it writes the state afterwards.
    @concurrent func saveState(slot: UInt8) async throws {
        _ = try send(.saveState, arguments: [slot])
    }

    /// Asks ARMSX2 to load `slot`. A failure only shows in ARMSX2's window.
    @concurrent func loadState(slot: UInt8) async throws {
        _ = try send(.loadState, arguments: [slot])
    }

    /// Retries `version` until ARMSX2 answers: its socket appears about two
    /// seconds after launch. Throws the last failure after `timeout`.
    @concurrent func waitUntilReady(timeout: Duration, interval: Duration = .milliseconds(250)) async throws -> String {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while true {
            do {
                return try string(in: send(.version))
            } catch {
                guard clock.now + interval < deadline else { throw error }
                try await Task.sleep(for: interval)
            }
        }
    }

    // MARK: Wire format

    /// The request for `opcode`, framed with its size.
    static func message(_ opcode: Opcode, arguments: [UInt8] = []) -> Data {
        let size = UInt32(4 + 1 + arguments.count)
        return withUnsafeBytes(of: size.littleEndian) { Data($0) } + [opcode.rawValue] + arguments
    }

    /// A string payload: `u32` length, then the bytes with a trailing NUL.
    func string(in payload: Data) throws -> String {
        guard payload.count >= 4 else { throw Failure.malformedReply }
        let length = Int(payload.uint32(at: 0))
        guard length <= payload.count - 4 else { throw Failure.malformedReply }
        let bytes = payload.dropFirst(4).prefix(length)
        return String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }

    /// Sends one request and returns the reply's payload (blocking).
    func send(_ opcode: Opcode, arguments: [UInt8] = []) throws -> Data {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Failure.unreachable }
        defer { close(descriptor) }

        var enabled: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        let (seconds, attoseconds) = timeout.components
        var interval = timeval(tv_sec: Int(seconds), tv_usec: Int32(attoseconds / 1_000_000_000_000))
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &interval, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &interval, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(socket.path(percentEncoded: false).utf8CString)
        // `sun_path` holds 104 bytes including the NUL.
        guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw Failure.unreachable }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            path.withUnsafeBytes { buffer.copyMemory(from: $0) }
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw Failure.unreachable }

        try write(Self.message(opcode, arguments: arguments), to: descriptor)
        let size = Int(try read(4, from: descriptor).uint32(at: 0))
        guard size >= 5, size <= 1 << 20 else { throw Failure.malformedReply }
        let reply = try read(size - 4, from: descriptor)
        guard reply[reply.startIndex] == 0 else { throw Failure.refused }
        return Data(reply.dropFirst())
    }

    private func write(_ data: Data, to descriptor: Int32) throws {
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress! + offset, data.count - offset) }
            if written < 0, errno == EINTR { continue }
            guard written > 0 else { throw errno == EAGAIN ? Failure.timedOut : Failure.unreachable }
            offset += written
        }
    }

    private func read(_ count: Int, from descriptor: Int32) throws -> Data {
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            let received = data.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress! + offset, count - offset) }
            if received < 0, errno == EINTR { continue }
            guard received > 0 else {
                // 0: ARMSX2 closed the connection mid-reply.
                throw received < 0 && errno == EAGAIN ? Failure.timedOut : Failure.malformedReply
            }
            offset += received
        }
        return data
    }
}
