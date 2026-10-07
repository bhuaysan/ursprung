// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation
import Testing
@testable import Ursprung

// MARK: - Patch builders

nonisolated private func varint(_ value: Int) -> [UInt8] {
    var value = value
    var bytes: [UInt8] = []
    while true {
        let low = UInt8(value & 0x7F)
        value >>= 7
        if value == 0 {
            bytes.append(0x80 | low)
            return bytes
        }
        bytes.append(low)
        value -= 1
    }
}

nonisolated private func le32(_ value: UInt32) -> [UInt8] {
    [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 24)]
}

/// Appends the checksums UPS and BPS end with.
nonisolated private func withFooter(_ body: [UInt8], source: [UInt8], target: [UInt8]) -> Data {
    var bytes = body + le32(Checksum.crc(of: Data(source))) + le32(Checksum.crc(of: Data(target)))
    bytes += le32(Checksum.crc(of: Data(bytes)))
    return Data(bytes)
}

nonisolated private func upsPatch(from source: [UInt8], to target: [UInt8]) -> Data {
    var body = Array("UPS1".utf8) + varint(source.count) + varint(target.count)
    var index = 0, relative = 0
    while index < target.count {
        let original = index < source.count ? source[index] : 0
        guard original != target[index] else { index += 1; continue }
        body += varint(index - relative)
        while index < target.count, (index < source.count ? source[index] : 0) != target[index] {
            body.append((index < source.count ? source[index] : 0) ^ target[index])
            index += 1
        }
        body.append(0)
        index += 1
        relative = index
    }
    return withFooter(body, source: source, target: target)
}

/// SourceRead where the bytes match, TargetRead where they don't.
nonisolated private func bpsPatch(from source: [UInt8], to target: [UInt8]) -> Data {
    var body = Array("BPS1".utf8) + varint(source.count) + varint(target.count) + varint(0)
    var index = 0
    while index < target.count {
        let matches = { (i: Int) in i < source.count && source[i] == target[i] }
        let start = index
        let kind = matches(index)
        while index < target.count, matches(index) == kind { index += 1 }
        let length = index - start
        body += varint((length - 1) << 2 | (kind ? 0 : 1))
        if !kind { body += target[start..<index] }
    }
    return withFooter(body, source: source, target: target)
}

@Suite("ROM patches")
struct ROMPatchTests {
    private let rom: [UInt8] = Array(0..<64)

    @Test func ipsWritesRecordsRunsAndGrowsTheFile() throws {
        var patch = Array("PATCH".utf8)
        patch += [0x00, 0x00, 0x02, 0x00, 0x02, 0xAA, 0xBB]       // 2 bytes at 2
        patch += [0x00, 0x00, 0x10, 0x00, 0x00, 0x00, 0x03, 0xCC] // run of 3 × CC at 16
        patch += [0x00, 0x00, 0x42, 0x00, 0x01, 0xDD]             // past the end: grows to 67
        patch += Array("EOF".utf8)
        let result = [UInt8](try ROMPatch.apply(Data(patch), to: Data(rom)))
        #expect(result.count == 67)
        #expect(result[2] == 0xAA && result[3] == 0xBB)
        #expect(result[16...18].allSatisfy { $0 == 0xCC } && result[19] == 19)
        #expect(result[64] == 0 && result[66] == 0xDD)
    }

    @Test func ipsTruncatesWhenItSaysSo() throws {
        let patch = Array("PATCH".utf8) + Array("EOF".utf8) + [0x00, 0x00, 0x20]
        #expect(try ROMPatch.apply(Data(patch), to: Data(rom)).count == 32)
    }

    @Test func upsAndBpsProduceTheTarget() throws {
        var target = rom
        target[5] = 0xFF
        target.replaceSubrange(20..<24, with: [9, 9, 9, 9])
        target += [1, 2, 3]
        #expect([UInt8](try ROMPatch.apply(upsPatch(from: rom, to: target), to: Data(rom))) == target)
        #expect([UInt8](try ROMPatch.apply(bpsPatch(from: rom, to: target), to: Data(rom))) == target)
    }

