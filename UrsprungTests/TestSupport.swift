// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
@testable import Ursprung

/// A fresh directory below the system temp directory. Callers remove it with `defer`.
func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(path: "UrsprungTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

/// Creates `archive` with `/usr/bin/zip` from a single file named `name`.
func makeZip(at archive: URL, containing name: String, bytes: Data) throws {
    try makeZip(at: archive, files: [(name, bytes)])
}

/// Creates `archive` with `/usr/bin/zip` from `files`; `stored` keeps them uncompressed.
func makeZip(at archive: URL, files: [(name: String, bytes: Data)], stored: Bool = false) throws {
    let staging = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: staging) }
    for file in files { try file.bytes.write(to: staging.appending(path: file.name)) }
    try? FileManager.default.removeItem(at: archive)
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/zip")
    process.currentDirectoryURL = staging
    process.arguments = ["-q"] + (stored ? ["-0"] : []) + [archive.path(percentEncoded: false)] + files.map(\.name)
    try process.run()
    process.waitUntilExit()
    precondition(process.terminationStatus == 0, "zip failed")
}

/// The files of a save state as ARMSX2 writes it: its version, every part
/// ARMSX2 requires except `omitting` (a few bytes each, not a real state)
/// and `extra` files.
func armsx2StateFiles(version: UInt32, omitting: Set<String> = [],
                      extra: [(name: String, bytes: Data)] = []) -> [(name: String, bytes: Data)] {
    var bytes = withUnsafeBytes(of: version.littleEndian) { Data($0) }
    bytes.append(contentsOf: Array("0.1 test".utf8) + [0])
    return [("PCSX2 Savestate Version.id", bytes)]
        + ARMSX2States.requiredEntries.filter { !omitting.contains($0) }.map { ($0, Data("part".utf8)) }
        + extra
}

/// A ZIP of stored `files` built byte by byte, independent of `/usr/bin/zip`.
/// An entry named in `zip64` gives its sizes and local header offset (nil:
/// the real one) in the central directory's ZIP64 field, whatever they are.
func handmadeZip(files: [(name: String, bytes: Data)],
                 zip64: [String: (uncompressed: UInt64, compressed: UInt64, offset: UInt64?)] = [:]) -> Data {
    var data = Data()
    func u16(_ value: Int, into data: inout Data) { data.append(contentsOf: [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)]) }
    func u32(_ value: UInt32, into data: inout Data) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    func u64(_ value: UInt64, into data: inout Data) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }

    var directory = Data()
    for file in files {
        let name = Array(file.name.utf8)
        let crc = Checksum.crc(of: file.bytes)
        let offset = UInt32(data.count)
        u32(0x04034B50, into: &data); u16(20, into: &data); u16(0, into: &data); u16(0, into: &data)
        u16(0, into: &data); u16(0, into: &data)
        u32(crc, into: &data); u32(UInt32(file.bytes.count), into: &data); u32(UInt32(file.bytes.count), into: &data)
        u16(name.count, into: &data); u16(0, into: &data)
        data.append(contentsOf: name); data.append(file.bytes)

        var extra = Data()
        if let values = zip64[file.name] {
            u16(1, into: &extra); u16(24, into: &extra)
            u64(values.uncompressed, into: &extra); u64(values.compressed, into: &extra); u64(values.offset ?? UInt64(offset), into: &extra)
        }
        let size: UInt32 = zip64[file.name] == nil ? UInt32(file.bytes.count) : 0xFFFF_FFFF
        u32(0x02014B50, into: &directory); u16(20, into: &directory); u16(20, into: &directory)
        u16(0, into: &directory); u16(0, into: &directory); u16(0, into: &directory); u16(0, into: &directory)
        u32(crc, into: &directory); u32(size, into: &directory); u32(size, into: &directory)
        u16(name.count, into: &directory); u16(extra.count, into: &directory); u16(0, into: &directory)
        u16(0, into: &directory); u16(0, into: &directory); u32(0, into: &directory)
        u32(zip64[file.name] == nil ? offset : 0xFFFF_FFFF, into: &directory)
        directory.append(contentsOf: name); directory.append(extra)
    }
    let directoryOffset = UInt32(data.count)
    data.append(directory)
    u32(0x06054B50, into: &data); u16(0, into: &data); u16(0, into: &data)
    u16(files.count, into: &data); u16(files.count, into: &data)
    u32(UInt32(directory.count), into: &data); u32(directoryOffset, into: &data); u16(0, into: &data)
    return data
}
