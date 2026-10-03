// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The user's own collections, such as “Couch Co-op”. Each game lists the
/// collections it belongs to; Preferences keep the sidebar order and
/// collections that are empty for now.
struct LibraryCollections {
    var load: () -> [String] = { Preferences.collections }
    var save: ([String]) -> Void = { Preferences.collections = $0 }

    /// Every collection: the stored order first, then names only games know
    /// (e.g. from a restored backup), alphabetically.
    func all(in games: [Game]) -> [String] {
        let stored = load()
        let extra = Set(games.flatMap(\.collections)).subtracting(stored)
        return stored + extra.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// `name` cleaned up for use as a collection name, or nil when it is
    /// empty or another collection already has it (ignoring case).
    static func validName(_ name: String, existing: [String], renaming current: String? = nil) -> String? {
        let cleaned = name.components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else { return nil }
        let taken = existing.contains { $0 != current && $0.caseInsensitiveCompare(cleaned) == .orderedSame }
        return taken ? nil : cleaned
    }

    /// Creates a collection with `games` in it; returns its name, or nil
    /// when the name is not valid.
    @discardableResult
    func create(_ name: String, with games: [Game] = [], library: [Game]) -> String? {
        let existing = all(in: library)
        guard let name = Self.validName(name, existing: existing) else { return nil }
        save(existing + [name])
        Self.add(games, to: name)
        return name
    }

    @discardableResult
    func rename(_ old: String, to new: String, library: [Game]) -> String? {
        let existing = all(in: library)
        guard let name = Self.validName(new, existing: existing, renaming: old) else { return nil }
        guard name != old else { return name }
        save(existing.map { $0 == old ? name : $0 })
        for game in library where game.collections.contains(old) {
            game.collections = game.collections.map { $0 == old ? name : $0 }
        }
        return name
    }

    /// Removes the collection; its games stay in the library.
    func delete(_ name: String, library: [Game]) {
        save(all(in: library).filter { $0 != name })
        Self.remove(library, from: name)
    }

    /// Puts the collections in a new order.
    func move(fromOffsets offsets: IndexSet, toOffset destination: Int, library: [Game]) {
        let names = all(in: library)
        let moving = offsets.map { names[$0] }
        var remaining = names.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
        remaining.insert(contentsOf: moving, at: destination - offsets.count { $0 < destination })
        save(remaining)
    }

    static func add(_ games: [Game], to name: String) {
        for game in games where !game.collections.contains(name) {
            game.collections.append(name)
        }
    }

    static func remove(_ games: [Game], from name: String) {
        for game in games where game.collections.contains(name) {
            game.collections.removeAll { $0 == name }
        }
    }
}

extension PlayStatus {
    var title: String {
        switch self {
        case .upNext: String(localized: "Up Next")
        case .playing: String(localized: "Playing")
        case .completed: String(localized: "Completed")
        case .abandoned: String(localized: "Abandoned")
        }
    }

    var symbol: String {
        switch self {
        case .upNext: "bookmark"
        case .playing: "gamecontroller"
        case .completed: "checkmark.seal"
        case .abandoned: "xmark.circle"
        }
    }
}
