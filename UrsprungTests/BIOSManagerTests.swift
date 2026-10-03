// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import Ursprung

@Suite("BIOS files")
struct BIOSManagerTests {
    private func system(_ id: String) throws -> GameSystem {
        try #require(SystemCatalog.system(withID: id))
    }

    @Test func intellivisionNeedsBothFiles() throws {
        let intellivision = try system("intellivision")
        func missing(_ present: [String]) -> [String] {
            let statuses = Dictionary(uniqueKeysWithValues: present.map { ($0, BIOSManager.Status.present) })
            return BIOSManager(statuses: statuses).missingRequired(for: intellivision).map(\.fileName)
        }
        #expect(missing([]) == ["exec.bin", "grom.bin"])
        #expect(missing(["exec.bin"]) == ["grom.bin"])
        #expect(missing(["grom.bin"]) == ["exec.bin"])
        #expect(missing(["exec.bin", "grom.bin"]).isEmpty)
    }

    @Test func oneRegionSufficesForSegaCD() throws {
        let segaCD = try system("segacd")
        #expect(BIOSManager().missingRequired(for: segaCD).count == 3)
        #expect(BIOSManager(statuses: ["bios_CD_E.bin": .verified]).missingRequired(for: segaCD).isEmpty)
    }

    @Test func importingTheInstalledFileKeepsIt() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let installed = directory.appending(path: "disksys.rom")
        try Data("bios".utf8).write(to: installed)
        let manager = BIOSManager(systemDirectory: directory)

        let result = await manager.importFiles([installed])

        #expect(result.imported == ["disksys.rom"])
        #expect(try Data(contentsOf: installed) == Data("bios".utf8))
    }

    @Test func importReplacesAnInstalledFile() async throws {
        let directory = try makeTemporaryDirectory()
        let source = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: source)
        }
        try Data("old".utf8).write(to: directory.appending(path: "disksys.rom"))
        try Data("new".utf8).write(to: source.appending(path: "DISKSYS.ROM"))
        let manager = BIOSManager(systemDirectory: directory)

        let result = await manager.importFiles([source.appending(path: "DISKSYS.ROM")])

        #expect(result.imported == ["disksys.rom"])
        #expect(try Data(contentsOf: directory.appending(path: "disksys.rom")) == Data("new".utf8))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))
        #expect(leftovers == ["disksys.rom"], "No staging file stays behind")
    }

    @Test func failedImportKeepsTheInstalledFile() async throws {
        let directory = try makeTemporaryDirectory()
        let source = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: source.appending(path: "disksys.rom").path(percentEncoded: false))
            try? FileManager.default.removeItem(at: source)
        }
        try Data("old".utf8).write(to: directory.appending(path: "disksys.rom"))
        let unreadable = source.appending(path: "disksys.rom")
        try Data("new".utf8).write(to: unreadable)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadable.path(percentEncoded: false))
        let manager = BIOSManager(systemDirectory: directory)

        let result = await manager.importFiles([unreadable])

        #expect(result.failed == ["disksys.rom"])
        #expect(result.unknown.isEmpty)
        #expect(try Data(contentsOf: directory.appending(path: "disksys.rom")) == Data("old".utf8))
    }
}
