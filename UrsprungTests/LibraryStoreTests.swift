// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import SwiftData
import Testing
@testable import Ursprung

/// Lets a test hold the first scan open while it changes the folder list.
private actor ScanGate {
    private var calls = 0
    private var hasEntered = false
    private var isOpen = false
    private var entered: CheckedContinuation<Void, Never>?
    private var released: CheckedContinuation<Void, Never>?

    /// Blocks the first caller until `open()`; later callers pass at once.
    func pass() async {
        calls += 1
        guard calls == 1 else { return }
        hasEntered = true
        entered?.resume(); entered = nil
        if !isOpen { await withCheckedContinuation { released = $0 } }
    }

    func waitUntilEntered() async {
        if !hasEntered { await withCheckedContinuation { entered = $0 } }
    }

    func open() {
        isOpen = true
        released?.resume(); released = nil
    }
}

nonisolated private func rom(_ path: String) -> ScannedROM {
    ScannedROM(url: URL(filePath: path), systemID: "snes", title: "Game", fileName: (path as NSString).lastPathComponent, fileSize: 1, crc32: nil)
}

private func makeContext() throws -> (ModelContainer, ModelContext) {
    let container = try ModelContainer(for: Game.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    return (container, ModelContext(container))
}

private func makeStore(folders: [URL], scanner: @escaping LibraryStore.Scanner = { _ in LibraryScan() }) -> LibraryStore {
    LibraryStore(metadata: MetadataService(), folders: folders, scanner: scanner,
                 persistFolders: { _ in }, scrapesAutomatically: { false })
}

private func gamePaths(in context: ModelContext) throws -> [String] {
    try context.fetch(FetchDescriptor<Game>()).map(\.path).sorted()
}

@Suite("Library folders")
struct LibraryFolderTests {
    @Test func existingGameIsNilOnceTheGameIsDeleted() throws {
        let (container, context) = try makeContext()
        _ = container
        let game = Game(path: "/ROMs/SNES/A.sfc", systemID: "snes", title: "t", fileName: "A.sfc", fileSize: 1, crc32: nil)
        context.insert(game)
        try context.save()
        let id = game.persistentModelID
        #expect(context.existingGame(id)?.path == "/ROMs/SNES/A.sfc")

        context.delete(game)
        try context.save()
        #expect(context.existingGame(id) == nil)
    }

    @Test func insideComparesWholePathComponents() {
        #expect(LibraryPaths.isInside("/ROMs/SNES/Game.sfc", folder: "/ROMs/SNES"))
        #expect(LibraryPaths.isInside("/ROMs/SNES/Sub/Game.sfc", folder: "/ROMs/SNES/"))
        #expect(!LibraryPaths.isInside("/ROMs/SNES-hacks/Game.sfc", folder: "/ROMs/SNES"))
        #expect(!LibraryPaths.isInside("/ROMs/SNES", folder: "/ROMs/SNES"))
    }

    @Test func removingAFolderKeepsGamesOfSimilarlyNamedNeighbours() throws {
        let (container, context) = try makeContext()
        _ = container
        let snes = URL(filePath: "/ROMs/SNES", directoryHint: .isDirectory)
        let hacks = URL(filePath: "/ROMs/SNES-hacks", directoryHint: .isDirectory)
        for path in ["/ROMs/SNES/A.sfc", "/ROMs/SNES/Sub/B.sfc", "/ROMs/SNES-hacks/C.sfc"] {
            let game = Game(path: path, systemID: "snes", title: "t", fileName: "x", fileSize: 1, crc32: nil)
            game.isFavorite = path.contains("hacks")
            context.insert(game)
        }
        let store = makeStore(folders: [snes, hacks])

        store.removeFolder(snes, context: context)

        #expect(try gamePaths(in: context) == ["/ROMs/SNES-hacks/C.sfc"])
        #expect(store.folders == [hacks])
        #expect(try context.fetch(FetchDescriptor<Game>()).first?.isFavorite == true)
    }

    @Test func removingAFolderKeepsGamesAnotherFolderStillCovers() throws {
        let (container, context) = try makeContext()
        _ = container
        let parent = URL(filePath: "/ROMs", directoryHint: .isDirectory)
        let child = URL(filePath: "/ROMs/SNES", directoryHint: .isDirectory)
        context.insert(Game(path: "/ROMs/SNES/A.sfc", systemID: "snes", title: "t", fileName: "A.sfc", fileSize: 1, crc32: nil))
        let store = makeStore(folders: [parent, child])

        store.removeFolder(child, context: context)

        #expect(try gamePaths(in: context) == ["/ROMs/SNES/A.sfc"])
    }

    @Test func countsTheGamesThatLeaveWithAFolder() throws {
        let (container, context) = try makeContext()
        _ = container
        let parent = URL(filePath: "/ROMs", directoryHint: .isDirectory)
        let snes = URL(filePath: "/ROMs/SNES", directoryHint: .isDirectory)
        let other = URL(filePath: "/Other", directoryHint: .isDirectory)
        for path in ["/ROMs/SNES/A.sfc", "/ROMs/B.sfc", "/Other/C.sfc"] {
            context.insert(Game(path: path, systemID: "snes", title: "t", fileName: "x", fileSize: 1, crc32: nil))
        }
        let store = makeStore(folders: [parent, snes, other])

        #expect(store.games(leavingWith: snes, context: context).isEmpty, "The parent folder still covers A")
        #expect(store.games(leavingWith: parent, context: context).map(\.path) == ["/ROMs/B.sfc"])
        #expect(store.games(leavingWith: other, context: context).map(\.path) == ["/Other/C.sfc"])
    }

    @Test func rescanKeepsGamesOfUnreachableNeighbourFolder() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let reachable = root.appending(path: "SNES", directoryHint: .isDirectory)
        let unreachable = root.appending(path: "SNES-hacks", directoryHint: .isDirectory) // never created: unmounted
        try FileManager.default.createDirectory(at: reachable, withIntermediateDirectories: true)

        let (container, context) = try makeContext()
        _ = container
        let kept = unreachable.appending(path: "Kept.sfc").path(percentEncoded: false)
        let vanished = reachable.appending(path: "Vanished.sfc").path(percentEncoded: false)
        for path in [kept, vanished] {
            context.insert(Game(path: path, systemID: "snes", title: "t", fileName: "x", fileSize: 1, crc32: nil))
        }
        let store = makeStore(folders: [reachable, unreachable])

        await store.rescan(context: context)

        #expect(try gamePaths(in: context) == [kept])
        #expect(store.unreachableFolders == [unreachable])

        store.removeFolder(unreachable, context: context)
        #expect(store.unreachableFolders.isEmpty)
    }

    @Test func volumeNameOfAFolder() {
        #expect(LibraryPaths.volumeName(of: URL(filePath: "/Volumes/Retro Drive/ROMs/SNES")) == "Retro Drive")
        #expect(LibraryPaths.volumeName(of: URL(filePath: "/Volumes/Retro", directoryHint: .isDirectory)) == "Retro")
        #expect(LibraryPaths.volumeName(of: URL(filePath: "/Users/me/ROMs", directoryHint: .isDirectory)) == "ROMs")
    }
}

