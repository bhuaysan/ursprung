// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import SwiftData

nonisolated enum ScrapeState: String, Codable, Sendable {
    case pending, matched, notFound, failed
}

/// A game in the library. Metadata and artwork come from ScreenScraper.
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
    var dateAdded: Date
    var lastPlayed: Date?
    var playCount: Int
    var playTime: Double
    var isFavorite: Bool
    /// Per-game core override (nil = system default).
    var coreID: String?

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
