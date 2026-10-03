// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import os
import SwiftData

/// The games of a library grouped into versions of the same game. Built
/// from the games in view; grouping shows one card per game.
struct VariantGroups {
    private var keys: [PersistentIdentifier: String] = [:]
    private var members: [String: [Game]] = [:]
    private let regionOrder: [String]
    private let languageCode: String

    init(_ games: [Game],
         regionOrder: [String] = VariantGrouping.regionOrder(scraperRegion: Preferences.scraperRegion,
                                                             languageCode: VariantGroups.languageCode),
         languageCode: String = VariantGroups.languageCode) {
        self.regionOrder = regionOrder
        self.languageCode = languageCode
        for game in games {
            let key = VariantGrouping.key(systemID: game.systemID, info: game.variantInfo)
            keys[game.persistentModelID] = key
            members[key, default: []].append(game)
        }
    }

    static var languageCode: String { Locale.current.language.languageCode?.identifier ?? "en" }

    /// Every version of `game`, the shown one first; just the game when it has no others.
    func versions(of game: Game) -> [Game] {
        guard let key = keys[game.persistentModelID], let group = members[key], group.count > 1 else { return [game] }
        let shown = representative(of: group)
        return [shown] + group.filter { $0 !== shown }.sorted {
            $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending
        }
    }

    func versionCount(of game: Game) -> Int {
        keys[game.persistentModelID].flatMap { members[$0]?.count } ?? 1
    }

    /// One game per group, in the order of `games`: the version the user
    /// chose, else the one played last, else the best match for their region.
    func collapse(_ games: [Game]) -> [Game] {
        var candidates: [String: [Game]] = [:]
        for game in games {
            guard let key = keys[game.persistentModelID] else { continue }
            candidates[key, default: []].append(game)
        }
        var shown = Set<ObjectIdentifier>()
        for group in candidates.values {
            shown.insert(ObjectIdentifier(representative(of: group)))
        }
        return games.filter { keys[$0.persistentModelID] == nil || shown.contains(ObjectIdentifier($0)) }
    }

    func representative(of group: [Game]) -> Game {
        if let chosen = group.first(where: \.isPreferredVariant) { return chosen }
        if let played = group.filter({ $0.lastPlayed != nil }).max(by: { $0.lastPlayed! < $1.lastPlayed! }) {
            return played
        }
        return group.max { lhs, rhs in
            let left = VariantGrouping.score(lhs.variantInfo, regionOrder: regionOrder, languageCode: languageCode)
            let right = VariantGrouping.score(rhs.variantInfo, regionOrder: regionOrder, languageCode: languageCode)
            if left != right { return left.lexicographicallyPrecedes(right) }
            // Stable among equals: the shorter, then alphabetically first name wins.
            return (lhs.fileName.count, lhs.fileName) > (rhs.fileName.count, rhs.fileName)
        } ?? group[0]
    }

    /// Makes `game` the version shown for its group.
    func prefer(_ game: Game) {
        for version in versions(of: game) {
            version.isPreferredVariant = version === game
        }
    }
}

extension Game {
    /// What the file name says about this version of the game.
    var variantInfo: VariantInfo { VariantInfoCache.info(for: fileName) }

    /// The version's description, falling back to the file name.
    var variantLabel: String {
        let label = variantInfo.label
        return label.isEmpty ? fileName : label
    }
}

/// Parsing file names on every redraw of a large library is slow; names do
/// not change their meaning, so results are kept.
nonisolated private enum VariantInfoCache {
    private static let cache = OSAllocatedUnfairLock(initialState: [String: VariantInfo]())

    static func info(for fileName: String) -> VariantInfo {
        if let info = cache.withLock({ $0[fileName] }) { return info }
        let info = VariantInfo.parse(fileName: fileName)
        cache.withLock { $0[fileName] = info }
        return info
    }
}
