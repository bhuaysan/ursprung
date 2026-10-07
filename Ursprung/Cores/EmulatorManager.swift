// SPDX-License-Identifier: GPL-3.0-or-later

import CryptoKit
import Foundation
import Observation
import Security

/// Downloads, verifies and removes standalone emulators (docs/STANDALONE_PLAN.md).
///
/// Ursprung pins one tested release per emulator in `SystemCatalog`. Every
/// version lives in its own folder, `Emulators/<name>/<commit>/<name>.app`;
/// the active version and the one before it are kept, so the user can go
/// back. `Emulators/<name>/data` (the emulator's own data folder) is shared
/// by all versions and left alone here.
@Observable
final class EmulatorManager {
    enum EmulatorError: LocalizedError {
        case downloadFailed(String)
        case checksumMismatch
        case invalidArchive
        case signatureInvalid(String)

        var errorDescription: String? {
            switch self {
            case .downloadFailed(let reason): String(localized: "The emulator could not be downloaded: \(reason)")
            case .checksumMismatch: String(localized: "The downloaded emulator is not the tested release: its checksum doesn’t match.")
            case .invalidArchive: String(localized: "The downloaded emulator archive is invalid.")
            case .signatureInvalid(let reason): String(localized: "The downloaded emulator is not signed by its developer: \(reason)")
            }
        }
    }

    typealias Downloader = HTTPDownload.Downloader
    /// Throws unless the app at the URL is validly signed by the Developer ID team.
    typealias SignatureVerifier = @Sendable (URL, _ teamIdentifier: String) throws -> Void

    /// Download progress (0…1) for emulators currently being installed.
    private(set) var downloads: [String: Double] = [:]
    /// Bumped whenever the installed versions change.
    private(set) var revision = 0
    /// Active and previous version of every emulator Ursprung installed.
    private(set) var versions: [String: EmulatorVersionEntry]

    private let directory: URL
    private let downloader: Downloader
    private let verifySignature: SignatureVerifier
    /// The running installation per emulator; later callers share its outcome.
    private var installations: [String: Task<Void, Error>] = [:]

    init(directory: URL = AppPaths.emulators,
         downloader: @escaping Downloader = EmulatorManager.downloadFile,
         verifySignature: @escaping SignatureVerifier = EmulatorManager.checkSignature) {
        self.directory = directory
        self.downloader = downloader
        self.verifySignature = verifySignature
        versions = EmulatorVersionStore.load(in: directory)
    }

    // MARK: - Locations

    /// `Emulators/<name>`: the versions and the shared data folder.
    func folder(for emulator: StandaloneEmulator) -> URL {
        directory.appending(path: emulator.name, directoryHint: .isDirectory)
    }

    /// The emulator's own data folder (settings, caches), shared by all versions.
    func dataFolder(for emulator: StandaloneEmulator) -> URL {
        folder(for: emulator).appending(path: "data", directoryHint: .isDirectory)
    }

    /// The log of the last run and the process output, replaced by every launch.
    func logFolder(for emulator: StandaloneEmulator) -> URL {
        folder(for: emulator).appending(path: "Logs", directoryHint: .isDirectory)
    }

    func appURL(for emulator: StandaloneEmulator, commit: String) -> URL {
        folder(for: emulator).appending(path: commit, directoryHint: .isDirectory)
            .appending(path: "\(emulator.name).app", directoryHint: .isDirectory)
    }

    /// The active version's app, if it is installed.
    func installedApp(for emulator: StandaloneEmulator) -> URL? {
        _ = revision
        guard let commit = versions[emulator.id]?.current?.commit, hasApp(emulator, commit: commit) else { return nil }
        return appURL(for: emulator, commit: commit)
    }

    func isInstalled(_ emulator: StandaloneEmulator) -> Bool {
        installedApp(for: emulator) != nil
    }

    /// The installed version differs from the release this Ursprung was tested with.
    func isUpdateAvailable(_ emulator: StandaloneEmulator) -> Bool {
        isInstalled(emulator) && versions[emulator.id]?.current?.commit != emulator.release.commit
    }

    func hasPreviousVersion(_ emulator: StandaloneEmulator) -> Bool {
        _ = revision
        guard let commit = versions[emulator.id]?.previous?.commit else { return false }
        return hasApp(emulator, commit: commit)
    }

    private func hasApp(_ emulator: StandaloneEmulator, commit: String) -> Bool {
        let executable = appURL(for: emulator, commit: commit).appending(path: emulator.executable)
        return FileManager.default.isExecutableFile(atPath: executable.path(percentEncoded: false))
    }

    // MARK: - Installing

    /// Returns the app to launch, installing the pinned release first if
    /// needed. A version the user went back to stays active until the pin moves.
    func ensureInstalled(_ emulator: StandaloneEmulator) async throws -> URL {
        try await install(emulator, onlyIfNeeded: true)
        guard let app = installedApp(for: emulator) else { throw EmulatorError.invalidArchive }
        return app
    }

