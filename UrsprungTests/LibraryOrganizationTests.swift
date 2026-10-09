// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import SwiftData
import Testing
@testable import Ursprung

private func makeContext() throws -> (ModelContainer, ModelContext) {
    let container = try ModelContainer.library(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
    return (container, ModelContext(container))
}

private func game(_ name: String, system: String = "snes", folder: String = "/ROMs") -> Game {
    Game(path: "\(folder)/\(name)", systemID: system, title: TitleFormatter.title(fromFileName: name), fileName: name,
         fileSize: 3, crc32: nil)
}

private func write(_ bytes: [UInt8], to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(bytes).write(to: url)
}

// MARK: - Collections and status

@Suite("Collections")
struct CollectionTests {
    /// Collections backed by a local list instead of the user's preferences.
    private final class Store {
        var names: [String] = []
        var collections: LibraryCollections {
            LibraryCollections(load: { self.names }, save: { self.names = $0 })
        }
    }

    @Test func gamesKeepTheirCollectionsWithoutDuplicates() {
        let game = game("Game.sfc")
        game.collections = ["Couch Co-op", "", "Couch Co-op", "Up Next"]
        #expect(game.collections == ["Couch Co-op", "Up Next"])
        #expect(game.collectionsRaw == "Couch Co-op\nUp Next")
        game.collections = []
        #expect(game.collectionsRaw == nil)
    }

    @Test func createRenameAndDelete() {
        let store = Store()
        let a = game("A.sfc"), b = game("B.sfc")
        let library = [a, b]
        #expect(store.collections.create("  Couch Co-op ", with: [a], library: library) == "Couch Co-op")
        #expect(store.names == ["Couch Co-op"])
        #expect(a.collections == ["Couch Co-op"] && b.collections.isEmpty)

        // Names are unique, ignoring case.
        #expect(store.collections.create("couch co-op", library: library) == nil)
        #expect(store.collections.create("Empty", library: library) == "Empty")
        #expect(store.collections.all(in: library) == ["Couch Co-op", "Empty"])

        #expect(store.collections.rename("Couch Co-op", to: "Party", library: library) == "Party")
        #expect(a.collections == ["Party"] && store.names == ["Party", "Empty"])
        #expect(store.collections.rename("Party", to: "empty", library: library) == nil)

        store.collections.delete("Party", library: library)
        #expect(a.collections.isEmpty && store.names == ["Empty"])
    }

    @Test func collectionsOnlyGamesKnowAreListedToo() {
        let store = Store()
        store.names = ["B"]
        let a = game("A.sfc")
        a.collections = ["Restored", "B"]
        #expect(store.collections.all(in: [a]) == ["B", "Restored"])
    }

    @Test func movingReordersTheSidebar() {
        let store = Store()
        store.names = ["A", "B", "C"]
        store.collections.move(fromOffsets: IndexSet(integer: 2), toOffset: 0, library: [])
        #expect(store.names == ["C", "A", "B"])
    }

    @Test func playStatusIsOptional() {
        let game = game("Game.sfc")
        #expect(game.playStatus == nil)
        game.playStatus = .completed
        #expect(game.playStatusRaw == "completed")
        game.playStatusRaw = "unknown"
        #expect(game.playStatus == nil)
    }
}

// MARK: - Filters

@Suite("Library filter")
struct LibraryFilterTests {
    @Test func parsesGenresPlayersAndDecades() {
        #expect(LibraryFilter.genres(of: "Action, Platform") == ["Action", "Platform"])
        #expect(LibraryFilter.genres(of: "Sports / Football") == ["Sports", "Football"])
        #expect(LibraryFilter.genres(of: nil).isEmpty)
        #expect(LibraryFilter.maximumPlayers("1-4") == 4)
        #expect(LibraryFilter.maximumPlayers("1 - 2") == 2)
        #expect(LibraryFilter.maximumPlayers("1") == 1)
        #expect(LibraryFilter.maximumPlayers("") == nil)
        #expect(LibraryFilter.decade(of: "1994-03-11") == 1990)
        #expect(LibraryFilter.decade(of: "2001") == 2000)
        #expect(LibraryFilter.decade(of: "unknown") == nil)
    }

    @Test func everyCriterionNarrowsTheGames() {
        let coop = game("Coop.sfc")
        coop.genre = "Action, Platform"
        coop.players = "1-2"
        coop.releaseDate = "1993-11-21"
        coop.scrapeState = .matched
        coop.playStatus = .upNext
        let solo = game("Solo.sfc")
        solo.genre = "RPG"
        solo.players = "1"
        solo.releaseDate = "1995-03-11"
        solo.missingSince = .now

        func matches(_ filter: LibraryFilter) -> [String] {
            [coop, solo].filter(filter.matches).map(\.fileName)
        }
        #expect(matches(LibraryFilter()) == ["Coop.sfc", "Solo.sfc"])
        #expect(matches(LibraryFilter(status: .status(.upNext))) == ["Coop.sfc"])
        #expect(matches(LibraryFilter(status: LibraryFilter.Status.none)) == ["Solo.sfc"])
        #expect(matches(LibraryFilter(genre: "platform")) == ["Coop.sfc"])
        #expect(matches(LibraryFilter(players: .multiplayer)) == ["Coop.sfc"])
        #expect(matches(LibraryFilter(players: .single)) == ["Solo.sfc"])
        #expect(matches(LibraryFilter(players: .fourOrMore)).isEmpty)
        #expect(matches(LibraryFilter(decade: 1990)) == ["Coop.sfc", "Solo.sfc"])
        #expect(matches(LibraryFilter(metadata: .complete)) == ["Coop.sfc"])
        #expect(matches(LibraryFilter(metadata: .incomplete)) == ["Solo.sfc"])
        #expect(matches(LibraryFilter(availability: .missing)) == ["Solo.sfc"])
        #expect(matches(LibraryFilter(genre: "RPG", availability: .available)).isEmpty)
        #expect(LibraryFilter(genre: "RPG", decade: 1990).activeCount == 2)
    }

    @Test func optionsListEachGenreOnce() {
        let a = game("A.sfc"), b = game("B.sfc")
        a.genre = "Action, Platform"
        b.genre = "action"
        b.releaseDate = "1988"
        let options = LibraryFilter.options(for: [a, b])
        #expect(options.genres == ["Action", "Platform"])
        #expect(options.decades == [1980])
    }

    @Test func editedMetadataCountsAsComplete() {
        let game = game("Game.sfc")
        #expect(!game.hasCompleteMetadata)
        game.lockedFields = [.title]
        #expect(game.hasCompleteMetadata)
        game.mediaIncomplete = true
        #expect(!game.hasCompleteMetadata)
    }

    @Test func emptyStatesForFiltersAndCollections() {
        func state(_ selection: LibrarySelection, filtered: Bool = false, search: String = "") -> LibraryState {
            LibraryState(hasFolders: true, isScanning: false, libraryCount: 5, visibleCount: 0, searchText: search,
                         selection: selection, isFiltered: filtered)
        }
        #expect(state(.all, filtered: true) == .noFilterResults)
        #expect(state(.favorites, filtered: true) == .noFilterResults)
        #expect(state(.all, filtered: true, search: "x") == .noResults(query: "x"))
        #expect(state(.collection("Party")) == .emptyCollection)
    }

    @Test func sortOrders() {
        let a = game("A.sfc"), b = game("B.sfc", system: "nes")
        a.playTime = 10
        b.playTime = 100
        #expect(LibrarySort.playTime.sorted([a, b]).map(\.fileName) == ["B.sfc", "A.sfc"])
        // “Nintendo Entertainment System” before “Super Nintendo …”.
        #expect(LibrarySort.system.sorted([a, b]).map(\.fileName) == ["B.sfc", "A.sfc"])
        #expect(LibrarySort.playTime.isDescendingByDefault && !LibrarySort.system.isDescendingByDefault)
    }
}

// MARK: - Selection

@Suite("Game selection")
struct GameSelectionTests {
    private let order = [1, 2, 3, 4, 5]

    @Test func clickSelectsOneAndCommandClickToggles() {
        var selection = GameSelection<Int>()
        selection.click(2, modifier: .none, order: order)
        #expect(selection.ids == [2] && selection.single == 2)
        selection.click(4, modifier: .toggle, order: order)
        #expect(selection.ids == [2, 4] && selection.focus == 4 && selection.single == nil)
        selection.click(2, modifier: .toggle, order: order)
        #expect(selection.ids == [4])
        selection.click(4, modifier: .toggle, order: order)
        #expect(selection.isEmpty && selection.focus == nil)
    }

    @Test func shiftSelectsARangeFromTheAnchor() {
        var selection = GameSelection<Int>()
        selection.click(2, modifier: .none, order: order)
        selection.click(4, modifier: .extend, order: order)
        #expect(selection.ids == [2, 3, 4])
        // A new range replaces the earlier one; the anchor stays.
        selection.click(1, modifier: .extend, order: order)
        #expect(selection.ids == [1, 2] && selection.anchor == 2 && selection.focus == 1)
        // Without an anchor, a range is a single game.
        var fresh = GameSelection<Int>()
        fresh.extend(to: 3, order: order)
        #expect(fresh.ids == [3])
    }

    @Test func selectAllKeepsAndReplace() {
        var selection = GameSelection<Int>()
        selection.select(3)
        selection.selectAll(order)
        #expect(selection.count == 5 && selection.focus == 3)
        selection.keep(only: [1, 2])
        #expect(selection.ids == [1, 2] && selection.focus != nil && [1, 2].contains(selection.focus!))
        selection.replace(with: [2, 5], order: order)
        #expect(selection.ids == [2, 5] && selection.focus == 5)
        selection.replace(with: [], order: order)
        #expect(selection.isEmpty && selection.focus == nil && selection.anchor == nil)
    }
}

// MARK: - Variants

@Suite("Game variants")
struct VariantTests {
    @Test func readsNoIntroNames() {
        let info = VariantInfo.parse(fileName: "Legend of Zelda, The - A Link to the Past (Europe) (Rev 1) (En,Fr,De).sfc")
        #expect(info.baseTitle == "The Legend of Zelda - A Link to the Past")
        #expect(info.regions == ["Europe"])
        #expect(info.revision == "1")
        #expect(info.languages == ["en", "fr", "de"])
        #expect(!info.isUnofficial)

        let multi = VariantInfo.parse(fileName: "Game (USA, Europe) (Beta).sfc")
        #expect(multi.regions == ["USA", "Europe"] && multi.flags.contains(.beta) && multi.isUnofficial)

        let disc = VariantInfo.parse(fileName: "Final Fantasy VII (USA) (Disc 2 of 3).cue")
        #expect(disc.disc == 2 && disc.discCount == 3 && disc.regions == ["USA"])
    }

    @Test func readsGoodToolsNames() {
        let info = VariantInfo.parse(fileName: "Secret of Mana (U) [T+Ger1.0] [!].smc")
        #expect(info.regions == ["USA"])
        #expect(info.translation == "de")
        #expect(info.flags.contains(.verified))
        #expect(info.isUnofficial)

        let hack = VariantInfo.parse(fileName: "Super Mario World (JU) [h1].smc")
        #expect(hack.regions == ["Japan", "USA"] && hack.flags.contains(.hack))
        #expect(VariantInfo.parse(fileName: "Game (Translated En).sfc").translation == "en")
        #expect(VariantInfo.parse(fileName: "Game (Proto 2).sfc").flags.contains(.prototype))
        #expect(VariantInfo.parse(fileName: "Game (v1.1).sfc").revision == "1.1")
    }

    @Test func labelsDescribeTheVersion() {
        #expect(!VariantInfo.parse(fileName: "Game (Europe) (Rev 1).sfc").label.isEmpty)
        #expect(VariantInfo.parse(fileName: "Game.sfc").label.isEmpty)
        let game = game("Game.sfc")
        #expect(game.variantLabel == "Game.sfc")
    }

    @Test func versionsShareAKeyButDiscsDoNot() {
        func key(_ name: String, system: String = "snes") -> String {
            VariantGrouping.key(systemID: system, info: VariantInfo.parse(fileName: name))
        }
        #expect(key("Pokémon Red (USA).gb") == key("Pokemon Red (Europe) [!].gb"))
        #expect(key("Game (USA).sfc") != key("Game (USA).sfc", system: "nes"))
        #expect(key("Game (USA) (Disc 1).cue") != key("Game (USA) (Disc 2).cue"))
        #expect(key("Game (Europe) (Disc 1).cue") == key("Game (USA) (Disc 1).cue"))
    }

    @Test func showsTheBestVersionForTheRegion() {
        let usa = game("Game (USA).sfc"), europe = game("Game (Europe).sfc"), hack = game("Game (Europe) [h1].sfc")
        let other = game("Other (USA).sfc")
        let europeFirst = VariantGroups([usa, europe, hack, other], regionOrder: ["Europe", "World", "USA"], languageCode: "en")
        #expect(europeFirst.collapse([usa, europe, hack, other]).map(\.fileName) == ["Game (Europe).sfc", "Other (USA).sfc"])
        #expect(europeFirst.versionCount(of: usa) == 3 && europeFirst.versionCount(of: other) == 1)
        #expect(europeFirst.versions(of: hack).first === europe)

        let usFirst = VariantGroups([usa, europe, hack], regionOrder: ["USA", "World", "Europe"], languageCode: "en")
        #expect(usFirst.collapse([usa, europe, hack]).map(\.fileName) == ["Game (USA).sfc"])

        // Only the versions in view compete: a filter that hides the best one shows the next.
        #expect(usFirst.collapse([europe, hack]).map(\.fileName) == ["Game (Europe).sfc"])
    }

    @Test func playedAndChosenVersionsWin() {
        let usa = game("Game (USA).sfc"), japan = game("Game (Japan).sfc")
        let groups = VariantGroups([usa, japan], regionOrder: ["USA", "Japan"], languageCode: "en")
        #expect(groups.collapse([usa, japan]) == [usa])
        japan.lastPlayed = .now
        #expect(groups.collapse([usa, japan]) == [japan])
        groups.prefer(usa)
        #expect(usa.isPreferredVariant && !japan.isPreferredVariant)
        #expect(groups.collapse([usa, japan]) == [usa])
    }
}

// MARK: - Discs

@Suite("Disc playlists")
struct DiscPlaylistTests {
    @Test func readsLabelsInBothForms() {
        let playlist = DiscPlaylist.parse("""
        #EXTM3U
        #EXTINF:0,Start
        Game (Disc 1).cue
        # a comment

        Game (Disc 2).cue|Ending
        Game (Disc 3).cue
        """)
        #expect(playlist.entries == [
            .init(path: "Game (Disc 1).cue", label: "Start"),
            .init(path: "Game (Disc 2).cue", label: "Ending"),
            .init(path: "Game (Disc 3).cue", label: nil),
        ])
    }

    @Test func writesAPlainListWithoutLabels() {
        let plain = DiscPlaylist(entries: [.init(path: "A.cue"), .init(path: "B.cue", label: " ")])
        #expect(plain.text == "A.cue\nB.cue\n")
        let labelled = DiscPlaylist(entries: [.init(path: "A.cue", label: "Start"), .init(path: "B.cue")])
        #expect(labelled.text == "#EXTM3U\n#EXTINF:0,Start\nA.cue\nB.cue\n")
        #expect(DiscPlaylist.parse(labelled.text) == labelled)
    }

    @Test func referencesAreRelativeInsideTheFolder() {
        let folder = URL(filePath: "/ROMs/PSX", directoryHint: .isDirectory)
        #expect(DiscPlaylist.reference(to: URL(filePath: "/ROMs/PSX/Game/Disc 1.cue"), from: folder) == "Game/Disc 1.cue")
        #expect(DiscPlaylist.reference(to: URL(filePath: "/Other/Disc 1.cue"), from: folder) == "/Other/Disc 1.cue")
        #expect(DiscPlaylist.resolve("Game/Disc 1.cue", in: folder).path(percentEncoded: false) == "/ROMs/PSX/Game/Disc 1.cue")
    }

    @Test func labelledEntriesAreNotMissingTracks() throws {
        let folder = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try write([1], to: folder.appending(path: "Disc 1.chd"))
        let playlist = folder.appending(path: "Game.m3u")
        try "Disc 1.chd|First\nDisc 2.chd\n".write(to: playlist, atomically: true, encoding: .utf8)
        #expect(LibraryScanner.parseM3U(playlist) == ["Disc 1.chd", "Disc 2.chd"])
        #expect(LibraryScanner.missingTracks(of: playlist) == ["Disc 2.chd"])
    }

    @Test func findsLooseDiscSets() {
        #expect(DiscSets.setName(of: "Final Fantasy VII (USA) (Disc 1).cue") == "Final Fantasy VII (USA)")
        #expect(DiscSets.setName(of: "Game (Disc 2 of 3) (Europe).chd") == "Game (Europe)")
        #expect(DiscSets.setName(of: "Game (USA).cue") == nil)
        #expect(DiscSets.missingDiscs([1, 3], declaredCount: nil) == [2])
        #expect(DiscSets.missingDiscs([1, 2], declaredCount: 3) == [3])
        #expect(DiscSets.missingDiscs([], declaredCount: nil).isEmpty)

        let one = game("Game (USA) (Disc 1).cue", system: "psx"), two = game("Game (USA) (Disc 2).cue", system: "psx")
        let elsewhere = game("Game (USA) (Disc 3).cue", system: "psx", folder: "/Other")
        let europe = game("Game (Europe) (Disc 2).cue", system: "psx")
        let set = DiscSets.set(containing: two, in: [europe, two, elsewhere, one])
        #expect(set.map(\.fileName) == ["Game (USA) (Disc 1).cue", "Game (USA) (Disc 2).cue"])
        #expect(DiscSets.set(containing: elsewhere, in: [one, two, elsewhere]) == [elsewhere])
    }

    @Test func aPlaylistJoinsTheDiscsIntoOneGame() throws {
        let data = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: data) }
        let folder = data.appending(path: "ROMs", directoryHint: .isDirectory)
        try write([1], to: folder.appending(path: "Game (Disc 1).cue"))
        try write([2], to: folder.appending(path: "Game (Disc 2).cue"))
        let (container, context) = try makeContext()
        _ = container
        let store = LibraryStore(metadata: MetadataService(), folders: [folder], persistFolders: { _ in },
                                 scrapesAutomatically: { false }, saves: data.appending(path: "Saves"),
                                 states: data.appending(path: "States"))
        let one = game("Game (Disc 1).cue", system: "psx", folder: folder.path(percentEncoded: false).trimmingSuffix("/"))
        let two = game("Game (Disc 2).cue", system: "psx", folder: folder.path(percentEncoded: false).trimmingSuffix("/"))
        one.playTime = 60
        two.playTime = 600
        two.isFavorite = true
        one.collections = ["RPGs"]
        context.insert(one)
        context.insert(two)
        try context.save()

        let playlist = folder.appending(path: "Game.m3u")
        try DiscPlaylist(entries: [.init(path: "Game (Disc 1).cue"), .init(path: "Game (Disc 2).cue")]).write(to: playlist)
        let main = try #require(try store.adoptPlaylist(playlist, discs: [one, two], context: context))

        let games = try context.fetch(FetchDescriptor<Game>())
        #expect(games.count == 1)
        // The disc played most keeps its identity.
        #expect(main.id == two.id && main.path == playlist.standardizedFileURL.path(percentEncoded: false))
        #expect(main.playTime == 660 && main.isFavorite && main.collections == ["RPGs"])
        #expect(main.title == "Game" && main.missingTracks.isEmpty)
    }
}

