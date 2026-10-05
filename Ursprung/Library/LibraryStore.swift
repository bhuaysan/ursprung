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
    /// Files the last scan found but could not identify; the scan report
    /// lets the user add them with a system of their choice.
    private(set) var unrecognizedFiles: [URL] = []
    /// Files and folders the last scan could not read.
    private(set) var unreadableFiles: [URL] = []

    let metadata: MetadataService

    @ObservationIgnored private let scanner: Scanner
    @ObservationIgnored private let matcher: Matcher
    @ObservationIgnored private let saves: URL
    @ObservationIgnored private let states: URL
    @ObservationIgnored private let extras: URL
    @ObservationIgnored private let persistFolders: ([URL]) -> Void
    @ObservationIgnored private let scrapesAutomatically: () -> Bool
    /// Bumped whenever the folder list changes, so a scan that started with an
    /// older list can tell that its result is stale.
    @ObservationIgnored private var folderRevision = 0
    @ObservationIgnored private var watcher: LibraryWatcher?
    @ObservationIgnored private var watchContext: ModelContext?
    @ObservationIgnored private let scheduler = RescanScheduler()

    init(metadata: MetadataService,
         folders: [URL] = Preferences.libraryFolders,
         scanner: @escaping Scanner = { await LibraryStore.scan($0) },
         matcher: @escaping Matcher = { await LibraryStore.match($0, $1) },
         persistFolders: @escaping ([URL]) -> Void = { Preferences.libraryFolders = $0 },
         scrapesAutomatically: @escaping () -> Bool = { Preferences.autoScrape },
         saves: URL = AppPaths.saves,
         states: URL = AppPaths.states,
         extras: URL = AppPaths.extras) {
        self.metadata = metadata
        self.folders = folders
        self.scanner = scanner
        self.matcher = matcher
        self.saves = saves
        self.states = states
        self.extras = extras
        self.persistFolders = persistFolders
        self.scrapesAutomatically = scrapesAutomatically
    }

    // MARK: Watching

    /// Rescans by itself whenever files in the library folders change (or a
    /// drive with a library folder comes or goes), once the changes settle.
    func startWatching(context: ModelContext) {
        watchContext = context
        if watcher == nil {
            watcher = LibraryWatcher { [weak self] in self?.foldersChanged() }
        }
        watcher?.watch(folders)
    }

    private func foldersChanged() {
        guard let context = watchContext else { return }
        scheduler.request { [weak self] in
            guard let self else { return true }
            guard !isScanning else { return false }
            await rescan(context: context)
            return true
        }
    }

    private func folderListChanged() {
        folderRevision += 1
        persistFolders(folders)
        if watchContext != nil { watcher?.watch(folders) }
    }

    // MARK: Folders

    func addFolder(_ url: URL, context: ModelContext) {
        let url = url.standardizedFileURL
        guard !folders.contains(url) else { return }
        folders.append(url)
        folderListChanged()
        Task { await rescan(context: context) }
    }

    /// Adds folders that are not in the library yet without scanning; the
    /// caller rescans once afterwards.
    func addFolders(_ urls: [URL]) {
        let new = urls.map(\.standardizedFileURL).filter { !folders.contains($0) }
        guard !new.isEmpty else { return }
        folders += new
        folderListChanged()
    }

    func removeFolder(_ url: URL, context: ModelContext) {
        let url = url.standardizedFileURL
        let leaving = games(leavingWith: url, context: context)
        folders.removeAll { $0.standardizedFileURL == url }
        unreachableFolders.removeAll { $0.standardizedFileURL == url }
        folderListChanged()
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
        // Unrecognized files may be games with a system the user chose.
        let scanned = Set((scan.roms.map(\.url) + scan.unrecognized).map { $0.standardizedFileURL.path(percentEncoded: false) })
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
                // A system the user chose wins over detection.
                changeSystem(of: game, to: game.systemOverride ?? rom.systemID)
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
                if game.missingTracks != rom.missingTracks { game.missingTracks = rom.missingTracks }
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
                game.missingTracks = rom.missingTracks
                context.insert(game)
                added.append(game)
            }
        }

        // Files the scanner could not identify may be games of the library:
        // added with a system of their choice, or recognized by a folder
        // name that has changed since. Those are present, not missing, and
        // keep their system.
        var unrecognized: [URL] = []
        for url in scan.unrecognized {
            let path = url.standardizedFileURL.path(percentEncoded: false)
            if let game = byPath[path] {
                seen.insert(path)
                if game.missingSince != nil { game.missingSince = nil }
            } else {
                unrecognized.append(url)
            }
        }
        unrecognizedFiles = unrecognized
        unreadableFiles = scan.unreadable

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
            // New games, games whose scraping was interrupted, and missing artwork.
            metadata.enqueue((try? context.fetch(FetchDescriptor<Game>())) ?? [], automatic: true, context: context)
        }
    }

    // MARK: Importing

    /// What dropping or opening files added.
    struct ImportResult {
        /// The library's games for the files, new or already known.
        var games: [Game] = []
        /// Files whose system is unknown; the scan report offers them.
        var unrecognized = 0
    }

    /// Adds dropped or opened files and folders. Folders become library
    /// folders. Files inside a library folder are found by a scan; files
    /// elsewhere are added one by one and stay where they are.
    func importItems(_ urls: [URL], context: ModelContext) async -> ImportResult {
        var folders: [URL] = []
        var files: [URL] = []
        for url in urls.map(\.standardizedFileURL) {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let isPackage = (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) ?? false
            if isDirectory, !isPackage { folders.append(url) } else { files.append(url) }
        }
        addFolders(folders)

        let folderPaths = self.folders.map { $0.path(percentEncoded: false) }
        let known = Set(((try? context.fetch(FetchDescriptor<Game>())) ?? []).map(\.path))
        let isCovered = { (url: URL) in folderPaths.contains { LibraryPaths.isInside(url.path(percentEncoded: false), folder: $0) } }
        if !folders.isEmpty || files.contains(where: { isCovered($0) && !known.contains($0.path(percentEncoded: false)) }) {
            await rescan(context: context)
        }

        let outside = files.filter { !isCovered($0) && !known.contains($0.path(percentEncoded: false)) }
        var result = ImportResult()
        if !outside.isEmpty {
            let scan = await Self.scanFiles(outside)
            for rom in scan.roms {
                let game = Game(path: rom.url.path(percentEncoded: false), systemID: rom.systemID, title: rom.title,
                                fileName: rom.fileName, fileSize: rom.fileSize, crc32: rom.crc32)
                game.fileModified = rom.modified
                game.missingTracks = rom.missingTracks
                context.insert(game)
            }
            let newUnrecognized = scan.unrecognized.filter { !unrecognizedFiles.contains($0) }
            unrecognizedFiles += newUnrecognized
            result.unrecognized = newUnrecognized.count
            try? context.save()
            let added = (try? context.fetch(FetchDescriptor<Game>())) ?? []
            if scrapesAutomatically() {
                let paths = Set(scan.roms.map { $0.url.path(percentEncoded: false) })
                metadata.enqueue(added.filter { paths.contains($0.path) }, context: context)
            }
        }

        let library = (try? context.fetch(FetchDescriptor<Game>())) ?? []
        let byPath = Dictionary(library.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        for file in files {
            guard let game = byPath[file.path(percentEncoded: false)] else { continue }
            // Adding a hidden game asks for it back.
            if game.isHidden { game.isHidden = false }
            result.games.append(game)
        }
        try? context.save()
        return result
    }

    @concurrent
    private static func scanFiles(_ files: [URL]) async -> LibraryScan {
        LibraryScanner.scan(files: files)
    }

    /// Adds a file the scan could not identify as a game of `systemID`. The
    /// choice is kept: later scans leave the system alone.
    func addUnrecognized(_ url: URL, systemID: String, context: ModelContext) {
        let url = url.standardizedFileURL
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let game = Game(path: url.path(percentEncoded: false), systemID: systemID,
                        title: TitleFormatter.title(fromFileName: url.lastPathComponent), fileName: url.lastPathComponent,
                        fileSize: Int64(values?.fileSize ?? 0), crc32: nil)
        game.fileModified = values?.contentModificationDate
        game.systemOverride = systemID
        context.insert(game)
        try? context.save()
        unrecognizedFiles.removeAll { $0.standardizedFileURL == url }
        if scrapesAutomatically() { metadata.enqueue([game], context: context) }
    }

    /// Gives `game` another system. Its battery saves are kept per system,
    /// so they move along; where the new system already has files of the
    /// game, nothing is lost (see `FileMerge`).
    func changeSystem(of game: Game, to systemID: String) {
        guard game.systemID != systemID else { return }
        let stamp = FileMerge.stamp()
        _ = try? GameSaveFiles.changeSystem(of: game.id, from: game.systemID, to: systemID, saves: saves,
                                            labels: FileMerge.Labels(existing: String(localized: "before merging \(stamp)"),
                                                                     incoming: String(localized: "merged \(stamp)")))
        game.systemID = systemID
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
        if game.systemOverride == nil, !SystemCatalog.ambiguousExtensions.contains(ext),
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

    // MARK: Disc playlists

    /// Makes one game of loose discs once a playlist for them exists at
    /// `playlist`. The disc played most keeps its identity and moves to the
    /// playlist; the others fold into it with their play time and saves.
    /// `keeping` is the playlist's own game when the playlist was edited.
    @discardableResult
    func adoptPlaylist(_ playlist: URL, discs: [Game], keeping: Game? = nil, context: ModelContext) throws -> Game? {
        let mostPlayed = discs.max { ($0.playTime, $0.lastPlayed ?? .distantPast) < ($1.playTime, $1.lastPlayed ?? .distantPast) }
        guard let main = keeping ?? mostPlayed else { return nil }
        let baseName = (playlist.lastPathComponent as NSString).deletingPathExtension
        let derivedTitle = main.title == TitleFormatter.title(fromFileName: main.fileName)
        for disc in discs where disc !== main {
            merge(disc, into: main, baseName: main.saveBaseName)
            context.delete(disc)
        }
        try relink(main, to: playlist, context: context)
        main.missingTracks = LibraryScanner.missingTracks(of: playlist)
        // A disc's title (“Game”) stays; only one derived from its file name follows the playlist.
        if derivedTitle, main.scrapeState != .matched, main.lockedFields.isEmpty {
            main.title = TitleFormatter.title(fromFileName: baseName)
        }
        try? context.save()
        return main
    }

    /// Folds `duplicate` into `game` before it is deleted.
    private func merge(_ duplicate: Game, into game: Game, baseName: String) {
        game.isFavorite = game.isFavorite || duplicate.isFavorite
        game.playTime += duplicate.playTime
        game.playCount += duplicate.playCount
        game.lastPlayed = [game.lastPlayed, duplicate.lastPlayed].compactMap { $0 }.max()
        game.dateAdded = min(game.dateAdded, duplicate.dateAdded)
        if game.coreID == nil { game.coreID = duplicate.coreID }
        if game.systemOverride == nil { game.systemOverride = duplicate.systemOverride }
        if game.coreOptionsData == nil { game.coreOptionsData = duplicate.coreOptionsData }
        if game.inputProfileData == nil { game.inputProfileData = duplicate.inputProfileData }
        game.collections += duplicate.collections
        if game.playStatus == nil { game.playStatus = duplicate.playStatus }
        if game.scrapeState != .matched, game.lockedFields.isEmpty, duplicate.scrapeState == .matched || !duplicate.lockedFields.isEmpty {
            game.adoptMetadata(of: duplicate)
        }
        let stamp = FileMerge.stamp()
        let labels = FileMerge.Labels(existing: String(localized: "before merging \(stamp)"),
                                      incoming: String(localized: "merged \(stamp)"))
        // The entry found meanwhile may have been given another system.
        _ = try? GameSaveFiles.changeSystem(of: duplicate.id, from: duplicate.systemID, to: game.systemID, saves: saves,
                                            labels: labels)
        _ = try? GameSaveFiles.merge(from: duplicate.id, into: game.id, systemID: game.systemID, baseName: baseName,
                                     saves: saves, states: states, labels: labels)
        // Screenshots, manual, patches and cheats come along too.
        let duplicateExtras = GameExtras.directory(in: extras, gameID: duplicate.id)
        if FileManager.default.fileExists(atPath: duplicateExtras.path(percentEncoded: false)),
           (try? FileMerge.mergeDirectory(duplicateExtras, into: GameExtras.directory(in: extras, gameID: game.id),
                                          moving: true, labels: labels)) != nil {
            try? FileManager.default.removeItem(at: duplicateExtras)
        }
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
