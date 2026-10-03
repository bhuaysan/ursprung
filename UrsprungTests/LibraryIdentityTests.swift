// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import SwiftData
import Testing
@testable import Ursprung

nonisolated private let date = Date(timeIntervalSinceReferenceDate: 800_000_000)

nonisolated private func fingerprint(_ fileName: String, size: Int64 = 100, crc: String? = nil, modified: Date? = date,
                                     system: String = "snes", id: UUID = UUID()) -> GameFingerprint {
    GameFingerprint(id: id, systemID: system, fileName: fileName, fileSize: size, crc32: crc, modified: modified)
}

nonisolated private func candidate(_ path: String, size: Int64 = 100, crc: String? = nil, modified: Date? = date,
                                   system: String = "snes") -> ScannedROM {
    ScannedROM(url: URL(filePath: path), systemID: system, title: "t", fileName: (path as NSString).lastPathComponent,
               fileSize: size, crc32: crc, modified: modified)
}

@Suite("Recognising moved games")
struct LibraryMatcherTests {
    @Test func renamedFileWithSameDateMatches() {
        let game = fingerprint("Old.sfc")
        let matches = LibraryMatcher.match(vanished: [game], candidates: [candidate("/ROMs/New.sfc")]) { _ in nil }
        #expect(matches == ["/ROMs/New.sfc": game.id])
    }

    @Test func knownChecksumDecides() {
        let game = fingerprint("Old.sfc", crc: "AABBCCDD", modified: nil)
        let same = LibraryMatcher.match(vanished: [game], candidates: [candidate("/ROMs/New.sfc", modified: .now)]) { _ in "aabbccdd" }
        #expect(same == ["/ROMs/New.sfc": game.id])
        // Same size and date but another checksum: a different revision or hack.
        let other = LibraryMatcher.match(vanished: [game], candidates: [candidate("/ROMs/New.sfc")]) { _ in "11111111" }
        #expect(other.isEmpty)
    }

    @Test func differentSizeSystemOrExtensionNeverMatch() {
        let game = fingerprint("Old.sfc")
        #expect(LibraryMatcher.match(vanished: [game], candidates: [candidate("/R/New.sfc", size: 101)]) { _ in nil }.isEmpty)
        #expect(LibraryMatcher.match(vanished: [game], candidates: [candidate("/R/New.sfc", system: "nes")]) { _ in nil }.isEmpty)
        #expect(LibraryMatcher.match(vanished: [game], candidates: [candidate("/R/New.smc")]) { _ in nil }.isEmpty)
        #expect(LibraryMatcher.match(vanished: [game], candidates: [candidate("/R/New.sfc", modified: date + 60)]) { _ in nil }.isEmpty)
    }

    @Test func ambiguousMatchesAreLeftToTheUser() {
        let first = fingerprint("A.sfc")
        let second = fingerprint("B.sfc")
        let matches = LibraryMatcher.match(vanished: [first, second], candidates: [candidate("/R/C.sfc")]) { _ in nil }
        #expect(matches.isEmpty)
    }

    @Test func sameFileNameResolvesAMovedFolder() {
        let first = fingerprint("A.sfc")
        let second = fingerprint("B.sfc")
        let matches = LibraryMatcher.match(vanished: [first, second],
                                           candidates: [candidate("/New/A.sfc"), candidate("/New/B.sfc")]) { _ in nil }
        #expect(matches == ["/New/A.sfc": first.id, "/New/B.sfc": second.id])
    }

    @Test func checksumIsOnlyComputedForPlausibleFiles() {
        var computed: [String] = []
        let game = fingerprint("Old.sfc", crc: "AABBCCDD")
        _ = LibraryMatcher.match(vanished: [game],
                                 candidates: [candidate("/R/Big.sfc", size: 5), candidate("/R/Fits.sfc")]) { url in
            computed.append(url.lastPathComponent)
            return nil
        }
        #expect(computed == ["Fits.sfc"])
    }
}