private extension String {
    func trimmingSuffix(_ suffix: String) -> String {
        hasSuffix(suffix) ? String(dropLast(suffix.count)) : self
    }
}

// MARK: - Importing

@Suite("Importing files")
struct ImportTests {
    @Test func scansSingleFiles() throws {
        let folder = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let rom = folder.appending(path: "Game (USA).sfc")
        let cue = folder.appending(path: "Disc.cue")
        let bin = folder.appending(path: "Disc.bin")
        let unknown = folder.appending(path: "Mystery.xyz")
        try write([1, 2, 3], to: rom)
        try #"FILE "Disc.bin" BINARY"#.write(to: cue, atomically: true, encoding: .utf8)
        try write([0], to: bin)
        try write([0], to: unknown)

        let scan = LibraryScanner.scan(files: [rom, cue, bin, unknown])
        #expect(scan.roms.map(\.fileName) == ["Game (USA).sfc"])
        // The track belongs to the cue sheet; .cue alone needs a system folder.
        #expect(Set(scan.unrecognized.map(\.lastPathComponent)) == ["Disc.cue", "Mystery.xyz"])
    }

    @Test func addsFilesOutsideTheLibraryFolders() async throws {
        let data = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: data) }
        let downloads = data.appending(path: "Downloads", directoryHint: .isDirectory)
        let rom = downloads.appending(path: "Game (USA).sfc")
        let unknown = downloads.appending(path: "Mystery.xyz")
        try write([1, 2, 3], to: rom)
        try write([0], to: unknown)
        let (container, context) = try makeContext()
        _ = container
        let store = LibraryStore(metadata: MetadataService(), folders: [], persistFolders: { _ in },
                                 scrapesAutomatically: { false }, saves: data.appending(path: "Saves"),
                                 states: data.appending(path: "States"))

        let result = await store.importItems([rom, unknown], context: context)
        #expect(result.games.map(\.fileName) == ["Game (USA).sfc"])
        #expect(result.unrecognized == 1 && store.unrecognizedFiles.map(\.lastPathComponent) == ["Mystery.xyz"])
        #expect(result.games.first?.systemID == "snes")

        // Adding it again finds the same game and brings a hidden one back.
        result.games.first?.isHidden = true
        let again = await store.importItems([rom], context: context)
        #expect(again.games.count == 1 && again.games.first?.isHidden == false)
        #expect(try context.fetch(FetchDescriptor<Game>()).count == 1)

        // A later scan keeps the game although no library folder covers it.
        await store.rescan(context: context)
        #expect(try context.fetch(FetchDescriptor<Game>()).first?.isMissing == false)
    }

    @Test func foldersBecomeLibraryFolders() async throws {
        let data = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: data) }
        let folder = data.appending(path: "SNES", directoryHint: .isDirectory)
        try write([1, 2, 3], to: folder.appending(path: "Game.sfc"))
        let (container, context) = try makeContext()
        _ = container
        var persisted: [URL] = []
        let store = LibraryStore(metadata: MetadataService(), folders: [], persistFolders: { persisted = $0 },
                                 scrapesAutomatically: { false }, saves: data.appending(path: "Saves"),
                                 states: data.appending(path: "States"))
        _ = await store.importItems([folder], context: context)
        #expect(persisted.map(\.lastPathComponent) == ["SNES"])
        #expect(try context.fetch(FetchDescriptor<Game>()).map(\.fileName) == ["Game.sfc"])
    }

    @Test func finderOpensEveryCatalogExtension() throws {
        let types = try #require(Bundle.main.infoDictionary?["CFBundleDocumentTypes"] as? [[String: Any]])
        let declared = Set(types.flatMap { $0["CFBundleTypeExtensions"] as? [String] ?? [] })
        // Archives and extensions other files commonly use are left out on purpose.
        let excluded: Set<String> = ["zip", "7z", "md", "o", "dmg", "iso", "img", "bin", "toc"]
        let catalog = Set(SystemCatalog.all.flatMap(\.extensions)).union(SystemCatalog.ambiguousExtensions)
        #expect(catalog.subtracting(excluded).subtracting(declared).isEmpty)
        #expect(declared.isDisjoint(with: excluded))
    }
}

