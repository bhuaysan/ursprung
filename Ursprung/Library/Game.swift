// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import SwiftData

nonisolated enum ScrapeState: String, Codable, Sendable {
    case pending, matched, notFound, failed
}

/// A game in the library. Metadata and artwork come from ScreenScraper.
///
/// The current version of the model; earlier ones are in `LibrarySchema.swift`.
/// Changing a stored property needs a new schema version there.
@Model
final class Game {
    @Attribute(.unique) var id: UUID
    /// Absolute path of the ROM / disc descriptor (.cue, .m3u, …).
    @Attribute(.unique) var path: String
    var systemID: String
    var title: String
    var fileName: String
    var fileSize: Int64
    /// CRC32 of the ROM (of the inner file for zipped cartridge games).
    var crc32: String?
    /// Modification date of the file when it was last scanned; a change
    /// invalidates `crc32`.
    var fileModified: Date?
    var dateAdded: Date
    var lastPlayed: Date?
    var playCount: Int
    var playTime: Double
    var isFavorite: Bool
    /// Per-game core override (nil = system default).
    var coreID: String?
    /// When a scan last found the file gone. The game stays in the library
    /// with its favourite, play time and saves until the user locates the
    /// file or removes the game; a later scan that finds it clears the date.
    var missingSince: Date?

    // Metadata
    var scrapeStateRaw: String
    var screenScraperID: String?
    var overview: String?
    var developer: String?
    var publisher: String?
    var genre: String?
    var releaseDate: String?
    var players: String?
    /// 0…1
    var rating: Double?

    // Artwork, file names relative to `AppPaths.media/<id>/`.
    var boxArtFile: String?
    var screenshotFile: String?
    var titleScreenFile: String?
    var logoFile: String?
    var fanartFile: String?

    init(path: String, systemID: String, title: String, fileName: String, fileSize: Int64, crc32: String?) {
        self.id = UUID()
        self.path = path
        self.systemID = systemID
        self.title = title
        self.fileName = fileName
        self.fileSize = fileSize
        self.crc32 = crc32
        self.dateAdded = .now
        self.playCount = 0
        self.playTime = 0
        self.isFavorite = false
        self.scrapeStateRaw = ScrapeState.pending.rawValue
    }

    var scrapeState: ScrapeState {
        get { ScrapeState(rawValue: scrapeStateRaw) ?? .pending }
        set { scrapeStateRaw = newValue.rawValue }
    }

    var isMissing: Bool { missingSince != nil }
    var system: GameSystem? { SystemCatalog.system(withID: systemID) }
    var fileURL: URL { URL(filePath: path) }
    var mediaDirectory: URL { AppPaths.media.appending(path: id.uuidString, directoryHint: .isDirectory) }

    func mediaURL(_ file: String?) -> URL? {
        guard let file else { return nil }
        return mediaDirectory.appending(path: file)
    }

    var boxArtURL: URL? { mediaURL(boxArtFile) }
    var screenshotURL: URL? { mediaURL(screenshotFile) ?? mediaURL(titleScreenFile) }
    var logoURL: URL? { mediaURL(logoFile) }
    var fanartURL: URL? { mediaURL(fanartFile) }

    /// Year for display ("1991").
    var releaseYear: String? {
        guard let releaseDate, releaseDate.count >= 4 else { return nil }
        return String(releaseDate.prefix(4))
    }

    /// Localised release date ("24 Sept 1992"), falling back to the raw value.
    var formattedReleaseDate: String? {
        guard let releaseDate else { return nil }
        let parts = releaseDate.split(separator: "-").compactMap { Int($0) }
        var components = DateComponents()
        components.year = parts.first
        components.month = parts.count > 1 ? parts[1] : nil
        components.day = parts.count > 2 ? parts[2] : nil
        guard components.year != nil, let date = Calendar(identifier: .gregorian).date(from: components) else { return releaseDate }
        switch parts.count {
        case 3: return date.formatted(date: .abbreviated, time: .omitted)
        case 2: return date.formatted(.dateTime.month(.wide).year())
        default: return String(parts[0])
        }
    }

    /// Base name used for battery saves and save states.
    var saveBaseName: String {
        (fileName as NSString).deletingPathExtension
    }