    @Test func bpsCopiesFromSourceAndOverlappingTarget() throws {
        let source: [UInt8] = [1, 2, 3, 4], target: [UInt8] = [3, 4, 3, 4, 3, 4]
        var body = Array("BPS1".utf8) + varint(source.count) + varint(target.count) + varint(0)
        body += varint((2 - 1) << 2 | 2) + varint(2 << 1)   // SourceCopy 2 bytes from offset 2
        body += varint((4 - 1) << 2 | 3) + varint(0)        // TargetCopy 4 bytes from 0, overlapping
        let patch = withFooter(body, source: source, target: target)
        #expect([UInt8](try ROMPatch.apply(patch, to: Data(source))) == target)
    }

    @Test func patchesForAnotherROMAreRefused() throws {
        var other = rom
        other[0] = 0x55
        let patch = bpsPatch(from: rom, to: rom.reversed())
        #expect(throws: ROMPatch.PatchError.self) { try ROMPatch.apply(patch, to: Data(other)) }
        #expect(throws: ROMPatch.PatchError.self) { try ROMPatch.check(patch, for: Data(other)) }
        try ROMPatch.check(patch, for: Data(rom))
        #expect(ROMPatch.expectedSourceCRC(patch) == Checksum.crc(of: Data(rom)))
    }

    @Test func damagedAndUnknownPatchesAreRefused() {
        var patch = [UInt8](upsPatch(from: rom, to: rom.map { $0 ^ 1 }))
        patch[8] ^= 0xFF
        #expect(throws: ROMPatch.PatchError.damaged) { try ROMPatch.apply(Data(patch), to: Data(rom)) }
        #expect(throws: ROMPatch.PatchError.unknownFormat) { try ROMPatch.apply(Data("hello".utf8), to: Data(rom)) }
        #expect(throws: ROMPatch.PatchError.damaged) { try ROMPatch.apply(Data(Array("PATCH".utf8) + [0, 0]), to: Data(rom)) }
    }
}

@Suite("Game extras")
struct GameExtrasTests {
    @Test func patchesAreCopiedSelectedAndRemoved() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let gameID = UUID()
        let file = root.appending(path: "Translation: English.ips")
        try Data(Array("PATCH".utf8) + Array("EOF".utf8)).write(to: file)
        let notAPatch = root.appending(path: "readme.ips")
        try Data("hello".utf8).write(to: notAPatch)
        let extras = root.appending(path: "Extras")

        let added = try PatchStore.add(file, in: extras, gameID: gameID)
        #expect(added.lastPathComponent == "Translation- English.ips")
        #expect(throws: ROMPatch.PatchError.self) { try PatchStore.add(notAPatch, in: extras, gameID: gameID) }
        #expect(PatchStore.patches(in: extras, gameID: gameID).map(\.lastPathComponent) == [added.lastPathComponent])
        #expect(PatchStore.active(in: extras, gameID: gameID) == nil)

        try PatchStore.setActive(added, in: extras, gameID: gameID)
        #expect(PatchStore.active(in: extras, gameID: gameID)?.lastPathComponent == added.lastPathComponent)
        #expect(PatchStore.saveFolderName(for: added) == "Translation- English")

