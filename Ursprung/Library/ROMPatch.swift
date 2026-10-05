// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Applies ROM patches (translations, hacks, fixes) in memory. The game file
/// itself is never changed: the patched copy goes to the cache.
///
/// Supported formats: IPS, UPS and BPS. UPS and BPS carry checksums of the
/// ROM they expect, so a patch for another revision is refused instead of
/// producing a broken game.
nonisolated enum ROMPatch {
    enum Format: String, Sendable {
        case ips, ups, bps

        var title: String { rawValue.uppercased() }

        /// File extensions of patches Ursprung can apply.
        static let fileExtensions: Set<String> = ["ips", "ups", "bps"]
    }

    enum PatchError: LocalizedError, Equatable {
        case unknownFormat
        case damaged
        /// The patch is for another ROM (checksum of the original differs).
        case wrongROM(expected: UInt32, found: UInt32)
        /// The result does not match the checksum the patch promises.
        case wrongResult

        var errorDescription: String? {
            switch self {
            case .unknownFormat:
                String(localized: "This isn't an IPS, UPS or BPS patch.")
            case .damaged:
                String(localized: "The patch file is damaged.")
            case .wrongROM(let expected, let found):
                String(localized: "The patch is made for another version of the game (CRC32 \(Checksum.hex(expected)), this file has \(Checksum.hex(found))).")
            case .wrongResult:
                String(localized: "Patching produced a different result than the patch expects.")
            }
        }
    }

    static func format(of patch: Data) -> Format? {
        if patch.starts(with: Array("PATCH".utf8)) { return .ips }
        if patch.starts(with: Array("UPS1".utf8)) { return .ups }
        if patch.starts(with: Array("BPS1".utf8)) { return .bps }
        return nil
    }

    /// The ROM `patch` turns `rom` into.
    static func apply(_ patch: Data, to rom: Data) throws -> Data {
        let patch = [UInt8](patch)
        let rom = [UInt8](rom)
        let result: [UInt8] = switch format(of: Data(patch)) {
        case .ips: try applyIPS(patch, to: rom)
        case .ups: try applyUPS(patch, to: rom)
        case .bps: try applyBPS(patch, to: rom)
        case nil: throw PatchError.unknownFormat
        }
        return Data(result)
    }

    /// Checks whether `patch` fits `rom` without patching: UPS and BPS
    /// compare the ROM's checksum; IPS has none and always fits.
    static func check(_ patch: Data, for rom: Data) throws {
        let bytes = [UInt8](patch)
        switch format(of: patch) {
        case .ips:
            return
        case .ups, .bps:
            guard bytes.count >= 16 else { throw PatchError.damaged }
            let expected = uint32LE(bytes, at: bytes.count - 12)
            let found = Checksum.crc(of: rom)
            if expected != found { throw PatchError.wrongROM(expected: expected, found: found) }
        case nil:
            throw PatchError.unknownFormat
        }
    }

    /// The CRC32 of the ROM a UPS or BPS patch is made for; nil for IPS,
    /// which records none.
    static func expectedSourceCRC(_ patch: Data) -> UInt32? {
        guard let format = format(of: patch), format != .ips, patch.count >= 16 else { return nil }
        return uint32LE([UInt8](patch.suffix(12).prefix(4)), at: 0)
    }

    // MARK: IPS

    private static func applyIPS(_ patch: [UInt8], to rom: [UInt8]) throws -> [UInt8] {
        var output = rom
        var offset = 5
        func read(_ count: Int) throws -> ArraySlice<UInt8> {
            guard offset + count <= patch.count else { throw PatchError.damaged }
            defer { offset += count }
            return patch[offset..<offset + count]
        }
        while true {
            let address = try read(3)
            if address.elementsEqual(Array("EOF".utf8)) {
                // An optional 3-byte length truncates the result.
                if offset + 3 <= patch.count {
                    let length = try read(3).reduce(0) { $0 << 8 | Int($1) }
                    if length < output.count { output.removeSubrange(length...) }
                }
                return output
            }
            let start = address.reduce(0) { $0 << 8 | Int($1) }
            let size = try read(2).reduce(0) { $0 << 8 | Int($1) }
            if size == 0 {
                // Run-length record: one byte repeated.
                let count = try read(2).reduce(0) { $0 << 8 | Int($1) }
                let value = try read(1).first!
                if output.count < start + count { output += [UInt8](repeating: 0, count: start + count - output.count) }
                for index in start..<start + count { output[index] = value }
            } else {
                let bytes = try read(size)
                if output.count < start + size { output += [UInt8](repeating: 0, count: start + size - output.count) }
                output.replaceSubrange(start..<start + size, with: bytes)
            }
        }
    }

    // MARK: UPS

    private static func applyUPS(_ patch: [UInt8], to rom: [UInt8]) throws -> [UInt8] {
        guard patch.count >= 16, uint32LE(patch, at: patch.count - 4) == Checksum.crc(of: Data(patch[..<(patch.count - 4)])) else {
            throw PatchError.damaged
        }
        var reader = VarintReader(bytes: patch, offset: 4, end: patch.count - 12)
        let inputSize = try reader.number()
        let outputSize = try reader.number()
        let inputCRC = uint32LE(patch, at: patch.count - 12)
        let outputCRC = uint32LE(patch, at: patch.count - 8)
        let romCRC = Checksum.crc(of: Data(rom))
        guard rom.count == inputSize, romCRC == inputCRC else {
            throw PatchError.wrongROM(expected: inputCRC, found: romCRC)
        }
        var output = [UInt8](repeating: 0, count: outputSize)
        output.replaceSubrange(0..<min(rom.count, outputSize), with: rom.prefix(outputSize))
        var position = 0
        while !reader.isAtEnd {
            position += try reader.number()
            while true {
                let value = try reader.byte()
                if position < outputSize { output[position] ^= value }
                position += 1
                if value == 0 { break }
            }
        }
        guard Checksum.crc(of: Data(output)) == outputCRC else { throw PatchError.wrongResult }
        return output
    }

    // MARK: BPS

    private static func applyBPS(_ patch: [UInt8], to rom: [UInt8]) throws -> [UInt8] {
        guard patch.count >= 16, uint32LE(patch, at: patch.count - 4) == Checksum.crc(of: Data(patch[..<(patch.count - 4)])) else {
            throw PatchError.damaged
        }
        var reader = VarintReader(bytes: patch, offset: 4, end: patch.count - 12)
        let sourceSize = try reader.number()
        let targetSize = try reader.number()
        let metadataSize = try reader.number()
        try reader.skip(metadataSize)
        let sourceCRC = uint32LE(patch, at: patch.count - 12)
        let targetCRC = uint32LE(patch, at: patch.count - 8)
        let romCRC = Checksum.crc(of: Data(rom))
        guard rom.count == sourceSize, romCRC == sourceCRC else {
            throw PatchError.wrongROM(expected: sourceCRC, found: romCRC)
        }

        var target = [UInt8](repeating: 0, count: targetSize)
        var outputOffset = 0
        var sourceRelative = 0
        var targetRelative = 0
        while !reader.isAtEnd {
            let data = try reader.number()
            let length = (data >> 2) + 1
            guard outputOffset + length <= targetSize else { throw PatchError.damaged }
            switch data & 3 {
            case 0: // SourceRead
                guard outputOffset + length <= rom.count else { throw PatchError.damaged }
                target.replaceSubrange(outputOffset..<outputOffset + length, with: rom[outputOffset..<outputOffset + length])
                outputOffset += length
            case 1: // TargetRead
                for _ in 0..<length {
                    target[outputOffset] = try reader.byte()
                    outputOffset += 1
                }
            case 2: // SourceCopy
                let offset = try reader.number()
                sourceRelative += (offset & 1 != 0 ? -1 : 1) * (offset >> 1)
                guard sourceRelative >= 0, sourceRelative + length <= rom.count else { throw PatchError.damaged }
                target.replaceSubrange(outputOffset..<outputOffset + length, with: rom[sourceRelative..<sourceRelative + length])
                outputOffset += length
                sourceRelative += length
            default: // TargetCopy: may overlap the bytes it writes, so byte by byte
                let offset = try reader.number()
                targetRelative += (offset & 1 != 0 ? -1 : 1) * (offset >> 1)
                guard targetRelative >= 0 else { throw PatchError.damaged }
                for _ in 0..<length {
                    guard targetRelative < outputOffset else { throw PatchError.damaged }
                    target[outputOffset] = target[targetRelative]
                    outputOffset += 1
                    targetRelative += 1
                }
            }
        }
        guard Checksum.crc(of: Data(target)) == targetCRC else { throw PatchError.wrongResult }
        return target
    }

    // MARK: Reading

    private static func uint32LE(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }

    /// Reads the variable-length numbers of UPS and BPS.
    private struct VarintReader {
        let bytes: [UInt8]
        var offset: Int
        let end: Int

        var isAtEnd: Bool { offset >= end }

        mutating func byte() throws -> UInt8 {
            guard offset < end else { throw PatchError.damaged }
            defer { offset += 1 }
            return bytes[offset]
        }

        mutating func skip(_ count: Int) throws {
            guard count >= 0, offset + count <= end else { throw PatchError.damaged }
            offset += count
        }

        mutating func number() throws -> Int {
            var value = 0
            var shift = 1
            while true {
                let byte = try byte()
                value += Int(byte & 0x7F) * shift
                if byte & 0x80 != 0 { return value }
                guard shift < 1 << 49 else { throw PatchError.damaged }
                shift <<= 7
                value += shift
            }
        }
    }
}
