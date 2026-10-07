// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import Ursprung

/// A solid PNG, standing in for the screenshot ARMSX2 stores in a state.
nonisolated private func png(width: Int, height: Int) -> Data {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
}

@Suite("PlayStation 2 saves")
struct PS2SavesTests {
    private let version: UInt32 = 0x9A59_0000

    /// A state laid out like ARMSX2's: version entry and stored screenshot.
    @discardableResult
    private func writeState(_ name: String, in folder: URL, version: UInt32? = nil, modified: Date? = nil) throws -> URL {
        var bytes = withUnsafeBytes(of: (version ?? self.version).littleEndian) { Data($0) }
        bytes.append(contentsOf: Array("0.1 test".utf8) + [0])
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: name)
        try makeZip(at: url, files: [("PCSX2 Savestate Version.id", bytes), ("Screenshot.png", png(width: 64, height: 48))],
                    stored: true)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path(percentEncoded: false))
        }
        return url
    }

    @Test func readsTheKindFromTheFileName() {
        // ARMSX2's slot 1 is Ursprung's Quick Save, its slot 0 Ursprung's slot 1.
        #expect(ARMSX2States.kind(ofFileName: "SLES-55474 (117D1977).01.p2s") == .slot(0))
        #expect(ARMSX2States.kind(ofFileName: "SLES-55474 (117D1977).00.p2s") == .slot(1))
        #expect(ARMSX2States.kind(ofFileName: "SLES-55474 (117D1977).10.p2s") == .slot(10))
        #expect(ARMSX2States.kind(ofFileName: "SLES-55474 (117D1977).resume.p2s") == .resume)
        #expect(ARMSX2States.kind(ofFileName: "SLES-55474 (117D1977).03 (from backup 2026-10-03 14.22.11).p2s") == .slot(3))
        #expect(ARMSX2States.kind(ofFileName: "SLES-55474 (117D1977).01.p2s.backup") == nil)
        #expect(ARMSX2States.kind(ofFileName: "SLES-55474 (117D1977).01.p2s.part") == nil)
        #expect(ARMSX2States.kind(ofFileName: ".SLES-55474 (117D1977).01.p2s") == nil)
        #expect(ARMSX2States.kind(ofFileName: "SLES-55474 (117D1977).01.json") == nil)
    }

    @Test func listsSlotsAndTheResumeStateWithThumbnails() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let gameID = UUID()
        let folder = SaveStateStore.directory(in: root, gameID: gameID, coreID: "armsx2")
        let now = Date.now
        try writeState("SLES-55474 (117D1977).02.p2s", in: folder, modified: now.addingTimeInterval(-60))
        try writeState("SLES-55474 (117D1977).01.p2s", in: folder, modified: now.addingTimeInterval(-120))
        let resume = try writeState("SLES-55474 (117D1977).resume.p2s", in: folder, modified: now)
        try writeState("SLES-55474 (117D1977).01.p2s.backup", in: folder)
        try Data().write(to: folder.appending(path: "SLES-55474 (117D1977).03.p2s.part"))

        let all = SaveStateStore.allStates(in: root, gameID: gameID)
        #expect(all.count == 1)
        let core = try #require(all.first)
        #expect(core.coreID == "armsx2")
        // allStates lists the folder's resolved path (/private/var/…).
        #expect(core.autosave?.stateURL.resolvingSymlinksInPath() == resume.resolvingSymlinksInPath())
        #expect(core.autosave?.isAutosave == true)
        #expect(core.slots.map(\.slot) == [0, 2])
        #expect(core.slots.allSatisfy { $0.isARMSX2 && $0.canRename && $0.manifest == nil })
        // The game can resume: the same check the library makes.
        #expect(ARMSX2States.resumeState(in: folder) == resume)

        let thumbnail = try #require(core.slots.first?.thumbnailURL)
        #expect(thumbnail == core.slots.first?.stateURL)
        let image = ArtworkCache().load(ArtworkCache.Version(thumbnail), maxPixel: 360)
        #expect(image?.width == 64 && image?.height == 48)
    }

    @Test func namesStickUntilARMSX2OverwritesTheSlot() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "armsx2")
        let url = try writeState("SLUS-21782 (01234567).04.p2s", in: folder, modified: .now.addingTimeInterval(-3600))
        var state = try #require(ARMSX2States.states(in: folder).slots.first)

        let origin = ARMSX2States.context(for: state, gameFileName: "Persona 4 (USA).iso", gameFileSize: 42)
        #expect(origin.coreID == "armsx2" && origin.coreVersion == "9A590000")
        try SaveStateStore.rename(state, to: " Before the dungeon ", origin: origin)
        state = try #require(ARMSX2States.states(in: folder).slots.first)
        #expect(state.name == "Before the dungeon")
        #expect(state.manifest?.gameFileName == "Persona 4 (USA).iso")
        #expect(state.manifestURL.lastPathComponent == "SLUS-21782 (01234567).04.json")

        // A new state in the slot is not the one that was named.
        try FileManager.default.setAttributes([.modificationDate: Date.now], ofItemAtPath: url.path(percentEncoded: false))
        #expect(ARMSX2States.states(in: folder).slots.first?.name == nil)
    }

    @Test func deletedStatesGoIntoTheHistoryAndComeBack() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let gameID = UUID()
        let folder = SaveStateStore.directory(in: root, gameID: gameID, coreID: "armsx2")
        let name = "SLES-55474 (117D1977).01.p2s"
        try writeState(name, in: folder, modified: .now.addingTimeInterval(-600))
        let first = try #require(ARMSX2States.states(in: folder).slots.first)
        try SaveStateStore.rename(first, to: "Old", origin: ARMSX2States.context(for: first, gameFileName: "g.iso", gameFileSize: 1))
        try SaveStateStore.discard(try #require(ARMSX2States.states(in: folder).slots.first),
                                   date: .now.addingTimeInterval(-300))
        #expect(ARMSX2States.states(in: folder).slots.isEmpty)

        let history = SaveStateStore.history(in: root, gameID: gameID, coreID: "armsx2")
        let entry = try #require(history.first)
        #expect(history.count == 1 && entry.slot == 0 && entry.isHistory && entry.name == "Old")

        // ARMSX2 has saved into the slot again; restoring swaps the two.
        try writeState(name, in: folder)
        try SaveStateStore.restore(entry, toSlot: entry.slot, in: folder)
        let restored = try #require(ARMSX2States.states(in: folder).slots.first)
        #expect(restored.stateURL.lastPathComponent == name)
        #expect(restored.name == "Old")
        let replaced = SaveStateStore.history(in: root, gameID: gameID, coreID: "armsx2")
        #expect(replaced.count == 1 && replaced.first?.name == nil)

        // Deleting the automatic state removes it for good.
        let resume = try writeState("SLES-55474 (117D1977).resume.p2s", in: folder)
        try SaveStateStore.discard(try #require(ARMSX2States.states(in: folder).autosave))
        #expect(!FileManager.default.fileExists(atPath: resume.path(percentEncoded: false)))
        #expect(SaveStateStore.history(in: root, gameID: gameID, coreID: "armsx2").count == 1)
    }

    @Test func theOldestStateOfAFullHistoryComesBackIntoAnOccupiedSlot() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "armsx2")
        let name = "SLES-55474 (117D1977).01.p2s"
        let start = Date.now.addingTimeInterval(-3600)
        for index in 0..<SaveStateStore.historyLimit {
            try writeState(name, in: folder, modified: start.addingTimeInterval(Double(index)))
            let state = try #require(ARMSX2States.states(in: folder).slots.first)
            if index == 0 {
                try SaveStateStore.rename(state, to: "Oldest",
                                          origin: ARMSX2States.context(for: state, gameFileName: "g.iso", gameFileSize: 1))
            }
            try SaveStateStore.discard(try #require(ARMSX2States.states(in: folder).slots.first),
                                       date: start.addingTimeInterval(Double(index) + 0.5))
        }
        try writeState(name, in: folder)
        let oldest = try #require(SaveStateStore.history(inCoreDirectory: folder).last)
        #expect(oldest.name == "Oldest")

        try SaveStateStore.restore(oldest, toSlot: oldest.slot, in: folder)
        let restored = try #require(ARMSX2States.states(in: folder).slots.first)
        #expect(restored.name == "Oldest")
        let history = SaveStateStore.history(inCoreDirectory: folder)
        #expect(history.count == SaveStateStore.historyLimit)
        #expect(history.first.map { abs($0.date.timeIntervalSinceNow) < 60 } == true, "The state it replaced")

        // An entry that can't be moved back leaves the slot as it was.
        let gone = try #require(history.last)
        try FileManager.default.removeItem(at: gone.stateURL)
        #expect(throws: (any Error).self) { try SaveStateStore.restore(gone, toSlot: gone.slot, in: folder) }
        #expect(ARMSX2States.states(in: folder).slots.first?.name == "Oldest")
        #expect(SaveStateStore.history(inCoreDirectory: folder).count == SaveStateStore.historyLimit - 1)
    }

    @Test func historyKeepsTheNewestStates() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "armsx2")
        let start = Date.now.addingTimeInterval(-3600)
        for index in 0..<(SaveStateStore.historyLimit + 2) {
            try writeState("SLES-55474 (117D1977).01.p2s", in: folder)
            try SaveStateStore.discard(try #require(ARMSX2States.states(in: folder).slots.first),
                                       date: start.addingTimeInterval(Double(index)))
        }
        let history = SaveStateStore.history(inCoreDirectory: folder)
        #expect(history.count == SaveStateStore.historyLimit)
        let newest = try #require(history.first?.replaced)
        #expect(abs(newest.timeIntervalSince(start) - Double(SaveStateStore.historyLimit + 1)) < 0.01)
    }

    @Test func startsFromAChosenStateOnlyWhenItLoads() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let game = root.appending(path: "Game (Europe).iso")
        try Data(count: 4096).write(to: game)
        let states = root.appending(path: "States/G/armsx2")
        var request = ARMSX2Launch.Request(
            app: root.appending(path: "ARMSX2.app"), executable: "Contents/MacOS/ARMSX2",
            dataFolder: root.appending(path: "data"), logFile: root.appending(path: "Logs/last-run.log"),
            pineFolder: root.appending(path: "PINE"), game: game, biosFolder: root.appending(path: "bios"), dumps: [],
            fallbackRegion: .europe, memoryCardFolder: root.appending(path: "Saves/ps2/G"), saveStateFolder: states,
            snapshotFolder: root.appending(path: "Extras/G/Screenshots"), resume: true, saveStateOnShutdown: true,
            fullscreen: false, controls: .standardUS, saveStateVersion: version)
        try writeState("SLES-55474 (117D1977).resume.p2s", in: states)
        request.stateFile = try writeState("SLES-55474 (117D1977).02.p2s", in: states)

        let launch = try ARMSX2Launch.prepare(request, environment: [:])
        #expect(launch.stateFile == request.stateFile, "The chosen state, not the resume state")

        request.stateFile = try writeState("SLES-55474 (117D1977).03.p2s", in: states, version: version + 1)
        #expect(throws: StandaloneLaunchError.self) { try ARMSX2Launch.prepare(request, environment: [:]) }

        // Without a known format of the installed version, no state is loadable.
        request.stateFile = nil
        request.saveStateVersion = nil
        #expect(try ARMSX2Launch.prepare(request, environment: [:]).stateFile == nil)
    }

    // MARK: Memory cards

    @Test func recognisesMemoryCards() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let formatted = root.appending(path: "formatted.ps2")
        var card = Data("Sony PS2 Memory Card Format 1.2.0.0".utf8)
        card.append(Data(count: 8_388_608 - card.count))
        try card.write(to: formatted)
        let blank = root.appending(path: "blank.ps2")
        try Data(repeating: 0xFF, count: 8_650_752).write(to: blank)
        let other = root.appending(path: "other.bin")
        try Data(count: 8_388_608).write(to: other)
        let small = root.appending(path: "Game.srm")
        try Data(count: 8192).write(to: small)

        #expect(PS2MemoryCard.isMemoryCard(formatted))
        #expect(PS2MemoryCard.isMemoryCard(blank))
        #expect(!PS2MemoryCard.isMemoryCard(other))
        #expect(!PS2MemoryCard.isMemoryCard(small))
        #expect(!PS2MemoryCard.isMemoryCard(root.appending(path: "missing.ps2")))
    }

    @Test func memoryCardsMoveAndMergeWithTheGame() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let saves = root.appending(path: "Saves"), states = root.appending(path: "States")
        let labels = FileMerge.Labels(existing: "before 2026-10-07 10.00.00", incoming: "from 2026-10-07 10.00.00")
        let game = UUID(), duplicate = UUID()

        // A game scanned as another system first keeps its card when it becomes a PS2 game.
        let misplaced = PS2MemoryCard.url(in: saves, systemID: "psx", gameID: game)
        try FileManager.default.createDirectory(at: misplaced.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: misplaced)
        try GameSaveFiles.changeSystem(of: game, from: "psx", to: "ps2", saves: saves, labels: labels)
        let card = PS2MemoryCard.url(in: saves, systemID: "ps2", gameID: game)
        #expect(try Data(contentsOf: card) == Data([1]))

        // Two entries of the same game come together: the newer card is used, the older one kept.
        let other = PS2MemoryCard.url(in: saves, systemID: "ps2", gameID: duplicate)
        try FileManager.default.createDirectory(at: other.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([2]).write(to: other)
        try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(60)],
                                              ofItemAtPath: other.path(percentEncoded: false))
        try writeState("SLES-55474 (117D1977).01.p2s", in: SaveStateStore.directory(in: states, gameID: duplicate, coreID: "armsx2"))
        let report = try GameSaveFiles.merge(from: duplicate, into: game, systemID: "ps2", baseName: "Persona 4 (Europe)",
                                             saves: saves, states: states, labels: labels)
        #expect(report.conflicts == 1 && report.added == 1)
        #expect(try Data(contentsOf: card) == Data([2]))
        #expect(FileManager.default.fileExists(atPath: card.deletingLastPathComponent()
            .appending(path: "Mcd001 (before 2026-10-07 10.00.00).ps2").path(percentEncoded: false)))
        #expect(ARMSX2States.states(in: SaveStateStore.directory(in: states, gameID: game, coreID: "armsx2")).slots.count == 1)
    }

    @Test func backupsCarryMemoryCardsAndStates() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        func locations(_ name: String) -> DataLocations {
            let base = root.appending(path: name)
            return DataLocations(saves: base.appending(path: "Saves"), states: base.appending(path: "States"),
                                 media: base.appending(path: "Media"), extras: base.appending(path: "Extras"),
                                 bezels: base.appending(path: "Bezels"), shaders: base.appending(path: "Shaders"))
        }
        let source = locations("old"), destination = locations("new")
        let gameID = UUID(), target = UUID()
        let card = PS2MemoryCard.url(in: source.saves, systemID: "ps2", gameID: gameID)
        try FileManager.default.createDirectory(at: card.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0xFF, count: 1024).write(to: card)
        let folder = SaveStateStore.directory(in: source.states, gameID: gameID, coreID: "armsx2")
        try writeState("SLES-55474 (117D1977).resume.p2s", in: folder)
        try writeState("SLES-55474 (117D1977).01.p2s", in: folder)

        let record = GameRecord(id: gameID, path: "/ROMS/PS2/Persona 4 (Europe).iso", systemID: "ps2", title: "Persona 4",
                                fileName: "Persona 4 (Europe).iso", fileSize: 1, crc32: nil, fileModified: nil, dateAdded: .now,
                                lastPlayed: nil, playCount: 0, playTime: 0, isFavorite: false, coreID: nil, missingSince: nil,
                                scrapeState: "pending", screenScraperID: nil, overview: nil, developer: nil, publisher: nil,
                                genre: nil, releaseDate: nil, players: nil, rating: nil, boxArtFile: nil, screenshotFile: nil,
                                titleScreenFile: nil, logoFile: nil, fanartFile: nil)
        let archive = root.appending(path: "Backup.zip")
        try Backup.create(records: [record], settings: Data(), locations: source, destination: archive, appVersion: "1.0")
        let contents = try Backup.open(archive)
        defer { contents.remove() }
        #expect(contents.batterySaveCount == 1 && contents.stateCount == 2)

        _ = try Backup.restoreFiles(of: contents, plan: [gameID: Backup.Target(id: target, isNew: false)], renames: [],
                                    locations: destination)
        let restoredCard = PS2MemoryCard.url(in: destination.saves, systemID: "ps2", gameID: target)
        #expect(try Data(contentsOf: restoredCard) == Data(repeating: 0xFF, count: 1024))
        let restored = SaveStateStore.allStates(in: destination.states, gameID: target)
        #expect(restored.first?.autosave != nil && restored.first?.slots.count == 1)
    }
}
