// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import Ursprung

/// Builds a one-entry ZIP by hand so the central directory can be made malformed.
private func handmadeZip(centralExtra: [UInt8], sentinelSizes: Bool) -> Data {
    var data = Data()
    func u16(_ value: Int) { data.append(contentsOf: [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)]) }
    func u32(_ value: UInt32) { for shift in stride(from: 0, to: 32, by: 8) { data.append(UInt8((value >> UInt32(shift)) & 0xFF)) } }
    let name = Array("a.bin".utf8)
    let payload = Array("abcd".utf8)

    // Local file header + stored data
    u32(0x04034B50); u16(20); u16(0); u16(0); u16(0); u16(0)
    u32(0); u32(4); u32(4); u16(name.count); u16(0)
    data.append(contentsOf: name); data.append(contentsOf: payload)

    // Central directory
    let directoryOffset = data.count
    u32(0x02014B50); u16(20); u16(20); u16(0); u16(0); u16(0); u16(0)
    u32(0)
    u32(sentinelSizes ? 0xFFFF_FFFF : 4); u32(sentinelSizes ? 0xFFFF_FFFF : 4)
    u16(name.count); u16(centralExtra.count); u16(0); u16(0); u16(0); u32(0); u32(0)
    data.append(contentsOf: name); data.append(contentsOf: centralExtra)
    let directorySize = data.count - directoryOffset

    // End of central directory
    u32(0x06054B50); u16(0); u16(0); u16(1); u16(1); u32(UInt32(directorySize)); u32(UInt32(directoryOffset)); u16(0)
    return data
}

private func zip64Field(tag: UInt16 = 1, declaredSize: Int, values: [UInt64]) -> [UInt8] {
    var field: [UInt8] = [UInt8(tag & 0xFF), UInt8(tag >> 8), UInt8(declaredSize & 0xFF), UInt8(declaredSize >> 8)]
    for value in values { field += (0..<8).map { UInt8((value >> UInt64($0 * 8)) & 0xFF) } }
    return field
}

@Suite("ZIP robustness")
struct ZipRobustnessTests {
    private func open(_ data: Data) throws -> ZipArchive {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "test.zip")
        try data.write(to: file)
        return try ZipArchive(url: file)
    }

    @Test func rejectsZip64FieldWithoutPayload() {
        let extra = zip64Field(declaredSize: 0, values: [])
        #expect(throws: ZipArchive.ZipError.self) { try open(handmadeZip(centralExtra: extra, sentinelSizes: true)) }
    }

    @Test func rejectsZip64FieldWithSevenPayloadBytes() {
        var extra = zip64Field(declaredSize: 7, values: [])
        extra += [UInt8](repeating: 1, count: 7)
        #expect(throws: ZipArchive.ZipError.self) { try open(handmadeZip(centralExtra: extra, sentinelSizes: true)) }
    }

    @Test func rejectsZip64FieldThatRunsPastTheExtraData() {
        // Declares 16 bytes but only 8 follow.
        let extra = zip64Field(declaredSize: 16, values: [4])
        #expect(throws: ZipArchive.ZipError.self) { try open(handmadeZip(centralExtra: extra, sentinelSizes: true)) }
    }

    @Test func rejectsZip64FieldMissingOneOfTwoSentinelValues() {
        let extra = zip64Field(declaredSize: 8, values: [4])
        #expect(throws: ZipArchive.ZipError.self) { try open(handmadeZip(centralExtra: extra, sentinelSizes: true)) }
    }

    @Test func readsValidZip64Field() throws {
        let extra = zip64Field(declaredSize: 16, values: [4, 4])
        let archive = try open(handmadeZip(centralExtra: extra, sentinelSizes: true))
        let entry = try #require(archive.files.first)
        #expect(entry.uncompressedSize == 4)
        #expect(entry.compressedSize == 4)
    }

    @Test func ignoresUnrelatedExtraFields() throws {
        let extra = zip64Field(tag: 0x5455, declaredSize: 5, values: []) + [1, 2, 3, 4, 5]
        let archive = try open(handmadeZip(centralExtra: extra, sentinelSizes: false))
        #expect(archive.files.first?.uncompressedSize == 4)
    }

    @Test func rejectsEntryCountLargerThanDirectory() throws {
        var data = handmadeZip(centralExtra: [], sentinelSizes: false)
        // Claim 60000 entries in the end-of-central-directory record.
        let eocd = data.count - 22
        data[eocd + 10] = 0x60; data[eocd + 11] = 0xEA
        #expect(throws: ZipArchive.ZipError.self) { try open(data) }
    }

    @Test func extractRejectsEntryPointingPastTheFile() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let extra = zip64Field(declaredSize: 24, values: [4, 4, UInt64.max - 10])
        let file = directory.appending(path: "test.zip")
        try handmadeZip(centralExtra: extra, sentinelSizes: true).replacingLocalOffsetSentinel().write(to: file)
        let archive = try ZipArchive(url: file)
        let entry = try #require(archive.files.first)
        let destination = FileManager.default.temporaryDirectory.appending(path: "never-\(UUID().uuidString)")
        #expect(throws: ZipArchive.ZipError.self) { try archive.extract(entry, to: destination) }
    }

    @Test func extractRejectsStoredPayloadWithWrongChecksum() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // The handmade entry stores "abcd" but claims a CRC32 of 0.
        let file = directory.appending(path: "test.zip")
        try handmadeZip(centralExtra: [], sentinelSizes: false).write(to: file)
        let archive = try ZipArchive(url: file)
        let entry = try #require(archive.files.first)
        let destination = directory.appending(path: "a.bin")
        try Data("old".utf8).write(to: destination)

        #expect(throws: ZipArchive.ZipError.self) { try archive.extract(entry, to: destination) }
        #expect(try Data(contentsOf: destination) == Data("old".utf8), "A failed extraction keeps the previous file")
    }

    @Test func extractRejectsDamagedDeflatedPayload() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "test.zip")
        try makeZip(at: file, containing: "rom.bin", bytes: Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 / 7) }))
        var data = try Data(contentsOf: file)
        // Flip a byte in the middle of the compressed data, past the local header.
        let payloadStart = 30 + Int(data.uint16(at: 26)) + Int(data.uint16(at: 28))
        data[payloadStart + 20] ^= 0x55
        try data.write(to: file)
        let archive = try ZipArchive(url: file)
        let entry = try #require(archive.files.first)

        #expect(throws: (any Error).self) { try archive.extract(entry, to: directory.appending(path: "rom.bin")) }
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "rom.bin").path(percentEncoded: false)))
    }
}

