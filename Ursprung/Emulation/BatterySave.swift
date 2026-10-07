// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Location of a game's battery save (.srm).
///
/// Games are identified by their library ID, not by their file name: two ROMs
/// that share a file name (`Original/Game.sfc`, `Hack/Game.sfc`, or `Game.sfc`
/// next to `Game.smc`) must never share a save.
nonisolated enum BatterySave {
    /// `<saves>/<system>/<game id>/<base name>.srm`
    static func url(in saves: URL, systemID: String, gameID: UUID, baseName: String) -> URL {
        saves.appending(path: systemID, directoryHint: .isDirectory)
            .appending(path: gameID.uuidString, directoryHint: .isDirectory)
            .appending(path: baseName + ".srm")
    }

    /// Earlier versions kept every save at `<saves>/<system>/<base name>.srm`.
    static func legacyURL(in saves: URL, systemID: String, baseName: String) -> URL {
        saves.appending(path: systemID, directoryHint: .isDirectory).appending(path: baseName + ".srm")
    }

    /// Moves a save from the legacy location to `destination` when it clearly
    /// belongs to this game. If several games of the system share the base name
    /// the legacy file could belong to any of them, so it stays untouched
    /// rather than being handed to the wrong game.
    @discardableResult
    static func migrateLegacy(to destination: URL, legacy: URL, isUnambiguous: Bool) -> Bool {
        let fileManager = FileManager.default
        guard isUnambiguous,
              !fileManager.fileExists(atPath: destination.path(percentEncoded: false)),
              fileManager.fileExists(atPath: legacy.path(percentEncoded: false)) else { return false }
        do {
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.moveItem(at: legacy, to: destination)
            return true
        } catch {
            return false
        }
    }

    /// Makes `source` the save at `destination`. A save that is already there
    /// is kept next to it as "<name> (<label>).srm".
    static func importSave(_ source: URL, to destination: URL, label: String) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destination.path(percentEncoded: false)) {
            try fileManager.moveItem(at: destination, to: FileMerge.available(destination, label: label))
        }
        try fileManager.copyItem(at: source, to: destination)
    }

    /// Real-time clock data some cores keep apart from save RAM, next to the save.
    static func rtcURL(forSave save: URL) -> URL {
        save.deletingPathExtension().appendingPathExtension("rtc")
    }

    /// The save of a game is named after its ROM. After a rename the folder
    /// still holds the save under the old name; when it is the only one, it
    /// takes the new name (and so does its clock file).
    @discardableResult
    static func adoptRenamed(at destination: URL) -> Bool {
        var adopted = false
        let directory = destination.deletingLastPathComponent()
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for ext in ["srm", "rtc"] {
            let target = destination.deletingPathExtension().appendingPathExtension(ext)
            guard !FileManager.default.fileExists(atPath: target.path(percentEncoded: false)) else { continue }
            let candidates = files.filter { $0.pathExtension.lowercased() == ext && !FileMerge.isLabelledCopy($0) }
            guard candidates.count == 1 else { continue }
            if (try? FileManager.default.moveItem(at: candidates[0], to: target)) != nil { adopted = true }
        }
        return adopted
    }
}

