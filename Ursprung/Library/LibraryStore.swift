// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation
import Observation
import SwiftData

/// Owns the list of library folders and keeps the SwiftData library in sync
/// with the files on disk.
@Observable
final class LibraryStore {
    typealias Scanner = @Sendable ([URL]) async -> LibraryScan
    /// Finds the games among `vanished` that the new files belong to; see `LibraryMatcher`.
    typealias Matcher = @Sendable (_ vanished: [GameFingerprint], _ candidates: [ScannedROM]) async -> [String: UUID]

    private(set) var folders: [URL]
    private(set) var isScanning = false
    private(set) var lastScanSummary: String?
    /// Library folders the last scan could not reach, e.g. on an unmounted volume.
    private(set) var unreachableFolders: [URL] = []

    let metadata: MetadataService

    @ObservationIgnored private let scanner: Scanner
    @ObservationIgnored private let matcher: Matcher
    @ObservationIgnored private let saves: URL
    @ObservationIgnored private let states: URL
    @ObservationIgnored private let persistFolders: ([URL]) -> Void
    @ObservationIgnored private let scrapesAutomatically: () -> Bool
    /// Bumped whenever the folder list changes, so a scan that started with an
    /// older list can tell that its result is stale.
    @ObservationIgnored private var folderRevision = 0

    init(metadata: MetadataService,
         folders: [URL] = Preferences.libraryFolders,
         scanner: @escaping Scanner = { await LibraryStore.scan($0) },
         matcher: @escaping Matcher = { await LibraryStore.match($0, $1) },
         persistFolders: @escaping ([URL]) -> Void = { Preferences.libraryFolders = $0 },
         scrapesAutomatically: @escaping () -> Bool = { Preferences.autoScrape },
         saves: URL = AppPaths.saves,
         states: URL = AppPaths.states) {
        self.metadata = metadata
        self.folders = folders
        self.scanner = scanner
        self.matcher = matcher
        self.saves = saves
        self.states = states
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

    /// Adds folders that are not in the library yet without scanning; the
    /// caller rescans once afterwards.
    func addFolders(_ urls: [URL]) {
        let new = urls.map(\.standardizedFileURL).filter { !folders.contains($0) }
        guard !new.isEmpty else { return }
        folders += new
        folderRevision += 1
        persistFolders(folders)
    }

    func removeFolder(_ url: URL, context: ModelContext) {
        let url = url.standardizedFileURL
        let leaving = games(leavingWith: url, context: context)
        folders.removeAll { $0.standardizedFileURL == url }
        unreachableFolders.removeAll { $0.standardizedFileURL == url }
        folderRevision += 1
        persistFolders(folders)
        for game in leaving {
            removeMedia(for: game)
            context.delete(game)
        }
        try? context.save()
    }

    /// The games that leave the library when `url` is removed. Games that
    /// another remaining folder still covers stay.
    func games(leavingWith url: URL, context: ModelContext) -> [Game] {
        let url = url.standardizedFileURL
        let remaining = folders.filter { $0.standardizedFileURL != url }.map { $0.path(percentEncoded: false) }
        let games = (try? context.fetch(FetchDescriptor<Game>())) ?? []
        return games.filter { game in
            LibraryPaths.isInside(game.path, folder: url.path(percentEncoded: false))
                && !remaining.contains { LibraryPaths.isInside(game.path, folder: $0) }
        }
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
            let (vanished, candidates) = relinkCandidates(scanned, reachable: reachable, folders: folders, context: context)
            let matches = await matcher(vanished, candidates)
            guard revision == folderRevision else { continue }
            unreachableFolders = folders.filter { !reachable.contains($0) }
            apply(scanned, matches: matches, reachable: reachable, folders: folders, context: context)
            return
        }
    }

