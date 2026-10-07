// SPDX-License-Identifier: GPL-3.0-or-later

import CryptoKit
import Foundation
import Observation

/// Verifies and imports BIOS files into the libretro system directory, and
/// finds the dumps in BIOS folders (`BIOSFolder`).
@Observable
final class BIOSManager {
    nonisolated enum Status: Sendable, Equatable {
        case missing
        case present
        case verified
        case mismatch
    }

    nonisolated struct ImportResult: Sendable {
        var imported: [String] = []
        var unknown: [String] = []
        /// Recognised files that could not be copied.
        var failed: [String] = []
    }

    private(set) var statuses: [String: Status]
    /// Recognised dumps per `BIOSFolder.path`, sorted by file name.
    private(set) var folderDumps: [String: [PS2BIOS]]
    private(set) var isRefreshing = false
    private let systemDirectory: URL

    init(systemDirectory: URL = AppPaths.system, statuses: [String: Status] = [:], folderDumps: [String: [PS2BIOS]] = [:]) {
        self.systemDirectory = systemDirectory
        self.statuses = statuses
        self.folderDumps = folderDumps
    }

    func dumps(in folder: BIOSFolder) -> [PS2BIOS] {
        folderDumps[folder.path] ?? []
    }

    func status(of file: BIOSFile) -> Status {
        statuses[file.fileName] ?? .missing
    }

    /// Whether all BIOS files that `coreID` (default: the system's default
    /// core) needs are present.
    func isReady(_ system: GameSystem, coreID: String? = nil) -> Bool {
        missingRequired(for: system, coreID: coreID).isEmpty && missingFolder(for: system, coreID: coreID) == nil
    }

    /// The system's BIOS folder when `coreID` needs a dump and it holds none.
    func missingFolder(for system: GameSystem, coreID: String? = nil) -> BIOSFolder? {
        guard let folder = system.biosFolder, folder.isRequired(forCore: coreID ?? system.defaultCore.id),
              dumps(in: folder).isEmpty else { return nil }
        return folder
    }

    /// What `coreID` is missing, for messages: file names, and a description
    /// of a missing folder dump.
    func missingDescriptions(for system: GameSystem, coreID: String? = nil) -> [String] {
        missingRequired(for: system, coreID: coreID).map(\.fileName)
            + (missingFolder(for: system, coreID: coreID).map { [Self.description(of: $0)] } ?? [])
    }

    nonisolated static func description(of folder: BIOSFolder) -> String {
        switch folder.kind {
        case .playStation2: String(localized: "a PlayStation 2 BIOS (any region)")
        }
    }

    /// The BIOS files `coreID` cannot start without that are missing. Which
    /// files are needed depends on the core: some bring a built-in BIOS.
    func missingRequired(for system: GameSystem, coreID: String? = nil) -> [BIOSFile] {
        let core = coreID ?? system.defaultCore.id
        let required = system.bios.filter { $0.isRequired(forCore: core) }
        // Alternatives (e.g. the Sega CD regions) only need one of their group.
        let satisfiedGroups = Set(required.filter { status(of: $0) != .missing }.compactMap(\.group))
        return required.filter { file in
            status(of: file) == .missing && !(file.group.map(satisfiedGroups.contains) ?? false)
        }
    }

    func refresh() async {
        isRefreshing = true
        let snapshot = await Self.computeStatuses(in: systemDirectory)
        statuses = snapshot.statuses
        folderDumps = snapshot.folderDumps
        isRefreshing = false
    }

    /// Copies BIOS files into the system directory. Files are recognised by
    /// name (case-insensitive) or by MD5, and renamed to what the cores expect.
    /// PlayStation 2 dumps are recognised by content and keep their names,
    /// together with the side files of the same base name.
    func importFiles(_ urls: [URL]) async -> ImportResult {
        let result = await Self.performImport(urls, into: systemDirectory)
        await refresh()
        return result
    }

    // MARK: - Background work

    private nonisolated struct Snapshot: Sendable {
        var statuses: [String: Status] = [:]
        var folderDumps: [String: [PS2BIOS]] = [:]
    }

    @concurrent
    private static func computeStatuses(in systemDirectory: URL) async -> Snapshot {
        var result: [String: Status] = [:]
        for file in SystemCatalog.all.flatMap(\.bios) {
            let url = systemDirectory.appending(path: file.fileName)
            guard let actual = resolveCaseInsensitive(url) else {
                result[file.fileName] = .missing
                continue
            }
            if let expected = file.md5, let md5 = md5(of: actual) {
                result[file.fileName] = md5 == expected ? .verified : .mismatch
            } else {
                result[file.fileName] = .present
            }
        }
        var folderDumps: [String: [PS2BIOS]] = [:]
        for folder in SystemCatalog.all.compactMap(\.biosFolder) {
            let directory = systemDirectory.appending(path: folder.path, directoryHint: .isDirectory)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
            folderDumps[folder.path] = names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                .compactMap { PS2BIOS.inspect(directory.appending(path: $0)) }
        }
        return Snapshot(statuses: result, folderDumps: folderDumps)
    }