@Suite("Library scanning")
struct LibraryScanRevisionTests {
    @Test func scanWithOutdatedFoldersIsDiscardedAndRepeated() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folderA = root.appending(path: "A", directoryHint: .isDirectory)
        let folderB = root.appending(path: "B", directoryHint: .isDirectory)
        for folder in [folderA, folderB] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }

        let gate = ScanGate()
        let (container, context) = try makeContext()
        _ = container
        let store = makeStore(folders: [folderA]) { folders in
            await gate.pass()
            return LibraryScan(roms: folders.map { rom($0.appending(path: "Game.sfc").path(percentEncoded: false)) })
        }

        let firstScan = Task { await store.rescan(context: context) }
        await gate.waitUntilEntered()
        // While the scan of [A] is running: A goes away and B arrives.
        store.removeFolder(folderA, context: context)
        store.addFolder(folderB, context: context)
        await gate.open()
        await firstScan.value
        // addFolder's own rescan may still be queued; it must find nothing left to do.
        while store.isScanning { await Task.yield() }

        #expect(try gamePaths(in: context) == [folderB.appending(path: "Game.sfc").path(percentEncoded: false)])
        #expect(store.folders == [folderB])
    }
}

@Suite("Library scan safety")
struct LibraryScanSafetyTests {
    private func makeStore(folders: [URL]) -> LibraryStore {
        LibraryStore(metadata: MetadataService(), folders: folders, scanner: { LibraryScanner.scan(folders: $0) },
                     persistFolders: { _ in }, scrapesAutomatically: { false })
    }

    @Test func overlappingFoldersKeepTheGame() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let snes = root.appending(path: "SNES", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: snes, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: snes.appending(path: "Game.sfc"))

        let (container, context) = try makeContext()
        _ = container
        let store = makeStore(folders: [root, snes])
        await store.rescan(context: context)
        let game = try #require(try context.fetch(FetchDescriptor<Game>()).first)
        let id = game.id
        game.isFavorite = true
        game.playTime = 1234
        try context.save()

        await store.rescan(context: context)

