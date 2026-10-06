// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Observation

/// The RetroArch slang shaders Ursprung can use: the libretro pack, downloaded
/// on demand like cores, and the user's own presets in `Shaders/User/`.
///
/// The pack is replaced as a whole on update and never edited; Ursprung
/// doesn't redistribute it, so every shader keeps the licence it comes with.
@Observable
final class ShaderLibrary {
    enum LibraryError: LocalizedError {
        case downloadFailed(String)
        case invalidArchive

        var errorDescription: String? {
            switch self {
            case .downloadFailed(let reason): String(localized: "The shaders could not be downloaded: \(reason)")
            case .invalidArchive: String(localized: "The downloaded shader archive contains no presets.")
            }
        }
    }

    static let packURL = URL(string: "https://buildbot.libretro.com/assets/frontend/shaders_slang.zip")!

    /// Presets of the pack and the user's folder, sorted for the browser.
    private(set) var presets: [ShaderPresetInfo] = []
    /// Presets are being listed or read.
    private(set) var isIndexing = false
    private(set) var hasIndex = false
    /// Disk space the pack takes; nil until indexed or when not installed.
    private(set) var packSize: Int64?
    /// When the installed pack was downloaded; nil when it isn't installed.
    private(set) var packInstalled: Date?
    /// Download progress (0…1) while the pack downloads.
    private(set) var downloadProgress: Double?
    /// The downloaded pack is being unpacked.
    private(set) var isUnpacking = false
    private(set) var updateAvailable = false
    private(set) var isCheckingForUpdates = false
    private(set) var lastUpdateCheck: Date?
    /// Favourite presets, in the order they were marked.
    private(set) var favorites: [ShaderPresetRef] = []

    var isPackInstalled: Bool { packInstalled != nil }
    var isInstallingPack: Bool { installation != nil }

    @ObservationIgnored let libraryDirectory: URL
    @ObservationIgnored let userDirectory: URL
    @ObservationIgnored private let rootDirectory: URL
    @ObservationIgnored private let downloader: HTTPDownload.Downloader
    @ObservationIgnored private let lastModified: HTTPDownload.LastModifiedFetcher
    @ObservationIgnored private let defaults: UserDefaults
    private var installation: Task<Void, Error>?
    @ObservationIgnored private var indexing: Task<Void, Never>?
    @ObservationIgnored private var indexesAgain = false

    init(root: URL = AppPaths.shaders,
         downloader: @escaping HTTPDownload.Downloader = ShaderLibrary.downloadFile,
         lastModified: @escaping HTTPDownload.LastModifiedFetcher = { try await HTTPDownload.lastModified(of: $0) },
         defaults: UserDefaults = .standard) {
        rootDirectory = root
        libraryDirectory = root.appending(path: "slang-shaders", directoryHint: .isDirectory)
        userDirectory = root.appending(path: "User", directoryHint: .isDirectory)
        self.downloader = downloader
        self.lastModified = lastModified
        self.defaults = defaults
        packInstalled = Self.installDate(of: libraryDirectory, root: root)
        favorites = (defaults.stringArray(forKey: PrefKey.shaderFavorites) ?? []).compactMap { raw in
            if case .preset(let preset)? = ShaderSelection(rawValue: raw) { preset } else { nil }
        }
    }

    func url(of preset: ShaderPresetRef) -> URL {
        preset.url(library: libraryDirectory, user: userDirectory)
    }

    func exists(_ preset: ShaderPresetRef) -> Bool {
        FileManager.default.fileExists(atPath: url(of: preset).path(percentEncoded: false))
    }

    // MARK: Index

    /// Indexes the shader folders once; later calls do nothing.
    func loadIfNeeded() {
        if !hasIndex && indexing == nil { refresh() }
    }

    /// Lists the presets again and reads the new or changed ones. Waits for
    /// a running refresh and then runs once more.
    func refresh() {
        guard indexing == nil else {
            indexesAgain = true
            return
        }
        isIndexing = true
        indexing = Task {
            repeat {
                indexesAgain = false
                await index()
            } while indexesAgain
            indexing = nil
            isIndexing = false
        }
    }

    /// Waits for the running refresh, if any.
    func waitForIndex() async {
        await indexing?.value
    }

    private func index() async {
        let (library, user, cacheURL) = (libraryDirectory, userDirectory, cacheURL)
        let (scan, cache) = await Self.scan(library: library, user: user, cacheURL: cacheURL)
        // Unchanged lists stay as they are, so open lists don't reload.
        if presets != scan.presets { presets = scan.presets }
        if packSize != scan.packSize { packSize = scan.packSize }
        if !hasIndex { hasIndex = true }
        guard !scan.pending.isEmpty else { return }
        let summaries = await Self.summarize(scan, cache: cache, folders: [library, user], cacheURL: cacheURL)
        presets = presets.map { info in
            guard let entry = summaries[info.ref] else { return info }
            var info = info
            info.passes = entry.passes
            info.parameters = entry.parameters
            info.problem = entry.problem
            return info
        }
    }

    private var cacheURL: URL { rootDirectory.appending(path: "index.json") }

    @concurrent
    private static func scan(library: URL, user: URL, cacheURL: URL) async -> (ShaderIndex.Scan, ShaderIndex.Cache) {
        let cache = ShaderIndex.loadCache(from: cacheURL)
        return (ShaderIndex.scan(library: library, user: user, cache: cache), cache)
    }

    @concurrent
    private static func summarize(_ scan: ShaderIndex.Scan, cache: ShaderIndex.Cache, folders: [URL],
                                  cacheURL: URL) async -> [ShaderPresetRef: ShaderIndex.CacheEntry] {
        let summaries = ShaderIndex.summarize(scan.pending, folders: folders)
        ShaderIndex.save(ShaderIndex.updated(cache, found: scan.found, summaries: summaries), to: cacheURL)
        return summaries
    }

