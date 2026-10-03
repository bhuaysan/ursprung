// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import Ursprung

nonisolated private func record(_ path: String, id: UUID = UUID(), crc: String? = nil, size: Int64 = 3) -> GameRecord {
    GameRecord(id: id, path: path, systemID: "snes", title: "t", fileName: (path as NSString).lastPathComponent,
               fileSize: size, crc32: crc, fileModified: nil, dateAdded: .now, lastPlayed: nil, playCount: 0, playTime: 0,
               isFavorite: false, coreID: nil, missingSince: nil, scrapeState: "pending", screenScraperID: nil,
               overview: nil, developer: nil, publisher: nil, genre: nil, releaseDate: nil, players: nil, rating: nil,
               boxArtFile: nil, screenshotFile: nil, titleScreenFile: nil, logoFile: nil, fanartFile: nil)
}

nonisolated private func existing(_ path: String, id: UUID = UUID(), crc: String? = nil, size: Int64 = 3) -> Backup.ExistingGame {
    Backup.ExistingGame(id: id, path: path, systemID: "snes", crc32: crc, fileName: (path as NSString).lastPathComponent,
                        fileSize: size)
}

nonisolated private func locations(in root: URL) -> DataLocations {
    DataLocations(saves: root.appending(path: "Saves"), states: root.appending(path: "States"), media: root.appending(path: "Media"))
}

@Suite("Backup")
struct BackupTests {
    @Test func planMatchesByIDPathChecksumAndName() {
        let sameID = UUID()
        let library = [existing("/A.sfc", id: sameID), existing("/B.sfc"), existing("/Other/C.sfc", crc: "CC"),
                       existing("/Other/D.sfc")]
        let records = [record("/Old/A.sfc", id: sameID), record("/B.sfc"), record("/Mac/C2.sfc", crc: "cc"),
                       record("/Mac/D.sfc"), record("/Mac/E.sfc")]

        let plan = Backup.plan(records: records, existing: library)

        #expect(plan[records[0].id] == Backup.Target(id: sameID, isNew: false))
        #expect(plan[records[1].id] == Backup.Target(id: library[1].id, isNew: false))
        #expect(plan[records[2].id] == Backup.Target(id: library[2].id, isNew: false))
        #expect(plan[records[3].id] == Backup.Target(id: library[3].id, isNew: false))
        #expect(plan[records[4].id] == Backup.Target(id: records[4].id, isNew: true))
    }

    @Test func ambiguousNamesBecomeNewEntries() {
        let library = [existing("/1/Game.sfc"), existing("/2/Game.sfc")]
        let item = record("/Mac/Game.sfc")
        #expect(Backup.plan(records: [item], existing: library)[item.id]?.isNew == true)
    }

    @Test func roundTripRestoresSavesUnderTheNewIDs() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = locations(in: root.appending(path: "old"))
        let gameID = UUID()
        let save = BatterySave.url(in: source.saves, systemID: "snes", gameID: gameID, baseName: "Old")
        try FileManager.default.createDirectory(at: save.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1, 2]).write(to: save)
        let state = SaveStateStore.directory(in: source.states, gameID: gameID, coreID: "snes9x")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        try Data([3]).write(to: state.appending(path: "slot1.state"))
        let media = source.media.appending(path: gameID.uuidString)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        try Data([4]).write(to: media.appending(path: "box.png"))

        var item = record("/Mac/Old.sfc", id: gameID)
        item.isFavorite = true
        let archive = root.appending(path: "Backup.zip")
        try Backup.create(records: [item], settings: Data(), locations: source, destination: archive, appVersion: "1.0")

        let contents = try Backup.open(archive)
        defer { contents.remove() }
        #expect(contents.records == [item])
        #expect(contents.batterySaveCount == 1 && contents.stateCount == 1)

        // The game is already in the new library, under another ID and file name.
        let target = UUID()
        let destination = locations(in: root.appending(path: "new"))
        let plan = [gameID: Backup.Target(id: target, isNew: false)]
        let report = try Backup.restoreFiles(of: contents, plan: plan,
                                             renames: [Backup.Rename(systemID: "snes", recordID: gameID, from: "Old", to: "New")],
                                             locations: destination)

        #expect(report.added == 2)
        let restoredSave = BatterySave.url(in: destination.saves, systemID: "snes", gameID: target, baseName: "New")
        #expect(try Data(contentsOf: restoredSave) == Data([1, 2]))
        let restoredState = SaveStateStore.directory(in: destination.states, gameID: target, coreID: "snes9x")
        #expect(try Data(contentsOf: restoredState.appending(path: "slot1.state")) == Data([3]))
        #expect(try Data(contentsOf: destination.media.appending(path: "\(target.uuidString)/box.png")) == Data([4]))
    }

    @Test func incompleteBackupIsRefused() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "Ursprung Backup", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("[]".utf8).write(to: folder.appending(path: "library.json"))
        let manifest = BackupManifest(created: .now, appVersion: "1", gameCount: 0,
                                      files: [.init(path: "library.json", size: 2), .init(path: "Saves/snes/x.srm", size: 8)])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: folder.appending(path: "manifest.json"))
        let archive = root.appending(path: "Backup.zip")
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/zip")
        process.currentDirectoryURL = root
        process.arguments = ["-qr", archive.path(percentEncoded: false), "Ursprung Backup"]
        try process.run()
        process.waitUntilExit()

        #expect {
            try Backup.open(archive)
        } throws: { error in
            if case .incomplete(missing: 1)? = error as? Backup.BackupError { true } else { false }
        }
    }

    @Test func otherZipIsNotABackup() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appending(path: "Game.zip")
        try makeZip(at: archive, containing: "Game.sfc", bytes: Data([1]))
        #expect {
            try Backup.open(archive)
        } throws: { error in
            if case .notABackup? = error as? Backup.BackupError { true } else { false }
        }
    }
}
