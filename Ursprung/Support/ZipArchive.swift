// SPDX-License-Identifier: GPL-3.0-or-later

import Compression
import Foundation

/// Read-only ZIP reader supporting "stored" and "deflate" entries — enough for
/// ROM archives and libretro buildbot downloads. Uses the zip central
/// directory, so listing an archive (including CRC32s) is instant.
nonisolated struct ZipArchive: Sendable {
    nonisolated struct Entry: Sendable, Hashable {
        let path: String
        let crc32: UInt32
        let compressedSize: UInt64
        let uncompressedSize: UInt64
        let method: UInt16
        let localHeaderOffset: UInt64

        var isDirectory: Bool { path.hasSuffix("/") }
        var fileName: String { (path as NSString).lastPathComponent }
        var fileExtension: String { (path as NSString).pathExtension.lowercased() }
    }

    enum ZipError: LocalizedError {
        case notAZip
        case unsupportedMethod(UInt16)
        case corrupt
        case decompressionFailed

        var errorDescription: String? {
            switch self {
            case .notAZip: String(localized: "The file is not a valid ZIP archive.")
            case .unsupportedMethod(let method): String(localized: "Unsupported ZIP compression method \(method).")
            case .corrupt: String(localized: "The ZIP archive is damaged.")
            case .decompressionFailed: String(localized: "The ZIP archive could not be decompressed.")
            }
        }
    }

    let url: URL
    let entries: [Entry]

    init(url: URL) throws {
        self.url = url
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        self.entries = try Self.readCentralDirectory(handle)
    }

    /// Files only (no directory entries, no macOS resource forks).
    var files: [Entry] {
        entries.filter { !$0.isDirectory && !$0.path.hasPrefix("__MACOSX/") && !$0.fileName.hasPrefix("._") }
    }

    func extract(_ entry: Entry, to destination: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let fileSize = try handle.seekToEnd()

        guard let compressedSize = Int(exactly: entry.compressedSize),
              let uncompressedSize = Int(exactly: entry.uncompressedSize),
              entry.localHeaderOffset <= fileSize, fileSize - entry.localHeaderOffset >= 30 else { throw ZipError.corrupt }
        try handle.seek(toOffset: entry.localHeaderOffset)
        guard let header = try handle.read(upToCount: 30), header.count == 30,
              header.uint32(at: 0) == 0x04034B50 else { throw ZipError.corrupt }
        let dataOffset = entry.localHeaderOffset + 30 + UInt64(header.uint16(at: 26)) + UInt64(header.uint16(at: 28))
        guard dataOffset <= fileSize, fileSize - dataOffset >= entry.compressedSize else { throw ZipError.corrupt }
        try handle.seek(toOffset: dataOffset)
        guard let compressed = try handle.read(upToCount: compressedSize), compressed.count == compressedSize else { throw ZipError.corrupt }

        let output: Data
        switch entry.method {
        case 0:
            output = compressed
        case 8:
            // Deflate cannot expand by more than ~1032:1; anything beyond is corrupt (or a bomb).
            let (limit, overflow) = entry.compressedSize.multipliedReportingOverflow(by: 1032)
            guard overflow || entry.uncompressedSize <= limit else { throw ZipError.corrupt }
            output = try Self.inflate(compressed, expectedSize: uncompressedSize)
        default:
            throw ZipError.unsupportedMethod(entry.method)
        }
        // Damaged payloads keep plausible offsets and sizes; only the
        // checksum notices them. Nothing is written for such an entry.
        guard output.count == uncompressedSize, Checksum.crc(of: output) == entry.crc32 else { throw ZipError.corrupt }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try output.write(to: destination, options: .atomic)
    }

    /// Extracts `entry` into `directory` unless an earlier extraction of the
    /// very same archive entry is still there. The cache is keyed by the
    /// entry's path, size and CRC32, so a replaced archive is never served
    /// from stale data, and an interrupted extraction leaves no marker.
    static func extractCached(_ entry: Entry, from archiveURL: URL, into directory: URL) throws -> URL {
        let destination = directory.appending(path: entry.fileName)
        let marker = directory.appending(path: ".identity")
        let identity = "\(entry.path)|\(entry.uncompressedSize)|\(entry.crc32)"
        let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path(percentEncoded: false))
        if (attributes?[.size] as? UInt64) == entry.uncompressedSize,
           (try? String(contentsOf: marker, encoding: .utf8)) == identity {
            return destination
        }
        try? FileManager.default.removeItem(at: directory)
        try ZipArchive(url: archiveURL).extract(entry, to: destination)
        try identity.write(to: marker, atomically: true, encoding: .utf8)
        return destination
    }

    /// Extracts all files below `directory`, preserving relative paths.
    func extractAll(to directory: URL) throws {
        for entry in files {
            let safePath = entry.path.split(separator: "/").filter { $0 != ".." && $0 != "." }.joined(separator: "/")
            try extract(entry, to: directory.appending(path: safePath))
        }
    }

    // MARK: - Parsing

    private static func readCentralDirectory(_ handle: FileHandle) throws -> [Entry] {
        let fileSize = try handle.seekToEnd()
        guard fileSize >= 22 else { throw ZipError.notAZip }

        // The end-of-central-directory record sits within the last 64 KiB + 22 bytes.
        let tailLength = min(fileSize, 65_557)
        try handle.seek(toOffset: fileSize - tailLength)
        guard let tail = try handle.read(upToCount: Int(tailLength)) else { throw ZipError.notAZip }

        var eocd: Int?
        var index = tail.count - 22
        while index >= 0 {
            if tail.uint32(at: index) == 0x06054B50 { eocd = index; break }
            index -= 1
        }
        guard let eocdIndex = eocd else { throw ZipError.notAZip }

        var entryCount = UInt64(tail.uint16(at: eocdIndex + 10))
        var directorySize = UInt64(tail.uint32(at: eocdIndex + 12))
        var directoryOffset = UInt64(tail.uint32(at: eocdIndex + 16))

        // ZIP64: locator directly precedes the EOCD record.
        if directoryOffset == 0xFFFF_FFFF || entryCount == 0xFFFF, eocdIndex >= 20,
           tail.uint32(at: eocdIndex - 20) == 0x07064B50 {
            let zip64Offset = tail.uint64(at: eocdIndex - 20 + 8)
            try handle.seek(toOffset: zip64Offset)
            if let record = try handle.read(upToCount: 56), record.count == 56, record.uint32(at: 0) == 0x06064B50 {
                entryCount = record.uint64(at: 32)
                directorySize = record.uint64(at: 40)
                directoryOffset = record.uint64(at: 48)
            }
        }

        // Every central directory record takes at least 46 bytes, so the
        // declared sizes must fit both the file and the record count.
        guard directoryOffset <= fileSize, directorySize <= fileSize - directoryOffset,
              let directoryLength = Int(exactly: directorySize),
              entryCount <= UInt64(directoryLength / 46) else { throw ZipError.corrupt }

        try handle.seek(toOffset: directoryOffset)
        guard let directory = try handle.read(upToCount: directoryLength), directory.count == directoryLength else { throw ZipError.corrupt }

        var entries: [Entry] = []
        entries.reserveCapacity(Int(entryCount))
        var offset = 0
        for _ in 0..<entryCount {
            guard offset + 46 <= directory.count, directory.uint32(at: offset) == 0x02014B50 else { throw ZipError.corrupt }
            let method = directory.uint16(at: offset + 10)
            let crc = directory.uint32(at: offset + 16)
            var compressed = UInt64(directory.uint32(at: offset + 20))
            var uncompressed = UInt64(directory.uint32(at: offset + 24))
            let nameLength = Int(directory.uint16(at: offset + 28))
            let extraLength = Int(directory.uint16(at: offset + 30))
            let commentLength = Int(directory.uint16(at: offset + 32))
            var localOffset = UInt64(directory.uint32(at: offset + 42))
            let flags = directory.uint16(at: offset + 8)

            let nameStart = offset + 46
            guard nameStart + nameLength + extraLength <= directory.count else { throw ZipError.corrupt }
            let nameData = directory.subdata(in: nameStart..<(nameStart + nameLength))
            let name = (flags & 0x0800) != 0
                ? String(decoding: nameData, as: UTF8.self)
                : (String(data: nameData, encoding: .isoLatin1) ?? String(decoding: nameData, as: UTF8.self))

            // ZIP64 extended information extra field: it only carries the
            // values whose 32-bit counterpart is the 0xFFFFFFFF sentinel.
            var extra = nameStart + nameLength
            let extraEnd = extra + extraLength
            while extra + 4 <= extraEnd {
                let tag = directory.uint16(at: extra)
                let size = Int(directory.uint16(at: extra + 2))
                let fieldStart = extra + 4
                let fieldEnd = fieldStart + size
                guard fieldEnd <= extraEnd else { throw ZipError.corrupt }
                if tag == 0x0001 {
                    var cursor = fieldStart
                    func next() throws -> UInt64 {
                        guard cursor + 8 <= fieldEnd else { throw ZipError.corrupt }
                        defer { cursor += 8 }
                        return directory.uint64(at: cursor)
                    }
                    if uncompressed == 0xFFFF_FFFF { uncompressed = try next() }
                    if compressed == 0xFFFF_FFFF { compressed = try next() }
                    if localOffset == 0xFFFF_FFFF { localOffset = try next() }
                }
                extra = fieldEnd
            }

            entries.append(Entry(path: name, crc32: crc, compressedSize: compressed, uncompressedSize: uncompressed,
                                 method: method, localHeaderOffset: localOffset))
            offset = nameStart + nameLength + extraLength + commentLength
        }
        return entries
    }

    private static func inflate(_ data: Data, expectedSize: Int) throws -> Data {
        if expectedSize == 0 { return Data() }
        var output = Data(count: expectedSize)
        let written = output.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                compression_decode_buffer(
                    destination.bindMemory(to: UInt8.self).baseAddress!, expectedSize,
                    source.bindMemory(to: UInt8.self).baseAddress!, data.count,
                    nil, COMPRESSION_ZLIB)
            }
        }
        guard written == expectedSize else { throw ZipError.decompressionFailed }
        return output
    }
}

