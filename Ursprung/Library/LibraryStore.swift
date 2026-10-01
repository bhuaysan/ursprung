// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation
import Observation
import SwiftData

/// Owns the list of library folders and keeps the SwiftData library in sync
/// with the files on disk.
@Observable
final class LibraryStore {
    typealias Scanner = @Sendable ([URL]) async -> [ScannedROM]

    private(set) var folders: [URL]
    private(set) var isScanning = false
    private(set) var lastScanSummary: String?
    /// Library folders the last scan could not reach, e.g. on an unmounted volume.
    private(set) var unreachableFolders: [URL] = []

    let metadata: MetadataService

    @ObservationIgnored private let scanner: Scanner
    @ObservationIgnored private let persistFolders: ([URL]) -> Void
    @ObservationIgnored private let scrapesAutomatically: () -> Bool
    /// Bumped whenever the folder list changes, so a scan that started with an
    /// older list can tell that its result is stale.
    @ObservationIgnored private var folderRevision = 0

    init(metadata: MetadataService,
         folders: [URL] = Preferences.libraryFolders,
         scanner: @escaping Scanner = { await LibraryStore.scan($0) },
         persistFolders: @escaping ([URL]) -> Void = { Preferences.libraryFolders = $0 },
         scrapesAutomatically: @escaping () -> Bool = { Preferences.autoScrape }) {
        self.metadata = metadata
        self.folders = folders
        self.scanner = scanner
        self.persistFolders = persistFolders
        self.scrapesAutomatically = scrapesAutomatically
    }

    // MARK: Folders

    func addFolder(_ url: URL, context: ModelContext) {
        let url = url.standardizedFileURL
        guard !folders.contains(url) else { return }
        folders.append(url)
        folderRevision += 1
        persistFolders(folders)
        Task { await rescan(context: context) }
    }

    func removeFolder(_ url: URL, context: ModelContext) {
        let url = url.standardizedFileURL
        folders.removeAll { $0.standardizedFileURL == url }
        unreachableFolders.removeAll { $0.standardizedFileURL == url }
        folderRevision += 1
        persistFolders(folders)
        // Games that another remaining folder still covers stay in the library.
        let remaining = folders.map { $0.path(percentEncoded: false) }
        let games = (try? context.fetch(FetchDescriptor<Game>())) ?? []
        for game in games where LibraryPaths.isInside(game.path, folder: url.path(percentEncoded: false))
            && !remaining.contains(where: { LibraryPaths.isInside(game.path, folder: $0) }) {
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

        // Folders may be added or removed while the (slow) scan runs. Such a
        // scan describes an outdated library, so its result is dropped and the
        // scan repeats with the current folders.
        while true {
            let revision = folderRevision
            let folders = self.folders
            let reachable = folders.filter { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
            let scanned = await scanner(reachable)
            guard revision == folderRevision else { continue }
            unreachableFolders = folders.filter { !reachable.contains($0) }
            apply(scanned, reachable: reachable, folders: folders, context: context)
            return
        }
    }

    private func apply(_ scanned: [ScannedROM], reachable: [URL], folders: [URL], context: ModelContext) {
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

        // Games that vanished from reachable folders are removed, as are games
        // no folder covers any more. Games on unmounted volumes are kept.
        let reachablePaths = reachable.map { $0.path(percentEncoded: false) }
        let folderPaths = folders.map { $0.path(percentEncoded: false) }
        var removed = 0
        for game in byPath.values {
            let isCovered = folderPaths.contains { LibraryPaths.isInside(game.path, folder: $0) }
            let isReachable = reachablePaths.contains { LibraryPaths.isInside(game.path, folder: $0) }
            guard isReachable || !isCovered else { continue }
            removeMedia(for: game)
            context.delete(game)
            removed += 1
        }
        try? context.save()

        lastScanSummary = String(localized: "\(scanned.count) games found, \(added.count) new, \(removed) removed.")
        if scrapesAutomatically() {
            // New games plus any whose scraping was interrupted earlier.
            let pending = ((try? context.fetch(FetchDescriptor<Game>())) ?? []).filter { $0.scrapeState == .pending }
            metadata.enqueue(pending, context: context)
        }
    }

    /// Hides the unreachable-folder warning until the next scan finds it again.
    func dismissUnreachableFolders() {
        unreachableFolders = []
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

/// Path comparisons for library folders.
nonisolated enum LibraryPaths {
    /// Whether `path` lies within `folder`, compared by whole path components:
    /// `/ROMs/SNES-hacks/Game.sfc` is not inside `/ROMs/SNES`.
    static func isInside(_ path: String, folder: String) -> Bool {
        let folder = folder.hasSuffix("/") ? folder : folder + "/"
        return path.hasPrefix(folder)
    }

    /// The name to show for an unreachable folder: its volume for a folder on
    /// `/Volumes/<name>`, otherwise the folder itself.
    static func volumeName(of folder: URL) -> String {
        let components = folder.standardizedFileURL.pathComponents
        if components.count > 2, components[1] == "Volumes" { return components[2] }
        return folder.lastPathComponent
    }
}