/// The save files of one library entry: its battery save folder and its
/// save states.
nonisolated enum GameSaveFiles {
    /// Moves the saves of the entry `sourceID` to the entry `targetID`, which
    /// is known by the file name `baseName` from now on. Nothing is lost:
    /// where both have a file, the newer one is used and the older one kept
    /// next to it.
    static func merge(from sourceID: UUID, into targetID: UUID, systemID: String, baseName: String,
                      saves: URL, states: URL, labels: FileMerge.Labels) throws -> FileMerge.Report {
        let targetSave = BatterySave.url(in: saves, systemID: systemID, gameID: targetID, baseName: baseName)
        // The target's own save may still carry an old name; it takes the new
        // one first, so the comparison below is between the right files.
        BatterySave.adoptRenamed(at: targetSave)
        let sourceSaves = targetSave.deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: sourceID.uuidString, directoryHint: .isDirectory)
        var report = FileMerge.Report()
        if FileManager.default.fileExists(atPath: sourceSaves.path(percentEncoded: false)) {
            let sourceSave = BatterySave.url(in: saves, systemID: systemID, gameID: sourceID, baseName: baseName)
            BatterySave.adoptRenamed(at: sourceSave)
            report = report + (try FileMerge.mergeDirectory(sourceSaves, into: targetSave.deletingLastPathComponent(),
                                                            moving: true, labels: labels))
        }
        let sourceStates = states.appending(path: sourceID.uuidString, directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: sourceStates.path(percentEncoded: false)) {
            report = report + (try FileMerge.mergeDirectory(sourceStates, into: states.appending(path: targetID.uuidString, directoryHint: .isDirectory),
                                                            moving: true, labels: labels))
        }
        return report
    }

    /// Battery saves are kept per system: when a game's system changes, its
    /// folder moves from `oldSystemID` to `newSystemID`. Where both have a
    /// file, the newer one is used and the older one kept next to it.
    @discardableResult
    static func changeSystem(of gameID: UUID, from oldSystemID: String, to newSystemID: String, saves: URL,
                             labels: FileMerge.Labels) throws -> FileMerge.Report {
        guard oldSystemID != newSystemID else { return FileMerge.Report() }
        let source = saves.appending(path: oldSystemID, directoryHint: .isDirectory)
            .appending(path: gameID.uuidString, directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: source.path(percentEncoded: false)) else { return FileMerge.Report() }
        let destination = saves.appending(path: newSystemID, directoryHint: .isDirectory)
            .appending(path: gameID.uuidString, directoryHint: .isDirectory)
        return try FileMerge.mergeDirectory(source, into: destination, moving: true, labels: labels)
    }

    /// Cores that manage their own files (memory cards, backup RAM) name them
    /// after the game in the system's save folder. After a rename those
    /// "<old name>.<ext>" files follow the game, unless a file with the new
    /// name is already there. Callers make sure no other game uses the old name.
    static func renameCoreSaves(in systemSaves: URL, from oldBaseName: String, to newBaseName: String) {
        guard oldBaseName != newBaseName,
              let files = try? FileManager.default.contentsOfDirectory(at: systemSaves, includingPropertiesForKeys: [.isRegularFileKey]) else { return }
        for file in files where file.lastPathComponent.hasPrefix(oldBaseName + ".") {
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let rest = file.lastPathComponent.dropFirst(oldBaseName.count)
            let target = systemSaves.appending(path: newBaseName + rest)
            guard !FileManager.default.fileExists(atPath: target.path(percentEncoded: false)) else { continue }
            try? FileManager.default.moveItem(at: file, to: target)
        }
    }
}

/// The memory card of a PlayStation 2 game: ARMSX2 keeps one card per game
/// in the game's save folder, `<saves>/<system>/<game id>/Mcd001.ps2`.
/// Moving, merging and backing up that folder works as for battery saves.
nonisolated enum PS2MemoryCard {
    /// Sizes of PCSX2 memory cards (8 to 64 MB, 528-byte pages with ECC).
    static let sizes: Set<Int> = [8_650_752, 17_301_504, 34_603_008, 69_206_016]
    private static let magic = Data("Sony PS2 Memory Card Format ".utf8)

    static func folder(in saves: URL, systemID: String, gameID: UUID) -> URL {
        saves.appending(path: systemID, directoryHint: .isDirectory)
            .appending(path: gameID.uuidString, directoryHint: .isDirectory)
    }

    static func url(in saves: URL, systemID: String, gameID: UUID) -> URL {
        folder(in: saves, systemID: systemID, gameID: gameID).appending(path: PCSX2Config.memoryCardFileName)
    }

    /// A formatted card starts with its format name; a new card is still
    /// unformatted (all 0xFF) and only recognisable by its size.
    static func isMemoryCard(_ url: URL) -> Bool {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size >= 8_388_608, size <= sizes.max()!,
              let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let header = (try? handle.read(upToCount: magic.count)) ?? Data()
        return header == magic || sizes.contains(size)
    }
}