    /// Makes the pinned release the active version: switches back to it if it
    /// is the previous version, downloads it otherwise.
    func install(_ emulator: StandaloneEmulator) async throws {
        try await install(emulator, onlyIfNeeded: false)
    }

    private func install(_ emulator: StandaloneEmulator, onlyIfNeeded: Bool) async throws {
        if let running = installations[emulator.id] { return try await running.value }
        let task = Task {
            defer { installations[emulator.id] = nil; downloads[emulator.id] = nil }
            let entry = versions[emulator.id]
            let pin = emulator.release.commit
            if onlyIfNeeded, isInstalled(emulator), entry?.current?.commit == pin || entry?.heldBackFrom == pin { return }
            if entry?.current?.commit == pin, isInstalled(emulator) {
                versions[emulator.id]?.heldBackFrom = nil
                saveVersions()
                return
            }
            if entry?.previous?.commit == pin, hasPreviousVersion(emulator) {
                restorePreviousVersion(emulator)
                return
            }
            downloads[emulator.id] = 0
            let archive = try await fetch(emulator.downloadURL, emulatorID: emulator.id)
            defer { try? FileManager.default.removeItem(at: archive) }
            try await Self.install(archive: archive, of: emulator,
                                   into: appURL(for: emulator, commit: pin).deletingLastPathComponent(),
                                   verifySignature: verifySignature)
            activate(EmulatorVersionRecord(tag: emulator.release.tag, commit: pin, installed: .now), of: emulator)
        }
        installations[emulator.id] = task
        try await task.value
    }

    /// Records a freshly installed version as active. The version it replaces
    /// becomes the previous one; any older version is deleted.
    private func activate(_ record: EmulatorVersionRecord, of emulator: StandaloneEmulator) {
        var entry = versions[emulator.id] ?? EmulatorVersionEntry()
        let displaced = [entry.current, entry.previous].compactMap { $0 }.filter { $0.commit != record.commit }
        for old in displaced.dropFirst() {
            try? FileManager.default.removeItem(at: appURL(for: emulator, commit: old.commit).deletingLastPathComponent())
        }
        entry.previous = displaced.first
        entry.current = record
        entry.heldBackFrom = nil
        versions[emulator.id] = entry
        saveVersions()
        revision += 1
    }

    /// Swaps the active and the previous version, so this can be undone the
    /// same way. Going back to a version other than the pinned release holds
    /// it until the pin moves.
    func restorePreviousVersion(_ emulator: StandaloneEmulator) {
        guard hasPreviousVersion(emulator), var entry = versions[emulator.id] else { return }
        (entry.current, entry.previous) = (entry.previous, entry.current)
        entry.heldBackFrom = entry.current?.commit == emulator.release.commit ? nil : emulator.release.commit
        versions[emulator.id] = entry
        saveVersions()
        revision += 1
    }

