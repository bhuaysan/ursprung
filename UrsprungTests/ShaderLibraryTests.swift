// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import Ursprung

/// Zips the contents of `folder` (not the folder itself) into `archive`.
func makeZip(at archive: URL, of folder: URL) throws {
    try? FileManager.default.removeItem(at: archive)
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/zip")
    process.currentDirectoryURL = folder
    process.arguments = ["-qr", archive.path(percentEncoded: false), "."]
    try process.run()
    process.waitUntilExit()
    precondition(process.terminationStatus == 0, "zip failed")
}

private func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
}

/// `writeShaderFixtures` into a folder that may not exist yet.
private func writeFixtures(in folder: URL) throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try writeShaderFixtures(in: folder)
}

/// A pack like libretro's: presets in category folders, shaders below them.
private func writePack(in folder: URL) throws {
    try writeFixtures(in: folder.appending(path: "crt", directoryHint: .isDirectory))
    try writeFixtures(in: folder.appending(path: "handheld/lcd", directoryHint: .isDirectory))
    try write("shaders = 1\nshader0 = missing.slang\n", to: folder.appending(path: "misc/broken.slangp"))
}

@Suite("Shader presets: files")
struct SlangPresetFileTests {
    @Test func readsValuesReferencesAndComments() {
        let preset = SlangPresetFile(text: """
            #reference "../base.slangp"
            # a comment
            shaders = "2"
            shader0 = shaders/first.slang
            shader1 = "shaders/second pass.slang" # trailing comment
            scale_type0 = viewport # comment
            textures = "MASK;LUT"
            MASK = "textures/mask.png"
            LUT = textures/lut.png
            """)
        #expect(preset.references == ["../base.slangp"])
        #expect(preset.values["shaders"] == "2")
        #expect(preset.values["scale_type0"] == "viewport")
        #expect(preset.shaderPaths == ["shaders/first.slang", "shaders/second pass.slang"])
        #expect(preset.texturePaths == ["textures/mask.png", "textures/lut.png"])
    }

    @Test func passCountFollowsReferences() throws {
        let folder = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try writeShaderFixtures(in: folder)
        try write("#reference \"../dim-strong.slangp\"\n", to: folder.appending(path: "more/again.slangp"))

        #expect(SlangPresetFile.passCount(of: folder.appending(path: "dim.slangp")) == 1)
        #expect(SlangPresetFile.passCount(of: folder.appending(path: "more/again.slangp")) == 1)
        #expect(SlangPresetFile.passCount(of: folder.appending(path: "none.slangp")) == nil)
    }

    @Test func dependenciesIncludeReferencesShadersIncludesAndTextures() throws {
        let folder = try makeTemporaryDirectory().standardizedFileURL
        defer { try? FileManager.default.removeItem(at: folder) }
        try write("#version 450\n#include \"../include/common.inc\"\n", to: folder.appending(path: "shaders/pass.slang"))
        try write("// common\n", to: folder.appending(path: "include/common.inc"))
        try write("png", to: folder.appending(path: "textures/mask.png"))
        try write("shaders = 2\nshader0 = shaders/pass.slang\nshader1 = shaders/gone.slang\ntextures = MASK\nMASK = textures/mask.png\n",
                  to: folder.appending(path: "base.slangp"))
        try write("#reference \"../base.slangp\"\n#reference \"/Library/elsewhere.slangp\"\n",
                  to: folder.appending(path: "presets/mine.slangp"))

        let (files, missing) = SlangPresetFile.dependencies(of: folder.appending(path: "presets/mine.slangp"))
        let relative = Set(files.map { $0.path(percentEncoded: false).replacing(folder.path(percentEncoded: false), with: "") })
        #expect(relative == ["presets/mine.slangp", "base.slangp", "shaders/pass.slang", "include/common.inc",
                             "textures/mask.png"])
        #expect(missing == ["shaders/gone.slang"])
    }
}

