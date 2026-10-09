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
    /// What ARMSX2 refuses to load a state without (`SaveState_UnzipFromZip`
    /// and the required `SavestateEntries` at the pinned commit).
    static let requiredEntries = [
        "PCSX2 Internal Structures.dat", "eeMemory.bin", "iopMemory.bin", "eeHwRegs.bin", "iopHwRegs.bin",
        "Scratchpad.bin", "vu0Memory.bin", "vu1Memory.bin", "vu0MicroMem.bin", "vu1MicroMem.bin",
        "SPU2.bin", "PAD.bin", "GS.bin",
    ]

    /// What a state file holds, from its name.
    enum Kind: Hashable, Sendable {
        /// Ursprung's slot number (see `armsx2Slot`).
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
        return Int(match.tag).map { .slot(armsx2Slot($0)) } ?? .resume
    }

    /// ARMSX2's slot for one of Ursprung's, and back. ARMSX2's hotkeys reach
    /// slots 1–10 only, so Ursprung's Quick Save (slot 0) is ARMSX2's slot 1:
    /// the Quick Save key in ARMSX2's window and Quick Save in Ursprung then
    /// keep the same state. Ursprung's slot 1 takes ARMSX2's slot 0 in
    /// exchange; every other slot has the same number in both.
    static func armsx2Slot(_ slot: Int) -> Int {
        switch slot {
        case 0: 1
        case 1: 0
        default: slot
        }
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
        _ = try moveToHistory(state, date: date)
        SaveStateStore.pruneHistory(in: state.stateURL.deletingLastPathComponent())
    }

    /// Moves a state and its manifest into the history without pruning it,
    /// and returns where they went.
    private static func moveToHistory(_ state: SaveStateSlot, date: Date) throws -> (state: URL, manifest: URL?) {
        let folder = state.stateURL.deletingLastPathComponent()
        let history = SaveStateStore.historyDirectory(folder)
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
        let prefix = SaveStateStore.historyStamp(date) + "-"
        // Moving keeps the modification date that the manifest is checked against.
        let destination = history.appending(path: prefix + state.stateURL.lastPathComponent)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: state.stateURL, to: destination)
        guard FileManager.default.fileExists(atPath: state.manifestURL.path(percentEncoded: false)) else { return (destination, nil) }
        let manifest = history.appending(path: prefix + state.manifestURL.lastPathComponent)
        try? FileManager.default.removeItem(at: manifest)
        guard (try? FileManager.default.moveItem(at: state.manifestURL, to: manifest)) != nil else { return (destination, nil) }
        return (destination, manifest)
    }

    /// Puts a state from the history back under its own name in `folder`.
    /// The state there now goes into the history in turn. The history is
    /// pruned only afterwards: `entry` may be its oldest state. If the entry
    /// can't be moved back, the state that was there returns.
    static func restore(_ entry: SaveStateSlot, in folder: URL, date: Date = .now) throws {
        let name = entry.stateURL.lastPathComponent
        guard let dash = name.firstIndex(of: "-") else { return }
        let destination = folder.appending(path: String(name[name.index(after: dash)...]))
        let manifest = manifestURL(for: destination)
        var replaced: (state: URL, manifest: URL?)?
        if let current = kind(ofFileName: destination.lastPathComponent).flatMap({ stateSlot(at: destination, kind: $0) }) {
            replaced = try moveToHistory(current, date: date)
        }
        do {
            try FileManager.default.moveItem(at: entry.stateURL, to: destination)
        } catch {
            if let replaced {
                try? FileManager.default.moveItem(at: replaced.state, to: destination)
                if let moved = replaced.manifest { try? FileManager.default.moveItem(at: moved, to: manifest) }
            }
            throw error
        }
        try? FileManager.default.removeItem(at: manifest)
        try? FileManager.default.moveItem(at: entry.manifestURL, to: manifest)
        SaveStateStore.pruneHistory(in: folder)
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

    /// Whether the emulator with save state format `current` can load the
    /// state, as far as Ursprung can tell: its format is compatible and it
    /// has every part ARMSX2 requires, each within the file. The compressed
    /// data itself is not checked (ARMSX2 uses Zstandard). Never when the
    /// format is unknown.
    static func isLoadable(_ url: URL, by current: UInt32?) -> Bool {
        guard let current, let zip = try? ZipArchive(url: url),
              let entry = zip.files.first(where: { $0.path == versionEntry }),
              let data = try? zip.data(of: entry), data.count >= 4,
              isCompatible(data.uint32(at: 0), with: current) else { return false }
        return hasRequiredEntries(zip)
    }

    /// Every required part is there, not empty, and has its local header,
    /// with its data before the central directory, as in a file that was
    /// written completely.
    private static func hasRequiredEntries(_ zip: ZipArchive) -> Bool {
        let entries = Dictionary(zip.files.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let required = requiredEntries.compactMap { entries[$0] }
        return required.count == requiredEntries.count && required.allSatisfy { $0.uncompressedSize > 0 }
            && zip.hasIntactLocalHeaders(required)
    }

    /// What a manifest records for a state ARMSX2 wrote, when the user names it.
    static func context(for state: SaveStateSlot, gameFileName: String, gameFileSize: Int64) -> SaveStateContext {
        SaveStateContext(coreID: state.stateURL.deletingLastPathComponent().lastPathComponent,
                         coreVersion: saveStateVersion(of: state.stateURL).map { String(format: "%08X", $0) } ?? "",
                         gameCRC32: nil, gameFileName: gameFileName, gameFileSize: gameFileSize)
    }

    // MARK: Saving and loading through PINE

    /// The file ARMSX2 writes for Ursprung's `slot` of the running disc
    /// (`VMManager::GetSaveStateFileName`); PINE reports the CRC in lowercase.
    static func slotFileName(serial: String, crc: String, slot: Int) -> String {
        "\(serial) (\(crc.uppercased())).\(String(format: "%02d", armsx2Slot(slot))).p2s"
    }

    /// Whether ARMSX2 can load `state` by its slot: a slot's own file, not
    /// the resume state, a merged copy or one from the history.
    static func isSlotFile(_ state: SaveStateSlot) -> Bool {
        guard state.isARMSX2, !state.isHistory, case .slot = kind(ofFileName: state.stateURL.lastPathComponent) else { return false }
        return !FileMerge.isLabelledCopy(state.stateURL)
    }

    /// Saves the running game into `slot` and waits until ARMSX2 has written
    /// the state: PINE answers as soon as the save is queued. The state it
    /// replaces goes into the history first, like a libretro core's slot.
    /// Cancelled before the request, nothing is saved. Once the request may
    /// have reached ARMSX2, nothing takes it back: ARMSX2 can still write the
    /// state after the wait has ended, so the copy in the history stays.
    @concurrent
    static func save(slot: Int, through client: PINEClient, in folder: URL,
                     timeout: Duration = .seconds(10)) async throws -> URL {
        let url = folder.appending(path: try await slotFileName(slot: slot, through: client))
        try Task.checkCancellation()
        let previous = modificationDate(url)
        let archived = try archiveCopy(of: url, date: .now)
        var mayBeQueued = false
        do {
            try Task.checkCancellation()
            do {
                mayBeQueued = true
                try await client.saveState(slot: UInt8(armsx2Slot(slot)))
            } catch let failure as PINEClient.Failure {
                // Not connected, or ARMSX2 said no: nothing is queued.
                mayBeQueued = failure != .unreachable && failure != .refused
                throw ARMSX2ControlError(failure)
            }
            // ARMSX2 writes `<state>.<random>.part` and renames it when done.
            let clock = ContinuousClock()
            let deadline = clock.now + timeout
            while clock.now < deadline {
                try await Task.sleep(for: .milliseconds(100))
                if modificationDate(url) > previous { break }
            }
            guard modificationDate(url) > previous else { throw ARMSX2ControlError.notSaved }
            didSave(into: url, in: folder)
            return url
        } catch {
            // Written after all, just before ARMSX2 quit or the wait ended:
            // the copy in the history is the replaced state.
            if modificationDate(url) > previous {
                didSave(into: url, in: folder)
                return url
            }
            if let archived, !mayBeQueued { unarchive(archived) }
            throw error
        }
    }

    /// The name of the replaced state went into the history with its copy.
    private static func didSave(into url: URL, in folder: URL) {
        try? FileManager.default.removeItem(at: manifestURL(for: url))
        SaveStateStore.pruneHistory(in: folder)
    }

    /// Loads the state in `slot` of the running disc. With `expected`, only
    /// when that is the file ARMSX2 would load. ARMSX2 shows a dialog for a
    /// state it cannot read, which crashes it, so the version is checked first.
    @concurrent
    static func load(slot: Int, in folder: URL, expected: URL? = nil, through client: PINEClient,
                     saveStateVersion: UInt32?) async throws {
        let url = folder.appending(path: try await slotFileName(slot: slot, through: client))
        if let expected, expected.standardizedFileURL.path(percentEncoded: false) != url.standardizedFileURL.path(percentEncoded: false) {
            throw ARMSX2ControlError.otherDisc
        }
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { throw ARMSX2ControlError.emptySlot }
        guard isLoadable(url, by: saveStateVersion) else { throw StandaloneLaunchError.stateNotLoadable }
        try Task.checkCancellation()
        do {
            try await client.loadState(slot: UInt8(armsx2Slot(slot)))
        } catch {
            throw ARMSX2ControlError(error)
        }
    }

    private static func slotFileName(slot: Int, through client: PINEClient) async throws -> String {
        guard (0...99).contains(slot) else { throw ARMSX2ControlError.emptySlot }
        do {
            let serial = try await client.serial(), crc = try await client.discCRC()
            // Without a serial ARMSX2 has no name for states and saves nothing.
            guard !serial.isEmpty, !crc.isEmpty else { throw ARMSX2ControlError.noGame }
            return slotFileName(serial: serial, crc: crc, slot: slot)
        } catch let error as PINEClient.Failure {
            throw ARMSX2ControlError(error)
        }
    }

    /// Copies the state at `url` (if any) and its manifest into the history.
    /// The copy keeps the state's date, which the manifest is checked
    /// against. The manifest stays next to the state until the new one is
    /// written: a name never goes with a state written later.
    private static func archiveCopy(of url: URL, date: Date) throws -> (state: URL, manifest: URL?)? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path(percentEncoded: false)) else { return nil }
        let folder = url.deletingLastPathComponent()
        let history = SaveStateStore.historyDirectory(folder)
        try fileManager.createDirectory(at: history, withIntermediateDirectories: true)
        let prefix = SaveStateStore.historyStamp(date) + "-"
        let copy = history.appending(path: prefix + url.lastPathComponent)
        try? fileManager.removeItem(at: copy)
        try fileManager.copyItem(at: url, to: copy)
        try? fileManager.setAttributes([.modificationDate: modificationDate(url)], ofItemAtPath: copy.path(percentEncoded: false))
        let manifest = manifestURL(for: url)
        guard fileManager.fileExists(atPath: manifest.path(percentEncoded: false)) else { return (copy, nil) }
        let copiedManifest = history.appending(path: prefix + manifest.lastPathComponent)
        try? fileManager.removeItem(at: copiedManifest)
        guard (try? fileManager.copyItem(at: manifest, to: copiedManifest)) != nil else { return (copy, nil) }
        return (copy, copiedManifest)
    }

    /// Undoes `archiveCopy` after a save that was never queued: the state is still in place.
    private static func unarchive(_ archived: (state: URL, manifest: URL?)) {
        try? FileManager.default.removeItem(at: archived.state)
        if let manifest = archived.manifest { try? FileManager.default.removeItem(at: manifest) }
    }

    // MARK: Resume

    /// Removes the resume states unless ARMSX2 wrote one since `date`.
    /// Quitting in ARMSX2 itself writes none, and an old one would continue
    /// from a point older than the memory card. Every old one goes: the next
    /// newest would otherwise become the automatic state. Merged copies are
    /// not automatic states and stay.
    static func removeStaleResumeState(in folder: URL, olderThan date: Date) {
        guard let newest = resumeState(in: folder), modificationDate(newest) < date else { return }
        for name in fileNames(in: folder) where name.hasSuffix(".resume.p2s") {
            let state = folder.appending(path: name)
            guard modificationDate(state) < date else { continue }
            try? FileManager.default.removeItem(at: state)
            try? FileManager.default.removeItem(at: manifestURL(for: state))
        }
    }

    private static func modificationDate(_ url: URL) -> Date {
        // Fresh values: a save is detected by the date changing.
        var url = url
        url.removeAllCachedResourceValues()
        return (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
    }
}

/// Why a save or load through PINE did not happen.
nonisolated enum ARMSX2ControlError: LocalizedError, Equatable {
    /// PINE does not answer: ARMSX2 is starting, quitting, or in hardcore mode.
    case notAnswering
    /// ARMSX2 runs, but no game yet (or one without a serial).
    case noGame
    /// The state did not appear in time, e.g. while the memory card was written.
    case notSaved
    case emptySlot
    /// The slot holds a state of another disc of the game.
    case otherDisc

    init(_ error: any Error) {
        switch error {
        case let error as ARMSX2ControlError: self = error
        case PINEClient.Failure.refused: self = .noGame
        default: self = .notAnswering
        }
    }

    var errorDescription: String? {
        switch self {
        case .notAnswering:
            String(localized: "ARMSX2 doesn't answer right now. Try again in a moment, or save in its window.")
        case .noGame:
            String(localized: "ARMSX2 isn't running the game yet. Try again in a moment.")
        case .notSaved:
            String(localized: "ARMSX2 didn't save the state. Its window may say why, for example while the memory card is being written.")
        case .emptySlot:
            String(localized: "No saved state in this slot")
        case .otherDisc:
            String(localized: "This state belongs to another disc of the game.")
        }
    }
}
