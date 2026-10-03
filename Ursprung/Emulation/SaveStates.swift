// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Where a save state came from. Written next to every state as
/// `slotN.json`; see docs/SAVES.md.
nonisolated struct SaveStateManifest: Codable, Sendable, Hashable {
    static let currentFormat = 1

    var format = SaveStateManifest.currentFormat
    var coreID: String
    var coreVersion: String
    /// The ROM the state was made from, to notice a replaced file.
    var gameCRC32: String?
    var gameFileName: String
    var gameFileSize: Int64
    var created: Date
}

/// What the running game looks like now, to compare a state's manifest with.
nonisolated struct SaveStateContext: Sendable, Hashable {
    let coreID: String
    let coreVersion: String
    let gameCRC32: String?
    let gameFileName: String
    let gameFileSize: Int64

    func manifest(created: Date = .now) -> SaveStateManifest {
        SaveStateManifest(coreID: coreID, coreVersion: coreVersion, gameCRC32: gameCRC32, gameFileName: gameFileName,
                          gameFileSize: gameFileSize, created: created)
    }
}

/// Reasons a state may not load, or may load into a different game.
nonisolated enum SaveStateIssue: Sendable, Hashable {
    /// Saved by Ursprung before states were kept per core: the core is unknown.
    case unknownOrigin
    /// Saved with another version of the same core.
    case coreVersion(String)
    /// Saved from a different file (another revision, a replaced ROM).
    case differentGameFile
}

/// A save state slot on disk.
nonisolated struct SaveStateSlot: Identifiable, Hashable, Sendable {
    let slot: Int
    let date: Date
    let stateURL: URL
    let thumbnailURL: URL
    let manifestURL: URL
    /// nil for states from earlier versions.
    var manifest: SaveStateManifest?
    /// Found in the game's folder instead of the core's (earlier versions).
    var isLegacy = false
    var id: Int { slot }

    func issues(for context: SaveStateContext) -> [SaveStateIssue] {
        guard let manifest else { return [.unknownOrigin] }
        var issues: [SaveStateIssue] = []
        if manifest.coreVersion != context.coreVersion { issues.append(.coreVersion(manifest.coreVersion)) }
        let sameFile: Bool = if let saved = manifest.gameCRC32, let current = context.gameCRC32 {
            saved.caseInsensitiveCompare(current) == .orderedSame
        } else {
            manifest.gameFileSize == context.gameFileSize
        }
        if !sameFile { issues.append(.differentGameFile) }
        return issues
    }
}

/// Save states live at `<states>/<game id>/<core id>/slotN.state`, with a
/// thumbnail (`slotN.png`) and a manifest (`slotN.json`). States are specific
/// to a core, so every core has its own slots and switching cores never
/// overwrites another core's states.
///
/// Earlier versions kept states directly in `<states>/<game id>/` without
/// recording the core. Those stay where they are and show up for a slot that
/// the current core has not used, marked as of unknown origin.
nonisolated enum SaveStateStore {
    static let slotRange = 0...9

    static func gameDirectory(in states: URL, gameID: UUID) -> URL {
        states.appending(path: gameID.uuidString, directoryHint: .isDirectory)
    }

    static func directory(in states: URL, gameID: UUID, coreID: String) -> URL {
        gameDirectory(in: states, gameID: gameID).appending(path: coreID, directoryHint: .isDirectory)
    }

    static func slots(in states: URL, gameID: UUID, coreID: String) -> [SaveStateSlot] {
        let coreDirectory = directory(in: states, gameID: gameID, coreID: coreID)
        let legacyDirectory = gameDirectory(in: states, gameID: gameID)
        return slotRange.compactMap { slot in
            if var found = slotFile(slot, in: coreDirectory) {
                found.manifest = readManifest(found.manifestURL)
                return found
            }
            guard var legacy = slotFile(slot, in: legacyDirectory) else { return nil }
            legacy.isLegacy = true
            return legacy
        }
    }

    /// The state that a save into `slot` writes for `coreID`.
    static func stateURL(in states: URL, gameID: UUID, coreID: String, slot: Int) -> URL {
        directory(in: states, gameID: gameID, coreID: coreID).appending(path: "slot\(slot).state")
    }

    /// Writes a state and its manifest. The state is written atomically, so
    /// a failed write leaves the previous state of the slot intact.
    static func write(_ data: Data, manifest: SaveStateManifest, slot: Int, in directory: URL) throws {
        try write(data, manifest: manifest, name: "slot\(slot)", in: directory)
    }

    private static func write(_ data: Data, manifest: SaveStateManifest, name: String, in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appending(path: "\(name).state"), options: .atomic)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: directory.appending(path: "\(name).json"), options: .atomic)
    }

    /// The automatic state saved when a game stops: `autosave.state` in the
    /// core's folder, apart from the numbered slots.
    static let autosaveSlot = -1

    static func autosave(in states: URL, gameID: UUID, coreID: String) -> SaveStateSlot? {
        let directory = directory(in: states, gameID: gameID, coreID: coreID)
        guard var found = slotFile(named: "autosave", slot: autosaveSlot, in: directory) else { return nil }
        found.manifest = readManifest(found.manifestURL)
        return found
    }

    /// Writes the automatic state. Like a slot, a failed write keeps the previous one.
    static func writeAutosave(_ data: Data, manifest: SaveStateManifest, in directory: URL) throws {
        try write(data, manifest: manifest, name: "autosave", in: directory)
    }

    static func delete(_ slot: SaveStateSlot) {
        for url in [slot.stateURL, slot.thumbnailURL, slot.manifestURL] {
            try? FileManager.default.removeItem(at: url)
        }
    }

    static func readManifest(_ url: URL) -> SaveStateManifest? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SaveStateManifest.self, from: data)
    }

    private static func slotFile(_ slot: Int, in directory: URL) -> SaveStateSlot? {
        slotFile(named: "slot\(slot)", slot: slot, in: directory)
    }

    private static func slotFile(named name: String, slot: Int, in directory: URL) -> SaveStateSlot? {
        let state = directory.appending(path: "\(name).state")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: state.path(percentEncoded: false)),
              let date = attributes[.modificationDate] as? Date else { return nil }
        return SaveStateSlot(slot: slot, date: date, stateURL: state,
                             thumbnailURL: directory.appending(path: "\(name).png"),
                             manifestURL: directory.appending(path: "\(name).json"))
    }
}