    // MARK: Favourites

    func isFavorite(_ preset: ShaderPresetRef) -> Bool {
        favorites.contains(preset)
    }

    func toggleFavorite(_ preset: ShaderPresetRef) {
        if let index = favorites.firstIndex(of: preset) {
            favorites.remove(at: index)
        } else {
            favorites.append(preset)
        }
        defaults.set(favorites.map { ShaderSelection.preset($0).rawValue }, forKey: PrefKey.shaderFavorites)
    }

    // MARK: Pack

    /// Downloads the pack and replaces the installed one. Everyone who asks
    /// while it runs waits for this one download.
    func installPack() async throws {
        if let installation { return try await installation.value }
        let task = Task {
            defer {
                installation = nil
                downloadProgress = nil
                isUnpacking = false
            }
            downloadProgress = 0
            let archive = try await downloader(Self.packURL) { fraction in
                Task { @MainActor in
                    // A late callback must not revive the progress of a finished download.
                    if self.installation != nil, !self.isUnpacking { self.downloadProgress = fraction }
                }
            }
            defer { try? FileManager.default.removeItem(at: archive) }
            downloadProgress = nil
            isUnpacking = true
            try await Self.unpack(archive, to: libraryDirectory)
            let installed = Date.now
            try Self.saveInstallDate(installed, root: rootDirectory)
            packInstalled = installed
            updateAvailable = false
            refresh()
        }
        installation = task
        try await task.value
    }

    /// Deletes the pack. Games set to one of its presets use the built-in filter.
    func removePack() throws {
        if FileManager.default.fileExists(atPath: libraryDirectory.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: libraryDirectory)
        }
        try? FileManager.default.removeItem(at: Self.packInfoURL(root: rootDirectory))
        packInstalled = nil
        packSize = nil
        updateAvailable = false
        refresh()
    }

    /// Asks the buildbot whether the pack changed since it was downloaded.
    func checkForUpdates() async throws {
        guard let installed = packInstalled, !isCheckingForUpdates else { return }
        isCheckingForUpdates = true
        defer { isCheckingForUpdates = false }
        let built = try await lastModified(Self.packURL)
        updateAvailable = built.map { $0 > installed } ?? false
        lastUpdateCheck = .now
    }

    /// Extracts the pack next to `destination` and swaps it in only when
    /// complete, so a failed update leaves the installed pack untouched.
    @concurrent
    private static func unpack(_ archive: URL, to destination: URL) async throws {
        let fileManager = FileManager.default
        let parent = destination.deletingLastPathComponent()
        let staging = parent.appending(path: ".\(destination.lastPathComponent).download", directoryHint: .isDirectory)
        let previous = parent.appending(path: ".\(destination.lastPathComponent).previous", directoryHint: .isDirectory)
        try? fileManager.removeItem(at: staging)
        try? fileManager.removeItem(at: previous)
        defer { try? fileManager.removeItem(at: staging) }

        let zip = try ZipArchive(url: archive)
        guard zip.files.contains(where: { $0.fileExtension == "slangp" }) else { throw LibraryError.invalidArchive }
        try zip.extractAll(to: staging, concurrently: true)

        let hasPack = fileManager.fileExists(atPath: destination.path(percentEncoded: false))
        if hasPack { try fileManager.moveItem(at: destination, to: previous) }
        do {
            try fileManager.moveItem(at: staging, to: destination)
        } catch {
            if hasPack { try? fileManager.moveItem(at: previous, to: destination) }
            throw error
        }
        try? fileManager.removeItem(at: previous)
    }

    private static let downloadFile: HTTPDownload.Downloader = { url, onProgress in
        do {
            return try await HTTPDownload.file(from: url, onProgress: onProgress)
        } catch let error as HTTPDownload.StatusError {
            throw LibraryError.downloadFailed("HTTP \(error.status)")
        }
    }

    // MARK: Pack info

    nonisolated private struct PackInfo: Codable {
        var installed: Date
    }

    nonisolated private static func packInfoURL(root: URL) -> URL {
        root.appending(path: "pack.json")
    }

    /// From `pack.json`; a pack put there by hand counts from its folder date.
    nonisolated private static func installDate(of library: URL, root: URL) -> Date? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: library.path(percentEncoded: false)) else { return nil }
        if let data = try? Data(contentsOf: packInfoURL(root: root)), let info = try? JSONDecoder().decode(PackInfo.self, from: data) {
            return info.installed
        }
        return (try? fileManager.attributesOfItem(atPath: library.path(percentEncoded: false)))?[.modificationDate] as? Date ?? .now
    }

    nonisolated private static func saveInstallDate(_ date: Date, root: URL) throws {
        try JSONEncoder().encode(PackInfo(installed: date)).write(to: packInfoURL(root: root), options: .atomic)
    }

    // MARK: Import

    /// Copies presets and shader folders into the user folder and returns
    /// what was imported.
    func importItems(_ urls: [URL]) async -> ShaderImport.Result {
        let accessed = urls.filter { $0.startAccessingSecurityScopedResource() }
        defer { accessed.forEach { $0.stopAccessingSecurityScopedResource() } }
        let result = await Self.importItems(urls, into: userDirectory)
        if !result.presets.isEmpty { refresh() }
        return result
    }

    @concurrent
    private static func importItems(_ urls: [URL], into user: URL) async -> ShaderImport.Result {
        ShaderImport.copy(urls, into: user)
    }

    /// Creates the user folder, e.g. before showing it in Finder.
    @discardableResult
    func makeUserDirectory() -> URL {
        try? FileManager.default.createDirectory(at: userDirectory, withIntermediateDirectories: true)
        return userDirectory
    }
}
