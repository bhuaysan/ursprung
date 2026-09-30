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

private func makeStore(folders: [URL], scanner: @escaping LibraryStore.Scanner = { _ in [] }) -> LibraryStore {
    LibraryStore(metadata: MetadataService(), folders: folders, scanner: scanner,
                 persistFolders: { _ in }, scrapesAutomatically: { false })
}

private func gamePaths(in context: ModelContext) throws -> [String] {
    try context.fetch(FetchDescriptor<Game>()).map(\.path).sorted()
}

@Suite("Library folders")
struct LibraryFolderTests {
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
            return folders.map { rom($0.appending(path: "Game.sfc").path(percentEncoded: false)) }
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
