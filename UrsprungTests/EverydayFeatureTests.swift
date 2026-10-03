// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import SwiftData
import Testing
@testable import Ursprung

private func makeContext() throws -> (ModelContainer, ModelContext) {
    let container = try ModelContainer.library(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
    return (container, ModelContext(container))
}

private func makeStore(folders: [URL], data: URL) -> LibraryStore {
    LibraryStore(metadata: MetadataService(), folders: folders, persistFolders: { _ in }, scrapesAutomatically: { false },
                 saves: data.appending(path: "Saves"), states: data.appending(path: "States"))
}

private func game(_ name: String = "Game.sfc", system: String = "snes") -> Game {
    Game(path: "/ROMs/\(name)", systemID: system, title: "Game", fileName: name, fileSize: 3, crc32: nil)
}

// MARK: - Editing metadata (M3)

@Suite("Editing metadata")
struct MetadataEditingTests {
    @Test func lockedFieldsSurviveScraping() throws {
        let (container, context) = try makeContext()
        _ = container
        let game = game()
        context.insert(game)
        game.title = "My Title"
        game.developer = "Me"
        game.lockedFields = [.title, .developer]

        var result = ScrapedGame(screenScraperID: "42")
        result.title = "Scraped Title"
        result.developer = "Studio"
        result.publisher = "Publisher"
        MetadataService.takeTexts(of: result, into: game)

        #expect(game.title == "My Title" && game.developer == "Me")
        #expect(game.publisher == "Publisher" && game.screenScraperID == "42")
    }

    @Test func lockedFieldsRoundTrip() {
        let game = game()
        game.lockedFields = [.boxArt, .title]
        #expect(game.lockedFieldsRaw == "boxArt,title")
        #expect(game.isLocked(.boxArt) && !game.isLocked(.genre))
        game.lockedFields = []
        #expect(game.lockedFieldsRaw == nil)
    }

    @Test func chosenSystemSurvivesRescans() async throws {
        let root = try makeTemporaryDirectory()
        let data = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: data)
        }
        let folder = root.appending(path: "SNES", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: folder.appending(path: "Game.zip"))
        let (container, context) = try makeContext()
        _ = container
        let store = makeStore(folders: [root], data: data)
        await store.rescan(context: context)
        let game = try #require(try context.fetch(FetchDescriptor<Game>()).first)
        #expect(game.systemID == "snes")

        game.systemOverride = "megadrive"
        game.systemID = "megadrive"
        try context.save()
        await store.rescan(context: context)
        #expect(game.systemID == "megadrive" && !game.isMissing)
    }
}

// MARK: - Fetching metadata (M9)

@Suite("Metadata jobs")
struct MetadataJobTests {
    @Test func picksTheJobByWhatIsMissing() {
        let game = game()
        #expect(isFull(MetadataService.job(for: game, force: false, automatic: true)))
        game.scrapeState = .notFound
        #expect(MetadataService.job(for: game, force: false, automatic: false) == nil)
        #expect(isFull(MetadataService.job(for: game, force: true, automatic: false)))

        game.scrapeState = .matched
        game.screenScraperID = "1"
        game.boxArtFile = "box.png"
        #expect(MetadataService.job(for: game, force: false, automatic: false) == nil)
        game.mediaIncomplete = true
        #expect(isMedia(MetadataService.job(for: game, force: false, automatic: true)))

        // A cover that never arrived is only retried on request.
        game.mediaIncomplete = false
        game.boxArtFile = nil
        #expect(MetadataService.job(for: game, force: false, automatic: true) == nil)
        #expect(isMedia(MetadataService.job(for: game, force: false, automatic: false)))
        game.lockedFields = [.boxArt]
        #expect(MetadataService.job(for: game, force: false, automatic: false) == nil)
    }

    @Test func sessionProblemsAreNoFaultOfTheGame() {
        #expect(MetadataService.isSessionFailure(ScreenScraperError.quotaExceeded))
        #expect(MetadataService.isSessionFailure(ScreenScraperError.invalidCredentials))
        #expect(MetadataService.isSessionFailure(URLError(.notConnectedToInternet)))
        #expect(!MetadataService.isSessionFailure(ScreenScraperError.invalidResponse))
    }

