// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import Ursprung

@Suite("Game grid layout")
struct GridLayoutTests {
    @Test(arguments: [
        (560.0, 180.0, 2),
        (580.0, 180.0, 3), // exactly 3 × 180 + 2 × 20
        (440.0, 180.0, 2),
        (736.0, 180.0, 3),
        (1200.0, 180.0, 6),
        (1200.0, 260.0, 4),
        (560.0, 120.0, 4),
    ])
    func slotsKeepTheChosenStepAndGapsTakeTheRest(width: Double, step: Double, expected: Int) {
        let layout = GridLayout(availableWidth: width, coverStep: step)
        #expect(layout.columns == expected)
        #expect(layout.slotWidth == step)
        #expect(layout.spacing >= 20)
        // Both grid edges stay aligned.
        let used = Double(layout.columns) * layout.slotWidth + Double(layout.columns - 1) * layout.spacing
        #expect(abs(used - width) < 0.001)
    }

    @Test func everyStepChangesTheCoverSize() {
        // With rounding, 150 and 180 pt used to give the same 186 pt slots here.
        let slots = AppMetrics.coverSteps.map { GridLayout(availableWidth: 560, coverStep: $0).slotWidth }
        #expect(slots == AppMetrics.coverSteps)
    }

    @Test func narrowWidthsShrinkTwoColumnsDownToTheSmallestStep() {
        // 260 pt does not fit twice, so two columns share the width.
        let squeezed = GridLayout(availableWidth: 300, coverStep: 260)
        #expect(squeezed.columns == 2)
        #expect(squeezed.slotWidth == 140)
        #expect(squeezed.spacing == 20)

        let smallest = GridLayout(availableWidth: 260, coverStep: 180)
        #expect(smallest.columns == 2)
        #expect(smallest.slotWidth == 120)

        let single = GridLayout(availableWidth: 259, coverStep: 180)
        #expect(single.columns == 1)
        #expect(single.slotWidth == 180)

        #expect(GridLayout(availableWidth: 100, coverStep: 180).slotWidth == 100)
        #expect(GridLayout(availableWidth: 0, coverStep: 180).columns == 1)
        #expect(GridLayout(availableWidth: -10, coverStep: 180).slotWidth == 0)
    }

    @Test func storedSizesSnapToTheNearestStep() {
        #expect(CoverSize.snapped(130) == 120)
        #expect(CoverSize.snapped(170) == 180)
        #expect(CoverSize.snapped(200) == 180) // halfway: the smaller step
        #expect(CoverSize.snapped(280) == 260)
        #expect(CoverSize.snapped(180) == 180)
    }

    @Test func stepsMoveOneAtATimeAndStopAtTheEnds() {
        #expect(CoverSize.larger(than: 180) == 220)
        #expect(CoverSize.smaller(than: 180) == 150)
        #expect(CoverSize.larger(than: 170) == 220) // from the snapped step
        #expect(CoverSize.larger(than: 260) == nil)
        #expect(CoverSize.smaller(than: 120) == nil)
    }
}

@Suite("Game grid navigation")
struct GridNavigationTests {
    // 10 games in 4 columns:
    //  0  1  2  3
    //  4  5  6  7
    //  8  9
    private func target(_ move: GridMove, from index: Int?, pageRows: Int = 1, entry: Int = 0) -> Int? {
        GridNavigation.target(of: move, from: index, count: 10, columns: 4, pageRows: pageRows, entry: entry)
    }

    @Test func horizontalMovesClampAtTheEnds() {
        #expect(target(.right, from: 3) == 4)
        #expect(target(.left, from: 4) == 3)
        #expect(target(.left, from: 0) == 0)
        #expect(target(.right, from: 9) == 9)
    }

    @Test func verticalMovesKeepTheColumn() {
        #expect(target(.down, from: 1) == 5)
        #expect(target(.down, from: 5) == 9)
        #expect(target(.up, from: 9) == 5)
        #expect(target(.up, from: 2) == 2)
        #expect(target(.down, from: 8) == 8)
    }

    @Test func downIntoAShortLastRowLandsOnTheLastGame() {
        #expect(target(.down, from: 6) == 9)
        #expect(target(.down, from: 7) == 9)
    }

    @Test func homeEndAndPages() {
        #expect(target(.home, from: 6) == 0)
        #expect(target(.end, from: 1) == 9)
        #expect(target(.pageDown, from: 1, pageRows: 2) == 9)
        #expect(target(.pageDown, from: 2, pageRows: 2) == 9) // column 2 has no last-row game
        #expect(target(.pageDown, from: 0, pageRows: 1) == 4)
        #expect(target(.pageUp, from: 9, pageRows: 2) == 1)
        #expect(target(.pageUp, from: 6, pageRows: 5) == 2)
        #expect(target(.pageDown, from: 0, pageRows: 0) == 4) // at least one row
    }

    @Test func withoutSelectionTheEntryGameIsSelected() {
        #expect(target(.down, from: nil, entry: 4) == 4)
        #expect(target(.left, from: nil, entry: 4) == 4)
        #expect(target(.home, from: nil, entry: 4) == 0)
        #expect(target(.end, from: nil, entry: 4) == 9)
        #expect(target(.right, from: nil, entry: 42) == 9)
    }

    @Test func emptyGridHasNoTarget() {
        #expect(GridNavigation.target(of: .down, from: nil, count: 0, columns: 4) == nil)
    }

    @Test func singleColumnMovesByOne() {
        #expect(GridNavigation.target(of: .down, from: 2, count: 5, columns: 1) == 3)
        #expect(GridNavigation.target(of: .up, from: 2, count: 5, columns: 0) == 1)
    }
}

@Suite("Type-select")
struct TypeSelectTests {
    private let titles = ["Super Mario World", "Super Metroid", "Street Fighter II", "Ōkami", "Zelda"]

    @Test func keysWithinTheTimeoutFormAPrefix() {
        var typeSelect = TypeSelect()
        let start = Date(timeIntervalSinceReferenceDate: 0)
        #expect(typeSelect.append("s", at: start) == "s")
        #expect(typeSelect.append("u", at: start + 0.5) == "su")
        #expect(typeSelect.append("z", at: start + 2) == "z")
    }

    @Test func spaceOnlyContinuesAPrefix() {
        var typeSelect = TypeSelect()
        let start = Date(timeIntervalSinceReferenceDate: 0)
        #expect(typeSelect.append(" ", at: start) == nil)
        #expect(typeSelect.append("s", at: start) == "s")
        #expect(typeSelect.append(" ", at: start + 0.1) == "s ")
    }

    @Test func matchesTheFirstTitleIgnoringCaseAndDiacritics() {
        #expect(TypeSelect.firstMatch(for: "s", in: titles) == 0)
        #expect(TypeSelect.firstMatch(for: "super me", in: titles) == 1)
        #expect(TypeSelect.firstMatch(for: "ST", in: titles) == 2)
        #expect(TypeSelect.firstMatch(for: "oka", in: titles) == 3)
        #expect(TypeSelect.firstMatch(for: "mario", in: titles) == nil)
    }
}
