// SPDX-License-Identifier: GPL-3.0-or-later

import Testing
@testable import Ursprung

@Suite("Library states")
struct LibraryStateTests {
    private func state(hasFolders: Bool = true, isScanning: Bool = false, libraryCount: Int = 10,
                       visibleCount: Int = 0, searchText: String = "",
                       selection: LibrarySelection = .all) -> LibraryState {
        LibraryState(hasFolders: hasFolders, isScanning: isScanning, libraryCount: libraryCount,
                     visibleCount: visibleCount, searchText: searchText, selection: selection)
    }

    @Test func noFoldersWelcomes() {
        #expect(state(hasFolders: false, libraryCount: 0) == .welcome)
        #expect(state(hasFolders: false, isScanning: true, libraryCount: 0) == .welcome)
    }

    @Test func anEmptyLibraryShowsScanningOrNoGames() {
        #expect(state(isScanning: true, libraryCount: 0) == .scanning)
        #expect(state(libraryCount: 0) == .noGames)
        #expect(state(libraryCount: 0, searchText: "zelda") == .noGames)
    }

    @Test func scanningKeepsTheGridOfKnownGames() {
        #expect(state(isScanning: true, visibleCount: 10) == .games)
        #expect(state(isScanning: true, selection: .favorites) == .noFavorites)
    }

    @Test func searchWinsOverTheSelectionsEmptyState() {
        #expect(state(searchText: "zelda", selection: .favorites) == .noResults(query: "zelda"))
        #expect(state(searchText: "zelda", selection: .all) == .noResults(query: "zelda"))
    }

    @Test func emptySelections() {
        #expect(state(selection: .favorites) == .noFavorites)
        #expect(state(selection: .recent) == .nothingPlayed)
        #expect(state(visibleCount: 3, selection: .favorites) == .games)
    }
}
