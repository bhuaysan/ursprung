// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import SwiftData
import Testing
@testable import Ursprung

/// A defaults suite of its own, removed when the test ends.
private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
    let suite = "UrsprungTests.ShaderSelection.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    try body(defaults)
}

@Suite("Shader selection")
struct ShaderSelectionTests {
    @Test func builtInFilterValuesDecodeUnchanged() {
        for filter in VideoFilter.allCases {
            #expect(ShaderSelection(rawValue: filter.rawValue) == .builtin(filter))
            #expect(ShaderSelection.builtin(filter).rawValue == filter.rawValue)
        }
    }

    @Test func presetReferencesRoundTrip() throws {
        let raw = "preset:library/crt/crt-royale.slangp"
        let selection = try #require(ShaderSelection(rawValue: raw))
        guard case .preset(let preset) = selection else { Issue.record("not a preset"); return }
        #expect(preset.source == .library)
        #expect(preset.path == "crt/crt-royale.slangp")
        #expect(preset.name == "crt-royale")
        #expect(selection.rawValue == raw)

        let user = try #require(ShaderPresetRef(source: .user, path: "Mine/soft.slangp"))
        #expect(ShaderSelection(rawValue: ShaderSelection.preset(user).rawValue) == .preset(user))
        #expect(user.url(library: URL(filePath: "/L"), user: URL(filePath: "/U")).path == "/U/Mine/soft.slangp")
    }

    @Test(arguments: ["", "crtt", "preset:", "preset:library", "preset:library/", "preset:other/a.slangp",
                      "preset:library/../a.slangp", "preset:user//a.slangp", "preset:user/a/./b.slangp",
                      "preset:library//etc/a.slangp"])
    func rejectsInvalidValues(_ raw: String) {
        #expect(ShaderSelection(rawValue: raw) == nil)
    }

    @Test func systemChoiceWinsOverAllSystems() throws {
        let suite = "UrsprungTests.ShaderSelection.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(ShaderSelection.current(for: "snes", defaults: defaults) == .builtin(.sharp))
        defaults.set("preset:library/crt/zfast-crt.slangp", forKey: PrefKey.videoFilter)
        let preset = try #require(ShaderPresetRef(source: .library, path: "crt/zfast-crt.slangp"))
        #expect(ShaderSelection.current(for: "snes", defaults: defaults) == .preset(preset))
        #expect(ShaderSelection.current(for: nil, defaults: defaults) == .preset(preset))

        defaults.set(VideoFilter.lcd.rawValue, forKey: PrefKey.systemVideoFilter("snes"))
        #expect(ShaderSelection.current(for: "snes", defaults: defaults) == .builtin(.lcd))
        // An unreadable system value falls back to all systems.
        defaults.set("preset:nowhere", forKey: PrefKey.systemVideoFilter("snes"))
        #expect(ShaderSelection.current(for: "snes", defaults: defaults) == .preset(preset))
    }

    @Test func gameChoiceWinsOverSystemAndAllSystems() throws {
        try withDefaults { defaults in
            let game = UUID()
            let preset = try #require(ShaderPresetRef(source: .user, path: "soft.slangp"))
            ShaderScope.all.setSelection(.builtin(.crt), defaults: defaults)
            ShaderScope.system("snes").setSelection(.builtin(.lcd), defaults: defaults)
            #expect(ShaderScope.deciding(gameID: game, systemID: "snes", defaults: defaults) == .system("snes"))
            #expect(ShaderSelection.current(for: "snes", gameID: game, defaults: defaults) == .builtin(.lcd))

            ShaderScope.game(game).setSelection(.preset(preset), defaults: defaults)
            #expect(defaults.string(forKey: "videoFilter.game.\(game.uuidString)") == "preset:user/soft.slangp")
            #expect(ShaderScope.deciding(gameID: game, systemID: "snes", defaults: defaults) == .game(game))
            #expect(ShaderSelection.current(for: "snes", gameID: game, defaults: defaults) == .preset(preset))
            // Other games of the system keep the system's choice.
            #expect(ShaderSelection.current(for: "snes", gameID: UUID(), defaults: defaults) == .builtin(.lcd))

            // Inheriting again removes the key.
            ShaderScope.game(game).setSelection(nil, defaults: defaults)
            #expect(defaults.object(forKey: PrefKey.gameVideoFilter(game)) == nil)
            ShaderScope.system("snes").setSelection(nil, defaults: defaults)
            #expect(ShaderScope.deciding(gameID: game, systemID: "snes", defaults: defaults) == .all)
            #expect(ShaderSelection.current(for: "snes", gameID: game, defaults: defaults) == .builtin(.crt))
        }
    }

    @Test func unreadableGameChoiceFallsBackToTheSystem() throws {
        try withDefaults { defaults in
            let game = UUID()
            defaults.set("preset:elsewhere/a.slangp", forKey: PrefKey.gameVideoFilter(game))
            ShaderScope.system("nes").setSelection(.builtin(.scanlines), defaults: defaults)
            #expect(ShaderScope.deciding(gameID: game, systemID: "nes", defaults: defaults) == .system("nes"))
            #expect(ShaderSelection.current(for: "nes", gameID: game, defaults: defaults) == .builtin(.scanlines))
        }
    }

    @Test func gamePresetsCountAsNeedingThePack() throws {
        try withDefaults { defaults in
            ShaderScope.game(UUID()).setSelection(ShaderSelection(rawValue: "preset:library/crt/zfast-crt.slangp"),
                                                  defaults: defaults)
            #expect(ShaderSelection.usesLibraryPresets(defaults: defaults))
        }
    }