        let games = try context.fetch(FetchDescriptor<Game>())
        #expect(games.count == 1)
        #expect(games.first?.id == id)
        #expect(games.first?.isFavorite == true)
        #expect(games.first?.playTime == 1234)
    }

    @Test func unreadableSubfolderKeepsItsGames() async throws {
        let root = try makeTemporaryDirectory()
        let sub = root.appending(path: "SNES", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sub.path(percentEncoded: false))
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: sub.appending(path: "Kept.sfc"))
        try Data([1, 2, 3]).write(to: root.appending(path: "Deleted.sfc"))

        let (container, context) = try makeContext()
        _ = container
        let store = makeStore(folders: [root])
        await store.rescan(context: context)
        #expect(try context.fetch(FetchDescriptor<Game>()).count == 2)

        try FileManager.default.removeItem(at: root.appending(path: "Deleted.sfc"))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: sub.path(percentEncoded: false))
        await store.rescan(context: context)

        // The deleted ROM sits in a readable folder and goes; the unreadable one stays.
        #expect(try gamePaths(in: context) == [sub.appending(path: "Kept.sfc").standardizedFileURL.path(percentEncoded: false)])
    }

    @Test func unreadableArchiveKeepsGameAndMedia() async throws {
        let root = try makeTemporaryDirectory()
        let archive = root.appending(path: "Game.zip")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: archive.path(percentEncoded: false))
            try? FileManager.default.removeItem(at: root)
        }
        // No system folder: the archive's contents decide the system.
        try makeZip(at: archive, containing: "Game.sfc", bytes: Data([1, 2, 3]))

        let (container, context) = try makeContext()
        _ = container
        let store = makeStore(folders: [root])
        await store.rescan(context: context)
        let game = try #require(try context.fetch(FetchDescriptor<Game>()).first)
        let id = game.id
        let media = game.mediaDirectory.appending(path: "box.png")
        defer { try? FileManager.default.removeItem(at: game.mediaDirectory) }
        try FileManager.default.createDirectory(at: game.mediaDirectory, withIntermediateDirectories: true)
        try Data([0]).write(to: media)

        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: archive.path(percentEncoded: false))
        #expect(LibraryScanner.scan(folders: [root]).unreadable == [archive.standardizedFileURL])
        await store.rescan(context: context)

        #expect(try context.fetch(FetchDescriptor<Game>()).map(\.id) == [id])
        #expect(FileManager.default.fileExists(atPath: media.path(percentEncoded: false)))
    }

    @Test func invalidArchiveIsNotAGame() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("not a zip".utf8).write(to: root.appending(path: "Notes.zip"))

        let scan = LibraryScanner.scan(folders: [root])

        #expect(scan.roms.isEmpty)
        #expect(scan.unreadable.isEmpty)
    }

    @Test func legacyGameDoesNotTrustUnversionedChecksum() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "Game.sfc")
        try Data([4, 5, 6]).write(to: file)

        // A game from a library that predates `fileModified`, whose file was
        // replaced by one of the same size since its checksum was computed.
        let (container, context) = try makeContext()
        _ = container
        let game = Game(path: file.standardizedFileURL.path(percentEncoded: false), systemID: "snes", title: "Game",
                        fileName: "Game.sfc", fileSize: 3, crc32: "55BC801D")
        context.insert(game)
        try context.save()
        let metadata = MetadataService(client: { ScreenScraperClient(devID: "", devPassword: "") })
        let store = LibraryStore(metadata: metadata, folders: [root], scanner: { LibraryScanner.scan(folders: $0) },
                                 persistFolders: { _ in }, scrapesAutomatically: { false })

        await store.rescan(context: context)
        #expect(game.crc32 == nil)

        metadata.enqueue([game], force: true, context: context)
        while metadata.isRunning { await Task.yield() }
        #expect(game.crc32 == Checksum.hex(Checksum.crc(of: Data([4, 5, 6]))))
    }

    @Test func sameSizeReplacementInvalidatesTheChecksum() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "Game.sfc")
        try Data([1, 2, 3]).write(to: file)

        let (container, context) = try makeContext()
        _ = container
        let store = makeStore(folders: [root])
        await store.rescan(context: context)
        let game = try #require(try context.fetch(FetchDescriptor<Game>()).first)
        game.crc32 = "55BC801D" // computed by an earlier scrape

        try Data([4, 5, 6]).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: file.path(percentEncoded: false))
        await store.rescan(context: context)

        #expect(game.crc32 == nil)
    }

    @Test func sameSizeZipReplacementTakesTheNewChecksum() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let snes = root.appending(path: "SNES", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: snes, withIntermediateDirectories: true)
        let archive = snes.appending(path: "Game.zip")
        try makeZip(at: archive, containing: "Game.sfc", bytes: Data([1, 2, 3]))

        let (container, context) = try makeContext()
        _ = container
        let store = makeStore(folders: [root])
        await store.rescan(context: context)
        let game = try #require(try context.fetch(FetchDescriptor<Game>()).first)
        #expect(game.crc32 == Checksum.hex(Checksum.crc(of: Data([1, 2, 3]))))

        try makeZip(at: archive, containing: "Game.sfc", bytes: Data([4, 5, 6]))
        await store.rescan(context: context)

        #expect(game.crc32 == Checksum.hex(Checksum.crc(of: Data([4, 5, 6]))))
    }
}
