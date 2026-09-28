// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation
import Observation
import SwiftData

/// Owns the list of library folders and keeps the SwiftData library in sync
/// with the files on disk.
@Observable
final class LibraryStore {
    private(set) var folders: [URL] = Preferences.libraryFolders
    private(set) var isScanning = false
    private(set) var lastScanSummary: String?

    let metadata: MetadataService

    init(metadata: MetadataService) {
        self.metadata = metadata
    }

    // MARK: Folders

    func addFolder(_ url: URL, context: ModelContext) {
        let url = url.standardizedFileURL
        guard !folders.contains(url) else { return }
        folders.append(url)
        Preferences.libraryFolders = folders
        Task { await rescan(context: context) }
    }

    func removeFolder(_ url: URL, context: ModelContext) {
        folders.removeAll { $0 == url }
        Preferences.libraryFolders = folders
        let prefix = url.path(percentEncoded: false)
        let games = (try? context.fetch(FetchDescriptor<Game>())) ?? []
        for game in games where game.path.hasPrefix(prefix) {
            removeMedia(for: game)
            context.delete(game)
        }
        try? context.save()
    }

    func presentAddFolderPanel(context: ModelContext) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Add to Library")
        panel.message = String(localized: "Choose folders that contain your games. Sub folders named after a system (e.g. “SNES” or “PSX”) help Ursprung identify disc images.")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { addFolder(url, context: context) }
    }

    // MARK: Scanning

    func rescan(context: ModelContext) async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }

        let folders = self.folders
        let reachable = folders.filter { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
        let scanned = await Self.scan(reachable)

        let existing = (try? context.fetch(FetchDescriptor<Game>())) ?? []
        var byPath = Dictionary(existing.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        var added: [Game] = []

        for rom in scanned {
            let path = rom.url.path(percentEncoded: false)
            if let game = byPath.removeValue(forKey: path) {
                if game.systemID != rom.systemID { game.systemID = rom.systemID }
                if game.fileSize != rom.fileSize {
                    game.fileSize = rom.fileSize
                    game.crc32 = rom.crc32
                }
            } else {
                let game = Game(path: path, systemID: rom.systemID, title: rom.title, fileName: rom.fileName,
                                fileSize: rom.fileSize, crc32: rom.crc32)
                context.insert(game)
                added.append(game)
            }
        }

        // Games that vanished from reachable folders are removed. Games on
        // unmounted volumes are kept.
        let reachablePrefixes = reachable.map { $0.path(percentEncoded: false) }
        var removed = 0
        for game in byPath.values where reachablePrefixes.contains(where: { game.path.hasPrefix($0) })
            || !folders.contains(where: { game.path.hasPrefix($0.path(percentEncoded: false)) }) {
            removeMedia(for: game)
            context.delete(game)
            removed += 1
        }
        try? context.save()

        lastScanSummary = String(localized: "\(scanned.count) games found, \(added.count) new, \(removed) removed.")
        if Preferences.autoScrape {
            // New games plus any whose scraping was interrupted earlier.
            let pending = ((try? context.fetch(FetchDescriptor<Game>())) ?? []).filter { $0.scrapeState == .pending }
            metadata.enqueue(pending, context: context)
        }
    }

    @concurrent
    private static func scan(_ folders: [URL]) async -> [ScannedROM] {
        LibraryScanner.scan(folders: folders)
    }

    // MARK: Games

    func remove(_ game: Game, context: ModelContext) {
        removeMedia(for: game)
        context.delete(game)
        try? context.save()
    }

    private func removeMedia(for game: Game) {
        try? FileManager.default.removeItem(at: game.mediaDirectory)
    }
}
