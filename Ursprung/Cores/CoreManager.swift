// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Observation

/// Downloads, updates and removes libretro cores from the libretro buildbot.
///
/// Cores are GPL/non-commercial third-party software and are therefore not
/// bundled with Ursprung; they are fetched on demand.
@Observable
final class CoreManager {
    enum CoreError: LocalizedError {
        case downloadFailed(String)
        case invalidArchive

        var errorDescription: String? {
            switch self {
            case .downloadFailed(let reason): String(localized: "The core could not be downloaded: \(reason)")
            case .invalidArchive: String(localized: "The downloaded core archive is invalid.")
            }
        }
    }

    static let buildbot = URL(string: "https://buildbot.libretro.com/nightly/apple/osx/arm64/latest/")!

    /// Fetches `url` to a temporary .zip file, reporting progress (0…1).
    typealias Downloader = @Sendable (URL, @escaping @Sendable (Double) -> Void) async throws -> URL
    /// When the file at a URL last changed on the server (HTTP Last-Modified).
    typealias LastModifiedFetcher = @Sendable (URL) async throws -> Date?

    /// Download progress (0…1) for cores currently being installed.
    private(set) var downloads: [String: Double] = [:]
    /// Bumped whenever the set of installed cores changes.
    private(set) var revision = 0
    /// Installed and previous version of every core Ursprung installed.
    private(set) var versions: [String: CoreVersionEntry]
    /// Cores with a newer build on the buildbot than the installed one.
    private(set) var updatesAvailable: Set<String> = []
    private(set) var isCheckingForUpdates = false
    private(set) var lastUpdateCheck: Date?

    private let coresDirectory: URL
    private let systemDirectory: URL
    private let downloader: Downloader
    private let lastModified: LastModifiedFetcher
    /// The running installation per core. Everyone who asks for a core that is
    /// being installed waits for this one operation and shares its outcome.
    private var installations: [String: Task<Void, Error>] = [:]

    init(coresDirectory: URL = AppPaths.cores,
         systemDirectory: URL = AppPaths.system,
         downloader: @escaping Downloader = CoreManager.downloadFile,
         lastModified: @escaping LastModifiedFetcher = CoreManager.fetchLastModified) {
        self.coresDirectory = coresDirectory
        self.systemDirectory = systemDirectory
        self.downloader = downloader
        self.lastModified = lastModified
        versions = CoreVersionStore.load(in: coresDirectory)
    }

    /// All distinct cores referenced by the system catalog.
    static let allCores: [CoreDefinition] = {
        var seen = Set<String>()
        return SystemCatalog.all.flatMap(\.cores).filter { seen.insert($0.id).inserted }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }()

    func installedURL(for core: CoreDefinition) -> URL {
        coresDirectory.appending(path: core.fileName)
    }

    func isInstalled(_ core: CoreDefinition) -> Bool {
        _ = revision
        return FileManager.default.fileExists(atPath: installedURL(for: core).path(percentEncoded: false))
    }

    func installedDate(_ core: CoreDefinition) -> Date? {
        _ = revision
        let attributes = try? FileManager.default.attributesOfItem(atPath: installedURL(for: core).path(percentEncoded: false))
        return attributes?[.modificationDate] as? Date
    }

    /// Returns the path of the core, downloading it (and its system assets) first if needed.
    func ensureInstalled(_ core: CoreDefinition) async throws -> URL {
        try await install(core, replacing: false)
        return installedURL(for: core)
    }

    /// Downloads the core (again, if it is installed) together with its system assets.
    func install(_ core: CoreDefinition) async throws {
        try await install(core, replacing: true)
    }

    private func install(_ core: CoreDefinition, replacing: Bool) async throws {
        if let running = installations[core.id] { return try await running.value }
        let task = Task {
            defer { installations[core.id] = nil; downloads[core.id] = nil }
            downloads[core.id] = 0
            if replacing || !isInstalled(core) { try await installCore(core) }
            try await ensureSystemAssets(for: core)
        }
        installations[core.id] = task
        try await task.value
    }

