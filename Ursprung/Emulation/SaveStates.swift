// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Where a save state came from. Written next to every state as
/// `slotN.json`; see docs/SAVES.md.
nonisolated struct SaveStateManifest: Codable, Sendable, Hashable {
    static let currentFormat = 1

    var format = SaveStateManifest.currentFormat
    var coreID: String
    var coreVersion: String
    /// The ROM the state was made from, to notice a replaced file.
    var gameCRC32: String?
    var gameFileName: String
    var gameFileSize: Int64
    var created: Date
    /// A name the user gave the state, e.g. “Before the final boss”.
    var name: String?
}

/// What the running game looks like now, to compare a state's manifest with.
nonisolated struct SaveStateContext: Sendable, Hashable {
    let coreID: String
    let coreVersion: String
    let gameCRC32: String?
    let gameFileName: String
    let gameFileSize: Int64

    func manifest(created: Date = .now) -> SaveStateManifest {
        SaveStateManifest(coreID: coreID, coreVersion: coreVersion, gameCRC32: gameCRC32, gameFileName: gameFileName,
                          gameFileSize: gameFileSize, created: created)
    }
}

/// Reasons a state may not load, or may load into a different game.
nonisolated enum SaveStateIssue: Sendable, Hashable {
    /// Saved by Ursprung before states were kept per core: the core is unknown.
    case unknownOrigin
    /// Saved with another version of the same core.
    case coreVersion(String)
    /// Saved from a different file (another revision, a replaced ROM).
    case differentGameFile
}

/// A save state on disk: in a slot, the automatic state, or one that a
/// newer state replaced (history).
nonisolated struct SaveStateSlot: Identifiable, Hashable, Sendable {
    let slot: Int
    let date: Date
    let stateURL: URL
    let thumbnailURL: URL
    let manifestURL: URL
    /// nil for states from earlier versions.
    var manifest: SaveStateManifest?
    /// Found in the game's folder instead of the core's (earlier versions).
    var isLegacy = false
    /// For states in the history: when they were replaced or deleted.
    var replaced: Date?
    var id: String { stateURL.path(percentEncoded: false) }

    var name: String? { manifest?.name }
    var isAutosave: Bool { slot == SaveStateStore.autosaveSlot }
    var isHistory: Bool { replaced != nil }
    /// Only states with a manifest can be named; others are of unknown origin.
    var canRename: Bool { manifest != nil && !isLegacy }

    /// “Slot 3”, “Quick Save” or “Automatic State”, for lists.
    var slotTitle: String {
        switch slot {
        case SaveStateStore.autosaveSlot: String(localized: "Automatic State")
        case 0: String(localized: "Quick Save")
        default: String(localized: "Slot \(slot)")
        }
    }

    func issues(for context: SaveStateContext) -> [SaveStateIssue] {
        guard let manifest else { return [.unknownOrigin] }
        var issues: [SaveStateIssue] = []
        if manifest.coreVersion != context.coreVersion { issues.append(.coreVersion(manifest.coreVersion)) }
        let sameFile: Bool = if let saved = manifest.gameCRC32, let current = context.gameCRC32 {
            saved.caseInsensitiveCompare(current) == .orderedSame
        } else {
            manifest.gameFileSize == context.gameFileSize
        }
        if !sameFile { issues.append(.differentGameFile) }
        return issues
    }
}