        try PatchStore.remove(added, in: extras, gameID: gameID)
        #expect(PatchStore.patches(in: extras, gameID: gameID).isEmpty)
        #expect(PatchStore.active(in: extras, gameID: gameID) == nil)
    }

    @Test func patchedCopyLeavesTheROMAlone() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let rom = root.appending(path: "Game.sfc")
        try Data([1, 2, 3, 4]).write(to: rom)
        let patch = root.appending(path: "fix.ips")
        try Data(Array("PATCH".utf8) + [0, 0, 1, 0, 1, 9] + Array("EOF".utf8)).write(to: patch)

        let copy = try PatchStore.patchedCopy(of: rom, with: patch, into: root.appending(path: "Cache"))
        #expect(try Data(contentsOf: copy) == Data([1, 9, 3, 4]))
        #expect(copy.lastPathComponent == "Game.sfc")
        #expect(try Data(contentsOf: rom) == Data([1, 2, 3, 4]))
    }

    @Test func manualIsReplacedAndRemoved() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let gameID = UUID()
        let extras = root.appending(path: "Extras")
        let first = root.appending(path: "Manual.pdf"), second = root.appending(path: "Booklet.png")
        try Data([1]).write(to: first)
        try Data([2]).write(to: second)

        try ManualStore.setManual(first, in: extras, gameID: gameID)
        try ManualStore.setManual(second, in: extras, gameID: gameID)
        #expect(ManualStore.manual(in: extras, gameID: gameID)?.lastPathComponent == "Booklet.png")
        #expect(try FileManager.default.contentsOfDirectory(atPath: ManualStore.directory(in: extras, gameID: gameID).path).count == 1)
        try ManualStore.removeManual(in: extras, gameID: gameID)
        #expect(ManualStore.manual(in: extras, gameID: gameID) == nil)
    }

    @Test func cheatFilesAreRead() {
        let text = """
        cheats = 3

        cheat0_desc = "Infinite Lives"
        cheat0_code = "7E0DBE:09"
        cheat0_enable = true

        cheat1_desc = ""
        cheat1_code = "C9A1-CD6D+DDA1-CD6D"
        cheat1_enable = false

        cheat2_desc = "No code"
        """
        let cheats = CheatStore.parseCHT(text)
        #expect(cheats.map(\.code) == ["7E0DBE:09", "C9A1-CD6D+DDA1-CD6D"])
        #expect(cheats.map(\.isEnabled) == [true, false])
        #expect(cheats[0].name == "Infinite Lives")
        #expect(!cheats[1].name.isEmpty)
    }

    @Test func cheatsAreSavedPerGame() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let gameID = UUID()
        let cheats = [Cheat(name: "A", code: "1234", isEnabled: true)]
        try CheatStore.save(cheats, in: root, gameID: gameID)
        #expect(CheatStore.cheats(in: root, gameID: gameID) == cheats)
        try CheatStore.save([], in: root, gameID: gameID)
        #expect(!FileManager.default.fileExists(atPath: CheatStore.url(in: root, gameID: gameID).path))
    }

    @Test func screenshotsTakeTheCoreAspectRatioAndRotation() throws {
        let context = try #require(CGContext(data: nil, width: 256, height: 224, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let frame = try #require(context.makeImage())

        let upright = try #require(ScreenshotStore.render(frame, aspectRatio: 4.0 / 3.0, rotation: 0))
        #expect(upright.height == 448 && upright.width == 597)
        let rotated = try #require(ScreenshotStore.render(frame, aspectRatio: 4.0 / 3.0, rotation: 1))
        #expect(rotated.width == 448 && rotated.height == 597)
    }

    @Test func screenshotNamesDoNotCollide() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let gameID = UUID(), date = Date(timeIntervalSince1970: 1_800_000_000)
        let first = ScreenshotStore.newURL(in: root, gameID: gameID, date: date)
        try FileManager.default.createDirectory(at: first.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: first)
        let second = ScreenshotStore.newURL(in: root, gameID: gameID, date: date)
        #expect(second != first && second.lastPathComponent.hasSuffix(" 2.png"))
    }
}

@Suite("Rewind buffer")
struct RewindBufferTests {
    /// A state that compresses badly, so capacity limits are reached quickly.
    private func noisyState(_ seed: UInt64, size: Int) -> [UInt8] {
        var value = seed &* 6364136223846793005 &+ 1442695040888963407
        return (0..<size).map { _ in
            value = value &* 6364136223846793005 &+ 1442695040888963407
            return UInt8(truncatingIfNeeded: value >> 33)
        }
    }