private extension Data {
    /// Sets the 32-bit local header offset of the only central directory record to the ZIP64 sentinel.
    func replacingLocalOffsetSentinel() -> Data {
        var data = self
        let eocd = data.count - 22
        let directoryOffset = Int(data.uint32(at: eocd + 16))
        for index in 0..<4 { data[directoryOffset + 42 + index] = 0xFF }
        return data
    }
}

@Suite("Extracted ROM cache")
struct ExtractedCacheTests {
    @Test func replacedArchiveWithSameSizeIsExtractedAgain() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appending(path: "Game.zip")
        let cache = root.appending(path: "cache")

        try makeZip(at: archive, containing: "rom.bin", bytes: Data("AAAAAAAA".utf8))
        let first = try ZipArchive(url: archive).files[0]
        let firstURL = try ZipArchive.extractCached(first, from: archive, into: cache)
        #expect(try Data(contentsOf: firstURL) == Data("AAAAAAAA".utf8))

        // Same path, same entry name, same size, different bytes.
        try makeZip(at: archive, containing: "rom.bin", bytes: Data("BBBBBBBB".utf8))
        let second = try ZipArchive(url: archive).files[0]
        #expect(second.uncompressedSize == first.uncompressedSize)
        let secondURL = try ZipArchive.extractCached(second, from: archive, into: cache)
        #expect(try Data(contentsOf: secondURL) == Data("BBBBBBBB".utf8))
    }

    @Test func unchangedArchiveIsServedFromTheCache() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appending(path: "Game.zip")
        let cache = root.appending(path: "cache")
        try makeZip(at: archive, containing: "rom.bin", bytes: Data("AAAAAAAA".utf8))
        let entry = try ZipArchive(url: archive).files[0]

        let url = try ZipArchive.extractCached(entry, from: archive, into: cache)
        let marker = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.modificationDate] as? Date
        _ = try ZipArchive.extractCached(entry, from: archive, into: cache)
        let after = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.modificationDate] as? Date
        #expect(marker == after)
    }

    @Test func failedExtractionLeavesNoValidCache() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appending(path: "Game.zip")
        let cache = root.appending(path: "cache")
        try makeZip(at: archive, containing: "rom.bin", bytes: Data("AAAAAAAA".utf8))
        let entry = try ZipArchive(url: archive).files[0]

        // Damage the local header (the archive starts with it).
        let handle = try FileHandle(forWritingTo: archive)
        try handle.write(contentsOf: Data([0, 0, 0, 0]))
        try handle.close()

        #expect(throws: ZipArchive.ZipError.self) { try ZipArchive.extractCached(entry, from: archive, into: cache) }
        #expect(!FileManager.default.fileExists(atPath: cache.appending(path: ".identity").path(percentEncoded: false)))
    }

    @Test func extractsAnEmptyEntry() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appending(path: "Empty.zip")
        try makeZip(at: archive, containing: "empty.txt", bytes: Data())
        let zip = try ZipArchive(url: archive)
        let destination = root.appending(path: "out/empty.txt")
        try zip.extract(try #require(zip.files.first), to: destination)
        #expect(try Data(contentsOf: destination).isEmpty)
    }
}