    @Test func quotaPauseLastsUntilMidnightInFrance() throws {
        let defaults = try #require(UserDefaults(suiteName: "UrsprungTests-\(UUID().uuidString)"))
        nonisolated(unsafe) let store = defaults
        var clock = Date(timeIntervalSince1970: 1_790_000_000) // 2026-09-21 16:53 Paris
        nonisolated(unsafe) var now = clock
        let pause = QuotaPause(defaults: { store }, now: { now })
        #expect(!pause.isActive)
        pause.start()
        #expect(pause.isActive)
        clock += 8 * 3600 // past midnight
        now = clock
        #expect(!pause.isActive)
        pause.start()
        pause.clear()
        #expect(!pause.isActive)
    }

    @Test func parsesTheAccount() {
        let account = ScreenScraperClient().parseAccount(["id": "player", "requeststoday": "12", "maxrequestsperday": "20000"])
        #expect(account == ScraperAccount(username: "player", requestsToday: 12, maxRequestsPerDay: 20000))
    }

    private func isFull(_ job: MetadataService.Job?) -> Bool {
        if case .full? = job { true } else { false }
    }

    private func isMedia(_ job: MetadataService.Job?) -> Bool {
        if case .media? = job { true } else { false }
    }
}

// MARK: - Import report and readiness (M4)

@Suite("Import report")
struct ImportReportTests {
    @Test func reportsMissingTracksAndUnknownFiles() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let psx = root.appending(path: "PSX", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: psx, withIntermediateDirectories: true)
        try Data("FILE \"Game (Track 1).bin\" BINARY\nFILE \"Game (Track 2).bin\" BINARY\n".utf8)
            .write(to: psx.appending(path: "Game.cue"))
        try Data([0]).write(to: psx.appending(path: "Game (Track 1).bin"))
        try Data("Game.cue\n".utf8).write(to: psx.appending(path: "Game.m3u"))
        try Data([0]).write(to: root.appending(path: "Mystery.xyz"))
        try Data([0]).write(to: root.appending(path: "Notes.txt"))
        try Data([0]).write(to: root.appending(path: "Game.srm"))

        let scan = LibraryScanner.scan(folders: [root])

        let playlist = try #require(scan.roms.first { $0.fileName == "Game.m3u" })
        #expect(playlist.missingTracks == ["Game (Track 2).bin"])
        #expect(scan.unrecognized.map(\.lastPathComponent) == ["Mystery.xyz"])
    }

    @Test func addedFilesStayPresent() async throws {
        let root = try makeTemporaryDirectory()
        let data = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: data)
        }
        let file = root.appending(path: "Homebrew.xyz")
        try Data([1]).write(to: file)
        let (container, context) = try makeContext()
        _ = container
        let store = makeStore(folders: [root], data: data)
        await store.rescan(context: context)
        #expect(store.unrecognizedFiles.map(\.lastPathComponent) == ["Homebrew.xyz"])

        store.addUnrecognized(file, systemID: "nes", context: context)
        await store.rescan(context: context)

        let game = try #require(try context.fetch(FetchDescriptor<Game>()).first)
        #expect(game.systemID == "nes" && !game.isMissing)
        #expect(store.unrecognizedFiles.isEmpty)
    }

    @Test func biosRequirementsDependOnTheCore() throws {
        let psx = try #require(SystemCatalog.system(withID: "psx"))
        let manager = BIOSManager()
        #expect(manager.missingRequired(for: psx, coreID: "pcsx_rearmed").isEmpty)
        #expect(manager.missingRequired(for: psx, coreID: "swanstation").count == 4)
        #expect(BIOSManager(statuses: ["scph5501.bin": .verified]).missingRequired(for: psx, coreID: "mednafen_psx").isEmpty)
    }
}

// MARK: - Watching and hiding (M7)

@Suite("Watching folders")
struct WatchingTests {
    @Test func hiddenFilesDoNotCount() {
        #expect(LibraryWatcher.isRelevant("/ROMs/SNES/Game.sfc"))
        #expect(!LibraryWatcher.isRelevant("/ROMs/SNES/.DS_Store"))
        #expect(!LibraryWatcher.isRelevant("/ROMs/.Trashes/Game.sfc"))
    }

