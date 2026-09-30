// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import SwiftData
import Testing
@testable import Ursprung

@Suite("Library database recovery")
struct LibraryDatabaseTests {
    private struct OpenFailure: Error {}

    private func writeStore(in directory: URL) throws -> [URL: Data] {
        let store = directory.appending(path: "Library.store")
        var contents: [URL: Data] = [:]
        for (file, text) in zip(LibraryDatabase.files(of: store), ["main", "shm", "wal"]) {
            try Data(text.utf8).write(to: file)
            contents[file] = Data(text.utf8)
        }
        return contents
    }

    @Test func failedOpenLeavesTheDatabaseUntouchedWhenUserQuits() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let contents = try writeStore(in: directory)
        let store = directory.appending(path: "Library.store")

        #expect(throws: LibraryDatabase.OpenError.self) {
            try LibraryDatabase.open(at: store, make: { _ in throw OpenFailure() }, recover: { _ in .quit })
        }
        for (file, data) in contents { #expect(try Data(contentsOf: file) == data) }
    }

    @Test func recoveryIsOnlyOfferedWhenOpeningFails() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var asked = false
        _ = try LibraryDatabase.open(
            at: directory.appending(path: "Library.store"),
            make: { _ in try ModelContainer(for: Game.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true)) },
            recover: { _ in asked = true; return .quit })
        #expect(!asked)
    }

    @Test func startingFreshMovesEveryFileIntoABackup() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let contents = try writeStore(in: directory)
        let store = directory.appending(path: "Library.store")

        var attempts = 0
        _ = try LibraryDatabase.open(
            at: store,
            make: { _ in
                attempts += 1
                if attempts == 1 { throw OpenFailure() }
                // The damaged files must be out of the way before the second attempt.
                #expect(!FileManager.default.fileExists(atPath: store.path(percentEncoded: false)))
                return try ModelContainer(for: Game.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
            },
            recover: { _ in .backUpAndStartFresh },
            stamp: { "test" })

        let backup = directory.appending(path: "Library.store-backup-test", directoryHint: .isDirectory)
        for (file, data) in contents {
            #expect(try Data(contentsOf: backup.appending(path: file.lastPathComponent)) == data)
        }
    }

    @Test func failingFreshStoreKeepsTheBackupAndReportsTheError() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try writeStore(in: directory)
        let store = directory.appending(path: "Library.store")

        #expect(throws: LibraryDatabase.OpenError.self) {
            try LibraryDatabase.open(at: store, make: { _ in throw OpenFailure() }, recover: { _ in .backUpAndStartFresh }, stamp: { "test" })
        }
        let backedUp = directory.appending(path: "Library.store-backup-test/Library.store")
        #expect(FileManager.default.fileExists(atPath: backedUp.path(percentEncoded: false)))
    }

    @Test func backingUpTwiceWithTheSameNameKeepsTheFirstBackup() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = directory.appending(path: "Library.store")

        try Data("original-library".utf8).write(to: store)
        let first = try LibraryDatabase.backUp(store, stamp: "same-second")
        try Data("fresh-library".utf8).write(to: store)
        let second = try LibraryDatabase.backUp(store, stamp: "same-second")

        #expect(first != second)
        #expect(try Data(contentsOf: first.appending(path: "Library.store")) == Data("original-library".utf8))
        #expect(try Data(contentsOf: second.appending(path: "Library.store")) == Data("fresh-library".utf8))
    }

    @Test func aFailedMoveRestoresTheFilesAndRemovesOnlyItsOwnEmptyFolder() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let contents = try writeStore(in: directory)
        let store = directory.appending(path: "Library.store")
        let earlier = try LibraryDatabase.backUp(directory.appending(path: "Other.store"), stamp: "x") // empty, foreign folder

        var calls = 0
        #expect(throws: LibraryDatabase.BackupFailure.self) {
            try LibraryDatabase.backUp(store, stamp: "test", move: { from, to in
                calls += 1
                if calls == 2 { throw OpenFailure() } // the sidecar fails after the store moved
                try FileManager.default.moveItem(at: from, to: to)
            })
        }
        for (file, data) in contents { #expect(try Data(contentsOf: file) == data) }
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "Library.store-backup-test").path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: earlier.path(percentEncoded: false)))
    }

    @Test func aFailedRollbackKeepsTheStrandedFiles() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try writeStore(in: directory)
        let store = directory.appending(path: "Library.store")

        var calls = 0
        let failure = #expect(throws: LibraryDatabase.BackupFailure.self) {
            try LibraryDatabase.backUp(store, stamp: "test", move: { from, to in
                calls += 1
                if calls >= 2 { throw OpenFailure() } // the second move and the rollback both fail
                try FileManager.default.moveItem(at: from, to: to)
            })
        }
        let backup = directory.appending(path: "Library.store-backup-test")
        #expect(try Data(contentsOf: backup.appending(path: "Library.store")) == Data("main".utf8))
        #expect(failure?.preservedAt?.standardizedFileURL.path == backup.standardizedFileURL.path)
        #expect(failure?.errorDescription?.contains("Library.store-backup-test") == true)
    }
}
