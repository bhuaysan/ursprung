// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation
import Observation
import SwiftData
import UniformTypeIdentifiers

/// Backs up the library, saves, states, artwork and settings into one file
/// and restores such a file. See `Backup` for the format.
@Observable
final class BackupService {
    /// What is happening right now, for a progress row; nil when idle.
    private(set) var activity: String?

    var isWorking: Bool { activity != nil }

    @ObservationIgnored private let container: ModelContainer
    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored private let session: EmulationSession
    @ObservationIgnored private let locations: DataLocations

    init(container: ModelContainer, library: LibraryStore, session: EmulationSession,
         locations: DataLocations = .standard) {
        self.container = container
        self.library = library
        self.session = session
        self.locations = locations
    }

    private var context: ModelContext { container.mainContext }

    // MARK: Back up

    func backUp() {
        guard !isWorking, ensureNoGameRunning() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = "\(Backup.folderName) \(Date.now.formatted(.iso8601.year().month().day())).zip"
        panel.message = String(localized: "The backup contains your library, battery saves, save states, artwork and settings.")
        panel.prompt = String(localized: "Back Up")
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        let records = ((try? context.fetch(FetchDescriptor<Game>())) ?? []).map(\.record)
        let settings: Data
        do {
            settings = try Preferences.backupData()
        } catch {
            report(failure: error, title: String(localized: "The backup couldn't be created"))
            return
        }
        let locations = locations
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        activity = String(localized: "Backing up…")
        Task {
            defer { activity = nil }
            do {
                try await Self.create(records: records, settings: settings, locations: locations, destination: destination,
                                      appVersion: appVersion)
                let alert = NSAlert()
                alert.messageText = String(localized: "Backup complete")
                alert.informativeText = String(localized: "The backup was saved as “\(destination.lastPathComponent)”.")
                alert.addButton(withTitle: String(localized: "OK"))
                alert.addButton(withTitle: String(localized: "Show in Finder"))
                if alert.runModal() == .alertSecondButtonReturn {
                    NSWorkspace.shared.activateFileViewerSelecting([destination])
                }
            } catch {
                report(failure: error, title: String(localized: "The backup couldn't be created"))
            }
        }
    }

    @concurrent
    private static func create(records: [GameRecord], settings: Data, locations: DataLocations, destination: URL,
                               appVersion: String) async throws {
        try Backup.create(records: records, settings: settings, locations: locations, destination: destination,
                          appVersion: appVersion)
    }

    // MARK: Restore

    func restore() {
        guard !isWorking, ensureNoGameRunning() else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip]
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Choose an Ursprung backup.")
        panel.prompt = String(localized: "Restore")
        guard panel.runModal() == .OK, let archive = panel.url else { return }

        activity = String(localized: "Checking backup…")
        Task {
            let contents: Backup.Contents
            do {
                contents = try await Self.open(archive)
            } catch {
                activity = nil
                report(failure: error, title: String(localized: "The backup can't be restored"))
                return
            }
            defer {
                contents.remove()
                activity = nil
            }
            guard let restoresSettings = confirm(contents), ensureNoGameRunning() else { return }
            activity = String(localized: "Restoring…")
            do {
                let summary = try await apply(contents, restoresSettings: restoresSettings)
                let alert = NSAlert()
                alert.messageText = String(localized: "Backup restored")
                alert.informativeText = summary
                alert.runModal()
            } catch {
                report(failure: error, title: String(localized: "The backup couldn't be restored completely"))
            }
            await library.rescan(context: context)
        }
    }

    @concurrent
    private static func open(_ archive: URL) async throws -> Backup.Contents {
        try Backup.open(archive)
    }

    @concurrent
    private static func restoreFiles(of contents: Backup.Contents, plan: [UUID: Backup.Target], renames: [Backup.Rename],
                                     locations: DataLocations) async throws -> FileMerge.Report {
        try Backup.restoreFiles(of: contents, plan: plan, renames: renames, locations: locations)
    }

    /// Shows what the backup holds and how it is restored. Returns whether
    /// settings are restored too, or nil when the user cancels.
    private func confirm(_ contents: Backup.Contents) -> Bool? {
        let alert = NSAlert()
        alert.messageText = String(localized: "Restore the backup from \(contents.manifest.created.formatted(date: .long, time: .shortened))?")
        alert.informativeText = String(localized: "Games: \(contents.records.count), save files: \(contents.batterySaveCount), save states: \(contents.stateCount).")
            + "\n\n" + String(localized: "Games already in your library keep their data and gain the backup's favorites and play time. Where a save exists in both, the newer one is used and the other is kept next to it as a copy. Nothing is deleted.")
        alert.addButton(withTitle: String(localized: "Restore"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        let settings = NSButton(checkboxWithTitle: String(localized: "Also restore settings"), target: nil, action: nil)
        settings.state = contents.settings == nil ? .off : .on
        settings.isEnabled = contents.settings != nil
        alert.accessoryView = settings
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return settings.state == .on
    }

    /// Restores `contents` into the library and returns a summary.
    private func apply(_ contents: Backup.Contents, restoresSettings: Bool) async throws -> String {
        let games = (try? context.fetch(FetchDescriptor<Game>())) ?? []
        let existing = games.map {
            Backup.ExistingGame(id: $0.id, path: $0.path, systemID: $0.systemID, crc32: $0.crc32,
                                fileName: $0.fileName, fileSize: $0.fileSize)
        }
        let plan = Backup.plan(records: contents.records, existing: existing)
        let byID = Dictionary(games.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var added = 0
        var renames: [Backup.Rename] = []
        for record in contents.records {
            guard let target = plan[record.id] else { continue }
            if target.isNew {
                let game = Game(record: record, id: target.id)
                // The file may be elsewhere on this Mac; the next scan
                // recognises it by checksum or name, or the user locates it.
                game.missingSince = FileManager.default.fileExists(atPath: record.path) ? nil : (record.missingSince ?? .now)
                context.insert(game)
                added += 1
            } else if let game = byID[target.id] {
                game.restore(record)
                renames.append(Backup.Rename(systemID: record.systemID, recordID: record.id,
                                             from: record.saveBaseName, to: game.saveBaseName))
            }
        }
        try context.save()

        let files = try await Self.restoreFiles(of: contents, plan: plan, renames: renames, locations: locations)

        if restoresSettings, let settings = contents.settings {
            library.addFolders(Preferences.restore(fromBackup: settings))
        }

        var summary = String(localized: "\(contents.records.count) games restored.")
        if added > 0 {
            summary += " " + String(localized: "\(added) were added as new games.")
        }
        if files.conflicts > 0 {
            summary += " " + String(localized: "\(files.conflicts) save files existed in both; the newer one is used and the other is kept as a copy.")
        }
        return summary
    }

    // MARK: Helpers

    /// A running game writes saves while files are copied; it has to stop first.
    private func ensureNoGameRunning() -> Bool {
        guard session.isActive else { return true }
        let alert = NSAlert()
        alert.messageText = String(localized: "Quit the game first")
        alert.informativeText = String(localized: "A running game keeps writing its saves. Close it, then try again.")
        alert.runModal()
        return false
    }

    private func report(failure error: Error, title: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}
