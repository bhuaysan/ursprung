// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import SwiftData
import Testing
@testable import Ursprung

@Suite("Metadata queue")
struct MetadataServiceTests {
    @Test func gamesQueuedAfterCancelAreStillScraped() async throws {
        let container = try ModelContainer(for: Game.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let first = Game(path: "/nowhere/A.sfc", systemID: "snes", title: "A", fileName: "A.sfc", fileSize: 1, crc32: nil)
        let second = Game(path: "/nowhere/B.sfc", systemID: "snes", title: "B", fileName: "B.sfc", fileSize: 1, crc32: nil)
        context.insert(first)
        context.insert(second)
        try context.save()
        // Without developer credentials every lookup fails at once, offline.
        let service = MetadataService(client: { ScreenScraperClient(devID: "", devPassword: "") })

        service.enqueue([first], context: context)
        service.cancel()
        service.enqueue([second], context: context)
        #expect(service.isRunning)
        while service.isRunning { await Task.yield() }

        #expect(service.lastError != nil, "The queued game was processed")
        // Missing credentials are no fault of the games: both stay pending.
        #expect(second.scrapeState == .pending)
        #expect(first.scrapeState == .pending)
    }
}
