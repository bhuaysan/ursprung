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
}