// MARK: - Save states

@Suite("Save state names and history")
struct SaveStateHistoryTests {
    private let gameID = UUID()
    private let context = SaveStateContext(coreID: "snes9x", coreVersion: "1.62", gameCRC32: nil,
                                           gameFileName: "Game.sfc", gameFileSize: 3)

    @Test func overwritingKeepsThePreviousStateInTheHistory() throws {
        let states = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: states) }
        let directory = SaveStateStore.directory(in: states, gameID: gameID, coreID: "snes9x")
        try SaveStateStore.write(Data([1]), manifest: context.manifest(), slot: 3, in: directory,
                                 date: Date(timeIntervalSince1970: 1000))
        try write([9], to: directory.appending(path: "slot3.png"))
        try SaveStateStore.write(Data([2]), manifest: context.manifest(), slot: 3, in: directory,
                                 date: Date(timeIntervalSince1970: 2000))

        let slots = SaveStateStore.slots(in: states, gameID: gameID, coreID: "snes9x")
        #expect(try Data(contentsOf: slots[0].stateURL) == Data([2]))
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "slot3.png").path(percentEncoded: false)))
        let history = SaveStateStore.history(in: states, gameID: gameID, coreID: "snes9x")
        #expect(history.count == 1)
        #expect(history[0].slot == 3 && history[0].replaced == Date(timeIntervalSince1970: 2000))
        #expect(try Data(contentsOf: history[0].stateURL) == Data([1]))
        #expect(FileManager.default.fileExists(atPath: history[0].thumbnailURL.path(percentEncoded: false)))
        #expect(history[0].manifest != nil && history[0].isHistory)
        // No leftovers from the safe write.
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))
        #expect(!files.contains { $0.hasPrefix(".") })
    }

    @Test func deletedStatesCanBeRestored() throws {
        let states = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: states) }
        let directory = SaveStateStore.directory(in: states, gameID: gameID, coreID: "snes9x")
        try SaveStateStore.write(Data([1]), manifest: context.manifest(), slot: 1, in: directory)
        try SaveStateStore.discard(SaveStateStore.slots(in: states, gameID: gameID, coreID: "snes9x")[0])
        #expect(SaveStateStore.slots(in: states, gameID: gameID, coreID: "snes9x").isEmpty)

        let entry = try #require(SaveStateStore.history(in: states, gameID: gameID, coreID: "snes9x").first)
        try SaveStateStore.restore(entry, toSlot: 1, in: directory)
        #expect(try Data(contentsOf: SaveStateStore.slots(in: states, gameID: gameID, coreID: "snes9x")[0].stateURL) == Data([1]))
        #expect(SaveStateStore.history(in: states, gameID: gameID, coreID: "snes9x").isEmpty)

        // Deleting a state from the history removes it for good.
        try SaveStateStore.write(Data([2]), manifest: context.manifest(), slot: 1, in: directory)
        let replaced = try #require(SaveStateStore.history(in: states, gameID: gameID, coreID: "snes9x").first)
        try SaveStateStore.discard(replaced)
        #expect(SaveStateStore.history(in: states, gameID: gameID, coreID: "snes9x").isEmpty)
    }

    @Test func theOldestStateOfAFullHistoryComesBackWhole() throws {
        let states = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: states) }
        let directory = SaveStateStore.directory(in: states, gameID: gameID, coreID: "snes9x")
        for index in 0...SaveStateStore.historyLimit {
            try SaveStateStore.write(Data([UInt8(index)]), manifest: context.manifest(), slot: 0, in: directory,
                                     date: Date(timeIntervalSince1970: Double(index)))
            try write([UInt8(index)], to: directory.appending(path: "slot0.png"))
        }
        let history = SaveStateStore.history(in: states, gameID: gameID, coreID: "snes9x")
        #expect(history.count == SaveStateStore.historyLimit)
        let oldest = try #require(history.last)

        try SaveStateStore.restore(oldest, toSlot: 0, in: directory)
        let slot = try #require(SaveStateStore.slots(in: states, gameID: gameID, coreID: "snes9x").first)
        #expect(try Data(contentsOf: slot.stateURL) == Data([0]))
        #expect(try Data(contentsOf: slot.thumbnailURL) == Data([0]), "Its thumbnail came back too")
        #expect(FileManager.default.fileExists(atPath: slot.manifestURL.path(percentEncoded: false)))
        #expect(SaveStateStore.history(in: states, gameID: gameID, coreID: "snes9x").count == SaveStateStore.historyLimit)
    }

    @Test func aStateThatCantBeArchivedIsKept() throws {
        let states = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: states) }
        let directory = SaveStateStore.directory(in: states, gameID: gameID, coreID: "snes9x")
        try SaveStateStore.write(Data([1]), manifest: context.manifest(), slot: 1, in: directory)
        // A file where the history folder goes.
        try write([0], to: SaveStateStore.historyDirectory(directory))

        let slot = try #require(SaveStateStore.slots(in: states, gameID: gameID, coreID: "snes9x").first)
        #expect(throws: (any Error).self) { try SaveStateStore.discard(slot) }
        #expect(try Data(contentsOf: slot.stateURL) == Data([1]), "Not deleted for good")
        #expect(SaveStateStore.history(in: states, gameID: gameID, coreID: "snes9x").isEmpty)
    }

    /// A history state, the automatic one or one of an earlier version that
    /// can't be removed stays, and the caller hears about it (B5 of the
    /// 2026-10-07 re-review).
    @Test func aStateThatCantBeDeletedReportsIt() throws {
        let states = try makeTemporaryDirectory()
        let directory = SaveStateStore.directory(in: states, gameID: gameID, coreID: "snes9x")
        try SaveStateStore.write(Data([1]), manifest: context.manifest(), slot: 1, in: directory)
        try SaveStateStore.discard(try #require(SaveStateStore.slots(in: states, gameID: gameID, coreID: "snes9x").first))
        try SaveStateStore.writeAutosave(Data([2]), manifest: context.manifest(), in: directory)
        let history = SaveStateStore.historyDirectory(directory)
        let locked = [history, directory]
        for folder in locked { try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path) }
        defer {
            for folder in locked { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
            try? FileManager.default.removeItem(at: states)
        }

        let entry = try #require(SaveStateStore.history(in: states, gameID: gameID, coreID: "snes9x").first)
        #expect(throws: (any Error).self) { try SaveStateStore.discard(entry) }
        #expect(FileManager.default.fileExists(atPath: entry.stateURL.path))
        let autosave = try #require(SaveStateStore.autosave(in: states, gameID: gameID, coreID: "snes9x"))
        #expect(throws: (any Error).self) { try SaveStateStore.discard(autosave) }
        #expect(FileManager.default.fileExists(atPath: autosave.stateURL.path))
    }

    @Test func theHistoryIsLimited() throws {
        let states = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: states) }
        let directory = SaveStateStore.directory(in: states, gameID: gameID, coreID: "snes9x")
        for index in 0...(SaveStateStore.historyLimit + 2) {
            try SaveStateStore.write(Data([UInt8(index)]), manifest: context.manifest(), slot: 0, in: directory,
                                     date: Date(timeIntervalSince1970: Double(index)))
        }
        let history = SaveStateStore.history(in: states, gameID: gameID, coreID: "snes9x")
        #expect(history.count == SaveStateStore.historyLimit)
        // The newest replaced state is the one written just before the current one.
        #expect(try Data(contentsOf: history[0].stateURL) == Data([UInt8(SaveStateStore.historyLimit + 1)]))
    }

    @Test func statesCanBeNamed() throws {
        let states = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: states) }
        let directory = SaveStateStore.directory(in: states, gameID: gameID, coreID: "snes9x")
        try SaveStateStore.write(Data([1]), manifest: context.manifest(), slot: 2, in: directory)
        let slot = SaveStateStore.slots(in: states, gameID: gameID, coreID: "snes9x")[0]
        #expect(slot.canRename && slot.name == nil)
        try SaveStateStore.rename(slot, to: "  Before the boss ")
        let named = SaveStateStore.slots(in: states, gameID: gameID, coreID: "snes9x")[0]
        #expect(named.name == "Before the boss")
        try SaveStateStore.rename(named, to: "")
        #expect(SaveStateStore.slots(in: states, gameID: gameID, coreID: "snes9x")[0].name == nil)

        // Manifests without a name (earlier versions) still decode.
        let old = Data(#"{"format":1,"coreID":"a","coreVersion":"1","gameFileName":"G","gameFileSize":1,"created":"2026-01-01T00:00:00Z"}"#.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(SaveStateManifest.self, from: old).name == nil)
    }

    @Test func listsTheStatesOfEveryCore() throws {
        let states = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: states) }
        try SaveStateStore.write(Data([1]), manifest: context.manifest(), slot: 1,
                                 in: SaveStateStore.directory(in: states, gameID: gameID, coreID: "snes9x"))
        try SaveStateStore.writeAutosave(Data([2]), manifest: context.manifest(),
                                         in: SaveStateStore.directory(in: states, gameID: gameID, coreID: "bsnes"))
        try write([3], to: SaveStateStore.gameDirectory(in: states, gameID: gameID).appending(path: "slot4.state"))

        let all = SaveStateStore.allStates(in: states, gameID: gameID)
        #expect(all.map(\.coreID) == ["bsnes", "snes9x", nil])
        #expect(all[0].autosave != nil && all[0].slots.isEmpty)
        #expect(all[1].slots.map(\.slot) == [1])
        #expect(all[2].slots.first?.isLegacy == true && all[2].slots.first?.canRename == false)
    }
}

