// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Structured filters on top of the sidebar selection and the search: play
/// status, genre, number of players, decade, metadata and file availability.
/// Every criterion left at nil lets all games through.
nonisolated struct LibraryFilter: Equatable, Sendable {
    enum Status: Hashable, Sendable {
        /// Games without a status.
        case none
        case status(PlayStatus)
    }

    enum Players: String, CaseIterable, Identifiable, Sendable {
        case single, multiplayer, fourOrMore
        var id: String { rawValue }
    }

    enum Metadata: String, CaseIterable, Identifiable, Sendable {
        /// Matched on ScreenScraper or edited by the user, with all artwork.
        case complete
        case incomplete
        var id: String { rawValue }
    }

    enum Availability: String, CaseIterable, Identifiable, Sendable {
        case available, missing
        var id: String { rawValue }
    }

    var status: Status?
    var genre: String?
    var players: Players?
    /// First year of the decade, e.g. 1990.
    var decade: Int?
    var metadata: Metadata?
    var availability: Availability?

    var activeCount: Int {
        [status != nil, genre != nil, players != nil, decade != nil, metadata != nil, availability != nil]
            .filter { $0 }.count
    }

    var isActive: Bool { activeCount > 0 }

    /// The genres of a game's genre text: ScreenScraper joins up to two with
    /// commas; edited values may use slashes.
    static func genres(of text: String?) -> [String] {
        (text ?? "").split(whereSeparator: { $0 == "," || $0 == "/" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// The largest player count in texts like “1”, “1-2” or “1 - 4”.
    static func maximumPlayers(_ text: String?) -> Int? {
        guard let text else { return nil }
        return text.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }.max()
    }

    /// The decade of a release date (“1994-03-11” → 1990).
    static func decade(of releaseDate: String?) -> Int? {
        guard let releaseDate, let year = Int(releaseDate.prefix(4)), year > 1900 else { return nil }
        return year / 10 * 10
    }

    func matches(status gameStatus: PlayStatus?, genre gameGenre: String?, players gamePlayers: String?,
                 releaseDate: String?, hasCompleteMetadata: Bool, isMissing: Bool) -> Bool {
        switch status {
        case nil: break
        case .none?: if gameStatus != nil { return false }
        case .status(let wanted)?: if gameStatus != wanted { return false }
        }
        if let genre, !Self.genres(of: gameGenre).contains(where: { $0.caseInsensitiveCompare(genre) == .orderedSame }) {
            return false
        }
        if let players {
            guard let count = Self.maximumPlayers(gamePlayers) else { return false }
            switch players {
            case .single: if count != 1 { return false }
            case .multiplayer: if count < 2 { return false }
            case .fourOrMore: if count < 4 { return false }
            }
        }
        if let decade, Self.decade(of: releaseDate) != decade { return false }
        if let metadata, hasCompleteMetadata != (metadata == .complete) { return false }
        if let availability, isMissing != (availability == .missing) { return false }
        return true
    }
}

/// The choices a filter menu offers for the games in view.
nonisolated struct LibraryFilterOptions: Equatable, Sendable {
    var genres: [String] = []
    var decades: [Int] = []
}

extension LibraryFilter {
    func matches(_ game: Game) -> Bool {
        matches(status: game.playStatus, genre: game.genre, players: game.players, releaseDate: game.releaseDate,
                hasCompleteMetadata: game.hasCompleteMetadata, isMissing: game.isMissing)
    }

    static func options(for games: [Game]) -> LibraryFilterOptions {
        var genres: [String: String] = [:]
        var decades = Set<Int>()
        for game in games {
            // One entry per genre, however its case varies.
            for genre in Self.genres(of: game.genre) where genres[genre.lowercased()] == nil {
                genres[genre.lowercased()] = genre
            }
            if let decade = Self.decade(of: game.releaseDate) { decades.insert(decade) }
        }
        return LibraryFilterOptions(
            genres: genres.values.sorted { $0.localizedStandardCompare($1) == .orderedAscending },
            decades: decades.sorted())
    }
}

extension Game {
    /// Matched (or filled in by the user) and no artwork left to download.
    var hasCompleteMetadata: Bool {
        (scrapeState == .matched || !lockedFields.isEmpty) && !mediaIncomplete
    }
}

extension LibraryFilter.Players {
    var title: String {
        switch self {
        case .single: String(localized: "Single Player")
        case .multiplayer: String(localized: "Multiplayer")
        case .fourOrMore: String(localized: "4 or More Players")
        }
    }
}

extension LibraryFilter.Metadata {
    var title: String {
        switch self {
        case .complete: String(localized: "Complete Metadata")
        case .incomplete: String(localized: "Incomplete Metadata")
        }
    }
}

extension LibraryFilter.Availability {
    var title: String {
        switch self {
        case .available: String(localized: "Available")
        case .missing: String(localized: "File Missing")
        }
    }
}
