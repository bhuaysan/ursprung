// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import Ursprung

@Suite("Battery saves")
struct BatterySaveTests {
    @Test func gamesWithTheSameFileNameGetDifferentSaves() throws {
        let saves = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: saves) }
        let original = BatterySave.url(in: saves, systemID: "snes", gameID: UUID(), baseName: "Game")
        let hack = BatterySave.url(in: saves, systemID: "snes", gameID: UUID(), baseName: "Game")
        #expect(original != hack)

        for (url, content) in [(original, "original"), (hack, "hack")] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(content.utf8).write(to: url)
        }
        #expect(try String(contentsOf: original, encoding: .utf8) == "original")
        #expect(try String(contentsOf: hack, encoding: .utf8) == "hack")
    }

    @Test func uniqueLegacySaveMovesToTheGame() throws {
        let saves = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: saves) }
        let id = UUID()
        let legacy = BatterySave.legacyURL(in: saves, systemID: "snes", baseName: "Game")
        let destination = BatterySave.url(in: saves, systemID: "snes", gameID: id, baseName: "Game")
        try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("progress".utf8).write(to: legacy)

        #expect(BatterySave.migrateLegacy(to: destination, legacy: legacy, isUnambiguous: true))
        #expect(try String(contentsOf: destination, encoding: .utf8) == "progress")
        #expect(!FileManager.default.fileExists(atPath: legacy.path(percentEncoded: false)))
    }

    @Test func ambiguousLegacySaveStaysUntouched() throws {
        let saves = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: saves) }
        let legacy = BatterySave.legacyURL(in: saves, systemID: "snes", baseName: "Game")
        let destination = BatterySave.url(in: saves, systemID: "snes", gameID: UUID(), baseName: "Game")
        try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("progress".utf8).write(to: legacy)

        #expect(!BatterySave.migrateLegacy(to: destination, legacy: legacy, isUnambiguous: false))
        #expect(FileManager.default.fileExists(atPath: legacy.path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)))
    }

    @Test func existingSaveIsNeverOverwrittenByMigration() throws {
        let saves = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: saves) }
        let legacy = BatterySave.legacyURL(in: saves, systemID: "snes", baseName: "Game")
        let destination = BatterySave.url(in: saves, systemID: "snes", gameID: UUID(), baseName: "Game")
        for (url, content) in [(legacy, "old"), (destination, "current")] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(content.utf8).write(to: url)
        }

        #expect(!BatterySave.migrateLegacy(to: destination, legacy: legacy, isUnambiguous: true))
        #expect(try String(contentsOf: destination, encoding: .utf8) == "current")
    }
}
