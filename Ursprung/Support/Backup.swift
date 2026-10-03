// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Where Ursprung keeps the data a backup contains.
nonisolated struct DataLocations: Sendable {
    var saves: URL
    var states: URL
    var media: URL

    static var standard: DataLocations {
        DataLocations(saves: AppPaths.saves, states: AppPaths.states, media: AppPaths.media)
    }
}

/// One game of the library as written to a backup.
nonisolated struct GameRecord: Codable, Sendable, Hashable {
    var id: UUID
    var path: String
    var systemID: String
    var title: String
    var fileName: String
    var fileSize: Int64
    var crc32: String?
    var fileModified: Date?
    var dateAdded: Date
    var lastPlayed: Date?
    var playCount: Int
    var playTime: Double
    var isFavorite: Bool
    var coreID: String?
    var missingSince: Date?
    var scrapeState: String
    var screenScraperID: String?
    var overview: String?
    var developer: String?
    var publisher: String?
    var genre: String?
    var releaseDate: String?
    var players: String?
    var rating: Double?
    var boxArtFile: String?
    var screenshotFile: String?
    var titleScreenFile: String?
    var logoFile: String?
    var fanartFile: String?
    // Added with schema version 3; optional so older backups still decode.
    var systemOverride: String?
    var lockedFields: String?
    var isHidden: Bool?
    var coreOptions: Data?
    var inputProfile: Data?
    // Added with schema version 4.
    var collections: [String]?
    var playStatus: String?
    var isPreferredVariant: Bool?

    var saveBaseName: String { (fileName as NSString).deletingPathExtension }
}

/// `manifest.json`: identifies a backup and lists every file in it, so an
/// incomplete or damaged backup is noticed before anything is restored.
nonisolated struct BackupManifest: Codable, Sendable {
    static let formatName = "ursprung-backup"
    static let currentVersion = 1

    struct Entry: Codable, Sendable, Hashable {
        var path: String
        var size: Int64
    }

    var format = BackupManifest.formatName
    var version = BackupManifest.currentVersion
    var created: Date
    var appVersion: String
    var gameCount: Int
    var files: [Entry]
}