    @Test func stepsBackThroughEveryRecordedState() throws {
        let buffer = try #require(URRewindBufferCreate(1 << 20))
        defer { URRewindBufferFree(buffer) }
        for value in 0..<5 {
            var state = [UInt8](repeating: UInt8(value), count: 1000)
            state[0] = 99
            URRewindBufferPush(buffer, state, state.count)
        }
        #expect(URRewindBufferDepth(buffer) == 4)
        var out = [UInt8](repeating: 0, count: 1000)
        for expected in [3, 2, 1, 0] {
            #expect(URRewindBufferStepBack(buffer, &out, out.count))
            #expect(out[1] == UInt8(expected) && out[999] == UInt8(expected) && out[0] == 99)
        }
        #expect(!URRewindBufferStepBack(buffer, &out, out.count))
    }

    @Test func recordingContinuesFromWhereRewindingStopped() throws {
        let buffer = try #require(URRewindBufferCreate(1 << 20))
        defer { URRewindBufferFree(buffer) }
        for value in [1, 2, 3] { URRewindBufferPush(buffer, [UInt8](repeating: UInt8(value), count: 64), 64) }
        var out = [UInt8](repeating: 0, count: 64)
        #expect(URRewindBufferStepBack(buffer, &out, 64) && out[0] == 2)
        URRewindBufferPush(buffer, [UInt8](repeating: 7, count: 64), 64)
        #expect(URRewindBufferStepBack(buffer, &out, 64) && out[0] == 2)
        #expect(URRewindBufferStepBack(buffer, &out, 64) && out[0] == 1)
    }

    @Test func oldestStatesGoWhenTheBufferIsFull() throws {
        let size = 4096
        let buffer = try #require(URRewindBufferCreate(3 * size))
        defer { URRewindBufferFree(buffer) }
        for seed in 0..<10 { URRewindBufferPush(buffer, noisyState(UInt64(seed), size: size), size) }
        #expect(URRewindBufferDepth(buffer) >= 1 && URRewindBufferDepth(buffer) <= 3)
        #expect(URRewindBufferUsedBytes(buffer) <= 3 * size)
        var out = [UInt8](repeating: 0, count: size)
        #expect(URRewindBufferStepBack(buffer, &out, size))
        #expect(out == noisyState(8, size: size))
    }

    @Test func aDifferentStateSizeStartsOver() throws {
        let buffer = try #require(URRewindBufferCreate(1 << 20))
        defer { URRewindBufferFree(buffer) }
        URRewindBufferPush(buffer, [UInt8](repeating: 1, count: 16), 16)
        URRewindBufferPush(buffer, [UInt8](repeating: 2, count: 16), 16)
        URRewindBufferPush(buffer, [UInt8](repeating: 3, count: 32), 32)
        #expect(URRewindBufferDepth(buffer) == 0)
    }
}

@Suite("Hotkeys and turbo")
struct HotkeyAndTurboTests {
    @Test func newHotkeysGetTheirKeysUnlessTaken() throws {
        // Saved before Rewind and Screenshot existed; F8 is already Quick Load.
        let old = HotkeyMapping(bindings: [
            .menu: KeyBinding(keyCode: HotKey.escape, label: "esc"),
            .quickLoad: KeyBinding(keyCode: HotKey.screenshot, label: "F8"),
        ], knownActions: nil)
        let mapping = old.addingNewActions()
        #expect(mapping.bindings[.rewind]?.keyCode == HotKey.rewind)
        #expect(mapping.bindings[.screenshot] == nil)
        #expect(mapping.bindings[.quickLoad]?.keyCode == HotKey.screenshot)
        // Actions the user knew and cleared stay cleared.
        #expect(mapping.bindings[.fastForward] == nil && mapping.bindings[.quickSave] == nil)

        var cleared = HotkeyMapping.standard
        cleared.bindings[.rewind] = nil
        #expect(cleared.addingNewActions().bindings[.rewind] == nil)
    }

    @Test func profilesFromBeforeTurboStillLoad() throws {
        let data = try JSONEncoder().encode(InputProfile.standard)
        var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["turboButtons"] = nil
        let profile = try #require(InputProfile.decode(try JSONSerialization.data(withJSONObject: json)))
        #expect(profile.turboButtons == nil && profile.turboMask == 0)

        var turbo = profile
        turbo.turboButtons = [.b, .y]
        #expect(turbo.turboMask == (1 << UInt32(RetroButton.B.rawValue)) | (1 << UInt32(RetroButton.Y.rawValue)))
    }

