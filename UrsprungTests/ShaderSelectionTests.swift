// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import Ursprung

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
