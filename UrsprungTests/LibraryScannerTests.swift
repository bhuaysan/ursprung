// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import Ursprung

@Suite("Title formatting")
struct TitleFormatterTests {
    @Test(arguments: [
        ("Super Mario World (U) [!].smc", "Super Mario World"),
        ("Legend of Zelda, The - A Link to the Past (U) [!].smc", "The Legend of Zelda - A Link to the Past"),
        ("Legend of Zelda, The - Ocarina of Time (U) (V1.2) [!].z64", "The Legend of Zelda - Ocarina of Time"),
        ("Pokemon - Red Version (USA, Europe).gb", "Pokemon - Red Version"),
        ("Sonic_The_Hedgehog.md", "Sonic The Hedgehog"),
        ("Mega Man X (U) (V1.0) [!].smc", "Mega Man X"),
    ])
    func cleansFileNames(fileName: String, expected: String) {
        #expect(TitleFormatter.title(fromFileName: fileName) == expected)
    }
}

@Suite("System detection")
struct SystemDetectionTests {
    @Test func unambiguousExtensions() {
        let cases: [(String, String)] = [("game.sfc", "snes"), ("game.gba", "gba"), ("game.z64", "n64"), ("game.nds", "nds"), ("game.gbc", "gbc")]
        for (file, system) in cases {
            #expect(LibraryScanner.detectSystem(for: URL(filePath: "/tmp/\(file)"), folderSystem: nil)?.id == system)
        }
    }

    @Test func ambiguousExtensionsNeedFolder() {
        let iso = URL(filePath: "/tmp/game.iso")
        #expect(LibraryScanner.detectSystem(for: iso, folderSystem: nil) == nil)
        #expect(LibraryScanner.detectSystem(for: iso, folderSystem: SystemCatalog.system(withID: "psp"))?.id == "psp")
        #expect(LibraryScanner.detectSystem(for: URL(filePath: "/tmp/g.cue"), folderSystem: SystemCatalog.system(withID: "saturn"))?.id == "saturn")
    }

    @Test(arguments: [("PSX", "psx"), ("PlayStation", "psx"), ("Mega Drive", "megadrive"), ("Genesis", "megadrive"),
                      ("SNES", "snes"), ("Sega CD", "segacd"), ("TurboGrafx-16", "pce"), ("Arcade", "arcade")])
    func folderAliases(folder: String, system: String) {
        #expect(SystemCatalog.system(forFolderName: folder)?.id == system)
    }

    @Test func catalogIsConsistent() {
        let ids = SystemCatalog.all.map(\.id)
        #expect(Set(ids).count == ids.count, "System IDs must be unique")
        for system in SystemCatalog.all {
            #expect(!system.cores.isEmpty, "\(system.id) has no core")
            #expect(system.screenScraperID > 0)
        }
    }
}

@Suite("Scanning folders")
struct ScanTests {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "UrsprungTests-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appending(path: "PSX"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appending(path: "SNES"), withIntermediateDirectories: true)
        try Data([0x00, 0x01]).write(to: root.appending(path: "SNES/Super Metroid (JU) [!].smc"))
        try Data("readme".utf8).write(to: root.appending(path: "SNES/readme.txt"))
        try Data(repeating: 0, count: 2352).write(to: root.appending(path: "PSX/Game (Track 1).bin"))
        try Data(repeating: 0, count: 2352).write(to: root.appending(path: "PSX/Game (Track 2).bin"))
        try """
        FILE "Game (Track 1).bin" BINARY
          TRACK 01 MODE2/2352
            INDEX 01 00:00:00
        FILE "Game (Track 2).bin" BINARY
          TRACK 02 AUDIO
            INDEX 01 00:02:00
        """.write(to: root.appending(path: "PSX/Game.cue"), atomically: true, encoding: .utf8)
    }

    @Test func findsGamesAndHidesTracks() {
        defer { try? FileManager.default.removeItem(at: root) }
        let results = LibraryScanner.scan(folder: root)
        #expect(results.count == 2)
        #expect(results.contains { $0.fileName == "Game.cue" && $0.systemID == "psx" })
        #expect(results.contains { $0.title == "Super Metroid" && $0.systemID == "snes" })
        #expect(!results.contains { $0.fileName.hasSuffix(".bin") })
    }

    @Test func parsesCueSheets() {
        defer { try? FileManager.default.removeItem(at: root) }
        let files = CueSheet.referencedFiles(in: root.appending(path: "PSX/Game.cue"))
        #expect(files == ["Game (Track 1).bin", "Game (Track 2).bin"])
    }
}