    @Test func keysTypeByPosition() {
        #expect(EmulatedKeyboard.retroKey(forKeyCode: 0x00) == 97)  // A
        #expect(EmulatedKeyboard.retroKey(forKeyCode: 0x24) == 13)  // Return
        #expect(EmulatedKeyboard.retroKey(forKeyCode: 0x7E) == 273) // Up
        #expect(EmulatedKeyboard.retroKey(forKeyCode: 0x6F) == 293) // F12
        #expect(EmulatedKeyboard.modifiers([.shift, .control]) == 0x03)
        #expect(EmulatedKeyboard.isModifierDown(keyCode: 0x38, flags: .shift))
        #expect(!EmulatedKeyboard.isModifierDown(keyCode: 0x38, flags: []))
    }
}

@Suite("Achievements")
struct AchievementTests {
    @Test func everySystemHasARetroAchievementsConsole() {
        // Standalone emulators handle achievements with their own login.
        for system in SystemCatalog.all where system.defaultCore.isLibretro {
            #expect(AchievementService.consoleID(for: system.id) != nil, "\(system.id)")
        }
    }

    @Test func hardcoreRulesComeFromRcheevos() {
        #expect(AchievementClient.isCore("Snes9x", allowedForConsole: 3))
        #expect(AchievementClient.disallowedOption(forCore: "Snes9x", console: 3,
                                                   options: ["snes9x_region": "pal", "snes9x_audio": "on"]) == "snes9x_region")
        #expect(AchievementClient.disallowedOption(forCore: "Snes9x", console: 3, options: ["snes9x_region": "auto"]) == nil)
    }
}

@Suite("Core versions")
struct CoreVersionTests {
    private let core = CoreDefinition(id: "versiontest", name: "Version Test")

    private actor Builds {
        var number = 0
        func next() -> Int { number += 1; return number }
    }

    /// Each download delivers the next build: "build 1", "build 2", …
    private func makeManager(root: URL, built: Date? = nil) throws -> CoreManager {
        for number in 1...3 {
            try makeZip(at: root.appending(path: "build\(number).zip"), containing: core.fileName,
                        bytes: Data("build \(number)".utf8))
        }
        let builds = Builds()
        return CoreManager(
            coresDirectory: root.appending(path: "Cores", directoryHint: .isDirectory),
            systemDirectory: root.appending(path: "System", directoryHint: .isDirectory),
            downloader: { _, _ in
                let copy = root.appending(path: "\(UUID().uuidString).zip")
                try FileManager.default.copyItem(at: root.appending(path: "build\(await builds.next()).zip"), to: copy)
                return copy
            },
            lastModified: { _ in built })
    }

    @Test func anUpdateKeepsThePreviousVersionToGoBackTo() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = try makeManager(root: root)
        _ = try await manager.ensureInstalled(core)
        manager.recordVersion("1.0", for: core)
        #expect(!manager.hasPreviousVersion(core))

        try await manager.install(core)
        #expect(manager.hasPreviousVersion(core))
        #expect(try String(contentsOf: manager.installedURL(for: core), encoding: .utf8) == "build 2")
        #expect(manager.versions[core.id]?.previous?.version == "1.0")
        #expect(manager.versions[core.id]?.current?.version == nil)

        try manager.restorePreviousVersion(core)
        #expect(try String(contentsOf: manager.installedURL(for: core), encoding: .utf8) == "build 1")
        #expect(try String(contentsOf: manager.previousURL(for: core), encoding: .utf8) == "build 2")
        #expect(manager.versions[core.id]?.current?.version == "1.0")

