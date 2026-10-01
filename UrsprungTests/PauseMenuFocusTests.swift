// SPDX-License-Identifier: GPL-3.0-or-later

import Testing
@testable import Ursprung

@Suite("Pause menu focus")
struct PauseMenuFocusTests {
    @Test func rowsWrapAround() {
        let rows = [1, 2, 3]
        #expect(PauseMenuFocus.row(after: 3, by: 1, in: rows) == 1)
        #expect(PauseMenuFocus.row(after: 1, by: -1, in: rows) == 3)
        #expect(PauseMenuFocus.row(after: 2, by: 1, in: rows) == 3)
    }

    @Test func focusOnAMissingRowStartsAtTheTop() {
        // A row that became disabled (Quick Load after the state vanished).
        #expect(PauseMenuFocus.row(after: 9, by: 1, in: [1, 2]) == 1)
        #expect(PauseMenuFocus.row(after: 1, by: 1, in: [Int]()) == nil)
    }

    @Test func slotsMoveInAThreeByThreeGridAndStopAtTheEdges() {
        #expect(PauseMenuFocus.slot(from: 5, moving: .up) == 2)
        #expect(PauseMenuFocus.slot(from: 5, moving: .down) == 8)
        #expect(PauseMenuFocus.slot(from: 5, moving: .left) == 4)
        #expect(PauseMenuFocus.slot(from: 5, moving: .right) == 6)

        #expect(PauseMenuFocus.slot(from: 1, moving: .up) == 1)
        #expect(PauseMenuFocus.slot(from: 1, moving: .left) == 1)
        #expect(PauseMenuFocus.slot(from: 3, moving: .right) == 3)
        #expect(PauseMenuFocus.slot(from: 4, moving: .left) == 4)
        #expect(PauseMenuFocus.slot(from: 9, moving: .down) == 9)
        #expect(PauseMenuFocus.slot(from: 7, moving: .confirm) == 7)
    }
}
