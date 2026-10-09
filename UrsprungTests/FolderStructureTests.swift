// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import Ursprung

@Suite("Folder structure")
struct FolderStructureTests {
    private func contents(of url: URL) throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: url.path(percentEncoded: false)))
    }

    @Test func everySystemFolderLeadsBackToItsSystem() {
        for system in SystemCatalog.all {
            #expect(SystemCatalog.folderNames[system.id] != nil, "\(system.id) has no folder name")
            #expect(SystemCatalog.system(forFolderName: system.folderName)?.id == system.id, "\(system.folderName)")
            #expect(!system.folderName.contains("/") && !system.folderName.contains(":"))
        }
        #expect(Set(SystemCatalog.all.map(\.folderName)).count == SystemCatalog.all.count)
        #expect(Set(SystemCatalog.folderNames.keys) == Set(SystemCatalog.all.map(\.id)), "No names for unknown systems")
    }

    @Test func createsROMsBIOSAndAFolderPerSystem() throws {
        let root = try makeTemporaryDirectory().appending(path: "Ursprung")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        let systems = try FolderStructure.create(at: root)

        #expect(systems == Set(SystemCatalog.all.map(\.id)))
        #expect(try contents(of: root) == [FolderStructure.romsName, FolderStructure.biosName, FolderStructure.readMeName])
        #expect(try contents(of: FolderStructure.roms(in: root)) == Set(SystemCatalog.all.map(\.folderName)))
        #expect(try contents(of: FolderStructure.bios(in: root)).isEmpty)
    }

    @Test func existingFoldersAndFilesStay() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let snes = FolderStructure.roms(in: root).appending(path: "SNES")
        try FileManager.default.createDirectory(at: snes, withIntermediateDirectories: true)
        try Data("game".utf8).write(to: snes.appending(path: "Game.sfc"))
        try Data("mine".utf8).write(to: root.appending(path: FolderStructure.readMeName))

        try FolderStructure.create(at: root)

        let folders = try contents(of: FolderStructure.roms(in: root))
        #expect(folders.contains("SNES"))
        #expect(!folders.contains("Super Nintendo"), "A folder of another name of the system counts")
        #expect(try Data(contentsOf: snes.appending(path: "Game.sfc")) == Data("game".utf8))
        #expect(try Data(contentsOf: root.appending(path: FolderStructure.readMeName)) == Data("mine".utf8))
    }

    @Test func onlyNewSystemsGetAFolderLater() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let all = SystemCatalog.all
        let old = Array(all.dropLast())
        var laidOut = try FolderStructure.create(at: root, systems: old)
        // The user deleted a folder they don't need.
        let deleted = FolderStructure.roms(in: root).appending(path: old[0].folderName)
        try FileManager.default.removeItem(at: deleted)

        laidOut = try FolderStructure.addNewSystems(at: root, laidOut: laidOut, systems: all)

        #expect(laidOut == Set(all.map(\.id)))
        let folders = try contents(of: FolderStructure.roms(in: root))
        #expect(folders.contains(all.last!.folderName))
        #expect(!folders.contains(old[0].folderName))
    }

    @Test func aMissingStructureIsNotRecreated() throws {
        let root = try makeTemporaryDirectory().appending(path: "Gone")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        let laidOut = try FolderStructure.addNewSystems(at: root, laidOut: ["nes"])

        #expect(laidOut == ["nes"])
        #expect(!FileManager.default.fileExists(atPath: root.path(percentEncoded: false)))
    }

    @Test func gamesInTheStructureAreFoundAndBIOSFilesAreSkipped() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FolderStructure.create(at: root)
        let psx = FolderStructure.roms(in: root).appending(path: "PlayStation")
        try Data("disc".utf8).write(to: psx.appending(path: "Game.iso"))
        try Data("bios".utf8).write(to: FolderStructure.bios(in: root).appending(path: "scph5501.bin"))

        // The whole structure as library folder: BIOS must not show up.
        let scan = LibraryScanner.scan(folders: [root], excluding: [FolderStructure.bios(in: root)])

        #expect(scan.roms.map(\.systemID) == ["psx"])
        #expect(scan.unrecognized.isEmpty)
        #expect(LibraryScanner.scan(folders: [root]).unrecognized.map(\.lastPathComponent) == ["scph5501.bin"])
    }

    @Test func emptyStructureAwaitsGames() {
        #expect(LibraryState(hasFolders: true, isScanning: false, libraryCount: 0, visibleCount: 0, searchText: "",
                             selection: .all, usesFolderStructure: true) == .awaitingGames)
        #expect(LibraryState(hasFolders: true, isScanning: true, libraryCount: 0, visibleCount: 0, searchText: "",
                             selection: .all, usesFolderStructure: true) == .scanning)
    }
}

@Suite("Watched BIOS folder")
struct WatchedBIOSFolderTests {
    @Test func importsWhatIsInTheFolder() async throws {
        let system = try makeTemporaryDirectory()
        let folder = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: system)
            try? FileManager.default.removeItem(at: folder)
        }
        try Data("bios".utf8).write(to: folder.appending(path: "DISKSYS.ROM"))
        let manager = BIOSManager(systemDirectory: system)

        manager.watch(folder)
        defer { manager.watch(nil) }
        let installed = system.appending(path: "disksys.rom")
        for _ in 0..<50 where !FileManager.default.fileExists(atPath: installed.path(percentEncoded: false)) {
            try await Task.sleep(for: .milliseconds(100))
        }

        #expect(try Data(contentsOf: installed) == Data("bios".utf8))
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "DISKSYS.ROM").path(percentEncoded: false)),
                "The file stays in the BIOS folder")
    }

    @Test func anInstalledFileIsNotCopiedAgain() async throws {
        let system = try makeTemporaryDirectory()
        let folder = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: system)
            try? FileManager.default.removeItem(at: folder)
        }
        try Data("bios".utf8).write(to: folder.appending(path: "disksys.rom"))
        let manager = BIOSManager(systemDirectory: system)
        _ = await manager.importFiles([folder])
        let installed = system.appending(path: "disksys.rom")
        let first = try installed.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier

        _ = await manager.importFiles([folder])

        let second = try installed.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
        #expect(first?.isEqual(second) == true)
    }
}
