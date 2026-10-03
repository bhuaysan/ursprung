// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import SwiftData

/// The library's schema history. Every change to `Game` adds a version here
/// and a stage to `LibraryMigrationPlan`, so a library written by an earlier
/// release opens instead of failing.
///
/// A frozen version keeps an exact copy of the model as it shipped: SwiftData
/// recognises a store by the hash of its model, and any difference in the
/// copy (a property, a type, an attribute option) makes the old store
/// unrecognisable.
enum LibrarySchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    static var models: [any PersistentModel.Type] { [Game.self] }

    /// `Game` as it shipped until October 2026. Do not change.
    @Model
    final class Game {
        @Attribute(.unique) var id: UUID
        @Attribute(.unique) var path: String
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

        var scrapeStateRaw: String
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
    }
}

/// Adds `Game.missingSince`: games whose file disappeared stay in the library.
enum LibrarySchemaV2: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }
    static var models: [any PersistentModel.Type] { [Game.self] }

    /// `Game` as it shipped in October 2026 (version 2). Do not change.
    @Model
    final class Game {
        @Attribute(.unique) var id: UUID
        @Attribute(.unique) var path: String
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

        var scrapeStateRaw: String
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
    }
}

/// Adds what the user can correct and configure per game: a manual system,
/// fields protected from scraping, hiding, per-game core options and
/// controls, plus incomplete artwork and missing disc tracks.
enum LibrarySchemaV3: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(3, 0, 0) }
    static var models: [any PersistentModel.Type] { [Game.self] }

    /// `Game` as it shipped in October 2026 (version 3). Do not change.
    @Model
    final class Game {
        @Attribute(.unique) var id: UUID
        @Attribute(.unique) var path: String
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
        var systemOverride: String?
        var lockedFieldsRaw: String?
        var isHidden: Bool = false
        var mediaIncomplete: Bool = false
        var missingTracksRaw: String?
        var coreOptionsData: Data?
        var inputProfileData: Data?

        var scrapeStateRaw: String
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
    }
}

/// Adds how the user organises the library: collections, a play status and
/// the preferred version among a game's variants.
enum LibrarySchemaV4: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(4, 0, 0) }
    static var models: [any PersistentModel.Type] { [Game.self] }
}

enum LibraryMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [LibrarySchemaV1.self, LibrarySchemaV2.self, LibrarySchemaV3.self, LibrarySchemaV4.self]
    }
    static var stages: [MigrationStage] {
        [.lightweight(fromVersion: LibrarySchemaV1.self, toVersion: LibrarySchemaV2.self),
         .lightweight(fromVersion: LibrarySchemaV2.self, toVersion: LibrarySchemaV3.self),
         .lightweight(fromVersion: LibrarySchemaV3.self, toVersion: LibrarySchemaV4.self)]
    }
}

extension ModelContainer {
    /// The library container in its current schema, migrating older stores.
    static func library(configuration: ModelConfiguration) throws -> ModelContainer {
        try ModelContainer(for: Schema(versionedSchema: LibrarySchemaV4.self),
                           migrationPlan: LibraryMigrationPlan.self,
                           configurations: configuration)
    }
}
