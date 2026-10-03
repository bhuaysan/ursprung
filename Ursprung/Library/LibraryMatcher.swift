// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// What the library knows about a game whose file a scan no longer finds.
nonisolated struct GameFingerprint: Sendable, Hashable {
    let id: UUID
    let systemID: String
    let fileName: String
    let fileSize: Int64
    let crc32: String?
    let modified: Date?
}

/// Recognises games whose file was renamed or moved, so they keep their
/// identity (favourite, play time, metadata and saves) instead of becoming a
/// new game.
///
/// Only certain matches count. A file matches a game when both belong to the
/// same system, have the same size and extension, and either
/// - the game's known CRC32 equals the file's, or
/// - the game has no CRC32 and the file kept its modification date (Finder
///   keeps it when renaming, moving and copying).
/// A different CRC32 never matches: other regions, revisions and hacks of a
/// game stay separate games. When several files match one game, or several
/// games one file, the one with the same file name wins; if that does not
/// decide, nothing is matched and the user can locate the file by hand.
nonisolated enum LibraryMatcher {
    /// Maps the standardised path of a new file to the game it belongs to.
    /// `checksum` computes a file's CRC32 (hex) when the scan did not; it is
    /// only called for files that could match a game with a known CRC32.
    static func match(vanished: [GameFingerprint], candidates: [ScannedROM],
                      checksum: (URL) -> String?) -> [String: UUID] {
        guard !vanished.isEmpty, !candidates.isEmpty else { return [:] }
        let bySize = Dictionary(grouping: vanished) { Key(systemID: $0.systemID, fileSize: $0.fileSize) }
        var checksums: [URL: String?] = [:]
        func crc(of rom: ScannedROM) -> String? {
            if let crc = rom.crc32 { return crc }
            if let known = checksums[rom.url] { return known }
            let computed = checksum(rom.url)
            checksums[rom.url] = computed
            return computed
        }

        // All plausible pairs in both directions.
        var gamesForFile: [Int: [GameFingerprint]] = [:]
        var filesForGame: [UUID: [Int]] = [:]
        for (index, rom) in candidates.enumerated() where rom.fileSize > 0 {
            for game in bySize[Key(systemID: rom.systemID, fileSize: rom.fileSize)] ?? [] where matches(game, rom, crc: crc) {
                gamesForFile[index, default: []].append(game)
                filesForGame[game.id, default: []].append(index)
            }
        }

        var result: [String: UUID] = [:]
        for (index, games) in gamesForFile {
            let rom = candidates[index]
            guard let game = preferred(games, fileName: rom.fileName, name: \.fileName),
                  let files = filesForGame[game.id],
                  let chosen = preferred(files, fileName: game.fileName, name: { candidates[$0].fileName }),
                  chosen == index else { continue }
            result[rom.url.standardizedFileURL.path(percentEncoded: false)] = game.id
        }
        return result
    }

    private struct Key: Hashable {
        let systemID: String
        let fileSize: Int64
    }

    private static func matches(_ game: GameFingerprint, _ rom: ScannedROM, crc: (ScannedROM) -> String?) -> Bool {
        let gameExtension = (game.fileName as NSString).pathExtension.lowercased()
        guard gameExtension == (rom.fileName as NSString).pathExtension.lowercased() else { return false }
        if let known = game.crc32 {
            return crc(rom)?.caseInsensitiveCompare(known) == .orderedSame
        }
        guard let modified = game.modified, let romModified = rom.modified else { return false }
        // FAT and exFAT volumes store times in two-second steps.
        return abs(modified.timeIntervalSince(romModified)) <= 2
    }

    /// The only element, or the only one whose name equals `fileName`.
    private static func preferred<T>(_ elements: [T], fileName: String, name: (T) -> String) -> T? {
        if elements.count == 1 { return elements[0] }
        let named = elements.filter { name($0) == fileName }
        return named.count == 1 ? named[0] : nil
    }
}