    /// Whether a game that the scan did not report is certainly gone: its
    /// folder was read completely, or no library folder covers it and its
    /// file does not exist. Games on unmounted volumes and in folders that
    /// could not be read may still be there.
    private func isGone(_ game: Game, scan: LibraryScan, reachable: [String], folders: [String]) -> Bool {
        let isCovered = folders.contains { LibraryPaths.isInside(game.path, folder: $0) }
        guard isCovered else { return !FileManager.default.fileExists(atPath: game.path) }
        return reachable.contains { LibraryPaths.isInside(game.path, folder: $0) } && !scan.isUnreadable(game.path)
    }

    /// The games whose file is gone and the new files that may be them.
    private func relinkCandidates(_ scan: LibraryScan, reachable: [URL], folders: [URL],
                                  context: ModelContext) -> ([GameFingerprint], [ScannedROM]) {
        let existing = (try? context.fetch(FetchDescriptor<Game>())) ?? []
        let known = Set(existing.map(\.path))
        let scanned = Set(scan.roms.map { $0.url.standardizedFileURL.path(percentEncoded: false) })
        let reachablePaths = reachable.map { $0.path(percentEncoded: false) }
        let folderPaths = folders.map { $0.path(percentEncoded: false) }
        let vanished = existing
            .filter { !scanned.contains($0.path) && isGone($0, scan: scan, reachable: reachablePaths, folders: folderPaths) }
            .map { GameFingerprint(id: $0.id, systemID: $0.systemID, fileName: $0.fileName, fileSize: $0.fileSize,
                                   crc32: $0.crc32, modified: $0.fileModified) }
        let candidates = scan.roms.filter { !known.contains($0.url.standardizedFileURL.path(percentEncoded: false)) }
        return (vanished, candidates)
    }

