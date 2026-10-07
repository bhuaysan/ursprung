// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import Ursprung

private actor DownloadLog {
    private(set) var urls: [URL] = []
    func append(_ url: URL) { urls.append(url) }
}

private struct SignatureRejected: Error {}

@Suite("Standalone emulator installation")
struct EmulatorManagerTests {
    /// A `.tar.xz` shaped like an ARMSX2 nightly: one oddly named app bundle.
    private func makeArchive(in root: URL, commit: String, bundleName: String? = nil) throws -> URL {
        let staging = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: staging) }
        let bundle = bundleName ?? "armsx2-macos-arm64-sha[\(commit)].app"
        let macOS = staging.appending(path: "\(bundle)/Contents/MacOS", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let executable = macOS.appending(path: "ARMSX2")
        try Data("#!/bin/sh\necho \(commit)\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path(percentEncoded: false))
        let archive = root.appending(path: "\(commit).tar.xz")
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/tar")
        process.currentDirectoryURL = staging
        process.arguments = ["-cJf", archive.path(percentEncoded: false), "."]
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
        return archive
    }

    private func emulator(commit: String, archive: URL, sha256: String? = nil,
                          saveStateVersion: UInt32 = 0) throws -> StandaloneEmulator {
        StandaloneEmulator(
            id: "armsx2", name: "ARMSX2", repository: "ARMSX2/ARMSX2",
            release: .init(tag: "nightly-\(commit)", assetName: archive.lastPathComponent,
                           sha256: try sha256 ?? EmulatorManager.sha256(of: archive), commit: commit),
            teamIdentifier: "TEAM123456", executable: "Contents/MacOS/ARMSX2", saveStateVersion: saveStateVersion)
    }

    /// Serves every archive in `root` by its file name, like the release assets.
    private func makeManager(root: URL, log: DownloadLog, signature: EmulatorManager.SignatureVerifier? = nil) -> EmulatorManager {
        EmulatorManager(
            directory: root.appending(path: "Emulators", directoryHint: .isDirectory),
            downloader: { url, onProgress in
                await log.append(url)
                onProgress(0.5)
                let copy = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString)-\(url.lastPathComponent)")
                try FileManager.default.copyItem(at: root.appending(path: url.lastPathComponent), to: copy)
                return copy
            },
            verifySignature: signature ?? { app, team in
                guard team == "TEAM123456", app.lastPathComponent == "ARMSX2.app" else { throw SignatureRejected() }
            })
    }

    private func visibleItems(in folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []).sorted()
    }

    @Test func installsThePinnedReleaseUnderItsCommit() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pinned = try emulator(commit: "aaaa", archive: makeArchive(in: root, commit: "aaaa"))
        let log = DownloadLog()
        let manager = makeManager(root: root, log: log)

        let app = try await manager.ensureInstalled(pinned)

        #expect(app == manager.appURL(for: pinned, commit: "aaaa"))
        #expect(app.path(percentEncoded: false).hasSuffix("Emulators/ARMSX2/aaaa/ARMSX2.app/"))
        #expect(FileManager.default.isExecutableFile(atPath: app.appending(path: pinned.executable).path(percentEncoded: false)))
        #expect(await log.urls == [pinned.downloadURL])
        #expect(manager.downloads.isEmpty)
        // Only the version folder: no staging leftovers.
        #expect(visibleItems(in: manager.folder(for: pinned)) == ["aaaa"])

        // Installed is installed: no second download, also after a restart.
        _ = try await manager.ensureInstalled(pinned)
        let restarted = makeManager(root: root, log: log)
        #expect(restarted.isInstalled(pinned))
        #expect(restarted.versions["armsx2"]?.current?.tag == "nightly-aaaa")
        #expect(await log.urls.count == 1)
    }

    @Test func aWrongChecksumInstallsNothing() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pinned = try emulator(commit: "aaaa", archive: makeArchive(in: root, commit: "aaaa"),
                                  sha256: String(repeating: "0", count: 64))
        let manager = makeManager(root: root, log: DownloadLog())

        await #expect(throws: EmulatorManager.EmulatorError.self) { try await manager.ensureInstalled(pinned) }
        #expect(!manager.isInstalled(pinned))
        #expect(visibleItems(in: manager.folder(for: pinned)).isEmpty)
    }

    @Test func aRejectedSignatureInstallsNothing() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pinned = try emulator(commit: "aaaa", archive: makeArchive(in: root, commit: "aaaa"))
        let manager = makeManager(root: root, log: DownloadLog(), signature: { _, _ in throw SignatureRejected() })

        await #expect(throws: SignatureRejected.self) { try await manager.ensureInstalled(pinned) }
        #expect(!manager.isInstalled(pinned))
        let all = (try? FileManager.default.contentsOfDirectory(atPath: manager.folder(for: pinned).path(percentEncoded: false))) ?? []
        #expect(all.isEmpty, "staging folder left behind: \(all)")
    }

    @Test func anArchiveWithoutAnAppIsInvalid() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pinned = try emulator(commit: "aaaa", archive: makeArchive(in: root, commit: "aaaa", bundleName: "ARMSX2"))
        let manager = makeManager(root: root, log: DownloadLog())

        await #expect(throws: EmulatorManager.EmulatorError.self) { try await manager.ensureInstalled(pinned) }
        #expect(!manager.isInstalled(pinned))
    }

    @Test func aNewPinKeepsTheVersionBeforeAndGoingBackHoldsIt() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try emulator(commit: "aaaa", archive: makeArchive(in: root, commit: "aaaa"))
        let second = try emulator(commit: "bbbb", archive: makeArchive(in: root, commit: "bbbb"))
        let third = try emulator(commit: "cccc", archive: makeArchive(in: root, commit: "cccc"))
        let log = DownloadLog()
        let manager = makeManager(root: root, log: log)
        _ = try await manager.ensureInstalled(first)

        // A newer Ursprung pins another release: it is installed on the next launch.
        #expect(manager.isUpdateAvailable(second))
        #expect(try await manager.ensureInstalled(second) == manager.appURL(for: second, commit: "bbbb"))
        #expect(manager.versions["armsx2"]?.previous?.commit == "aaaa")
        #expect(manager.hasPreviousVersion(second))

        // Going back sticks while the pin stays the same.
        manager.restorePreviousVersion(second)
        #expect(manager.versions["armsx2"]?.current?.commit == "aaaa")
        #expect(manager.isUpdateAvailable(second))
        #expect(try await manager.ensureInstalled(second) == manager.appURL(for: second, commit: "aaaa"))

        // Updating switches back to the kept release without downloading it again.
        try await manager.install(second)
        #expect(manager.versions["armsx2"]?.current?.commit == "bbbb")
        #expect(manager.versions["armsx2"]?.heldBackFrom == nil)
        #expect(await log.urls.count == 2)

        // A held version gives way when the pin moves; the oldest version is deleted.
        manager.restorePreviousVersion(second)
        _ = try await manager.ensureInstalled(third)
        #expect(manager.versions["armsx2"]?.current?.commit == "cccc")
        #expect(manager.versions["armsx2"]?.previous?.commit == "aaaa")
        #expect(visibleItems(in: manager.folder(for: third)) == ["aaaa", "cccc"])
        #expect(await log.urls == [first.downloadURL, second.downloadURL, third.downloadURL])
    }

    @Test func goingBackChecksStatesAgainstTheOlderFormat() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = try emulator(commit: "aaaa", archive: makeArchive(in: root, commit: "aaaa"), saveStateVersion: 0x9A59_0000)
        let new = try emulator(commit: "bbbb", archive: makeArchive(in: root, commit: "bbbb"), saveStateVersion: 0x9B00_0000)
        let manager = makeManager(root: root, log: DownloadLog())
        _ = try await manager.ensureInstalled(old)
        _ = try await manager.ensureInstalled(new)
        #expect(manager.saveStateVersion(of: new) == 0x9B00_0000)

        manager.restorePreviousVersion(new)
        #expect(manager.saveStateVersion(of: new) == 0x9A59_0000)
        // Ursprung keeps the format across launches.
        let reloaded = makeManager(root: root, log: DownloadLog())
        #expect(reloaded.saveStateVersion(of: new) == 0x9A59_0000)

        // Versions recorded without a format: the pin's is known, any other one is not.
        let directory = root.appending(path: "Emulators", directoryHint: .isDirectory)
        try EmulatorVersionStore.save(["armsx2": EmulatorVersionEntry(
            current: EmulatorVersionRecord(tag: "nightly-aaaa", commit: "aaaa", installed: .now),
            previous: EmulatorVersionRecord(tag: "nightly-bbbb", commit: "bbbb", installed: .now))], in: directory)
        let legacy = makeManager(root: root, log: DownloadLog())
        #expect(legacy.saveStateVersion(of: new) == nil)
        #expect(legacy.saveStateVersion(of: old) == 0x9A59_0000)
    }

    @Test func removingDeletesTheVersionsButKeepsTheDataFolder() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try emulator(commit: "aaaa", archive: makeArchive(in: root, commit: "aaaa"))
        let second = try emulator(commit: "bbbb", archive: makeArchive(in: root, commit: "bbbb"))
        let manager = makeManager(root: root, log: DownloadLog())
        _ = try await manager.ensureInstalled(first)
        _ = try await manager.ensureInstalled(second)
        let data = manager.folder(for: second).appending(path: "data/ARMSX2/inis", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        #expect(await manager.installedSize(of: second) > 0)

        manager.remove(second)

        #expect(!manager.isInstalled(second))
        #expect(!manager.hasPreviousVersion(second))
        #expect(visibleItems(in: manager.folder(for: second)) == ["data"])
    }

    @Test func callersShareOneDownload() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pinned = try emulator(commit: "aaaa", archive: makeArchive(in: root, commit: "aaaa"))
        let log = DownloadLog()
        let manager = makeManager(root: root, log: log)

        async let first = manager.ensureInstalled(pinned)
        async let second = manager.ensureInstalled(pinned)
        #expect(try await first == second)
        #expect(await log.urls.count == 1)
    }

    @Test func theSignatureCheckRejectsUnsignedAndForeignApps() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let unsigned = root.appending(path: "Unsigned.app/Contents/MacOS", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: unsigned, withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: unsigned.appending(path: "Unsigned"))

        #expect(throws: EmulatorManager.EmulatorError.self) {
            try EmulatorManager.checkSignature(root.appending(path: "Unsigned.app"), "L296QD7JFU")
        }
        // Validly signed, but not by ARMSX2's team.
        #expect(throws: EmulatorManager.EmulatorError.self) {
            try EmulatorManager.checkSignature(URL(filePath: "/System/Applications/Calculator.app"), "L296QD7JFU")
        }
    }
}