    /// Deletes every installed version. The data folder (settings, caches)
    /// stays for the next installation.
    func remove(_ emulator: StandaloneEmulator) {
        let entry = versions[emulator.id]
        for commit in [entry?.current?.commit, entry?.previous?.commit, emulator.release.commit].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: appURL(for: emulator, commit: commit).deletingLastPathComponent())
        }
        versions[emulator.id] = nil
        saveVersions()
        revision += 1
    }

    /// Disk space of the installed versions, in bytes.
    func installedSize(of emulator: StandaloneEmulator) async -> Int64 {
        let entry = versions[emulator.id]
        let folders = [entry?.current?.commit, entry?.previous?.commit].compactMap { $0 }
            .map { appURL(for: emulator, commit: $0).deletingLastPathComponent() }
        return await Self.allocatedSize(of: folders)
    }

    private func saveVersions() {
        try? EmulatorVersionStore.save(versions, in: directory)
    }

    // MARK: - Helpers

    private func fetch(_ url: URL, emulatorID: String) async throws -> URL {
        try await downloader(url) { [weak self] fraction in
            Task { @MainActor in
                // A late callback must not revive the progress of a finished installation.
                if let self, self.installations[emulatorID] != nil { self.downloads[emulatorID] = fraction }
            }
        }
    }

    private static let downloadFile: Downloader = { url, onProgress in
        do {
            return try await HTTPDownload.file(from: url, onProgress: onProgress)
        } catch let error as HTTPDownload.StatusError {
            throw EmulatorError.downloadFailed("HTTP \(error.status)")
        }
    }

    /// Checks the archive against the pin, unpacks it next to `destination`,
    /// renames the single app inside to `<name>.app`, checks its signature and
    /// only then moves it into place.
    @concurrent
    private static func install(archive: URL, of emulator: StandaloneEmulator, into destination: URL,
                                verifySignature: SignatureVerifier) async throws {
        guard try sha256(of: archive) == emulator.release.sha256.lowercased() else { throw EmulatorError.checksumMismatch }

        let fileManager = FileManager.default
        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        // Left over when Ursprung quit during an installation.
        let stagingPrefix = ".\(destination.lastPathComponent)-"
        for leftover in (try? fileManager.contentsOfDirectory(atPath: parent.path(percentEncoded: false))) ?? []
        where leftover.hasPrefix(stagingPrefix) {
            try? fileManager.removeItem(at: parent.appending(path: leftover))
        }
        let staging = parent.appending(path: stagingPrefix + UUID().uuidString, directoryHint: .isDirectory)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        // bsdtar detects the compression and refuses absolute paths and `..`.
        guard try await run("/usr/bin/tar", ["-xf", archive.path(percentEncoded: false), "-C", staging.path(percentEncoded: false)]) == 0 else {
            throw EmulatorError.invalidArchive
        }
        let apps = try fileManager.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
            .filter { $0.pathExtension == "app" }
        guard apps.count == 1, let unpacked = apps.first else { throw EmulatorError.invalidArchive }
        let app = staging.appending(path: "\(emulator.name).app", directoryHint: .isDirectory)
        if unpacked.lastPathComponent != app.lastPathComponent { try fileManager.moveItem(at: unpacked, to: app) }
        guard fileManager.isExecutableFile(atPath: app.appending(path: emulator.executable).path(percentEncoded: false)) else {
            throw EmulatorError.invalidArchive
        }
        // The SHA-256 pin and the team check below stand in for Gatekeeper.
        removeQuarantine(below: app)
        try verifySignature(app, emulator.teamIdentifier)

        // `staging` now holds exactly `<name>.app` and becomes `<commit>/`.
        try? fileManager.removeItem(at: destination)
        try fileManager.moveItem(at: staging, to: destination)
    }

    nonisolated static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Runs a tool and returns its exit status.
    @concurrent
    private static func run(_ executable: String, _ arguments: [String]) async throws -> Int32 {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }

    nonisolated private static func removeQuarantine(below url: URL) {
        removexattr(url.path(percentEncoded: false), "com.apple.quarantine", XATTR_NOFOLLOW)
        guard let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) else { return }
        for case let file as URL in files {
            removexattr(file.path(percentEncoded: false), "com.apple.quarantine", XATTR_NOFOLLOW)
        }
    }

    /// Checks the whole bundle, nested code included, against a Developer ID
    /// signature of `teamIdentifier`.
    nonisolated static let checkSignature: SignatureVerifier = { app, teamIdentifier in
        var code: SecStaticCode?
        var status = SecStaticCodeCreateWithPath(app as CFURL, [], &code)
        guard status == errSecSuccess, let code else { throw EmulatorError.signatureInvalid(message(for: status)) }
        let text = "anchor apple generic and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
        var requirement: SecRequirement?
        status = SecRequirementCreateWithString(text as CFString, [], &requirement)
        guard status == errSecSuccess, let requirement else { throw EmulatorError.signatureInvalid(message(for: status)) }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        status = SecStaticCodeCheckValidity(code, flags, requirement)
        guard status == errSecSuccess else { throw EmulatorError.signatureInvalid(message(for: status)) }
    }

    nonisolated private static func message(for status: OSStatus) -> String {
        SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
    }

    @concurrent
    private static func allocatedSize(of folders: [URL]) async -> Int64 {
        folders.reduce(0) { $0 + allocatedSize(of: $1) }
    }

    nonisolated private static func allocatedSize(of folder: URL) -> Int64 {
        var total: Int64 = 0
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else { return 0 }
        for case let file as URL in files {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}

/// One installed version of a standalone emulator.
nonisolated struct EmulatorVersionRecord: Codable, Equatable, Sendable {
    /// Release tag, e.g. `nightly-20261006`.
    var tag: String
    /// Source commit; also the version's folder name.
    var commit: String
    var installed: Date
}

/// An emulator's active version and the one before it.
nonisolated struct EmulatorVersionEntry: Codable, Equatable, Sendable {
    var current: EmulatorVersionRecord?
    var previous: EmulatorVersionRecord?
    /// The pinned commit at the time the user went back to an older version.
    /// While the pin stays the same, Ursprung keeps the user's choice.
    var heldBackFrom: String?
}

/// `Emulators/versions.json`.
nonisolated enum EmulatorVersionStore {
    static func load(in directory: URL) -> [String: EmulatorVersionEntry] {
        guard let data = try? Data(contentsOf: directory.appending(path: "versions.json")) else { return [:] }
        return (try? JSONDecoder().decode([String: EmulatorVersionEntry].self, from: data)) ?? [:]
    }

    static func save(_ versions: [String: EmulatorVersionEntry], in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(versions).write(to: directory.appending(path: "versions.json"), options: .atomic)
    }
}