    private func apply(_ scan: LibraryScan, matches: [String: UUID], reachable: [URL], folders: [URL], context: ModelContext) {
        let existing = (try? context.fetch(FetchDescriptor<Game>())) ?? []
        let byPath = Dictionary(existing.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let byID = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Overlapping folders can report a file twice. A path is applied once,
        // so the second report never creates a fresh game over the first.
        var seen = Set<String>()
        var added: [Game] = []
        var relinked = 0

        for rom in scan.roms {
            let path = rom.url.standardizedFileURL.path(percentEncoded: false)
            guard seen.insert(path).inserted else { continue }
            if let game = byPath[path] {
                if game.systemID != rom.systemID { game.systemID = rom.systemID }
                // A file replaced at the same path may keep its size; its
                // modification date still changes. A checksum without a known
                // date (older libraries, unreadable dates) may belong to an
                // earlier file and is not trusted. A zip's CRC is read on
                // every scan, so a new value always wins.
                let isReplaced = game.fileSize != rom.fileSize
                    || game.fileModified == nil || game.fileModified != rom.modified
                if isReplaced || (rom.crc32 != nil && rom.crc32 != game.crc32) { game.crc32 = rom.crc32 }
                if game.fileSize != rom.fileSize { game.fileSize = rom.fileSize }
                if game.fileModified != rom.modified { game.fileModified = rom.modified }
                if game.missingSince != nil { game.missingSince = nil }
            } else if let id = matches[path], let game = byID[id], !seen.contains(game.path), byPath[game.path] === game {
                // A renamed or moved file: the game keeps its identity. The
                // matcher compared checksums when the game had one.
                move(game, to: path, fileName: rom.fileName, fileSize: rom.fileSize, modified: rom.modified,
                     crc32: rom.crc32 ?? game.crc32, library: existing)
                relinked += 1
            } else {
                let game = Game(path: path, systemID: rom.systemID, title: rom.title, fileName: rom.fileName,
                                fileSize: rom.fileSize, crc32: rom.crc32)
                game.fileModified = rom.modified
                context.insert(game)
                added.append(game)
            }
        }

        // Games whose file is gone stay in the library, marked as missing, so
        // favourites, play time and saves survive until the file is located
        // or the user removes the game. Games on unmounted volumes and in sub
        // folders the scan could not read are left as they are.
        let reachablePaths = reachable.map { $0.path(percentEncoded: false) }
        let folderPaths = folders.map { $0.path(percentEncoded: false) }
        for game in existing where !seen.contains(game.path) {
            if isGone(game, scan: scan, reachable: reachablePaths, folders: folderPaths) {
                if game.missingSince == nil { game.missingSince = .now }
            } else if game.missingSince != nil, FileManager.default.fileExists(atPath: game.path) {
                game.missingSince = nil
            }
        }
        try? context.save()

        let missing = existing.filter(\.isMissing).count
        var summary = String(localized: "\(seen.count) games found, \(added.count) new.")
        if relinked > 0 {
            summary += " " + String(localized: "\(relinked) renamed or moved games were recognized.")
        }
        if missing > 0 {
            summary += " " + String(localized: "\(missing) games are missing.")
        }
        if !scan.unreadable.isEmpty {
            summary += " " + String(localized: "Some files or folders couldn't be read; their games were kept.")
        }
        lastScanSummary = summary
        if scrapesAutomatically() {
            // New games plus any whose scraping was interrupted earlier.
            let pending = ((try? context.fetch(FetchDescriptor<Game>())) ?? [])
                .filter { $0.scrapeState == .pending && !$0.isMissing }
            metadata.enqueue(pending, context: context)
        }
    }

    /// Hides the unreachable-folder warning until the next scan finds it again.
    func dismissUnreachableFolders() {
        unreachableFolders = []
    }

    @concurrent
    private static func scan(_ folders: [URL]) async -> LibraryScan {
        LibraryScanner.scan(folders: folders)
    }

    @concurrent
    private static func match(_ vanished: [GameFingerprint], _ candidates: [ScannedROM]) async -> [String: UUID] {
        LibraryMatcher.match(vanished: vanished, candidates: candidates) { url in
            (try? Checksum.crc(of: url)).map(Checksum.hex)
        }
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

    // MARK: Missing files

    enum RelinkError: LocalizedError {
        case wrongSystem(systemName: String)
        case unreadable(Error)

        var errorDescription: String? {
            switch self {
            case .wrongSystem(let name): String(localized: "This file is not a \(name) game.")
            case .unreadable(let error): error.localizedDescription
            }
        }
    }

    /// The library folder that holds `game` if that folder is not there right
    /// now, e.g. on a drive that is not connected.
    func offlineFolder(containing game: Game) -> URL? {
        folders.first {
            let path = $0.path(percentEncoded: false)
            return LibraryPaths.isInside(game.path, folder: path) && !FileManager.default.fileExists(atPath: path)
        }
    }

    /// Lets the user choose the file of a missing game.
    func presentLocatePanel(for game: Game, context: ModelContext) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Locate")
        panel.message = String(localized: "Choose the file of “\(game.title)”. Favorites, play time and saves stay with the game.")
        let folder = game.fileURL.deletingLastPathComponent()
        panel.directoryURL = FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)) ? folder : folders.first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try relink(game, to: url, context: context)
        } catch {
            let alert = NSAlert()
            alert.messageText = String(localized: "The file couldn't be used")
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    // MARK: Battery saves

    /// Lets the user choose a battery save from another emulator or an
    /// earlier installation for `game`. The game must not be running, or its
    /// next save would overwrite the import.
    func presentBatterySaveImport(for game: Game) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Import")
        panel.message = String(localized: "Choose a battery save (.srm or .sav) for “\(game.title)”. The current save is kept as a copy.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            // Save RAM is at most a few megabytes; anything larger is a ROM or disc image.
            guard size > 0, size <= 16 << 20 else { throw CocoaError(.fileReadCorruptFile) }
            let destination = BatterySave.url(in: saves, systemID: game.systemID, gameID: game.id, baseName: game.saveBaseName)
            BatterySave.adoptRenamed(at: destination)
            try BatterySave.importSave(url, to: destination, label: String(localized: "before import \(FileMerge.stamp())"))
        } catch {
            let alert = NSAlert()
            alert.messageText = String(localized: "The battery save couldn't be imported")
            alert.informativeText = (error as? CocoaError)?.code == .fileReadCorruptFile
                ? String(localized: "The file is not a battery save.")
                : error.localizedDescription
            alert.runModal()
        }
    }

    /// Points `game` at the file `url`. If the library already lists that
    /// file as another game (it was found after the rename), the two become
    /// one: favourites, play time and saves of both are kept.
    func relink(_ game: Game, to url: URL, context: ModelContext) throws {
        let url = url.standardizedFileURL
        let path = url.path(percentEncoded: false)
        guard path != game.path else {
            game.missingSince = nil
            try? context.save()
            return
        }
        let ext = url.pathExtension.lowercased()
        let system = game.system
        if !SystemCatalog.ambiguousExtensions.contains(ext),
           !SystemCatalog.candidates(forExtension: ext).contains(where: { $0.id == game.systemID }) {
            throw RelinkError.wrongSystem(systemName: system?.name ?? game.systemID)
        }
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
        } catch {
            throw RelinkError.unreadable(error)
        }
        var crc: String?
        if ext == "zip", let system, !system.archivesAreNative, let entry = LibraryScanner.primaryEntry(inZip: url, system: system) {
            crc = Checksum.hex(entry.crc32)
        }

        let library = (try? context.fetch(FetchDescriptor<Game>())) ?? []
        if let duplicate = library.first(where: { $0.path == path && $0.id != game.id }) {
            merge(duplicate, into: game, baseName: (url.lastPathComponent as NSString).deletingPathExtension)
            context.delete(duplicate)
            try? context.save()
        }
        move(game, to: path, fileName: url.lastPathComponent, fileSize: Int64(values.fileSize ?? 0),
             modified: values.contentModificationDate, crc32: crc, library: library)
        try? context.save()
    }

    /// Gives `game` a new file. Its saves follow the new file name, and a
    /// title that was only derived from the old file name is derived anew.
    private func move(_ game: Game, to path: String, fileName: String, fileSize: Int64, modified: Date?, crc32: String?,
                      library: [Game]) {
        let oldBaseName = game.saveBaseName
        let titleWasDerived = game.scrapeState != .matched && game.title == TitleFormatter.title(fromFileName: game.fileName)
        game.path = path
        game.fileName = fileName
        game.fileSize = fileSize
        game.fileModified = modified
        game.crc32 = crc32
        game.missingSince = nil
        if titleWasDerived { game.title = TitleFormatter.title(fromFileName: fileName) }

        let newBaseName = game.saveBaseName
        guard newBaseName != oldBaseName else { return }
        BatterySave.adoptRenamed(at: BatterySave.url(in: saves, systemID: game.systemID, gameID: game.id, baseName: newBaseName))
        // Files that cores name after the game are shared by every game with
        // that name; they only move when no other game uses the old name.
        let shared = library.contains { $0.id != game.id && $0.systemID == game.systemID && $0.saveBaseName == oldBaseName }
        if !shared {
            GameSaveFiles.renameCoreSaves(in: saves.appending(path: game.systemID, directoryHint: .isDirectory),
                                          from: oldBaseName, to: newBaseName)
        }
    }

    /// Folds `duplicate` into `game` before it is deleted.
    private func merge(_ duplicate: Game, into game: Game, baseName: String) {
        game.isFavorite = game.isFavorite || duplicate.isFavorite
        game.playTime += duplicate.playTime
        game.playCount += duplicate.playCount
        game.lastPlayed = [game.lastPlayed, duplicate.lastPlayed].compactMap { $0 }.max()
        game.dateAdded = min(game.dateAdded, duplicate.dateAdded)
        if game.coreID == nil { game.coreID = duplicate.coreID }
        if game.scrapeState != .matched, duplicate.scrapeState == .matched {
            game.adoptMetadata(of: duplicate)
        }
        let stamp = FileMerge.stamp()
        _ = try? GameSaveFiles.merge(from: duplicate.id, into: game.id, systemID: game.systemID, baseName: baseName,
                                     saves: saves, states: states,
                                     labels: FileMerge.Labels(existing: String(localized: "before merging \(stamp)"),
                                                              incoming: String(localized: "merged \(stamp)")))
        removeMedia(for: duplicate)
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
