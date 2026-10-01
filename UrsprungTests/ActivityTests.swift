// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import Ursprung

@Suite("Activity footer")
struct ActivityTests {
    private let offline = MetadataFailure(reason: "Offline", message: "Offline. Retry later.")

    @Test func nothingRunningShowsNoRows() {
        #expect(Activity.rows(isScanning: false, metadata: nil, isFetchingSystemMedia: false, error: nil).isEmpty)
    }

    @Test func rowsKeepTheirOrder() {
        let rows = Activity.rows(isScanning: true, metadata: (4, 10, "Zelda"), isFetchingSystemMedia: false, error: offline)
        #expect(rows == [.scan, .metadata(completed: 4, total: 10, currentTitle: "Zelda"), .error(offline)])
    }

    @Test func atMostThreeRowsWithTheErrorDroppedFirst() {
        let rows = Activity.rows(isScanning: true, metadata: (0, 1, nil), isFetchingSystemMedia: true, error: offline)
        #expect(rows.map(\.id) == ["scan", "metadata", "systemMedia"])
    }

    @Test func unreachableFoldersFollowTheErrorOncePerVolume() {
        let folders = [URL(filePath: "/Volumes/Retro/SNES"), URL(filePath: "/Volumes/Retro/PSX"),
                       URL(filePath: "/Users/me/ROMs")]
        let rows = Activity.rows(isScanning: false, metadata: nil, isFetchingSystemMedia: false, error: offline,
                                 unreachableFolders: folders)
        #expect(rows == [.error(offline), .unreachable(volumes: ["Retro", "ROMs"])])
    }
}

@Suite("Metadata failures")
struct MetadataFailureTests {
    @Test func screenScraperErrorsKeepTheirMessage() {
        let failure = MetadataFailure(ScreenScraperError.quotaExceeded)
        #expect(failure.message == ScreenScraperError.quotaExceeded.localizedDescription)
        #expect(failure.reason == ScreenScraperError.quotaExceeded.reason)
    }

    @Test func networkErrorsAreRewritten() {
        let error = URLError(.notConnectedToInternet)
        let failure = MetadataFailure(error)
        #expect(failure.message != error.localizedDescription)
        #expect(failure.reason != error.localizedDescription)
    }

    @Test func otherErrorsAddWhatToDo() {
        let error = CocoaError(.fileReadCorruptFile)
        let failure = MetadataFailure(error)
        #expect(failure.message.hasPrefix(error.localizedDescription))
        #expect(failure.message.count > error.localizedDescription.count)
    }
}
