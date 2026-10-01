// SPDX-License-Identifier: GPL-3.0-or-later

import Testing
@testable import Ursprung

@Suite("Activity footer")
struct ActivityTests {
    @Test func nothingRunningShowsNoRows() {
        #expect(Activity.rows(isScanning: false, metadata: nil, isFetchingSystemMedia: false, error: nil).isEmpty)
    }

    @Test func rowsKeepTheirOrder() {
        let rows = Activity.rows(isScanning: true, metadata: (4, 10, "Zelda"), isFetchingSystemMedia: false, error: "Offline")
        #expect(rows == [.scan, .metadata(completed: 4, total: 10, currentTitle: "Zelda"), .error("Offline")])
    }

    @Test func atMostThreeRowsWithTheErrorDroppedFirst() {
        let rows = Activity.rows(isScanning: true, metadata: (0, 1, nil), isFetchingSystemMedia: true, error: "Offline")
        #expect(rows.map(\.id) == ["scan", "metadata", "systemMedia"])
    }
}