    func remove(_ core: CoreDefinition) {
        try? FileManager.default.removeItem(at: installedURL(for: core))
        try? FileManager.default.removeItem(at: previousURL(for: core))
        versions[core.id] = nil
        updatesAvailable.remove(core.id)
        saveVersions()
        revision += 1
    }

    // MARK: - Versions

    /// Where the version before the last update is kept.
    func previousURL(for core: CoreDefinition) -> URL {
        coresDirectory.appending(path: "Previous", directoryHint: .isDirectory).appending(path: core.fileName)
    }

    func hasPreviousVersion(_ core: CoreDefinition) -> Bool {
        _ = revision
        return FileManager.default.fileExists(atPath: previousURL(for: core).path(percentEncoded: false))
    }

    /// Notes the version a core reported when a game started with it.
    func recordVersion(_ version: String, for core: CoreDefinition) {
        guard !version.isEmpty else { return }
        let coreID = core.id
        var entry = versions[coreID] ?? CoreVersionEntry()
        if entry.current == nil { entry.current = CoreVersionRecord(version: nil, installed: installedDate(core) ?? .now) }
        guard entry.current?.version != version else { return }
        entry.current?.version = version
        versions[coreID] = entry
        saveVersions()
    }

    /// Puts the version before the last update back; the newer one becomes
    /// the previous version, so this can be undone the same way.
    func restorePreviousVersion(_ core: CoreDefinition) throws {
        let fileManager = FileManager.default
        let current = installedURL(for: core), previous = previousURL(for: core)
        let swap = coresDirectory.appending(path: ".\(core.fileName).swap")
        try? fileManager.removeItem(at: swap)
        let hasCurrent = fileManager.fileExists(atPath: current.path(percentEncoded: false))
        if hasCurrent { try fileManager.moveItem(at: current, to: swap) }
        do {
            try fileManager.moveItem(at: previous, to: current)
        } catch {
            if hasCurrent { try? fileManager.moveItem(at: swap, to: current) }
            throw error
        }
        if hasCurrent { try fileManager.moveItem(at: swap, to: previous) }
        var entry = versions[core.id] ?? CoreVersionEntry()
        (entry.current, entry.previous) = (entry.previous, entry.current)
        versions[core.id] = entry
        // Whether a newer build exists is unknown again.
        updatesAvailable.remove(core.id)
        saveVersions()
        revision += 1
    }

    /// Asks the buildbot which installed cores have newer builds.
    func checkForUpdates(of candidates: [CoreDefinition] = CoreManager.allCores) async throws {
        guard !isCheckingForUpdates else { return }
        isCheckingForUpdates = true
        defer { isCheckingForUpdates = false }
        var available: Set<String> = []
        for core in candidates where isInstalled(core) {
            let installed = versions[core.id]?.current?.installed ?? installedDate(core) ?? .distantPast
            if let built = try await lastModified(Self.buildbot.appending(path: "\(core.fileName).zip")), built > installed {
                available.insert(core.id)
            }
        }
        updatesAvailable = available
        lastUpdateCheck = .now
    }

    private func saveVersions() {
        try? CoreVersionStore.save(versions, in: coresDirectory)
    }

    // MARK: - Helpers

    private func installCore(_ core: CoreDefinition) async throws {
        let archive = try await download(Self.buildbot.appending(path: "\(core.fileName).zip"), coreID: core.id)
        defer { try? FileManager.default.removeItem(at: archive) }
        // The installed version stays available for going back.
        var entry = versions[core.id] ?? CoreVersionEntry()
        if isInstalled(core) {
            let previous = previousURL(for: core)
            try? FileManager.default.createDirectory(at: previous.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: previous)
            try FileManager.default.copyItem(at: installedURL(for: core), to: previous)
            entry.previous = entry.current ?? CoreVersionRecord(version: nil, installed: installedDate(core) ?? .now)
        }
        try await Self.extractCore(archive: archive, fileName: core.fileName, to: installedURL(for: core))
        entry.current = CoreVersionRecord(version: nil, installed: .now)
        versions[core.id] = entry
        updatesAvailable.remove(core.id)
        saveVersions()
        revision += 1
    }