    @concurrent
    private static func performImport(_ urls: [URL], into systemDirectory: URL) async -> ImportResult {
        let known = SystemCatalog.all.flatMap(\.bios)
        let byMD5 = Dictionary(known.compactMap { file in file.md5.map { ($0, file) } }, uniquingKeysWith: { first, _ in first })
        let byName = Dictionary(known.map { (($0.fileName as NSString).lastPathComponent.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })

        var files = expand(urls)
        // PS2 dumps and their side files go into the folder under their own
        // names, also side files that were not selected themselves.
        var folderTargets: [String: String] = [:]
        var unselectedSideFiles: [URL] = []
        if let folder = SystemCatalog.all.compactMap(\.biosFolder).first(where: { $0.kind == .playStation2 }) {
            for url in files where byName[url.lastPathComponent.lowercased()] == nil {
                guard PS2BIOS.inspect(url) != nil else { continue }
                folderTargets[pathKey(url)] = "\(folder.path)/\(url.lastPathComponent)"
                for side in sideFiles(of: url) {
                    if !files.contains(where: { pathKey($0) == pathKey(side) }) { unselectedSideFiles.append(side) }
                    folderTargets[pathKey(side)] = "\(folder.path)/\(side.lastPathComponent)"
                }
            }
        }
        files += unselectedSideFiles

        var result = ImportResult()
        for url in files {
            let name = url.lastPathComponent
            let target: String
            if let folderTarget = folderTargets[pathKey(url)] {
                target = folderTarget
            } else if let hash = md5(of: url), let file = byMD5[hash] {
                target = file.fileName
            } else if let file = byName[name.lowercased()] {
                target = file.fileName
            } else {
                result.unknown.append(name)
                continue
            }
            let destination = systemDirectory.appending(path: target)
            do {
                try install(url, at: destination)
                result.imported.append(target)
            } catch {
                result.failed.append(name)
            }
        }
        return result
    }

    /// Copies `source` to `destination`. An existing file is only replaced
    /// once the copy is complete, and importing the installed file itself
    /// (e.g. from the opened system folder) leaves it alone.
    private nonisolated static func install(_ source: URL, at destination: URL) throws {
        let fm = FileManager.default
        let existing = resolveCaseInsensitive(destination)
        if let existing, isSameFile(source, existing) { return }

        let directory = destination.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let staging = directory.appending(path: ".import-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: staging) }
        try fm.copyItem(at: source, to: staging)
        if fm.fileExists(atPath: destination.path(percentEncoded: false)) {
            _ = try fm.replaceItemAt(destination, withItemAt: staging)
        } else {
            try fm.moveItem(at: staging, to: destination)
        }
        // On a case-sensitive volume the old file may differ in case only.
        if let existing, existing.lastPathComponent != destination.lastPathComponent, !isSameFile(existing, destination) {
            try? fm.removeItem(at: existing)
        }
    }

    private nonisolated static func isSameFile(_ a: URL, _ b: URL) -> Bool {
        let key: Set<URLResourceKey> = [.fileResourceIdentifierKey]
        guard let first = try? a.resourceValues(forKeys: key).fileResourceIdentifier,
              let second = try? b.resourceValues(forKeys: key).fileResourceIdentifier else { return false }
        return first.isEqual(second)
    }

    /// Files next to a PS2 dump that ARMSX2 loads with it (`<base>.NVM`, …).
    private nonisolated static func sideFiles(of dump: URL) -> [URL] {
        let directory = dump.deletingLastPathComponent()
        let base = dump.deletingPathExtension().lastPathComponent.lowercased()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
        return names.map { directory.appending(path: $0) }.filter { url in
            url.deletingPathExtension().lastPathComponent.lowercased() == base
                && PS2BIOS.sideFileExtensions.contains(url.pathExtension.lowercased())
        }
    }

    /// Compares URLs from the folder enumerator with ones built from a directory.
    private nonisolated static func pathKey(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path(percentEncoded: false)
    }

    /// Folders are imported recursively.
    private nonisolated static func expand(_ urls: [URL]) -> [URL] {
        urls.flatMap { url -> [URL] in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory) else { return [] }
            guard isDirectory.boolValue else { return [url] }
            let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                                                            options: [.skipsHiddenFiles])
            return (enumerator?.allObjects as? [URL] ?? []).filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
        }
    }

    private nonisolated static func resolveCaseInsensitive(_ url: URL) -> URL? {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path(percentEncoded: false)) { return url }
        let directory = url.deletingLastPathComponent()
        let name = url.lastPathComponent.lowercased()
        let match = (try? fm.contentsOfDirectory(atPath: directory.path(percentEncoded: false)))?.first { $0.lowercased() == name }
        return match.map { directory.appending(path: $0) }
    }

    private nonisolated static func md5(of url: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false)),
              let size = attributes[.size] as? Int, size <= 64 << 20,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
