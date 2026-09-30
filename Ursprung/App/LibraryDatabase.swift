// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftData

/// Opens the SwiftData library without ever destroying it on its own.
///
/// The library holds favourites, play time and scraped metadata that cannot be
/// rebuilt from the ROM folders, so a failure to open it is never answered by
/// deleting it. The user decides; starting over moves the old files into a
/// backup folder first.
enum LibraryDatabase {
    enum Recovery {
        case quit
        case backUpAndStartFresh
    }

    enum OpenError: LocalizedError {
        /// The store could not be opened and the user chose not to replace it.
        case declined(underlying: Error)
        /// The old store could not be backed up, so nothing was replaced.
        case backupFailed(underlying: Error)
        /// Even a fresh store could not be created.
        case freshStoreFailed(underlying: Error)

        var errorDescription: String? {
            switch self {
            case .declined(let error): error.localizedDescription
            case .backupFailed(let error): String(localized: "The library could not be backed up: \(error.localizedDescription)")
            case .freshStoreFailed(let error): String(localized: "A new library could not be created: \(error.localizedDescription)")
            }
        }
    }

    /// The store file and the SQLite sidecar files that belong to it.
    static func files(of store: URL) -> [URL] {
        ["", "-shm", "-wal"].map { URL(filePath: store.path(percentEncoded: false) + $0) }
    }

    /// A backup that could not be completed. Files that could not be moved back
    /// are still in `preservedAt`.
    struct BackupFailure: LocalizedError {
        let underlying: Error
        let preservedAt: URL?

        var errorDescription: String? {
            guard let preservedAt else { return underlying.localizedDescription }
            return String(localized: "\(underlying.localizedDescription) Files that could not be restored are in “\(preservedAt.path(percentEncoded: false))”.")
        }
    }

    /// Moves the store and its sidecars into a new, empty folder next to it and
    /// returns that folder. The folder is always created fresh (a name that is
    /// taken gets a numeric suffix), so an earlier backup is never touched.
    /// If moving fails, the files already moved go back; whatever cannot go
    /// back stays in the backup folder, which is then kept.
    static func backUp(_ store: URL,
                       stamp: String,
                       move: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }) throws -> URL {
        let fileManager = FileManager.default
        let base = store.path(percentEncoded: false) + "-backup-" + stamp
        var backup = URL(filePath: base, directoryHint: .isDirectory)
        var attempt = 1
        while true {
            do {
                // Without intermediate directories this fails if the folder exists.
                try fileManager.createDirectory(at: backup, withIntermediateDirectories: false)
                break
            } catch CocoaError.fileWriteFileExists {
                attempt += 1
                guard attempt < 1000 else { throw BackupFailure(underlying: CocoaError(.fileWriteFileExists), preservedAt: nil) }
                backup = URL(filePath: "\(base)-\(attempt)", directoryHint: .isDirectory)
            }
        }

        var moved: [(from: URL, to: URL)] = []
        do {
            for file in files(of: store) where fileManager.fileExists(atPath: file.path(percentEncoded: false)) {
                let target = backup.appending(path: file.lastPathComponent)
                try move(file, target)
                moved.append((file, target))
            }
        } catch {
            var stranded = false
            for entry in moved.reversed() {
                do { try move(entry.to, entry.from) } catch { stranded = true }
            }
            if stranded { throw BackupFailure(underlying: error, preservedAt: backup) }
            // Everything is back; the folder is ours and empty, so removing it is safe.
            if (try? fileManager.contentsOfDirectory(atPath: backup.path(percentEncoded: false)))?.isEmpty == true {
                try? fileManager.removeItem(at: backup)
            }
            throw BackupFailure(underlying: error, preservedAt: nil)
        }
        return backup
    }

    /// Creates the container with `make`. If that fails, `recover` decides what
    /// happens; the existing files are only touched after an explicit
    /// `.backUpAndStartFresh`, and then only by moving them into a backup.
    static func open(at store: URL,
                     make: (URL) throws -> ModelContainer,
                     recover: (Error) -> Recovery,
                     stamp: () -> String = { ISO8601DateFormatter().string(from: .now).replacing(":", with: "-") }) throws -> ModelContainer {
        do {
            return try make(store)
        } catch {
            guard recover(error) == .backUpAndStartFresh else { throw OpenError.declined(underlying: error) }
            do {
                _ = try backUp(store, stamp: stamp())
            } catch {
                throw OpenError.backupFailed(underlying: error)
            }
            do {
                return try make(store)
            } catch {
                throw OpenError.freshStoreFailed(underlying: error)
            }
        }
    }

    // MARK: - Dialogs

    /// Asks the user what to do with a library that will not open.
    static func askUser(_ error: Error) -> Recovery {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = String(localized: "The library could not be opened")
        alert.informativeText = String(localized: "Your games, favorites and play times have not been changed. You can quit and try again, for example after updating Ursprung, or move the library aside as a backup and start with an empty one.\n\n\(error.localizedDescription)")
        alert.addButton(withTitle: String(localized: "Quit"))
        alert.addButton(withTitle: String(localized: "Back Up and Start Fresh"))
        return alert.runModal() == .alertSecondButtonReturn ? .backUpAndStartFresh : .quit
    }

    /// Reports why the app cannot start. Staying silent is right when the user
    /// chose to quit.
    static func reportFailure(_ error: Error) {
        if case .declined? = error as? OpenError { return }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = String(localized: "Ursprung cannot start")
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}