    private func ensureSystemAssets(for core: CoreDefinition) async throws {
        guard let assets = core.systemAssets else { return }
        let marker = systemDirectory.appending(path: ".assets-\(core.id)")
        guard !FileManager.default.fileExists(atPath: marker.path(percentEncoded: false)) else { return }

        let archive = try await download(assets, coreID: core.id)
        defer { try? FileManager.default.removeItem(at: archive) }
        try await Self.extractAll(archive: archive, to: systemDirectory)
        try Data().write(to: marker)
    }

    private func download(_ url: URL, coreID: String) async throws -> URL {
        try await downloader(url) { [weak self] fraction in
            Task { @MainActor in
                // A late callback must not revive the progress of a finished installation.
                if let self, self.installations[coreID] != nil { self.downloads[coreID] = fraction }
            }
        }
    }

    private static let downloadFile: Downloader = { url, onProgress in
        let tracker = DownloadTracker(onProgress: onProgress)
        let (temporary, response) = try await URLSession.shared.download(from: url, delegate: tracker)
        tracker.stop()
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw CoreError.downloadFailed("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        let destination = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".zip")
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }

    private static let fetchLastModified: LastModifiedFetcher = { url in
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let header = http.value(forHTTPHeaderField: "Last-Modified") else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: header)
    }

    @concurrent
    private static func extractCore(archive: URL, fileName: String, to destination: URL) async throws {
        let zip = try ZipArchive(url: archive)
        guard let entry = zip.files.first(where: { $0.fileName == fileName }) ?? zip.files.first(where: { $0.fileExtension == "dylib" }) else {
            throw CoreError.invalidArchive
        }
        let staging = destination.deletingLastPathComponent().appending(path: ".\(fileName).download")
        try zip.extract(entry, to: staging)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: staging, to: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path(percentEncoded: false))
        removexattr(destination.path(percentEncoded: false), "com.apple.quarantine", 0)
    }

    @concurrent
    private static func extractAll(archive: URL, to directory: URL) async throws {
        try ZipArchive(url: archive).extractAll(to: directory)
    }
}

/// Reports download progress of a single URLSession task.
private final class DownloadTracker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Double) -> Void
    private var observation: NSKeyValueObservation?

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        observation = task.progress.observe(\.fractionCompleted, options: [.new]) { [onProgress] progress, _ in
            onProgress(progress.fractionCompleted)
        }
    }

    func stop() {
        observation?.invalidate()
        observation = nil
    }
}


/// One version of an installed core.
nonisolated struct CoreVersionRecord: Codable, Equatable, Sendable {
    /// The core's own version (libretro `library_version`); known once a
    /// game ran with it.
    var version: String?
    var installed: Date
}

/// A core's installed version and the one before its last update.
nonisolated struct CoreVersionEntry: Codable, Equatable, Sendable {
    var current: CoreVersionRecord?
    var previous: CoreVersionRecord?
}

/// `Cores/versions.json`.
nonisolated enum CoreVersionStore {
    static func load(in coresDirectory: URL) -> [String: CoreVersionEntry] {
        guard let data = try? Data(contentsOf: coresDirectory.appending(path: "versions.json")) else { return [:] }
        return (try? decoder.decode([String: CoreVersionEntry].self, from: data)) ?? [:]
    }

    static func save(_ versions: [String: CoreVersionEntry], in coresDirectory: URL) throws {
        try FileManager.default.createDirectory(at: coresDirectory, withIntermediateDirectories: true)
        // Dates as numbers: exact, so they compare equal after a restart.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(versions).write(to: coresDirectory.appending(path: "versions.json"), options: .atomic)
    }

    private static var decoder: JSONDecoder { JSONDecoder() }
}