    @Test func burstsBecomeOneScan() async throws {
        let scheduler = RescanScheduler(settle: .milliseconds(50), minimumInterval: 0)
        var scans = 0
        for _ in 0..<5 {
            scheduler.request { scans += 1; return true }
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(scans == 1)
    }

    @Test func aBusyScanIsRetried() async throws {
        let scheduler = RescanScheduler(settle: .milliseconds(20), minimumInterval: 0)
        var attempts = 0
        scheduler.request {
            attempts += 1
            return attempts > 1
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(attempts == 2)
    }

    @Test func folderChangesTriggerTheWatcher() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var changes = 0
        let watcher = LibraryWatcher { changes += 1 }
        watcher.watch([root])
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(200))
        try Data([1]).write(to: root.appending(path: "Game.sfc"))
        for _ in 0..<50 where changes == 0 { try await Task.sleep(for: .milliseconds(100)) }
        #expect(changes > 0)
    }

    @Test func hiddenGamesKeepTheirStateAcrossRescans() async throws {
        let root = try makeTemporaryDirectory()
        let data = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: data)
        }
        try Data([1, 2, 3]).write(to: root.appending(path: "Game.sfc"))
        let (container, context) = try makeContext()
        _ = container
        let store = makeStore(folders: [root], data: data)
        await store.rescan(context: context)
        let game = try #require(try context.fetch(FetchDescriptor<Game>()).first)
        game.isHidden = true
        try context.save()
        await store.rescan(context: context)
        #expect(try context.fetch(FetchDescriptor<Game>()).map(\.isHidden) == [true])
    }
}

// MARK: - Resuming (M5)

@Suite("Automatic state")
struct AutosaveTests {
    @Test func autosaveIsApartFromTheSlots() throws {
        let states = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: states) }
        let id = UUID()
        let context = SaveStateContext(coreID: "snes9x", coreVersion: "1", gameCRC32: nil, gameFileName: "G.sfc", gameFileSize: 3)
        let directory = SaveStateStore.directory(in: states, gameID: id, coreID: "snes9x")
        #expect(SaveStateStore.autosave(in: states, gameID: id, coreID: "snes9x") == nil)

        try SaveStateStore.writeAutosave(Data([7]), manifest: context.manifest(), in: directory)

        let autosave = try #require(SaveStateStore.autosave(in: states, gameID: id, coreID: "snes9x"))
        #expect(try Data(contentsOf: autosave.stateURL) == Data([7]))
        #expect(autosave.manifest?.coreID == "snes9x")
        #expect(SaveStateStore.slots(in: states, gameID: id, coreID: "snes9x").isEmpty)
        #expect(SaveStateStore.autosave(in: states, gameID: id, coreID: "bsnes") == nil)
    }
}

// MARK: - Controls (M8)

@Suite("Controls")
struct ControlsTests {
    private func bit(_ button: RetroButton) -> UInt32 { 1 << UInt32(button.rawValue) }

    @Test func controllerButtonsCanBeRemapped() {
        var mapping = ControllerMapping.standard
        var pad = PadState()
        pad.set(.B, true)
        pad.leftStick = SIMD2(0.5, 0)
        #expect(mapping.apply(to: pad) == pad)

        mapping.setSource(.b, for: .a) // the bottom button presses A
        mapping.setSource(nil, for: .b) // and nothing presses B
        let mapped = mapping.apply(to: pad)
        #expect(mapped.buttonMask == bit(.A))
        #expect(mapped.leftStick == pad.leftStick)

        mapping.setSource(.a, for: .a)
        #expect(mapping.sources[.a] == nil, "Mapping a button to itself is the default")
    }

    @Test func fixedPlayersKeepTheirPorts() {
        let ids = PortAssignment.ids(for: [("gc", "DualSense"), ("xinput", "8BitDo"), ("xinput", "8BitDo")])
        #expect(ids == ["gc:DualSense#1", "xinput:8BitDo#1", "xinput:8BitDo#2"])
        #expect(PortAssignment.resolve(ids, fixed: [:], ports: 4) == [0, 1, 2])
        #expect(PortAssignment.resolve(ids, fixed: ["xinput:8BitDo#2": 0], ports: 4) == [1, 2, 0])
        #expect(PortAssignment.resolve(ids, fixed: ["gc:DualSense#1": 1, "xinput:8BitDo#1": 1], ports: 2) == [1, 1, 0])
        #expect(PortAssignment.resolve(ids, fixed: [:], ports: 2) == [0, 1, nil])
    }