@Suite("Shader library")
struct ShaderLibraryTests {
    private func makeLibrary(root: URL, pack: URL? = nil, lastModified: Date? = nil,
                             defaults: UserDefaults = UserDefaults(suiteName: "UrsprungTests.Shaders.\(UUID().uuidString)")!)
        -> ShaderLibrary {
        ShaderLibrary(root: root.appending(path: "Shaders", directoryHint: .isDirectory),
                      downloader: { _, progress in
                          guard let pack else { throw URLError(.notConnectedToInternet) }
                          progress(1)
                          let copy = root.appending(path: "\(UUID().uuidString).zip")
                          try FileManager.default.copyItem(at: pack, to: copy)
                          return copy
                      },
                      lastModified: { _ in lastModified },
                      defaults: defaults)
    }

    @Test func indexesCategoriesFoldersAndSummaries() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = makeLibrary(root: root)
        try writePack(in: library.libraryDirectory)
        try writeFixtures(in: library.userDirectory.appending(path: "Mine", directoryHint: .isDirectory))

        library.refresh()
        await library.waitForIndex()

        let byPath = Dictionary(uniqueKeysWithValues: library.presets.map { ("\($0.ref.source)/\($0.ref.path)", $0) })
        #expect(library.presets.count == 7)
        // The user's presets come first.
        #expect(library.presets.first?.ref.source == .user)
        let lcd = try #require(byPath["library/handheld/lcd/dim-strong.slangp"])
        #expect(lcd.category == "handheld" && lcd.folder == "lcd")
        #expect(lcd.passes == 1 && lcd.parameters == 1 && lcd.problem == nil)
        let mine = try #require(byPath["user/Mine/dim.slangp"])
        #expect(mine.category == "" && mine.folder == "Mine")
        let broken = try #require(byPath["library/misc/broken.slangp"])
        #expect(broken.problem != nil && broken.parameters == nil)
        #expect((library.packSize ?? 0) > 0)
        #expect(ShaderIndex.title(ofCategory: "edge-smoothing") == "Edge Smoothing")
        #expect(ShaderIndex.title(ofCategory: "nes_raw_palette") == "NES Raw Palette")
        #expect(ShaderIndex.title(ofCategory: "stereoscopic-3d") == "Stereoscopic 3D")
    }

    @Test func cacheSkipsUnchangedPresets() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pack = root.appending(path: "pack", directoryHint: .isDirectory)
        let user = root.appending(path: "user", directoryHint: .isDirectory)
        try writePack(in: pack)

        let first = ShaderIndex.scan(library: pack, user: user, cache: ShaderIndex.Cache())
        #expect(first.pending.count == 5)
        let cache = ShaderIndex.updated(ShaderIndex.Cache(), found: first.found, summaries: ShaderIndex.summarize(first.pending))
        let second = ShaderIndex.scan(library: pack, user: user, cache: cache)
        #expect(second.pending.isEmpty)
        #expect(second.presets.allSatisfy { $0.passes != nil })

        let changed = pack.appending(path: "crt/dim.slangp")
        try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(10)],
                                              ofItemAtPath: changed.path(percentEncoded: false))
        #expect(ShaderIndex.scan(library: pack, user: user, cache: cache).pending.map(\.ref.path) == ["crt/dim.slangp"])
    }

    @Test func installsUpdatesAndRemovesThePack() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "source", directoryHint: .isDirectory)
        try writePack(in: source)
        let archive = root.appending(path: "shaders_slang.zip")
        try makeZip(at: archive, of: source)
        let library = makeLibrary(root: root, pack: archive, lastModified: .now.addingTimeInterval(3600))
        #expect(!library.isPackInstalled)

        try await library.installPack()
        await library.waitForIndex()
        #expect(library.isPackInstalled && !library.isInstallingPack && library.downloadProgress == nil)
        #expect(library.presets.count == 5)
        #expect(FileManager.default.fileExists(atPath: library.libraryDirectory.appending(path: "crt/dim.slang").path(percentEncoded: false)))

        try await library.checkForUpdates()
        #expect(library.updateAvailable)

        // A new instance reads the install date back.
        #expect(makeLibrary(root: root).packInstalled == library.packInstalled)

        try library.removePack()
        await library.waitForIndex()
        #expect(!library.isPackInstalled && library.presets.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: library.libraryDirectory.path(percentEncoded: false)))
    }

    @Test func archiveWithoutPresetsKeepsTheInstalledPack() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appending(path: "other.zip")
        try makeZip(at: archive, containing: "readme.txt", bytes: Data("no shaders".utf8))
        let library = makeLibrary(root: root, pack: archive)
        try writePack(in: library.libraryDirectory)

        await #expect(throws: ShaderLibrary.LibraryError.self) { try await library.installPack() }
        #expect(FileManager.default.fileExists(atPath: library.libraryDirectory.appending(path: "crt/dim.slangp").path(percentEncoded: false)))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: library.libraryDirectory.deletingLastPathComponent().path(percentEncoded: false))
        #expect(leftovers.sorted() == ["slang-shaders"])
    }

    @Test func importsFoldersAndPresetsWithTheirFiles() async throws {
        let root = try makeTemporaryDirectory().standardizedFileURL
        defer { try? FileManager.default.removeItem(at: root) }
        let library = makeLibrary(root: root)
        let downloads = root.appending(path: "Downloads", directoryHint: .isDirectory)
        try writeFixtures(in: downloads.appending(path: "Pack", directoryHint: .isDirectory))
        // A preset whose shader is one folder up.
        try write(dimShader, to: downloads.appending(path: "shaders/dim.slang"))
        try write("shaders = 1\nshader0 = ../shaders/dim.slang\n", to: downloads.appending(path: "presets/soft.slangp"))
        try write("text", to: downloads.appending(path: "notes.txt"))

        let result = await library.importItems([downloads.appending(path: "Pack"), downloads.appending(path: "presets/soft.slangp"),
                                                downloads.appending(path: "notes.txt")])
        #expect(Set(result.presets.map(\.path)) == ["Pack/dim.slangp", "Pack/dim-strong.slangp", "soft/presets/soft.slangp"])
        #expect(result.failures.map(\.name) == ["notes.txt"])
        #expect(result.missing.isEmpty)
        #expect(FileManager.default.fileExists(atPath: library.userDirectory.appending(path: "soft/shaders/dim.slang").path(percentEncoded: false)))

        // The copy works on its own.
        let soft = library.url(of: try #require(result.presets.first { $0.path.hasPrefix("soft/") }))
        #expect(try ShaderPreset.parametersOfPreset(atPath: soft.path(percentEncoded: false)).count == 1)

        // A second import gets its own folder; the user's own files are refused.
        let again = await library.importItems([downloads.appending(path: "Pack"), library.userDirectory.appending(path: "Pack")])
        #expect(again.presets.map(\.path).allSatisfy { $0.hasPrefix("Pack 2/") })
        #expect(again.failures.count == 1)
        await library.waitForIndex()
        #expect(library.presets.count == 5)
    }

    @Test func importLeavesFilesBehindThatArentShadersOrImages() async throws {
        let root = try makeTemporaryDirectory().standardizedFileURL
        defer { try? FileManager.default.removeItem(at: root) }
        let library = makeLibrary(root: root)
        let downloads = root.appending(path: "Downloads", directoryHint: .isDirectory)
        try write("secret", to: root.appending(path: "Private/id_rsa"))
        try write("secret", to: root.appending(path: "Private/notes.txt"))
        try write("png", to: downloads.appending(path: "shaders/mask.png"))
        try write(dimShader.replacing("#version 450", with: "#version 450\n#include \"../../Private/notes.txt\""),
                  to: downloads.appending(path: "shaders/dim.slang"))
        try write("shaders = 1\nshader0 = ../shaders/dim.slang\ntextures = \"MASK;KEY\"\nMASK = ../shaders/mask.png\nKEY = ../../Private/id_rsa\n",
                  to: downloads.appending(path: "presets/greedy.slangp"))

        let result = await library.importItems([downloads.appending(path: "presets/greedy.slangp")])
        #expect(result.presets.map(\.path) == ["greedy/presets/greedy.slangp"], "Laid out as if the other files weren't there")
        #expect(result.failures.map(\.name) == ["greedy.slangp"])
        #expect(result.failures.first?.reason.contains("id_rsa") == true)
        let copied = FileManager.default.enumerator(atPath: library.userDirectory.path(percentEncoded: false))?
            .compactMap { $0 as? String } ?? []
        #expect(Set(copied.filter { !$0.hasSuffix("/") }.map { ($0 as NSString).lastPathComponent })
            .isSuperset(of: ["greedy.slangp", "dim.slang", "mask.png"]))
        #expect(!copied.contains { $0.hasSuffix("id_rsa") || $0.hasSuffix("notes.txt") })
    }

    /// A preset takes along only what lies in its package: the folder of the
    /// preset, the presets it references and their passes (B1 of the
    /// 2026-10-07 re-review).
    @Test func importStaysInsideThePresetsPackage() async throws {
        let root = try makeTemporaryDirectory().standardizedFileURL
        defer { try? FileManager.default.removeItem(at: root) }
        let library = makeLibrary(root: root)
        let downloads = root.appending(path: "Downloads", directoryHint: .isDirectory)
        try write("png", to: root.appending(path: "Private/photo.png"))
        try write("text", to: root.appending(path: "Private/folder.png/notes.txt"))
        try write("// outside\n", to: root.appending(path: "Private/shared.inc"))
        try write("png", to: root.appending(path: "Private/linked.png"))
        try write("png", to: downloads.appending(path: "Pack/textures/mask.png"))
        try FileManager.default.createSymbolicLink(at: downloads.appending(path: "Pack/textures/link.png"),
                                                   withDestinationURL: root.appending(path: "Private/linked.png"))
        try write(dimShader.replacing("#version 450", with: "#version 450\n#include \"../../../Private/shared.inc\""),
                  to: downloads.appending(path: "Pack/shaders/dim.slang"))
        try write("""
            shaders = 1
            shader0 = shaders/dim.slang
            textures = "MASK;PHOTO;FOLDER;LINK"
            MASK = textures/mask.png
            PHOTO = ../../Private/photo.png
            FOLDER = ../../Private/folder.png
            LINK = textures/link.png
            """, to: downloads.appending(path: "Pack/greedy.slangp"))

        let result = await library.importItems([downloads.appending(path: "Pack/greedy.slangp")])
        #expect(result.presets.map(\.path) == ["greedy/greedy.slangp"])
        let reason = try #require(result.failures.first?.reason)
        for name in ["photo.png", "folder.png", "link.png", "shared.inc"] {
            #expect(reason.contains(name), "\(name) is reported")
        }
        let copied = FileManager.default.enumerator(atPath: library.userDirectory.path(percentEncoded: false))?
            .compactMap { $0 as? String } ?? []
        #expect(Set(copied) == ["greedy", "greedy/greedy.slangp", "greedy/shaders", "greedy/shaders/dim.slang",
                                "greedy/textures", "greedy/textures/mask.png"])
    }

    @Test func aPackageMayNotBeTheHomeFolderOrAVolume() throws {
        let home = try makeTemporaryDirectory().standardizedFileURL
        defer { try? FileManager.default.removeItem(at: home) }
        try write(dimShader, to: home.appending(path: "Pack/shaders/dim.slang"))
        try write("shaders = 1\nshader0 = shaders/dim.slang\n", to: home.appending(path: "Pack/dim.slangp"))
        // Its pass belongs to a pack elsewhere in the home folder.
        try write("shaders = 1\nshader0 = ../Pack/shaders/dim.slang\n", to: home.appending(path: "Downloads/wide.slangp"))

        #expect(ShaderImport.package(of: home.appending(path: "Pack/dim.slangp"), home: home)
            == home.appending(path: "Pack", directoryHint: .isDirectory).resolvingSymlinksInPath())
        #expect(ShaderImport.package(of: home.appending(path: "Downloads/wide.slangp"), home: home) == nil)
    }

    /// A folder is copied as it is, but links that lead out of it are not.
    @Test func importedFoldersKeepNoLinksOutOfThem() async throws {
        let root = try makeTemporaryDirectory().standardizedFileURL
        defer { try? FileManager.default.removeItem(at: root) }
        let library = makeLibrary(root: root)
        let pack = root.appending(path: "Downloads/Pack", directoryHint: .isDirectory)
        try writeFixtures(in: pack)
        try write("text", to: root.appending(path: "Private/notes.txt"))
        try FileManager.default.createSymbolicLink(at: pack.appending(path: "linked.slang"),
                                                   withDestinationURL: root.appending(path: "Private/notes.txt"))
        try FileManager.default.createSymbolicLink(at: pack.appending(path: "private"),
                                                   withDestinationURL: root.appending(path: "Private"))
        try FileManager.default.createSymbolicLink(at: pack.appending(path: "same.slangp"),
                                                   withDestinationURL: pack.appending(path: "dim.slangp"))

        let result = await library.importItems([pack])
        #expect(Set(result.presets.map(\.path)) == ["Pack/dim.slangp", "Pack/dim-strong.slangp", "Pack/same.slangp"])
        #expect(result.failures.map(\.name) == ["Pack"])
        #expect(result.failures.first?.reason.contains("linked.slang") == true)
        let copy = library.userDirectory.appending(path: "Pack", directoryHint: .isDirectory)
        let fileManager = FileManager.default
        #expect(!fileManager.fileExists(atPath: copy.appending(path: "linked.slang").path(percentEncoded: false)))
        #expect(!fileManager.fileExists(atPath: copy.appending(path: "private").path(percentEncoded: false)))
        let same = try copy.appending(path: "same.slangp").resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
        #expect(same.isSymbolicLink == false && same.isRegularFile == true, "A link inside the folder becomes a copy")
    }

    @Test func favoritesPersist() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = try #require(UserDefaults(suiteName: "UrsprungTests.Shaders.\(UUID().uuidString)"))
        let library = makeLibrary(root: root, defaults: defaults)
        let royale = try #require(ShaderPresetRef(source: .library, path: "crt/crt-royale.slangp"))
        let mine = try #require(ShaderPresetRef(source: .user, path: "Mine/soft.slangp"))

        library.toggleFavorite(royale)
        library.toggleFavorite(mine)
        #expect(makeLibrary(root: root, defaults: defaults).favorites == [royale, mine])
        library.toggleFavorite(royale)
        #expect(makeLibrary(root: root, defaults: defaults).favorites == [mine])
    }

    /// Unpacks and indexes the real libretro pack:
    /// `TEST_RUNNER_URSPRUNG_SHADER_PACK=<shaders_slang.zip> make test`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["URSPRUNG_SHADER_PACK"] != nil))
    func realPackUnpacksAndIndexes() async throws {
        let pack = URL(filePath: try #require(ProcessInfo.processInfo.environment["URSPRUNG_SHADER_PACK"]))
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = makeLibrary(root: root, pack: pack)

        let clock = ContinuousClock()
        let unpack = try await clock.measure { try await library.installPack() }
        let index = await clock.measure { await library.waitForIndex() }
        let rescan = await clock.measure {
            library.refresh()
            await library.waitForIndex()
        }
        let problems = library.presets.filter { $0.problem != nil }
        print("Shader pack: unpack \(unpack), first index \(index), warm index \(rescan); \(library.presets.count) presets, \(problems.count) with problems")
        for preset in problems.prefix(20) { print("  \(preset.ref.path): \(preset.problem ?? "")") }
        #expect(library.presets.count > 2000)
        // Parameter fragments and wildcard examples (`$CORE$`) have no pass count of their own.
        #expect(library.presets.filter { $0.passes == nil }.count < 50)
        #expect(!problems.contains { $0.problem?.contains(library.libraryDirectory.path(percentEncoded: false)) == true })
        #expect(rescan < .seconds(1))
    }
}