/// Save states live at `<states>/<game id>/<core id>/slotN.state`, with a
/// thumbnail (`slotN.png`) and a manifest (`slotN.json`). States are specific
/// to a core, so every core has its own slots and switching cores never
/// overwrites another core's states.
///
/// Earlier versions kept states directly in `<states>/<game id>/` without
/// recording the core. Those stay where they are and show up for a slot that
/// the current core has not used, marked as of unknown origin.
nonisolated enum SaveStateStore {
    static let slotRange = 0...9

    static func gameDirectory(in states: URL, gameID: UUID) -> URL {
        states.appending(path: gameID.uuidString, directoryHint: .isDirectory)
    }

    static func directory(in states: URL, gameID: UUID, coreID: String) -> URL {
        gameDirectory(in: states, gameID: gameID).appending(path: coreID, directoryHint: .isDirectory)
    }

    static func slots(in states: URL, gameID: UUID, coreID: String) -> [SaveStateSlot] {
        let coreDirectory = directory(in: states, gameID: gameID, coreID: coreID)
        let legacyDirectory = gameDirectory(in: states, gameID: gameID)
        return slotRange.compactMap { slot in
            if var found = slotFile(slot, in: coreDirectory) {
                found.manifest = readManifest(found.manifestURL)
                return found
            }
            guard var legacy = slotFile(slot, in: legacyDirectory) else { return nil }
            legacy.isLegacy = true
            return legacy
        }
    }

    /// The state that a save into `slot` writes for `coreID`.
    static func stateURL(in states: URL, gameID: UUID, coreID: String, slot: Int) -> URL {
        directory(in: states, gameID: gameID, coreID: coreID).appending(path: "slot\(slot).state")
    }

    /// Writes a state and its manifest. The state it replaces goes into the
    /// history, but only once the new one is safely on disk: a failed write
    /// leaves the slot as it was.
    static func write(_ data: Data, manifest: SaveStateManifest, slot: Int, in directory: URL, date: Date = .now) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pending = directory.appending(path: ".slot\(slot)-\(UUID().uuidString).state")
        defer { try? FileManager.default.removeItem(at: pending) }
        try data.write(to: pending)
        try archive(slot: slot, in: directory, date: date)
        let name = "slot\(slot)"
        try FileManager.default.moveItem(at: pending, to: directory.appending(path: "\(name).state"))
        try encoder.encode(manifest).write(to: directory.appending(path: "\(name).json"), options: .atomic)
    }

    private static func write(_ data: Data, manifest: SaveStateManifest, name: String, in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appending(path: "\(name).state"), options: .atomic)
        try encoder.encode(manifest).write(to: directory.appending(path: "\(name).json"), options: .atomic)
    }

    /// The automatic state saved when a game stops: `autosave.state` in the
    /// core's folder, apart from the numbered slots.
    static let autosaveSlot = -1

    static func autosave(in states: URL, gameID: UUID, coreID: String) -> SaveStateSlot? {
        let directory = directory(in: states, gameID: gameID, coreID: coreID)
        guard var found = slotFile(named: "autosave", slot: autosaveSlot, in: directory) else { return nil }
        found.manifest = readManifest(found.manifestURL)
        return found
    }

    /// Writes the automatic state. Like a slot, a failed write keeps the previous one.
    static func writeAutosave(_ data: Data, manifest: SaveStateManifest, in directory: URL) throws {
        try write(data, manifest: manifest, name: "autosave", in: directory)
    }

    /// Removes a state for good.
    static func delete(_ slot: SaveStateSlot) {
        for url in [slot.stateURL, slot.thumbnailURL, slot.manifestURL] {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Deletes a state the way the user does: a slot's state goes into the
    /// history, where it can be restored; a state in the history is removed.
    /// A slot's state that can't go into the history stays.
    static func discard(_ state: SaveStateSlot, date: Date = .now) throws {
        guard !state.isHistory, !state.isLegacy, !state.isAutosave else { return delete(state) }
        try archive(slot: state.slot, in: state.stateURL.deletingLastPathComponent(), date: date)
    }

    /// Names a state, or removes its name with nil or an empty name.
    static func rename(_ state: SaveStateSlot, to name: String?) throws {
        guard var manifest = state.manifest else { return }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        manifest.name = trimmed?.isEmpty == false ? trimmed : nil
        try encoder.encode(manifest).write(to: state.manifestURL, options: .atomic)
    }

    // MARK: History

    /// States replaced or deleted per game and core that are kept; older ones go.
    static let historyLimit = 20

    static func historyDirectory(_ coreDirectory: URL) -> URL {
        coreDirectory.appending(path: "History", directoryHint: .isDirectory)
    }

    /// Moves the state in `slot` (if any) into the history as
    /// `History/<time>-slotN.*`.
    static func archive(slot: Int, in directory: URL, date: Date = .now) throws {
        let name = "slot\(slot)"
        let state = directory.appending(path: "\(name).state")
        guard FileManager.default.fileExists(atPath: state.path(percentEncoded: false)) else { return }
        let history = historyDirectory(directory)
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
        let stamp = historyStamp(date)
        for ext in ["state", "png", "json"] {
            let source = directory.appending(path: "\(name).\(ext)")
            guard FileManager.default.fileExists(atPath: source.path(percentEncoded: false)) else { continue }
            let destination = history.appending(path: "\(stamp)-\(name).\(ext)")
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: source, to: destination)
        }
        pruneHistory(in: directory)
    }

    /// The replaced and deleted states of a game for a core, newest first.
    static func history(in states: URL, gameID: UUID, coreID: String) -> [SaveStateSlot] {
        history(inCoreDirectory: directory(in: states, gameID: gameID, coreID: coreID))
    }

    static func history(inCoreDirectory directory: URL) -> [SaveStateSlot] {
        let history = historyDirectory(directory)
        let files = (try? FileManager.default.contentsOfDirectory(at: history, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "state" }.compactMap { url -> SaveStateSlot? in
            let base = url.deletingPathExtension().lastPathComponent
            guard let dash = base.lastIndex(of: "-"),
                  let replaced = historyDate(String(base[..<dash])),
                  let slot = Int(base[base.index(after: dash)...].dropFirst("slot".count)),
                  var found = slotFile(named: base, slot: slot, in: history) else { return nil }
            found.manifest = readManifest(found.manifestURL)
            found.replaced = replaced
            return found
        }
        .sorted { $0.replaced! > $1.replaced! }
    }

    /// Puts a state from the history back into `slot`. The state there now
    /// goes into the history in turn.
    static func restore(_ entry: SaveStateSlot, toSlot slot: Int, in directory: URL, date: Date = .now) throws {
        let data = try Data(contentsOf: entry.stateURL)
        try archive(slot: slot, in: directory, date: date)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appending(path: "slot\(slot).state"), options: .atomic)
        for (source, ext) in [(entry.thumbnailURL, "png"), (entry.manifestURL, "json")] {
            let destination = directory.appending(path: "slot\(slot).\(ext)")
            try? FileManager.default.removeItem(at: destination)
            try? FileManager.default.copyItem(at: source, to: destination)
        }
        delete(entry)
    }

    private static func pruneHistory(in directory: URL) {
        for entry in history(inCoreDirectory: directory).dropFirst(historyLimit) { delete(entry) }
    }

    private static func historyStamp(_ date: Date) -> String {
        String(Int64((date.timeIntervalSince1970 * 1000).rounded()))
    }

    private static func historyDate(_ stamp: String) -> Date? {
        Int64(stamp).map { Date(timeIntervalSince1970: Double($0) / 1000) }
    }

    // MARK: All states of a game

    /// The states of one core, for the library's save state browser.
    struct CoreStates: Identifiable, Sendable {
        /// nil for states of unknown origin (earlier versions).
        let coreID: String?
        var autosave: SaveStateSlot?
        var slots: [SaveStateSlot]
        var history: [SaveStateSlot]
        var id: String { coreID ?? "" }
        var isEmpty: Bool { autosave == nil && slots.isEmpty && history.isEmpty }
    }

    /// Every state of a game, per core; states of unknown origin last.
    static func allStates(in states: URL, gameID: UUID) -> [CoreStates] {
        let gameDirectory = gameDirectory(in: states, gameID: gameID)
        let entries = (try? FileManager.default.contentsOfDirectory(at: gameDirectory, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        var result: [CoreStates] = []
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            let coreID = entry.lastPathComponent
            let slots = slotRange.compactMap { slot -> SaveStateSlot? in
                guard var found = slotFile(slot, in: entry) else { return nil }
                found.manifest = readManifest(found.manifestURL)
                return found
            }
            let core = CoreStates(coreID: coreID, autosave: autosave(in: states, gameID: gameID, coreID: coreID),
                                  slots: slots, history: history(inCoreDirectory: entry))
            if !core.isEmpty { result.append(core) }
        }
        let legacy = slotRange.compactMap { slot -> SaveStateSlot? in
            guard var found = slotFile(slot, in: gameDirectory) else { return nil }
            found.isLegacy = true
            return found
        }
        if !legacy.isEmpty { result.append(CoreStates(coreID: nil, slots: legacy, history: [])) }
        return result
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    static func readManifest(_ url: URL) -> SaveStateManifest? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SaveStateManifest.self, from: data)
    }

    private static func slotFile(_ slot: Int, in directory: URL) -> SaveStateSlot? {
        slotFile(named: "slot\(slot)", slot: slot, in: directory)
    }

    private static func slotFile(named name: String, slot: Int, in directory: URL) -> SaveStateSlot? {
        let state = directory.appending(path: "\(name).state")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: state.path(percentEncoded: false)),
              let date = attributes[.modificationDate] as? Date else { return nil }
        return SaveStateSlot(slot: slot, date: date, stateURL: state,
                             thumbnailURL: directory.appending(path: "\(name).png"),
                             manifestURL: directory.appending(path: "\(name).json"))
    }
}