// MARK: - Schema, backups and controllers

@Suite("Library schema version 4")
struct SchemaV4Tests {
    @Test func libraryFromVersionThreeOpens() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = directory.appending(path: "Library.store")
        do {
            let old = try ModelContainer(for: Schema(versionedSchema: LibrarySchemaV3.self),
                                         configurations: ModelConfiguration(url: store))
            let context = ModelContext(old)
            let game = LibrarySchemaV3.Game(path: "/ROMs/Game.sfc", systemID: "snes", title: "Game", fileName: "Game.sfc",
                                            fileSize: 3, crc32: nil)
            game.isHidden = true
            context.insert(game)
            try context.save()
        }
        let container = try ModelContainer.library(configuration: ModelConfiguration(url: store))
        let game = try #require(try ModelContext(container).fetch(FetchDescriptor<Game>()).first)
        #expect(game.isHidden && game.collections.isEmpty && game.playStatus == nil && !game.isPreferredVariant)
    }

    @Test func backupsCarryCollectionsStatusAndChosenVersions() throws {
        let original = game("Game.sfc")
        original.collections = ["Party"]
        original.playStatus = .playing
        original.isPreferredVariant = true
        let record = original.record
        let copy = Game(record: try JSONDecoder().decode(GameRecord.self, from: JSONEncoder().encode(record)), id: UUID())
        #expect(copy.collections == ["Party"] && copy.playStatus == .playing && copy.isPreferredVariant)

        // Restoring adds collections and keeps a status already set.
        let existing = game("Game.sfc")
        existing.collections = ["Mine"]
        existing.playStatus = .completed
        existing.restore(record)
        #expect(existing.collections == ["Mine", "Party"] && existing.playStatus == .completed)
    }

    @Test func backupsFromBeforeVersionFourDecode() throws {
        let json = Data("""
        [{"id": "\(UUID().uuidString)", "path": "/R/G.sfc", "systemID": "snes", "title": "G", "fileName": "G.sfc",
          "fileSize": 3, "dateAdded": 0, "playCount": 0, "playTime": 0, "isFavorite": false, "scrapeState": "pending",
          "isHidden": true}]
        """.utf8)
        let record = try #require(try JSONDecoder().decode([GameRecord].self, from: json).first)
        #expect(record.collections == nil && record.playStatus == nil && record.isPreferredVariant == nil)
    }

    @Test func controllerButtonsForTheLibrary() {
        var shoulders = PadState()
        shoulders.set(.L, true)
        shoulders.set(.R, true)
        shoulders.set(.X, true)
        #expect(InputRouter.menuCommands(pressed: InputRouter.menuMask(of: [shoulders]), previous: 0)
                == [.secondary, .previousPage, .nextPage])
        #expect(MenuCommand.up.repeats && !MenuCommand.confirm.repeats)
    }
}