    @Test func noticesSettingsThatNeedThePack() throws {
        let suite = "UrsprungTests.ShaderSelection.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(VideoFilter.crt.rawValue, forKey: PrefKey.videoFilter)
        defaults.set("preset:user/Mine/soft.slangp", forKey: PrefKey.systemVideoFilter("nes"))
        #expect(!ShaderSelection.usesLibraryPresets(defaults: defaults))
        defaults.set("preset:library/crt/zfast-crt.slangp", forKey: PrefKey.systemVideoFilter("gba"))
        #expect(ShaderSelection.usesLibraryPresets(defaults: defaults))
    }
}

@Suite("Presentation layout")
struct PresentationLayoutTests {
    @Test func fitsTheAspectRatioCentredOnWholePixels() {
        // 4:3 into 1001 × 700: 933.33 × 700, centred.
        let layout = PresentationLayout(drawableSize: CGSize(width: 1001, height: 700), frameWidth: 256, frameHeight: 224,
                                        aspectRatio: 4.0 / 3.0, rotation: 0, integerScaling: false)
        #expect(layout.rect == CGRect(x: 34, y: 0, width: 933, height: 700))
        #expect(layout.outputSize == CGSize(width: 933, height: 700))
    }

    @Test func integerScalingKeepsWholeMultiples() {
        let layout = PresentationLayout(drawableSize: CGSize(width: 1920, height: 1080), frameWidth: 256, frameHeight: 224,
                                        aspectRatio: 8.0 / 7.0, rotation: 0, integerScaling: true)
        #expect(layout.rect.height == 896)
        #expect(layout.rect.width == 1024)
        #expect(layout.rect.minY == 92)
        #expect(layout.rect.minX == 448)
    }

    @Test func rotatedGamesRenderUnrotatedOutput() {
        // A vertical arcade game: 4:3 frame turned by 90°.
        let layout = PresentationLayout(drawableSize: CGSize(width: 1600, height: 900), frameWidth: 288, frameHeight: 224,
                                        aspectRatio: 4.0 / 3.0, rotation: 1, integerScaling: false)
        #expect(layout.rect == CGRect(x: 462, y: 0, width: 675, height: 900))
        #expect(layout.outputSize == CGSize(width: 900, height: 675))

        let scaled = PresentationLayout(drawableSize: CGSize(width: 1600, height: 900), frameWidth: 288, frameHeight: 224,
                                        aspectRatio: 4.0 / 3.0, rotation: 3, integerScaling: true)
        #expect(scaled.rect.height == 864)
        #expect(scaled.outputSize.width == 864)
    }

    @Test func emptyDrawablesStillGiveAPixel() {
        let layout = PresentationLayout(drawableSize: .zero, frameWidth: 256, frameHeight: 224, aspectRatio: 0,
                                        rotation: -1, integerScaling: true)
        #expect(layout.rect.width >= 1 && layout.rect.height >= 1)
        #expect(layout.rotation == 0)
    }
}

@Suite("Per-game shaders in the library")
struct GameShaderLibraryTests {
    private func makeStore(data: URL, defaults: UserDefaults) -> LibraryStore {
        LibraryStore(metadata: MetadataService(), folders: [], persistFolders: { _ in }, scrapesAutomatically: { false },
                     saves: data.appending(path: "Saves"), states: data.appending(path: "States"),
                     extras: data.appending(path: "Extras"), defaults: defaults)
    }

    @Test func removingAGameForgetsItsShader() throws {
        let data = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: data) }
        try withDefaults { defaults in
            let container = try ModelContainer.library(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
            let context = ModelContext(container)
            let game = Game(path: "/ROMs/A.sfc", systemID: "snes", title: "A", fileName: "A.sfc", fileSize: 1, crc32: nil)
            context.insert(game)
            ShaderScope.game(game.id).setSelection(.builtin(.crt), defaults: defaults)

            makeStore(data: data, defaults: defaults).remove(game, context: context)

            #expect(defaults.object(forKey: PrefKey.gameVideoFilter(game.id)) == nil)
        }
    }

    @Test func joinedDiscsKeepTheirShader() throws {
        let data = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: data) }
        try withDefaults { defaults in
            let folder = data.appending(path: "ROMs", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for name in ["Game (Disc 1).cue", "Game (Disc 2).cue"] {
                try Data([1]).write(to: folder.appending(path: name))
            }
            let container = try ModelContainer.library(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
            let context = ModelContext(container)
            let path = folder.path(percentEncoded: false)
            let one = Game(path: path + "Game (Disc 1).cue", systemID: "psx", title: "Game", fileName: "Game (Disc 1).cue",
                           fileSize: 1, crc32: nil)
            let two = Game(path: path + "Game (Disc 2).cue", systemID: "psx", title: "Game", fileName: "Game (Disc 2).cue",
                           fileSize: 1, crc32: nil)
            two.playTime = 600
            context.insert(one)
            context.insert(two)
            try context.save()
            // Only the disc that folds into the other has a shader of its own.
            let (oneID, twoID) = (one.id, two.id)
            ShaderScope.game(oneID).setSelection(.builtin(.crtCurved), defaults: defaults)

            let playlist = folder.appending(path: "Game.m3u")
            try DiscPlaylist(entries: [.init(path: "Game (Disc 1).cue"), .init(path: "Game (Disc 2).cue")]).write(to: playlist)
            let main = try #require(try makeStore(data: data, defaults: defaults).adoptPlaylist(playlist, discs: [one, two],
                                                                                                 context: context))

            #expect(main.id == twoID)
            #expect(ShaderScope.game(twoID).selection(defaults: defaults) == .builtin(.crtCurved))
            #expect(defaults.object(forKey: PrefKey.gameVideoFilter(oneID)) == nil)
        }
    }
}