    @Test func escAlwaysOpensTheMenu() {
        var hotkeys = HotkeyMapping.standard
        hotkeys.bindings[.menu] = KeyBinding(keyCode: 12, label: "Q")
        #expect(hotkeys.action(forKeyCode: 12) == .menu)
        #expect(hotkeys.action(forKeyCode: HotKey.escape) == .menu)
        #expect(hotkeys.action(forKeyCode: HotKey.quickSave) == .quickSave)
        #expect(hotkeys.action(forKeyCode: 0) == nil)
    }

    @Test func deadZoneIsRadial() {
        #expect(PadState.applyDeadZone(SIMD2(0.1, 0.1), deadZone: 0.2) == .zero)
        let full = PadState.applyDeadZone(SIMD2(1, 0), deadZone: 0.2)
        #expect(full == SIMD2(1, 0))
        let diagonal = PadState.applyDeadZone(SIMD2(0.5, 0.5), deadZone: 0.2)
        #expect(abs(diagonal.x - diagonal.y) < 0.0001 && diagonal.x > 0)
    }

    @Test func aGamesOwnProfileWins() throws {
        var own = InputProfile.standard
        own.keyboard.bindings[.a] = KeyBinding(keyCode: 0, label: "A")
        let data = try #require(own.encoded)
        #expect(InputProfile.resolved(gameProfile: data, systemID: "snes") == own)
    }

    @Test func gameCoreOptionsArePerCore() {
        let game = game()
        #expect(game.coreOptions(for: "snes9x") == nil)
        game.setCoreOptions(["snes9x_region": "PAL"], for: "snes9x")
        game.setCoreOptions([:], for: "bsnes")
        #expect(game.coreOptions(for: "snes9x") == ["snes9x_region": "PAL"])
        #expect(game.coreOptions(for: "bsnes") == [:])
        game.setCoreOptions(nil, for: "snes9x")
        game.setCoreOptions(nil, for: "bsnes")
        #expect(game.coreOptionsData == nil)
    }
}

// MARK: - Updates

@Suite("Updates")
struct UpdateTests {
    @Test func comparesVersions() {
        #expect(UpdateChecker.isNewer("0.10.0", than: "0.9.2"))
        #expect(UpdateChecker.isNewer("1.0", than: "0.9.9"))
        #expect(!UpdateChecker.isNewer("0.1.0", than: "0.1"))
        #expect(!UpdateChecker.isNewer("0.1.0", than: "0.2.0"))
    }

    @Test func parsesARelease() throws {
        let json = Data(#"{"tag_name": "v0.2.0", "html_url": "https://github.com/bhuaysan/ursprung/releases/tag/v0.2.0"}"#.utf8)
        let release = try #require(UpdateChecker.parse(json))
        #expect(release.version == "0.2.0")
    }
}

// MARK: - Schema and backups

@Suite("Library schema version 3")
struct SchemaV3Tests {
    @Test func libraryFromVersionTwoOpens() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = directory.appending(path: "Library.store")
        do {
            let old = try ModelContainer(for: Schema(versionedSchema: LibrarySchemaV2.self),
                                         configurations: ModelConfiguration(url: store))
            let context = ModelContext(old)
            let game = LibrarySchemaV2.Game(path: "/ROMs/Game.sfc", systemID: "snes", title: "Game", fileName: "Game.sfc",
                                            fileSize: 3, crc32: nil)
            game.missingSince = .now
            context.insert(game)
            try context.save()
        }
        let container = try ModelContainer.library(configuration: ModelConfiguration(url: store))
        let game = try #require(try ModelContext(container).fetch(FetchDescriptor<Game>()).first)
        #expect(game.isMissing && !game.isHidden && !game.mediaIncomplete && game.systemOverride == nil)
    }

    @Test func backupsFromBeforeVersionThreeDecode() throws {
        let json = Data("""
        [{"id": "\(UUID().uuidString)", "path": "/R/G.sfc", "systemID": "snes", "title": "G", "fileName": "G.sfc",
          "fileSize": 3, "dateAdded": 0, "playCount": 0, "playTime": 0, "isFavorite": true, "scrapeState": "pending"}]
        """.utf8)
        let records = try JSONDecoder().decode([GameRecord].self, from: json)
        #expect(records.first?.isHidden == nil && records.first?.isFavorite == true)
    }
}

// MARK: - Review fixes (2026-10-03)

