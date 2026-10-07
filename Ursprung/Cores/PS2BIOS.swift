// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A PlayStation 2 BIOS dump, recognised by content the way ARMSX2 does it
/// (`LoadBiosVersion` in pcsx2/ps2/BiosTools.cpp): the ROM directory starts
/// with a `RESET` entry, and the `ROMVER` file holds version, region and date.
/// Dumps exist in dozens of versions with arbitrary names, so neither the
/// file name nor a checksum identifies them.
nonisolated struct PS2BIOS: Sendable, Hashable {
    enum Region: String, Sendable {
        case japan, usa, europe, asia, china, other
    }

    /// File name inside the BIOS folder.
    let fileName: String
    let region: Region
    /// "2.00" for ROMVER `0200…`.
    let version: String
    /// Build date from ROMVER, at noon UTC so it shows as the same day everywhere.
    let date: Date?

    /// ARMSX2 only considers files of this size (`MIN_BIOS_SIZE`, `MAX_BIOS_SIZE`).
    static let sizeRange = (4 << 20)...(8 << 20)

    /// Files ARMSX2 loads next to a dump with the same base name.
    static let sideFileExtensions: Set<String> = ["erom", "rom1", "rom2", "nvm", "mec"]

    static func inspect(_ url: URL) -> PS2BIOS? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, sizeRange.contains(size),
              let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        return parse(data, fileName: url.lastPathComponent)
    }

    static func parse(_ data: Data, fileName: String) -> PS2BIOS? {
        guard sizeRange.contains(data.count), let romver = romver(in: data) else { return nil }
        let text = String(decoding: romver, as: UTF8.self)
        let characters = Array(text)
        guard characters.count == 14, characters[0...3].allSatisfy(\.isNumber) else { return nil }
        // An arcade board's BIOS (COH-H) cannot run console games.
        if characters[4] == "T", characters[5] == "Z" { return nil }
        let region: Region = switch characters[4] {
        case "J": .japan
        case "A": .usa
        case "E": .europe
        case "H": .asia
        case "C": .china
        default: .other
        }
        let major = Int(String(characters[0...1])) ?? 0
        let version = "\(major).\(String(characters[2...3]))"
        return PS2BIOS(fileName: fileName, region: region, version: version, date: date(String(characters[6...13])))
    }

    /// The 14 bytes of the `ROMVER` file, found through the ROM directory.
    private static func romver(in data: Data) -> [UInt8]? {
        data.withUnsafeBytes { raw -> [UInt8]? in
            let entrySize = 16
            /// An entry's name: up to 10 bytes, NUL-terminated within them.
            func name(at offset: Int) -> [UInt8]? {
                let bytes = raw[offset..<offset + 10]
                guard let end = bytes.firstIndex(of: 0) else { return nil }
                return Array(bytes[offset..<end])
            }
            let reset = Array("RESET".utf8)
            var entry = 0
            while entry + entrySize <= raw.count, name(at: entry) != reset { entry += entrySize }
            guard entry + entrySize <= raw.count else { return nil }

            // Files follow each other from the start of the image, each
            // padded to 16 bytes, in the order of the directory.
            var fileOffset = 0
            while entry + entrySize <= raw.count, let name = name(at: entry), !name.isEmpty {
                let size = Int(raw.loadUnaligned(fromByteOffset: entry + 12, as: UInt32.self).littleEndian)
                if name == Array("ROMVER".utf8) {
                    guard fileOffset + 14 <= raw.count else { return nil }
                    return Array(raw[fileOffset..<fileOffset + 14])
                }
                fileOffset += (size + 15) & ~15
                entry += entrySize
            }
            return nil
        }
    }

    private static func date(_ yyyymmdd: String) -> Date? {
        guard yyyymmdd.count == 8, let year = Int(yyyymmdd.prefix(4)),
              let month = Int(yyyymmdd.dropFirst(4).prefix(2)), let day = Int(yyyymmdd.suffix(2)) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))
    }
}