nonisolated extension Data {
    func uint16(at offset: Int) -> UInt16 {
        UInt16(self[startIndex + offset]) | UInt16(self[startIndex + offset + 1]) << 8
    }

    func uint32(at offset: Int) -> UInt32 {
        UInt32(uint16(at: offset)) | UInt32(uint16(at: offset + 2)) << 16
    }

    func uint64(at offset: Int) -> UInt64 {
        UInt64(uint32(at: offset)) | UInt64(uint32(at: offset + 4)) << 32
    }
}

/// CRC32 (IEEE) via zlib, streaming for large files.
nonisolated enum Checksum {
    static func crc(of url: URL, maxBytes: UInt64 = .max) throws -> UInt32 {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var crc = crc32(0, nil, 0)
        var remaining = maxBytes
        while remaining > 0, let chunk = try handle.read(upToCount: Int(min(remaining, 4 << 20))), !chunk.isEmpty {
            crc = chunk.withUnsafeBytes { buffer in
                crc32(crc, buffer.bindMemory(to: Bytef.self).baseAddress, uInt(buffer.count))
            }
            remaining -= UInt64(chunk.count)
        }
        return UInt32(crc)
    }

    static func crc(of data: Data) -> UInt32 {
        data.withUnsafeBytes { buffer in
            var crc = crc32(0, nil, 0)
            var offset = 0
            // zlib takes 32-bit lengths.
            while offset < buffer.count {
                let length = min(buffer.count - offset, Int(UInt32.max))
                crc = crc32(crc, buffer.baseAddress!.advanced(by: offset).assumingMemoryBound(to: Bytef.self), uInt(length))
                offset += length
            }
            return UInt32(crc)
        }
    }

    static func hex(_ value: UInt32) -> String {
        String(format: "%08X", value)
    }
}