@Suite("Review fixes for P0 and P1")
struct ReviewFixTests {
    @Test func aKnownGameThatIsNoLongerRecognizedStaysPresent() async throws {
        let root = try makeTemporaryDirectory()
        let data = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: data)
        }
        let file = root.appending(path: "Homebrew.xyz")
        try Data([1]).write(to: file)
        let (container, context) = try makeContext()
        _ = container
        let store = makeStore(folders: [root], data: data)
        await store.rescan(context: context)
        store.addUnrecognized(file, systemID: "nes", context: context)
        // Back to automatic detection, which cannot tell the system.
        let game = try #require(try context.fetch(FetchDescriptor<Game>()).first)
        game.systemOverride = nil
        try context.save()
        await store.rescan(context: context)

        #expect(!game.isMissing && game.systemID == "nes")
        // Listing it would offer to add the file a second time.
        #expect(store.unrecognizedFiles.isEmpty)
    }

    @Test func batterySavesFollowASystemChange() throws {
        let data = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: data) }
        let (container, context) = try makeContext()
        _ = container
        let store = makeStore(folders: [], data: data)
        let entry = game("Game.gb", system: "gb")
        context.insert(entry)
        let saves = data.appending(path: "Saves")
        let old = BatterySave.url(in: saves, systemID: "gb", gameID: entry.id, baseName: "Game")
        try FileManager.default.createDirectory(at: old.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([7]).write(to: old)

        store.changeSystem(of: entry, to: "gbc")

        let new = BatterySave.url(in: saves, systemID: "gbc", gameID: entry.id, baseName: "Game")
        #expect(entry.systemID == "gbc")
        #expect(try Data(contentsOf: new) == Data([7]))
        #expect(!FileManager.default.fileExists(atPath: old.path(percentEncoded: false)))
    }

    @Test func fetchingMetadataKeepsTheChecksumOfAMissingFile() async throws {
        let (container, context) = try makeContext()
        _ = container
        let entry = Game(path: "/Nowhere/Game.sfc", systemID: "snes", title: "Game", fileName: "Game.sfc", fileSize: 3,
                         crc32: "AABBCCDD")
        context.insert(entry)
        let service = MetadataService(client: { ScreenScraperClient(devID: "", devPassword: "") })
        service.enqueue([entry], force: true, context: context)
        while service.isRunning { await Task.yield() }
        #expect(entry.crc32 == "AABBCCDD")
    }

    @Test func choosingAMatchForAQueuedGameDoesNotCountTwice() throws {
        let (container, context) = try makeContext()
        _ = container
        let entry = game()
        context.insert(entry)
        let service = MetadataService(client: { ScreenScraperClient(devID: "", devPassword: "") })
        service.enqueue([entry], force: true, context: context)
        service.apply(ScrapedGame(screenScraperID: "1"), to: entry, context: context)
        #expect(service.total == 1)
        service.cancel()
    }

    @Test func libraryFoldersInsideHiddenFoldersAreWatched() {
        let folders = ["/Users/me/.roms/SNES/"]
        #expect(LibraryWatcher.isRelevant("/Users/me/.roms/SNES/Game.sfc", folders: folders))
        #expect(LibraryWatcher.isRelevant("/Users/me/.roms/SNES", folders: folders))
        #expect(!LibraryWatcher.isRelevant("/Users/me/.roms/SNES/.DS_Store", folders: folders))
        #expect(!LibraryWatcher.isRelevant("/Users/me/.roms/SNES/.hidden/Game.sfc", folders: folders))
    }

    @Test func missingTracksAreCheckedAgain() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cue = root.appending(path: "Game.cue")
        try Data("FILE \"Game (Track 1).bin\" BINARY\n".utf8).write(to: cue)
        let playlist = root.appending(path: "Game.m3u")
        try Data("Game.cue\n".utf8).write(to: playlist)
        #expect(LibraryScanner.missingTracks(of: cue) == ["Game (Track 1).bin"])
        #expect(LibraryScanner.missingTracks(of: playlist) == ["Game (Track 1).bin"])

        try Data([0]).write(to: root.appending(path: "Game (Track 1).bin"))
        #expect(LibraryScanner.missingTracks(of: cue).isEmpty)
        #expect(LibraryScanner.missingTracks(of: playlist).isEmpty)
        #expect(LibraryScanner.missingTracks(of: root.appending(path: "Game.sfc")).isEmpty)
    }
}
