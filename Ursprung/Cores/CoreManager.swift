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

    /// Download progress (0…1) for cores currently being installed.
    private(set) var downloads: [String: Double] = [:]
    /// Bumped whenever the set of installed cores changes.
    private(set) var revision = 0

    private let coresDirectory: URL
    private let systemDirectory: URL
    private let downloader: Downloader
    /// The running installation per core. Everyone who asks for a core that is
    /// being installed waits for this one operation and shares its outcome.
    private var installations: [String: Task<Void, Error>] = [:]

    init(coresDirectory: URL = AppPaths.cores,
         systemDirectory: URL = AppPaths.system,
         downloader: @escaping Downloader = CoreManager.downloadFile) {
        self.coresDirectory = coresDirectory
        self.systemDirectory = systemDirectory
        self.downloader = downloader
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
        revision += 1
    }

    // MARK: - Helpers

    private func installCore(_ core: CoreDefinition) async throws {
        let archive = try await download(Self.buildbot.appending(path: "\(core.fileName).zip"), coreID: core.id)
        defer { try? FileManager.default.removeItem(at: archive) }
        try await Self.extractCore(archive: archive, fileName: core.fileName, to: installedURL(for: core))
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