        // The records survive a restart.
        let reloaded = try makeManager(root: root)
        #expect(reloaded.versions[core.id] == manager.versions[core.id])
    }

    @Test func updatesAreNewerBuildsThanTheInstalledOne() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let newer = try makeManager(root: root, built: .now.addingTimeInterval(3600))
        _ = try await newer.ensureInstalled(core)
        try await newer.checkForUpdates(of: [core])
        #expect(newer.updatesAvailable == [core.id])

        let older = try makeManager(root: root, built: .now.addingTimeInterval(-3600))
        try await older.checkForUpdates(of: [core])
        #expect(older.updatesAvailable.isEmpty && older.lastUpdateCheck != nil)
    }
}

@Suite("Video presets")
struct VideoPresetTests {
    @Test func everyFilterHasItsOwnShaderIndex() {
        #expect(Set(VideoFilter.allCases.map(\.shaderIndex)).count == VideoFilter.allCases.count)
    }

    @Test func bezelImagesReplaceEachOther() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let png = root.appending(path: "a.png"), jpg = root.appending(path: "b.PNG")
        try Data([1]).write(to: png)
        try Data([2]).write(to: jpg)
        let bezels = root.appending(path: "Bezels")
        try BezelImages.setImage(png, for: "snes", in: bezels)
        try BezelImages.setImage(jpg, for: "snes", in: bezels)
        #expect(try Data(contentsOf: try #require(BezelImages.image(for: "snes", in: bezels))) == Data([2]))
        #expect(try FileManager.default.contentsOfDirectory(atPath: bezels.path).count == 1)
        try BezelImages.removeImage(for: "snes", in: bezels)
        #expect(BezelImages.image(for: "snes", in: bezels) == nil)
    }
}

@Suite("Backup of extras")
struct ExtrasBackupTests {
    @Test func screenshotsAndCheatsMoveToTheGameTheyJoin() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        func locations(_ name: String) -> DataLocations {
            let base = root.appending(path: name)
            return DataLocations(saves: base.appending(path: "Saves"), states: base.appending(path: "States"),
                                 media: base.appending(path: "Media"), extras: base.appending(path: "Extras"),
                                 bezels: base.appending(path: "Bezels"), shaders: base.appending(path: "Shaders"))
        }
        let source = locations("old")
        let gameID = UUID()
        let screenshot = ScreenshotStore.newURL(in: source.extras, gameID: gameID)
        try FileManager.default.createDirectory(at: screenshot.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([7]).write(to: screenshot)
        try CheatStore.save([Cheat(name: "A", code: "1", isEnabled: true)], in: source.extras, gameID: gameID)
        try FileManager.default.createDirectory(at: source.bezels, withIntermediateDirectories: true)
        try Data([8]).write(to: source.bezels.appending(path: "snes.png"))

        let record = GameRecord(id: gameID, path: "/Mac/Game.sfc", systemID: "snes", title: "Game", fileName: "Game.sfc",
                                fileSize: 3, crc32: nil, fileModified: nil, dateAdded: .now, lastPlayed: nil, playCount: 0,
                                playTime: 0, isFavorite: false, coreID: nil, missingSince: nil, scrapeState: "pending",
                                screenScraperID: nil, overview: nil, developer: nil, publisher: nil, genre: nil,
                                releaseDate: nil, players: nil, rating: nil, boxArtFile: nil, screenshotFile: nil,
                                titleScreenFile: nil, logoFile: nil, fanartFile: nil)
        let archive = root.appending(path: "Backup.zip")
        try Backup.create(records: [record], settings: Data(), locations: source, destination: archive, appVersion: "1.0")
        let contents = try Backup.open(archive)
        defer { contents.remove() }

        let target = UUID()
        let destination = locations("new")
        _ = try Backup.restoreFiles(of: contents, plan: [gameID: Backup.Target(id: target, isNew: false)], renames: [],
                                    locations: destination)
        #expect(ScreenshotStore.screenshots(in: destination.extras, gameID: target).count == 1)
        #expect(CheatStore.cheats(in: destination.extras, gameID: target).map(\.code) == ["1"])
        #expect(BezelImages.image(for: "snes", in: destination.bezels) != nil)
    }
}
