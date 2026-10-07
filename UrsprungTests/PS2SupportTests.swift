// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import Ursprung

/// A 4 MB image with a minimal ROM directory: `RESET` (the directory's
/// offset), `ROMDIR` (the directory itself) and `ROMVER` right after it.
private func syntheticBIOS(romver: String = "0200EC20040614", size: Int = 4 << 20) -> Data {
    var data = Data(count: size)
    func entry(_ name: String, size: UInt32, at offset: Int) {
        data.replaceSubrange(offset..<offset + name.utf8.count, with: Array(name.utf8))
        withUnsafeBytes(of: size.littleEndian) { data.replaceSubrange(offset + 12..<offset + 16, with: $0) }
    }
    entry("RESET", size: 0x40, at: 0x40)
    entry("ROMDIR", size: 0x40, at: 0x50)
    entry("ROMVER", size: UInt32(romver.utf8.count), at: 0x60)
    // RESET covers 0x00–0x3F, ROMDIR 0x40–0x7F, so ROMVER starts at 0x80.
    data.replaceSubrange(0x80..<0x80 + romver.utf8.count, with: Array(romver.utf8))
    return data
}

@Suite("PlayStation 2")
struct PS2SupportTests {
    private var ps2: GameSystem {
        get throws { try #require(SystemCatalog.system(withID: "ps2")) }
    }

    // MARK: Catalog

    @Test func catalogInvariants() {
        #expect(SystemCatalog.all.allSatisfy { !$0.cores.isEmpty }, "Every system has a default core")
        #expect(Set(SystemCatalog.all.map(\.id)).count == SystemCatalog.all.count)
        let standalone = CoreManager.standaloneEmulators
        #expect(Set(standalone.map(\.id)).count == standalone.count)
        #expect(Set(standalone.map(\.id)).isDisjoint(with: CoreManager.allCores.map(\.id)))
        #expect(CoreManager.allCores.allSatisfy { $0.isLibretro })
        for system in SystemCatalog.all {
            for id in system.biosFolder?.requiredBy ?? [] {
                #expect(system.cores.contains { $0.id == id }, "\(system.id) needs a BIOS for a core it does not have")
            }
        }
    }

    @Test func playStation2RunsInARMSX2() throws {
        let system = try ps2
        let emulator = try #require(system.defaultCore.standalone)
        #expect(emulator.id == "armsx2")
        #expect(emulator.downloadURL.absoluteString
            == "https://github.com/ARMSX2/ARMSX2/releases/download/nightly-20261006/ARMSX2-nightly-20261006-46c06fe7ca-macOS-arm64.tar.xz")
        #expect(SystemCatalog.discSystems.contains("ps2"))
        #expect(!system.supportsPatches)
        #expect(AchievementService.consoleID(for: "ps2") == nil, "Achievements are handled in ARMSX2")
    }

    // MARK: Scanner

    @Test func scannerFindsGamesInAPS2Folder() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "PS2", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["Persona 4 (Europe).iso", "Game.chd", "Other.cso", "Packed.zso"] {
            try Data([0]).write(to: folder.appending(path: name))
        }

        let results = LibraryScanner.scan(folder: root)

        #expect(results.count == 4)
        #expect(results.allSatisfy { $0.systemID == "ps2" })
    }

    @Test(arguments: [("PS2", "ps2"), ("PlayStation 2", "ps2"), ("Sony PlayStation 2", "ps2"), ("PlayStation", "psx")])
    func folderAliases(folder: String, system: String) {
        #expect(SystemCatalog.system(forFolderName: folder)?.id == system)
    }

    @Test func csoOutsideAPS2FolderStaysPSP() throws {
        #expect(try LibraryScanner.detectSystem(for: URL(filePath: "/tmp/game.cso"), folderSystem: nil)?.id == "psp")
        let system = try ps2
        #expect(try LibraryScanner.detectSystem(for: URL(filePath: "/tmp/game.cso"), folderSystem: system)?.id == "ps2")
        #expect(try LibraryScanner.detectSystem(for: URL(filePath: "/tmp/game.zso"), folderSystem: nil)?.id == "ps2")
    }

    // MARK: BIOS recognition

    @Test func recognizesADumpByItsROMDirectory() throws {
        let dump = try #require(PS2BIOS.parse(syntheticBIOS(), fileName: "any name.bin"))
        #expect(dump.region == .europe)
        #expect(dump.version == "2.00")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        #expect(dump.date.map { calendar.dateComponents([.year, .month, .day], from: $0) }
            == DateComponents(year: 2004, month: 6, day: 14))

        #expect(PS2BIOS.parse(syntheticBIOS(romver: "0170AC20030325"), fileName: "x")?.region == .usa)
        #expect(PS2BIOS.parse(syntheticBIOS(romver: "0220JC20050620"), fileName: "x")?.version == "2.20")
    }

    @Test func rejectsWhatIsNotAConsoleBIOS() {
        #expect(PS2BIOS.parse(Data(count: 4 << 20), fileName: "zeros") == nil, "No ROM directory")
        #expect(PS2BIOS.parse(syntheticBIOS(size: 2 << 20), fileName: "small") == nil, "Smaller than ARMSX2 accepts")
        #expect(PS2BIOS.parse(syntheticBIOS(romver: "0100TZ20000603"), fileName: "coh") == nil, "Arcade board BIOS")
    }

    @Test func folderDumpSatisfiesARMSX2() async throws {
        let system = try ps2
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = BIOSManager(systemDirectory: directory)

        await manager.refresh()
        #expect(manager.missingFolder(for: system) != nil)
        #expect(manager.missingDescriptions(for: system).count == 1)
        #expect(!manager.isReady(system))

        let folder = directory.appending(path: "pcsx2/bios", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try syntheticBIOS().write(to: folder.appending(path: "My Console.bin"))
        try Data("side".utf8).write(to: folder.appending(path: "My Console.NVM"))
        await manager.refresh()

        let biosFolder = try #require(system.biosFolder)
        #expect(manager.dumps(in: biosFolder).map(\.fileName) == ["My Console.bin"])
        #expect(manager.missingDescriptions(for: system).isEmpty)
        #expect(manager.isReady(system))
    }

    @Test func importKeepsNamesAndBringsSideFiles() async throws {
        let directory = try makeTemporaryDirectory()
        let source = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: source)
        }
        try syntheticBIOS().write(to: source.appending(path: "SCPH-70004 EU.BIN"))
        for side in ["SCPH-70004 EU.NVM", "SCPH-70004 EU.ROM1", "scph-70004 eu.erom"] {
            try Data(side.utf8).write(to: source.appending(path: side))
        }
        try Data("notes".utf8).write(to: source.appending(path: "readme.txt"))
        let manager = BIOSManager(systemDirectory: directory)

        // Selecting only the dump also brings its side files.
        let single = await manager.importFiles([source.appending(path: "SCPH-70004 EU.BIN")])
        #expect(Set(single.imported) == ["pcsx2/bios/SCPH-70004 EU.BIN", "pcsx2/bios/SCPH-70004 EU.NVM",
                                         "pcsx2/bios/SCPH-70004 EU.ROM1", "pcsx2/bios/scph-70004 eu.erom"])
        #expect(single.unknown.isEmpty)

        // A whole folder: side files are not reported as unknown.
        let folder = await manager.importFiles([source])
        #expect(folder.imported.count == 4)
        #expect(folder.unknown == ["readme.txt"])
        #expect(manager.folderDumps["pcsx2/bios"]?.map(\.fileName) == ["SCPH-70004 EU.BIN"])
    }
}
