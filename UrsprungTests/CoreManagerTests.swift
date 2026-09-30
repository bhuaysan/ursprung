// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import Ursprung

private actor CallCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

private struct DownloadFailure: Error {}

@Suite("Core installation")
struct CoreManagerTests {
    private let core = CoreDefinition(id: "testcore", name: "Test Core")

    private func makeManager(root: URL, counter: CallCounter, fails: Bool = false) throws -> CoreManager {
        let archive = root.appending(path: "template.zip")
        try makeZip(at: archive, containing: core.fileName, bytes: Data("dylib".utf8))
        return CoreManager(
            coresDirectory: root.appending(path: "Cores", directoryHint: .isDirectory),
            systemDirectory: root.appending(path: "System", directoryHint: .isDirectory),
            downloader: { _, _ in
                await counter.increment()
                try await Task.sleep(for: .milliseconds(150))
                if fails { throw DownloadFailure() }
                let copy = root.appending(path: "\(UUID().uuidString).zip")
                try FileManager.default.copyItem(at: archive, to: copy)
                return copy
            })
    }

    private func waitForDownloadToStart(_ manager: CoreManager) async throws {
        for _ in 0..<400 where manager.downloads[core.id] == nil { try await Task.sleep(for: .milliseconds(5)) }
        try #require(manager.downloads[core.id] != nil)
    }

    @Test func secondCallerWaitsForTheRunningInstallation() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appending(path: "Cores"), withIntermediateDirectories: true)
        let counter = CallCounter()
        let manager = try makeManager(root: root, counter: counter)

        let first = Task { try await manager.ensureInstalled(core) }
        try await waitForDownloadToStart(manager)
        let second = try await manager.ensureInstalled(core)

        // The second caller must not return before the dylib exists.
        #expect(FileManager.default.fileExists(atPath: second.path(percentEncoded: false)))
        #expect(try await first.value == second)
        #expect(await counter.count == 1)
        #expect(manager.downloads[core.id] == nil)
    }

    @Test func callersShareTheFailureOfTheInstallation() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appending(path: "Cores"), withIntermediateDirectories: true)
        let counter = CallCounter()
        let manager = try makeManager(root: root, counter: counter, fails: true)

        let first = Task { try await manager.ensureInstalled(core) }
        try await waitForDownloadToStart(manager)
        await #expect(throws: DownloadFailure.self) { try await manager.ensureInstalled(core) }
        await #expect(throws: DownloadFailure.self) { try await first.value }
        #expect(await counter.count == 1)

        // A failed installation does not block a later attempt.
        await #expect(throws: DownloadFailure.self) { try await manager.ensureInstalled(core) }
        #expect(await counter.count == 2)
    }
}