    /// Takes over the scraped metadata and artwork of `other`, which is about
    /// to leave the library. Its artwork files move into this game's folder.
    func adoptMetadata(of other: Game) {
        title = other.title
        scrapeState = other.scrapeState
        screenScraperID = other.screenScraperID
        overview = other.overview
        developer = other.developer
        publisher = other.publisher
        genre = other.genre
        releaseDate = other.releaseDate
        players = other.players
        rating = other.rating
        let artwork: [ReferenceWritableKeyPath<Game, String?>] = [\.boxArtFile, \.screenshotFile, \.titleScreenFile, \.logoFile, \.fanartFile]
        try? FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        for keyPath in artwork {
            guard let file = other[keyPath: keyPath], let source = other.mediaURL(file) else { continue }
            let destination = mediaDirectory.appending(path: file)
            try? FileManager.default.removeItem(at: destination)
            if (try? FileManager.default.moveItem(at: source, to: destination)) != nil { self[keyPath: keyPath] = file }
        }
    }
}

extension Game {
    /// The game as written to a backup.
    var record: GameRecord {
        GameRecord(id: id, path: path, systemID: systemID, title: title, fileName: fileName, fileSize: fileSize,
                   crc32: crc32, fileModified: fileModified, dateAdded: dateAdded, lastPlayed: lastPlayed,
                   playCount: playCount, playTime: playTime, isFavorite: isFavorite, coreID: coreID,
                   missingSince: missingSince, scrapeState: scrapeStateRaw, screenScraperID: screenScraperID,
                   overview: overview, developer: developer, publisher: publisher, genre: genre,
                   releaseDate: releaseDate, players: players, rating: rating, boxArtFile: boxArtFile,
                   screenshotFile: screenshotFile, titleScreenFile: titleScreenFile, logoFile: logoFile,
                   fanartFile: fanartFile)
    }

    /// A new library entry from a backup record.
    convenience init(record: GameRecord, id: UUID) {
        self.init(path: record.path, systemID: record.systemID, title: record.title, fileName: record.fileName,
                  fileSize: record.fileSize, crc32: record.crc32)
        self.id = id
        fileModified = record.fileModified
        dateAdded = record.dateAdded
        lastPlayed = record.lastPlayed
        playCount = record.playCount
        playTime = record.playTime
        isFavorite = record.isFavorite
        coreID = record.coreID
        missingSince = record.missingSince
        adoptMetadata(of: record)
    }

    /// Adds a backup record's history to this game. Counters take the larger
    /// value rather than the sum, so restoring the same backup twice changes
    /// nothing. Metadata is taken only when this game has none.
    func restore(_ record: GameRecord) {
        isFavorite = isFavorite || record.isFavorite
        playCount = max(playCount, record.playCount)
        playTime = max(playTime, record.playTime)
        lastPlayed = [lastPlayed, record.lastPlayed].compactMap { $0 }.max()
        dateAdded = min(dateAdded, record.dateAdded)
        if coreID == nil { coreID = record.coreID }
        if scrapeState != .matched, record.scrapeState == ScrapeState.matched.rawValue {
            adoptMetadata(of: record)
        }
    }

    private func adoptMetadata(of record: GameRecord) {
        title = record.title
        scrapeStateRaw = record.scrapeState
        screenScraperID = record.screenScraperID
        overview = record.overview
        developer = record.developer
        publisher = record.publisher
        genre = record.genre
        releaseDate = record.releaseDate
        players = record.players
        rating = record.rating
        boxArtFile = record.boxArtFile
        screenshotFile = record.screenshotFile
        titleScreenFile = record.titleScreenFile
        logoFile = record.logoFile
        fanartFile = record.fanartFile
    }
}

extension ModelContext {
    /// The game with this ID, or nil when it has left the library meanwhile
    /// (rescan, folder removal). `model(for:)` would return a placeholder whose
    /// first property access traps.
    func existingGame(_ id: PersistentIdentifier) -> Game? {
        var descriptor = FetchDescriptor<Game>(predicate: #Predicate { $0.persistentModelID == id })
        descriptor.fetchLimit = 1
        return try? fetch(descriptor).first
    }
}
