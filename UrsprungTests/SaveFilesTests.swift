// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import Ursprung

nonisolated private let labels = FileMerge.Labels(existing: "before 2026-10-03 12.00.00", incoming: "from 2026-10-01 12.00.00")

nonisolated private func write(_ bytes: [UInt8], to url: URL, age: TimeInterval = 0) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(bytes).write(to: url)
    try FileManager.default.setAttributes([.modificationDate: Date.now - age], ofItemAtPath: url.path(percentEncoded: false))
}

nonisolated private func names(in directory: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)).sorted()
}

@Suite("Merging files")
struct FileMergeTests {
    @Test func addsIdenticalAndConflictingFiles() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "in", directoryHint: .isDirectory)
        let destination = root.appending(path: "out", directoryHint: .isDirectory)
        try write([1], to: source.appending(path: "new.srm"))
        try write([2], to: source.appending(path: "same.srm"))
        try write([2], to: destination.appending(path: "same.srm"))
        try write([3], to: source.appending(path: "newer.srm"))
        try write([4], to: destination.appending(path: "newer.srm"), age: 60)
        try write([5], to: source.appending(path: "older.srm"), age: 60)
        try write([6], to: destination.appending(path: "older.srm"))

        let report = try FileMerge.mergeDirectory(source, into: destination, moving: false, labels: labels)

        #expect(report == FileMerge.Report(added: 1, identical: 1, conflicts: 2))
        #expect(try Data(contentsOf: destination.appending(path: "newer.srm")) == Data([3]))
        #expect(try Data(contentsOf: destination.appending(path: "newer (before 2026-10-03 12.00.00).srm")) == Data([4]))
        #expect(try Data(contentsOf: destination.appending(path: "older.srm")) == Data([6]))
        #expect(try Data(contentsOf: destination.appending(path: "older (from 2026-10-01 12.00.00).srm")) == Data([5]))
    }

    @Test func mapsPathComponents() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "in", directoryHint: .isDirectory)
        try write([1], to: source.appending(path: "snes/OLD/Game.srm"))
        _ = try FileMerge.mergeDirectory(source, into: root.appending(path: "out"), moving: true, labels: labels) {
            $0 == "OLD" ? "NEW" : $0
        }
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "out/snes/NEW/Game.srm").path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: source.path(percentEncoded: false)))
    }

    @Test func recognisesLabelledCopies() {
        #expect(FileMerge.isLabelledCopy(URL(filePath: "/s/Game (USA) (before restore 2026-10-03 14.22.10).srm")))
        #expect(FileMerge.isLabelledCopy(URL(filePath: "/s/Game (vor dem Import 2026-10-03 14.22.10 2).srm")))
        #expect(!FileMerge.isLabelledCopy(URL(filePath: "/s/Game (USA) (Rev 1).srm")))
    }
}

@Suite("Battery saves after a rename")
struct BatterySaveRenameTests {
    @Test func onlySaveTakesTheNewName() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write([1], to: root.appending(path: "Old.srm"))
        try write([2], to: root.appending(path: "Old.rtc"))
        try write([3], to: root.appending(path: "Older (before import 2026-10-03 12.00.00).srm"))

        #expect(BatterySave.adoptRenamed(at: root.appending(path: "New.srm")))
        #expect(try names(in: root) == ["New.rtc", "New.srm", "Older (before import 2026-10-03 12.00.00).srm"])
    }

    @Test func severalSavesStayAsTheyAre() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write([1], to: root.appending(path: "A.srm"))
        try write([2], to: root.appending(path: "B.srm"))
        #expect(!BatterySave.adoptRenamed(at: root.appending(path: "New.srm")))
        #expect(try names(in: root) == ["A.srm", "B.srm"])
    }

    @Test func importKeepsTheCurrentSave() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appending(path: "Game/Game.srm")
        try write([1], to: destination)
        try write([2], to: root.appending(path: "other.sav"))
        try BatterySave.importSave(root.appending(path: "other.sav"), to: destination, label: "before import 2026-10-03 12.00.00")
        #expect(try Data(contentsOf: destination) == Data([2]))
        #expect(try names(in: destination.deletingLastPathComponent()) == ["Game (before import 2026-10-03 12.00.00).srm", "Game.srm"])
    }

    @Test func coreSavesFollowTheName() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write([1], to: root.appending(path: "Old.bkr"))
        try write([2], to: root.appending(path: "Older.bkr"))
        try write([3], to: root.appending(path: "Old.mcr"))
        try write([4], to: root.appending(path: "New.mcr"))
        GameSaveFiles.renameCoreSaves(in: root, from: "Old", to: "New")
        // "Older" is another game; New.mcr already exists and wins.
        #expect(try names(in: root) == ["New.bkr", "New.mcr", "Old.mcr", "Older.bkr"])
    }
}

@Suite("Save states")
struct SaveStateStoreTests {
    private let gameID = UUID()
    private let context = SaveStateContext(coreID: "snes9x", coreVersion: "1.62", gameCRC32: "AABBCCDD",
                                           gameFileName: "Game.sfc", gameFileSize: 3)

    @Test func everyCoreHasItsOwnSlots() throws {
        let states = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: states) }
        try SaveStateStore.write(Data([1]), manifest: context.manifest(), slot: 1,
                                 in: SaveStateStore.directory(in: states, gameID: gameID, coreID: "snes9x"))
        try SaveStateStore.write(Data([2]), manifest: context.manifest(), slot: 1,
                                 in: SaveStateStore.directory(in: states, gameID: gameID, coreID: "bsnes"))

        let snes9x = SaveStateStore.slots(in: states, gameID: gameID, coreID: "snes9x")
        #expect(snes9x.map(\.slot) == [1])
        #expect(try Data(contentsOf: snes9x[0].stateURL) == Data([1]))
        #expect(snes9x[0].manifest?.coreVersion == "1.62")
        #expect(snes9x[0].issues(for: context).isEmpty)
        #expect(try Data(contentsOf: SaveStateStore.slots(in: states, gameID: gameID, coreID: "bsnes")[0].stateURL) == Data([2]))
    }

    @Test func legacyStatesShowWhereTheCoreHasNone() throws {
        let states = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: states) }
        let legacy = SaveStateStore.gameDirectory(in: states, gameID: gameID)
        try write([9], to: legacy.appending(path: "slot1.state"))
        try write([9], to: legacy.appending(path: "slot2.state"))
        try SaveStateStore.write(Data([1]), manifest: context.manifest(), slot: 2,
                                 in: SaveStateStore.directory(in: states, gameID: gameID, coreID: "snes9x"))

        let slots = SaveStateStore.slots(in: states, gameID: gameID, coreID: "snes9x")
        #expect(slots.map(\.slot) == [1, 2])
        #expect(slots[0].isLegacy && slots[0].issues(for: context) == [.unknownOrigin])
        #expect(!slots[1].isLegacy)

        // Deleting the core's state does not touch the legacy one.
        try SaveStateStore.delete(slots[1])
        #expect(SaveStateStore.slots(in: states, gameID: gameID, coreID: "snes9x").map(\.isLegacy) == [true, true])
    }

    @Test func reportsOtherCoreVersionsAndFiles() {
        var manifest = context.manifest()
        manifest.coreVersion = "1.60"
        manifest.gameCRC32 = "11111111"
        let slot = SaveStateSlot(slot: 1, date: .now, stateURL: URL(filePath: "/s"), thumbnailURL: URL(filePath: "/t"),
                                 manifestURL: URL(filePath: "/m"), manifest: manifest)
        #expect(slot.issues(for: context) == [.coreVersion("1.60"), .differentGameFile])
    }
}