private func makeContext() throws -> (ModelContainer, ModelContext) {
    let container = try ModelContainer.library(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
    return (container, ModelContext(container))
}

private func makeStore(folders: [URL], data: URL) -> LibraryStore {
    LibraryStore(metadata: MetadataService(), folders: folders, persistFolders: { _ in }, scrapesAutomatically: { false },
                 saves: data.appending(path: "Saves"), states: data.appending(path: "States"))
}

private func path(_ url: URL) -> String { url.standardizedFileURL.path(percentEncoded: false) }

@Suite("Game identity")
struct GameIdentityTests {
    @Test func renamedROMKeepsItsGameAndSave() async throws {
        let root = try makeTemporaryDirectory()
        let data = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: data)
        }
        let folder = root.appending(path: "SNES", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 64).write(to: folder.appending(path: "Old Name.sfc"))

        let (container, context) = try makeContext()
        _ = container
        let store = makeStore(folders: [root], data: data)
        await store.rescan(context: context)
        let game = try #require(try context.fetch(FetchDescriptor<Game>()).first)
        let id = game.id
        game.isFavorite = true
        game.playTime = 3600
        try context.save()
        let oldSave = BatterySave.url(in: data.appending(path: "Saves"), systemID: "snes", gameID: id, baseName: "Old Name")
        try FileManager.default.createDirectory(at: oldSave.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: oldSave)

        // Finder keeps the modification date when renaming.
        try FileManager.default.moveItem(at: folder.appending(path: "Old Name.sfc"), to: folder.appending(path: "New Name.sfc"))
        await store.rescan(context: context)

        let games = try context.fetch(FetchDescriptor<Game>())
        #expect(games.count == 1)
        let renamed = try #require(games.first)
        #expect(renamed.id == id)
        #expect(renamed.isFavorite && renamed.playTime == 3600 && !renamed.isMissing)
        #expect(renamed.path == path(folder.appending(path: "New Name.sfc")))
        #expect(renamed.title == "New Name")
        let newSave = BatterySave.url(in: data.appending(path: "Saves"), systemID: "snes", gameID: id, baseName: "New Name")
        #expect(FileManager.default.fileExists(atPath: newSave.path(percentEncoded: false)))
    }

    @Test func deletedROMIsMissingUntilItReturns() async throws {
        let root = try makeTemporaryDirectory()
        let data = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: data)
        }
        let file = root.appending(path: "Game.sfc")
        try Data([1, 2, 3]).write(to: file)
        let (container, context) = try makeContext()
        _ = container
        let store = makeStore(folders: [root], data: data)
        await store.rescan(context: context)

        let parked = data.appending(path: "Game.sfc")
        try FileManager.default.moveItem(at: file, to: parked)
        await store.rescan(context: context)
        #expect(try context.fetch(FetchDescriptor<Game>()).map(\.isMissing) == [true])
        #expect(store.lastScanSummary?.contains("1") == true)

        try FileManager.default.moveItem(at: parked, to: file)
        await store.rescan(context: context)
        #expect(try context.fetch(FetchDescriptor<Game>()).map(\.isMissing) == [false])
    }

    @Test func gameOutsideTheFoldersIsNeverDeletedByAScan() async throws {
        let root = try makeTemporaryDirectory()
        let data = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: data)
        }
        let (container, context) = try makeContext()
        _ = container
        // E.g. restored from a backup made on another Mac.
        context.insert(Game(path: "/Elsewhere/Game.sfc", systemID: "snes", title: "t", fileName: "Game.sfc", fileSize: 3, crc32: nil))
        try context.save()
        let store = makeStore(folders: [root], data: data)
        await store.rescan(context: context)
        #expect(try context.fetch(FetchDescriptor<Game>()).map(\.isMissing) == [true])
    }

    @Test func locatingAFileMergesTheEntryFoundMeanwhile() async throws {
        let root = try makeTemporaryDirectory()
        let data = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: data)
        }
        let (container, context) = try makeContext()
        _ = container
        let store = makeStore(folders: [root], data: data)
        let saves = data.appending(path: "Saves")

        let missing = Game(path: path(root.appending(path: "Old.sfc")), systemID: "snes", title: "Old", fileName: "Old.sfc",
                           fileSize: 3, crc32: nil)
        missing.missingSince = .now
        missing.isFavorite = true
        missing.playTime = 100
        let file = root.appending(path: "New.sfc")
        try Data([1, 2, 3]).write(to: file)
        let found = Game(path: path(file), systemID: "snes", title: "New", fileName: "New.sfc", fileSize: 3, crc32: nil)
        found.playTime = 50
        context.insert(missing)
        context.insert(found)
        try context.save()

        // The old entry has an old save; the new entry was played since and has a newer one.
        let oldSave = BatterySave.url(in: saves, systemID: "snes", gameID: missing.id, baseName: "Old")
        let newSave = BatterySave.url(in: saves, systemID: "snes", gameID: found.id, baseName: "New")
        for (url, byte, age) in [(oldSave, UInt8(1), 3600.0), (newSave, UInt8(2), 0)] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([byte]).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date.now - age], ofItemAtPath: url.path(percentEncoded: false))
        }

        try store.relink(missing, to: file, context: context)

        let games = try context.fetch(FetchDescriptor<Game>())
        #expect(games.map(\.id) == [missing.id])
        #expect(missing.path == path(file) && !missing.isMissing && missing.isFavorite && missing.playTime == 150)
        let merged = BatterySave.url(in: saves, systemID: "snes", gameID: missing.id, baseName: "New")
        #expect(try Data(contentsOf: merged) == Data([2]))
        // The older save is kept as a copy.
        let folder = merged.deletingLastPathComponent()
        let copies = try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false)).filter { $0 != "New.srm" }
        #expect(copies.count == 1)
        #expect(try Data(contentsOf: folder.appending(path: copies[0])) == Data([1]))
    }

    @Test func locatingAFileOfAnotherSystemFails() throws {
        let (container, context) = try makeContext()
        _ = container
        let data = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: data) }
        let store = makeStore(folders: [], data: data)
        let game = Game(path: "/ROMs/Game.sfc", systemID: "snes", title: "t", fileName: "Game.sfc", fileSize: 3, crc32: nil)
        context.insert(game)
        #expect(throws: LibraryStore.RelinkError.self) {
            try store.relink(game, to: URL(filePath: "/ROMs/Game.gba"), context: context)
        }
    }
}

@Suite("Library schema")
struct LibrarySchemaTests {
    @Test func libraryFromTheFirstVersionOpens() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = directory.appending(path: "Library.store")
        do {
            let old = try ModelContainer(for: Schema(versionedSchema: LibrarySchemaV1.self),
                                         configurations: ModelConfiguration(url: store))
            let context = ModelContext(old)
            let game = LibrarySchemaV1.Game(path: "/ROMs/Game.sfc", systemID: "snes", title: "Game", fileName: "Game.sfc",
                                            fileSize: 3, crc32: "AABBCCDD")
            game.isFavorite = true
            context.insert(game)
            try context.save()
        }

        let container = try ModelContainer.library(configuration: ModelConfiguration(url: store))
        let games = try ModelContext(container).fetch(FetchDescriptor<Game>())
        #expect(games.count == 1)
        #expect(games.first?.isFavorite == true && games.first?.crc32 == "AABBCCDD" && games.first?.isMissing == false)
    }
}