/// A backup is a zip archive with one folder:
///
///     Ursprung Backup/
///       manifest.json    format, version, date and every file with its size
///       library.json     the games (`GameRecord`)
///       settings.plist   preferences (no passwords: those stay in the keychain)
///       Saves/           battery saves and core save folders
///       States/          save states with their manifests
///       Media/           artwork
///
/// BIOS files and cores are not included. See docs/SAVES.md.
nonisolated enum Backup {
    static let folderName = "Ursprung Backup"

    enum BackupError: LocalizedError {
        case notABackup
        case newerVersion
        case incomplete(missing: Int)
        case damaged(Error)

        var errorDescription: String? {
            switch self {
            case .notABackup: String(localized: "The file is not an Ursprung backup.")
            case .newerVersion: String(localized: "The backup was made by a newer version of Ursprung. Update Ursprung to restore it.")
            case .incomplete(let missing): String(localized: "The backup is incomplete: \(missing) files are missing or have the wrong size. Nothing was restored.")
            case .damaged(let error): String(localized: "The backup is damaged. Nothing was restored. \(error.localizedDescription)")
            }
        }
    }

    // MARK: Creating

    /// Writes a backup of `records`, `settings` and the data folders to
    /// `destination`. The archive is assembled next to the destination and
    /// only replaces it when complete.
    static func create(records: [GameRecord], settings: Data, locations: DataLocations, destination: URL,
                       appVersion: String, created: Date = .now) throws {
        let fileManager = FileManager.default
        let staging = fileManager.temporaryDirectory.appending(path: "UrsprungBackup-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fileManager.removeItem(at: staging) }
        let root = staging.appending(path: folderName, directoryHint: .isDirectory)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        try recordEncoder.encode(records).write(to: root.appending(path: "library.json"))
        try settings.write(to: root.appending(path: "settings.plist"))
        for (name, source) in [("Saves", locations.saves), ("States", locations.states), ("Media", locations.media)]
        where fileManager.fileExists(atPath: source.path(percentEncoded: false)) {
            // Clones on APFS: instant and without extra space.
            try fileManager.copyItem(at: source, to: root.appending(path: name, directoryHint: .isDirectory))
        }
        let entries = FileMerge.files(below: root)
            .filter { $0.components.last != ".DS_Store" }
            .map { file in
                BackupManifest.Entry(path: file.components.joined(separator: "/"),
                                     size: Int64((try? file.url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0))
            }
        let manifest = BackupManifest(created: created, appVersion: appVersion, gameCount: records.count, files: entries)
        try encoder.encode(manifest).write(to: root.appending(path: "manifest.json"))

        try zip(root, to: destination)
    }

    /// Zips `folder` (the archive contains the folder itself) into `destination`.
    private static func zip(_ folder: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        let partial = destination.deletingLastPathComponent().appending(path: ".\(destination.lastPathComponent).partial")
        try? fileManager.removeItem(at: partial)
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: .forUploading, error: &coordinationError) { archive in
            do { try fileManager.copyItem(at: archive, to: partial) } catch { copyError = error }
        }
        if let error = coordinationError ?? copyError {
            try? fileManager.removeItem(at: partial)
            throw error
        }
        do {
            if fileManager.fileExists(atPath: destination.path(percentEncoded: false)) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: partial)
            } else {
                try fileManager.moveItem(at: partial, to: destination)
            }
        } catch {
            try? fileManager.removeItem(at: partial)
            throw error
        }
    }

    // MARK: Opening

    /// An extracted, verified backup. `remove()` deletes the extracted files.
    struct Contents: Sendable {
        let manifest: BackupManifest
        let records: [GameRecord]
        let settings: Data?
        /// The extracted backup folder (with manifest.json).
        let root: URL
        /// The temporary folder that holds `root`.
        let temporary: URL

        var batterySaveCount: Int { count(in: "Saves") { _ in true } }
        var stateCount: Int { count(in: "States") { $0.hasSuffix(".state") } }

        func remove() {
            try? FileManager.default.removeItem(at: temporary)
        }

        private func count(in folder: String, where include: (String) -> Bool) -> Int {
            manifest.files.filter { $0.path.hasPrefix(folder + "/") && include($0.path) }.count
        }
    }

    /// Extracts and checks the backup at `archive`. Throws when it is not a
    /// backup, comes from a newer version, or misses or garbles any file it
    /// lists; nothing has been restored at that point.
    static func open(_ archive: URL) throws -> Contents {
        let fileManager = FileManager.default
        let temporary = fileManager.temporaryDirectory.appending(path: "UrsprungRestore-\(UUID().uuidString)", directoryHint: .isDirectory)
        do {
            let zip: ZipArchive
            do { zip = try ZipArchive(url: archive) } catch { throw BackupError.notABackup }
            guard zip.files.contains(where: { $0.fileName == "manifest.json" }) else { throw BackupError.notABackup }
            do { try zip.extractAll(to: temporary) } catch { throw BackupError.damaged(error) }

            guard let root = manifestFolder(in: temporary),
                  let manifest = try? decoder.decode(BackupManifest.self, from: Data(contentsOf: root.appending(path: "manifest.json"))),
                  manifest.format == BackupManifest.formatName else { throw BackupError.notABackup }
            guard manifest.version <= BackupManifest.currentVersion else { throw BackupError.newerVersion }

            let missing = manifest.files.filter { entry in
                let url = root.appending(path: entry.path)
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
                return size.map(Int64.init) != entry.size
            }
            guard missing.isEmpty else { throw BackupError.incomplete(missing: missing.count) }

            let records: [GameRecord]
            do {
                records = try JSONDecoder().decode([GameRecord].self, from: Data(contentsOf: root.appending(path: "library.json")))
            } catch {
                throw BackupError.damaged(error)
            }
            let settings = try? Data(contentsOf: root.appending(path: "settings.plist"))
            return Contents(manifest: manifest, records: records, settings: settings, root: root, temporary: temporary)
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    /// The folder with manifest.json: the extraction folder or its one sub folder.
    private static func manifestFolder(in directory: URL) -> URL? {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: directory.appending(path: "manifest.json").path(percentEncoded: false)) { return directory }
        let children = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return children.first { fileManager.fileExists(atPath: $0.appending(path: "manifest.json").path(percentEncoded: false)) }
    }

    // MARK: Restoring

    /// What the library knows about a game, to match backup records against.
    struct ExistingGame: Sendable {
        let id: UUID
        let path: String
        let systemID: String
        let crc32: String?
        let fileName: String
        let fileSize: Int64
    }

    /// Where a backup record goes.
    struct Target: Sendable, Equatable {
        /// The library entry that receives the record's data.
        let id: UUID
        /// True when the record becomes a new library entry.
        let isNew: Bool
    }

    /// Matches every record to a game of the library: the same entry (ID),
    /// the same file (path), or the same game by unique checksum or unique
    /// file name and size. Unmatched records become new entries, keeping their
    /// ID where it is free.
    static func plan(records: [GameRecord], existing: [ExistingGame]) -> [UUID: Target] {
        var available = existing
        let existingIDs = Set(existing.map(\.id))
        let ownerOfPath = Dictionary(existing.map { ($0.path, $0.id) }, uniquingKeysWith: { first, _ in first })
        var plan: [UUID: Target] = [:]

        func claim(_ predicate: (ExistingGame) -> Bool, unique: Bool) -> UUID? {
            let found = available.filter(predicate)
            guard let first = found.first, !unique || found.count == 1 else { return nil }
            available.removeAll { $0.id == first.id }
            return first.id
        }

        var unmatched: [GameRecord] = []
        for record in records {
            if let id = claim({ $0.id == record.id }, unique: false) ?? claim({ $0.path == record.path }, unique: false) {
                plan[record.id] = Target(id: id, isNew: false)
            } else {
                unmatched.append(record)
            }
        }
        for record in unmatched {
            let crc = record.crc32
            let id = crc.flatMap { crc in
                claim({ $0.systemID == record.systemID && $0.crc32?.caseInsensitiveCompare(crc) == .orderedSame }, unique: true)
            } ?? claim({ $0.systemID == record.systemID && $0.fileName == record.fileName && $0.fileSize == record.fileSize }, unique: true)
            if let id {
                plan[record.id] = Target(id: id, isNew: false)
            } else if let owner = ownerOfPath[record.path] {
                // The file is in the library under an entry that another record
                // already claimed; both records add to it.
                plan[record.id] = Target(id: owner, isNew: false)
            } else {
                plan[record.id] = Target(id: existingIDs.contains(record.id) ? UUID() : record.id, isNew: true)
            }
        }
        return plan
    }

    /// A battery save that has to take the name of the game it joins.
    struct Rename: Sendable {
        let systemID: String
        let recordID: UUID
        let from: String
        let to: String
    }

    /// Restores the backup's files for `plan`. Saves and states are merged
    /// without losing any file (see `FileMerge`); artwork only fills in what
    /// is missing. The extracted files are moved, not copied.
    static func restoreFiles(of contents: Contents, plan: [UUID: Target], renames: [Rename],
                             locations: DataLocations, now: Date = .now) throws -> FileMerge.Report {
        let fileManager = FileManager.default
        let ids = Dictionary(plan.map { ($0.key.uuidString, $0.value.id.uuidString) }, uniquingKeysWith: { first, _ in first })
        let mapComponent = { (component: String) in ids[component] ?? component }

        // A save named after the record's file takes the name of the game it joins.
        for rename in renames where rename.from != rename.to {
            let folder = contents.root.appending(path: "Saves").appending(path: rename.systemID)
                .appending(path: rename.recordID.uuidString, directoryHint: .isDirectory)
            for ext in ["srm", "rtc"] {
                let source = folder.appending(path: "\(rename.from).\(ext)")
                let target = folder.appending(path: "\(rename.to).\(ext)")
                if fileManager.fileExists(atPath: source.path(percentEncoded: false)),
                   !fileManager.fileExists(atPath: target.path(percentEncoded: false)) {
                    try fileManager.moveItem(at: source, to: target)
                }
            }
        }

        let labels = FileMerge.Labels(existing: String(localized: "before restore \(FileMerge.stamp(now))"),
                                      incoming: String(localized: "from backup \(FileMerge.stamp(contents.manifest.created))"))
        var report = FileMerge.Report()
        for (name, destination) in [("Saves", locations.saves), ("States", locations.states)] {
            let source = contents.root.appending(path: name, directoryHint: .isDirectory)
            guard fileManager.fileExists(atPath: source.path(percentEncoded: false)) else { continue }
            report = report + (try FileMerge.mergeDirectory(source, into: destination, moving: true, labels: labels,
                                                            mapComponent: mapComponent))
        }
        let media = contents.root.appending(path: "Media", directoryHint: .isDirectory)
        for (file, components) in FileMerge.files(below: media) {
            var target = locations.media
            for component in components { target = target.appending(path: mapComponent(component)) }
            guard !fileManager.fileExists(atPath: target.path(percentEncoded: false)) else { continue }
            try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.moveItem(at: file, to: target)
        }
        return report
    }

    /// Dates as numbers: exact, so a restored modification date still equals the file's.
    private static var recordEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
