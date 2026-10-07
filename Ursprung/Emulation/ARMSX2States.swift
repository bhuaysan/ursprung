// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// ARMSX2's save state files in a game's state folder (docs/STANDALONE_PLAN.md, S8).
///
/// ARMSX2 names its states `<serial> (<CRC>).<NN>.p2s` for the slots and
/// `<serial> (<CRC>).resume.p2s` for the state it writes when Ursprung quits
/// it. A state is a zip whose `Screenshot.png` is the thumbnail. Ursprung adds
/// only what ARMSX2 does not keep: a name in `<state>.json` next to the state
/// (a `SaveStateManifest`), and the history of replaced states in `History/`
/// as `<time>-<state>.p2s`, like the slots of libretro cores.
nonisolated enum ARMSX2States {
    static let fileExtension = "p2s"
    private static let screenshotEntry = "Screenshot.png"
    private static let versionEntry = "PCSX2 Savestate Version.id"

    /// What a state file holds, from its name.
    enum Kind: Hashable, Sendable {
        case slot(Int)
        case resume
    }

    /// The kind of `<serial> (<CRC>).<NN>.p2s` or `….resume.p2s`. Copies kept
    /// when saves were merged (`… .03 (from backup …).p2s`) count as their
    /// slot; `.backup`, `.part` and hidden files are not states.
    static func kind(ofFileName name: String) -> Kind? {
        guard !name.hasPrefix("."), name.lowercased().hasSuffix("." + fileExtension) else { return nil }
        let stem = name.dropLast(fileExtension.count + 1)
        guard let match = stem.wholeMatch(of: #/.+\.(?<tag>\d{1,2}|resume)(?: \([^()]*\))?/#.ignoresCase()) else { return nil }
        return Int(match.tag).map(Kind.slot) ?? .resume
    }

    // MARK: Listing

    /// The states in `folder`: the newest resume state as the automatic
    /// state, everything else by slot. Resume states of another disc or
    /// merged copies of one show up among the slots.
    static func states(in folder: URL) -> (autosave: SaveStateSlot?, slots: [SaveStateSlot]) {
        var resume: [SaveStateSlot] = []
        var slots: [SaveStateSlot] = []
        for name in fileNames(in: folder) {
            guard let fileKind = kind(ofFileName: name),
                  let state = stateSlot(at: folder.appending(path: name), kind: fileKind) else { continue }
            if fileKind == .resume, !FileMerge.isLabelledCopy(state.stateURL) {
                resume.append(state)
            } else {
                slots.append(state)
            }
        }
        resume.sort { $0.date > $1.date }
        let autosave = resume.first
        slots += resume.dropFirst()
        slots.sort { lhs, rhs in
            // Slots in order, then the other resume states.
            let left = lhs.isAutosave ? Int.max : lhs.slot, right = rhs.isAutosave ? Int.max : rhs.slot
            return left == right ? lhs.date > rhs.date : left < right
        }
        return (autosave, slots)
    }

    /// The states in `folder/History`, newest first.
    static func history(in folder: URL) -> [SaveStateSlot] {
        let history = SaveStateStore.historyDirectory(folder)
        return fileNames(in: history).compactMap { name -> SaveStateSlot? in
            guard let dash = name.firstIndex(of: "-"),
                  let replaced = SaveStateStore.historyDate(String(name[..<dash])),
                  let fileKind = kind(ofFileName: String(name[name.index(after: dash)...])),
                  var state = stateSlot(at: history.appending(path: name), kind: fileKind) else { return nil }
            state.replaced = replaced
            return state
        }
        .sorted { $0.replaced! > $1.replaced! }
    }

    /// `<serial> (<CRC>).resume.p2s`, written by ARMSX2 when Ursprung quits it.
    static func resumeState(in folder: URL) -> URL? {
        fileNames(in: folder).filter { $0.hasSuffix(".resume.p2s") }
            .map { folder.appending(path: $0) }
            .max { modificationDate($0) < modificationDate($1) }
    }

    private static func stateSlot(at url: URL, kind: Kind) -> SaveStateSlot? {
        let date = modificationDate(url)
        guard date != .distantPast else { return nil }
        let manifestURL = manifestURL(for: url)
        let slot: Int = switch kind {
        case .slot(let number): number
        case .resume: SaveStateStore.autosaveSlot
        }
        return SaveStateSlot(slot: slot, date: date, stateURL: url, thumbnailURL: url, manifestURL: manifestURL,
                             manifest: manifest(at: manifestURL, forStateFrom: date))
    }

    /// `<state>.json` next to the state.
    static func manifestURL(for state: URL) -> URL {
        state.deletingPathExtension().appendingPathExtension("json")
    }

    /// The manifest, unless ARMSX2 has written a new state into the slot
    /// since: a manifest records the date of the state it names.
    private static func manifest(at url: URL, forStateFrom date: Date) -> SaveStateManifest? {
        guard let manifest = SaveStateStore.readManifest(url), abs(manifest.created.timeIntervalSince(date)) < 2 else { return nil }
        return manifest
    }

    private static func fileNames(in folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? [])
            .filter { !$0.hasPrefix(".") && $0.lowercased().hasSuffix("." + fileExtension) }
    }

    // MARK: History

    /// Moves a state and its manifest into the history.
    static func archive(_ state: SaveStateSlot, date: Date = .now) throws {
        let folder = state.stateURL.deletingLastPathComponent()
        let history = SaveStateStore.historyDirectory(folder)
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
        let prefix = SaveStateStore.historyStamp(date) + "-"
        // Moving keeps the modification date that the manifest is checked against.
        let destination = history.appending(path: prefix + state.stateURL.lastPathComponent)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: state.stateURL, to: destination)
        if FileManager.default.fileExists(atPath: state.manifestURL.path(percentEncoded: false)) {
            let manifest = history.appending(path: prefix + state.manifestURL.lastPathComponent)
            try? FileManager.default.removeItem(at: manifest)
            try? FileManager.default.moveItem(at: state.manifestURL, to: manifest)
        }
        SaveStateStore.pruneHistory(in: folder)
    }

    /// Puts a state from the history back under its own name in `folder`.
    /// The state there now goes into the history in turn.
    static func restore(_ entry: SaveStateSlot, in folder: URL, date: Date = .now) throws {
        let name = entry.stateURL.lastPathComponent
        guard let dash = name.firstIndex(of: "-") else { return }
        let destination = folder.appending(path: String(name[name.index(after: dash)...]))
        if let current = kind(ofFileName: destination.lastPathComponent).flatMap({ stateSlot(at: destination, kind: $0) }) {
            try archive(current, date: date)
        }
        try FileManager.default.moveItem(at: entry.stateURL, to: destination)
        let manifest = manifestURL(for: destination)
        try? FileManager.default.removeItem(at: manifest)
        try? FileManager.default.moveItem(at: entry.manifestURL, to: manifest)
    }

    // MARK: Contents

    /// The screenshot ARMSX2 stores in the state (640 × 480 PNG).
    static func screenshot(of url: URL) -> Data? {
        guard let zip = try? ZipArchive(url: url),
              let entry = zip.files.first(where: { $0.path == screenshotEntry }) else { return nil }
        return try? zip.data(of: entry)
    }

    /// The `u32` at the start of the state's `PCSX2 Savestate Version.id`.
    static func saveStateVersion(of url: URL) -> UInt32? {
        guard let zip = try? ZipArchive(url: url),
              let entry = zip.files.first(where: { $0.path == versionEntry }),
              let data = try? zip.data(of: entry), data.count >= 4 else { return nil }
        return data.uint32(at: 0)
    }

    /// ARMSX2 loads states of the same major version that are not newer than its own.
    static func isCompatible(_ version: UInt32, with current: UInt32) -> Bool {
        version >> 16 == current >> 16 && version <= current
    }

    static func isLoadable(_ url: URL, by current: UInt32) -> Bool {
        saveStateVersion(of: url).map { isCompatible($0, with: current) } ?? false
    }

    /// What a manifest records for a state ARMSX2 wrote, when the user names it.
    static func context(for state: SaveStateSlot, gameFileName: String, gameFileSize: Int64) -> SaveStateContext {
        SaveStateContext(coreID: state.stateURL.deletingLastPathComponent().lastPathComponent,
                         coreVersion: saveStateVersion(of: state.stateURL).map { String(format: "%08X", $0) } ?? "",
                         gameCRC32: nil, gameFileName: gameFileName, gameFileSize: gameFileSize)
    }

    // MARK: Resume

    /// Removes the resume state unless ARMSX2 wrote it since `date`. Quitting
    /// in ARMSX2 itself writes none, and the old one would continue from a
    /// point older than the memory card.
    static func removeStaleResumeState(in folder: URL, olderThan date: Date) {
        guard let state = resumeState(in: folder), modificationDate(state) < date else { return }
        try? FileManager.default.removeItem(at: state)
        try? FileManager.default.removeItem(at: manifestURL(for: state))
    }

    private static func modificationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
    }
}
