// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import Ursprung

/// An ISO 9660 image with a root directory that holds only `SYSTEM.CNF`.
/// `raw` wraps every sector like a Mode 2 Form 1 BIN (2352 bytes).
private func syntheticISO(systemCNF: String, raw: Bool = false) -> Data {
    var sectors = [Data](repeating: Data(count: 2048), count: 20)
    func put(_ bytes: [UInt8], sector: Int, at offset: Int) {
        sectors[sector].replaceSubrange(offset..<offset + bytes.count, with: bytes)
    }
    func le32(_ value: Int) -> [UInt8] { withUnsafeBytes(of: UInt32(value).littleEndian, Array.init) }
    func record(name: [UInt8], extent: Int, size: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 33 + name.count + (name.count % 2 == 0 ? 1 : 0))
        bytes[0] = UInt8(bytes.count)
        bytes.replaceSubrange(2..<6, with: le32(extent))
        bytes.replaceSubrange(10..<14, with: le32(size))
        bytes[32] = UInt8(name.count)
        bytes.replaceSubrange(33..<33 + name.count, with: name)
        return bytes
    }
    let contents = Array(systemCNF.utf8)
    put([1] + Array("CD001".utf8), sector: 16, at: 0)
    put(record(name: [0], extent: 18, size: 2048), sector: 16, at: 156)
    let directory = record(name: [0], extent: 18, size: 2048) + record(name: [1], extent: 18, size: 2048)
        + record(name: Array("SYSTEM.CNF;1".utf8), extent: 19, size: contents.count)
    put(directory, sector: 18, at: 0)
    put(contents, sector: 19, at: 0)
    guard raw else { return sectors.reduce(Data(), +) }
    let sync: [UInt8] = [0x00] + Array(repeating: 0xFF, count: 10) + [0x00]
    return sectors.reduce(Data()) { image, sector in
        image + Data(sync + [0, 2, 0, 2] + Array(repeating: 0, count: 8)) + sector + Data(count: 280)
    }
}

private func bios(_ name: String, _ region: PS2BIOS.Region, _ version: String) -> PS2BIOS {
    PS2BIOS(fileName: name, region: region, version: version, date: nil)
}

@Suite("Standalone emulator launch")
struct StandaloneLaunchTests {
    // MARK: ini

    @Test func iniKeepsRepeatedKeysAndUnmanagedEntries() {
        var ini = IniDocument(parsing: """
            [Pad1]
            Type = DualShock2
            Cross = Keyboard/K
            Cross = SDL-0/FaceSouth
            Deadzone = 0.2

            [ui]
            MainWindowGeometry = AdnQ==
            """)
        #expect(ini.values("Cross", in: "pad1") == ["Keyboard/K", "SDL-0/FaceSouth"])
        ini.set([.init("cross", "Keyboard/X"), .init("Start", "Keyboard/Return"), .init("Cross", "SDL-0/FaceEast")], in: "Pad1")
        ini.set([.init("SettingsVersion", "1")], in: "UI")
        ini.set([.init("Renderer", "17")], in: "EmuCore/GS")
        #expect(ini.text == """
            [Pad1]
            Type = DualShock2
            cross = Keyboard/X
            Cross = SDL-0/FaceEast
            Deadzone = 0.2
            Start = Keyboard/Return

            [ui]
            MainWindowGeometry = AdnQ==
            SettingsVersion = 1

            [EmuCore/GS]
            Renderer = 17

            """)
    }

    @Test func configMergesIntoARMSX2sOwnFile() {
        let config = PCSX2Config(biosFolder: URL(filePath: "/S/pcsx2/bios"), biosFileName: "EU 200.BIN",
                                 memoryCardFolder: URL(filePath: "/Saves/ps2/G"), saveStateFolder: URL(filePath: "/States/G/armsx2"),
                                 snapshotFolder: URL(filePath: "/Extras/G/Screenshots"), pineSlot: 28012,
                                 saveStateOnShutdown: true, fullscreen: false)
        let existing = """
            [UI]
            SettingsVersion = 1
            SetupWizardIncomplete = true
            ConfirmShutdown = true
            DisplayWindowGeometry = AdnQywAD

            [EmuCore/GS]
            Renderer = 12
            upscale_multiplier = 3

            [Pad1]
            Cross = Keyboard/Z
            Cross = SDL-1/FaceSouth
            """
        let ini = IniDocument(parsing: config.merged(into: existing))
        #expect(ini.values("SetupWizardIncomplete", in: "UI") == ["false"])
        #expect(ini.values("ConfirmShutdown", in: "UI") == ["false"])
        #expect(ini.values("StartFullscreen", in: "UI") == ["false"])
        #expect(ini.values("DisplayWindowGeometry", in: "UI") == ["AdnQywAD"], "Window geometry stays")
        #expect(ini.values("Renderer", in: "EmuCore/GS") == ["17"])
        #expect(ini.values("upscale_multiplier", in: "EmuCore/GS") == ["3"], "ARMSX2 settings of the user stay")
        #expect(ini.values("Cross", in: "Pad1") == ["Keyboard/K", "SDL-0/FaceSouth"])
        #expect(ini.values("Bios", in: "Folders") == ["/S/pcsx2/bios"])
        #expect(ini.values("MemoryCards", in: "Folders") == ["/Saves/ps2/G"])
        #expect(ini.values("Savestates", in: "Folders") == ["/States/G/armsx2"])
        #expect(ini.values("Snapshots", in: "Folders") == ["/Extras/G/Screenshots"])
        #expect(ini.values("BIOS", in: "Filenames") == ["EU 200.BIN"])
        #expect(ini.values("Slot2_Enable", in: "MemoryCards") == ["false"])
        #expect(ini.values("PINESlot", in: "EmuCore") == ["28012"])
        #expect(ini.values("SaveStateOnShutdown", in: "EmuCore") == ["true"])
        #expect(ini.values("BackupSavestate", in: "EmuCore") == ["false"])
        #expect(ini.values("OpenPauseMenu", in: "Hotkeys") == ["Keyboard/Escape"])
        // Merging again changes nothing.
        let text = config.merged(into: existing)
        #expect(config.merged(into: text) == text)
    }

    @Test func padBindingsMatchARMSX2sAutomaticMapping() {
        let bindings = PCSX2Config.padBindings
        #expect(bindings.first == .init("Type", "DualShock2"))
        #expect(bindings.filter { $0.key == "Up" }.map(\.value) == ["Keyboard/Up", "SDL-0/DPadUp"])
        #expect(bindings.filter { $0.key == "L2" }.map(\.value) == ["Keyboard/1", "SDL-0/+LeftTrigger"])
        #expect(bindings.filter { $0.key == "LLeft" }.map(\.value) == ["Keyboard/A", "SDL-0/-LeftX"])
        #expect(bindings.filter { $0.key == "LargeMotor" }.map(\.value) == ["SDL-0/LargeMotor"])
        #expect(bindings.count == 1 + 24 * 2 + 2)
    }

    // MARK: Disc and BIOS

    @Test func readsTheSerialFromTheDisc() throws {
        let folder = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let cnf = "BOOT2 = cdrom0:\\SLES_554.74;1\r\nVER = 1.00\r\nVMODE = PAL\r\n"
        let iso = folder.appending(path: "game.iso")
        try syntheticISO(systemCNF: cnf).write(to: iso)
        #expect(PS2Disc.serial(of: iso) == "SLES-55474")
        let bin = folder.appending(path: "game.bin")
        try syntheticISO(systemCNF: cnf, raw: true).write(to: bin)
        #expect(PS2Disc.serial(of: bin) == "SLES-55474")
        let garbage = folder.appending(path: "garbage.iso")
        try Data(repeating: 0x5A, count: 64 * 1024).write(to: garbage)
        #expect(PS2Disc.serial(of: garbage) == nil)
    }

    @Test func serialsAndRegions() {
        #expect(PS2Disc.serial(fromSystemCNF: "BOOT2 = cdrom0:\\SLUS_217.82;1") == "SLUS-21782")
        #expect(PS2Disc.serial(fromSystemCNF: "BOOT2=cdrom0:\\SCPS_150.55;1\nVER=1.00") == "SCPS-15055")
        #expect(PS2Disc.serial(fromSystemCNF: "BOOT = cdrom:\\SLUS_007.11;1") == nil, "PlayStation discs say BOOT")
        #expect(PS2Disc.region(ofSerial: "SLES-55474") == .europe)
        #expect(PS2Disc.region(ofSerial: "SCUS-97328") == .usa)
        #expect(PS2Disc.region(ofSerial: "SLPM-66127") == .japan)
        #expect(PS2Disc.region(ofSerial: "XXXX-00000") == nil)
        #expect(PS2Disc.region(ofFileName: "Persona 4 (Europe).iso") == .europe)
        #expect(PS2Disc.region(ofFileName: "Okami (USA).iso") == .usa)
        #expect(PS2Disc.region(ofFileName: "Okami.iso") == nil)
    }

    @Test func choosesTheNewestDumpOfTheDiscsRegion() {
        let dumps = [bios("JP 220.bin", .japan, "2.20"), bios("EU 160.bin", .europe, "1.60"),
                     bios("EU 200.BIN", .europe, "2.00"), bios("US 170.bin", .usa, "1.70")]
        #expect(PS2BIOS.preferred(in: dumps, region: .europe)?.fileName == "EU 200.BIN")
        #expect(PS2BIOS.preferred(in: dumps, region: .usa)?.fileName == "US 170.bin")
        #expect(PS2BIOS.preferred(in: dumps, region: .asia)?.fileName == "JP 220.bin", "Any dump, newest first")
        #expect(PS2BIOS.preferred(in: [], region: .europe) == nil)
    }

    // MARK: Launch

    private struct Fixture {
        let root: URL
        var request: ARMSX2Launch.Request

        init() throws {
            root = try makeTemporaryDirectory()
            let game = root.appending(path: "ROMS/Persona 4 (Europe).iso")
            try FileManager.default.createDirectory(at: game.deletingLastPathComponent(), withIntermediateDirectories: true)
            try syntheticISO(systemCNF: "BOOT2 = cdrom0:\\SLUS_217.82;1\n").write(to: game)
            request = ARMSX2Launch.Request(
                app: root.appending(path: "ARMSX2.app"), executable: "Contents/MacOS/ARMSX2",
                dataFolder: root.appending(path: "data"), logFile: root.appending(path: "Logs/last-run.log"),
                pineFolder: root.appending(path: "PINE"), game: game, biosFolder: root.appending(path: "bios"),
                dumps: [bios("EU.bin", .europe, "2.00"), bios("US.bin", .usa, "1.70")], fallbackRegion: .japan,
                memoryCardFolder: root.appending(path: "Saves/ps2/G"), saveStateFolder: root.appending(path: "States/G/armsx2"),
                snapshotFolder: root.appending(path: "Extras/G/Screenshots"), resume: false, saveStateOnShutdown: true,
                fullscreen: true, saveStateVersion: 0x9A59_0000)
        }

        /// A state as ARMSX2 writes it, with only its version entry.
        func writeState(named name: String, version: UInt32) throws -> URL {
            var bytes = withUnsafeBytes(of: version.littleEndian) { Data($0) }
            bytes.append(contentsOf: Array("0.1 test".utf8) + [0])
            let url = request.saveStateFolder.appending(path: name)
            try FileManager.default.createDirectory(at: request.saveStateFolder, withIntermediateDirectories: true)
            try makeZip(at: url, containing: "PCSX2 Savestate Version.id", bytes: bytes)
            return url
        }
    }

    @Test func preparesArgumentsEnvironmentAndSettings() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let launch = try ARMSX2Launch.prepare(fixture.request, environment: ["HOME": "/Users/x", "TMPDIR": "/var/T/"])
        let request = fixture.request

        #expect(launch.executable == request.app.appending(path: "Contents/MacOS/ARMSX2"))
        #expect(launch.arguments == ["-datapath", request.dataFolder.path(percentEncoded: false), "-batch", "-nogui",
                                     "-logfile", request.logFile.path(percentEncoded: false), "-fullscreen",
                                     "--", request.game.path(percentEncoded: false)])
        #expect(launch.environment == ["HOME": "/Users/x", "TMPDIR": request.pineFolder.path(percentEncoded: false)])
        #expect(launch.stateFile == nil)
        // The disc is SLUS: the US dump, although the file name says Europe.
        #expect(launch.config.biosFileName == "US.bin")
        #expect(launch.pineSocket == request.pineFolder.appending(path: "pcsx2.sock"))

        let written = try String(contentsOf: PCSX2Config.iniURL(dataFolder: request.dataFolder), encoding: .utf8)
        #expect(written == launch.config.merged(into: ""))
        for folder in [request.memoryCardFolder, request.saveStateFolder, request.snapshotFolder, request.pineFolder] {
            #expect(FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)))
        }
    }

    @Test func picksAFreePINESlot() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.createDirectory(at: fixture.request.pineFolder, withIntermediateDirectories: true)
        try Data().write(to: fixture.request.pineFolder.appending(path: "pcsx2.sock"))
        let launch = try ARMSX2Launch.prepare(fixture.request, environment: [:])
        #expect(launch.config.pineSlot == 28012)
        #expect(launch.pineSocket.lastPathComponent == "pcsx2.sock.28012")
    }

    @Test func resumesOnlyFromLoadableStates() throws {
        var fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.request.resume = true
        #expect(try ARMSX2Launch.prepare(fixture.request, environment: [:]).stateFile == nil, "No state yet")

        let state = try fixture.writeState(named: "SLUS-21782 (01234567).resume.p2s", version: 0x9A59_0000)
        let launch = try ARMSX2Launch.prepare(fixture.request, environment: [:])
        #expect(launch.stateFile == state)
        #expect(launch.arguments.suffix(4) == ["-statefile", state.path(percentEncoded: false),
                                               "--", fixture.request.game.path(percentEncoded: false)])

        _ = try fixture.writeState(named: "SLUS-21782 (01234567).resume.p2s", version: 0x9A59_0001)
        #expect(try ARMSX2Launch.prepare(fixture.request, environment: [:]).stateFile == nil, "Newer than ARMSX2")
        _ = try fixture.writeState(named: "SLUS-21782 (01234567).resume.p2s", version: 0x9A58_0000)
        #expect(try ARMSX2Launch.prepare(fixture.request, environment: [:]).stateFile == nil, "Other major version")
        try Data("not a zip".utf8).write(to: state)
        #expect(try ARMSX2Launch.prepare(fixture.request, environment: [:]).stateFile == nil, "Damaged")
    }

    @Test func refusesWhatWouldCrashARMSX2() throws {
        var fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let card = fixture.request.memoryCardFolder.appending(path: PCSX2Config.memoryCardFileName)
        try FileManager.default.createDirectory(at: fixture.request.memoryCardFolder, withIntermediateDirectories: true)
        try Data(count: 16).write(to: card)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: card.path(percentEncoded: false))
        #expect(throws: StandaloneLaunchError.self) { try ARMSX2Launch.prepare(fixture.request, environment: [:]) }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: card.path(percentEncoded: false))
        _ = try ARMSX2Launch.prepare(fixture.request, environment: [:])

        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fixture.request.game.path(percentEncoded: false))
        #expect(throws: StandaloneLaunchError.self) { try ARMSX2Launch.prepare(fixture.request, environment: [:]) }
        fixture.request.game = fixture.root.appending(path: "missing.iso")
        #expect(throws: StandaloneLaunchError.self) { try ARMSX2Launch.prepare(fixture.request, environment: [:]) }
    }

    @Test func removesOnlyStaleResumeStates() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let state = try fixture.writeState(named: "SLUS-21782 (01234567).resume.p2s", version: 0x9A59_0000)
        let start = Date.now
        try FileManager.default.setAttributes([.modificationDate: start.addingTimeInterval(5)],
                                              ofItemAtPath: state.path(percentEncoded: false))
        ARMSX2States.removeStaleResumeState(in: fixture.request.saveStateFolder, olderThan: start)
        #expect(FileManager.default.fileExists(atPath: state.path(percentEncoded: false)), "Written during the session")
        try FileManager.default.setAttributes([.modificationDate: start.addingTimeInterval(-60)],
                                              ofItemAtPath: state.path(percentEncoded: false))
        ARMSX2States.removeStaleResumeState(in: fixture.request.saveStateFolder, olderThan: start)
        #expect(!FileManager.default.fileExists(atPath: state.path(percentEncoded: false)))
    }

    @Test func findsTheErrorInTheLog() {
        let log = """
            [    0.1044] IOKit is enabled, MFI is enabled.
            [    0.2533] Applying settings...
            [    0.2534] ReportErrorAsync: Error while starting: The file '/x.iso' does not exist.
            [    0.2600] Shutting down.
            """
        #expect(ARMSX2Launch.errorMessage(inLog: log) == "Error while starting: The file '/x.iso' does not exist.")
        #expect(ARMSX2Launch.errorMessage(inLog: "[0.1] all fine") == nil)
    }
}

/// The process lifecycle, against a shell script standing in for ARMSX2.
@Suite("Standalone emulator process")
struct ExternalSessionTests {
    /// Writes its arguments and `TMPDIR` to `$LOG`, then runs until TERM
    /// (exiting with `$TERM_STATUS`), or exits with `$EXIT_STATUS` at once.
    /// `IGNORE_TERM` makes it ignore TERM.
    private static let script = """
        #!/bin/sh
        echo "args: $* tmp: $TMPDIR" > "$LOG"
        if [ -n "$IGNORE_TERM" ]; then trap '' TERM; else trap 'echo term >> "$LOG"; exit ${TERM_STATUS:-0}' TERM; fi
        [ -n "$EXIT_STATUS" ] && exit $EXIT_STATUS
        while :; do sleep 0.05; done
        """

    private struct Fake {
        let folder: URL
        let executable: URL
        var log: URL { folder.appending(path: "log.txt") }

        init() throws {
            folder = try makeTemporaryDirectory()
            executable = folder.appending(path: "fake-emulator")
            try ExternalSessionTests.script.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path(percentEncoded: false))
        }

        func start(_ environment: [String: String] = [:]) throws -> ExternalSession {
            try ExternalSession(executable: executable, arguments: ["-batch", "--", "game.iso"],
                                environment: environment.merging(["LOG": log.path(percentEncoded: false), "TMPDIR": "/pine/",
                                                                  "PATH": "/usr/bin:/bin"]) { $1 },
                                output: folder.appending(path: "output.txt"))
        }

        /// Waits until the script has written its log, so its trap is set.
        func waitUntilStarted() async throws {
            for _ in 0..<200 where !FileManager.default.fileExists(atPath: log.path(percentEncoded: false)) {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
    }

    @Test func quitsWithOneTerm() async throws {
        let fake = try Fake()
        defer { try? FileManager.default.removeItem(at: fake.folder) }
        let session = try fake.start()
        var reported: ExternalSession.Exit?
        session.onExit = { reported = $0 }
        try await fake.waitUntilStarted()
        #expect(session.isRunning)

        let exit = await session.stop()
        #expect(exit == ExternalSession.Exit(status: 0, wasSignaled: false, wasRequested: true))
        #expect(exit.isClean)
        #expect(reported == exit)
        #expect(!session.isRunning)
        let log = try String(contentsOf: fake.log, encoding: .utf8)
        #expect(log == "args: -batch -- game.iso tmp: /pine/\nterm\n", "TERM arrives once")
        #expect(await session.stop() == exit, "Stopping again reports the same exit")
    }

    @Test func reportsAnExitOfItsOwn() async throws {
        let fake = try Fake()
        defer { try? FileManager.default.removeItem(at: fake.folder) }
        let session = try fake.start(["EXIT_STATUS": "3"])
        let exit = await withCheckedContinuation { continuation in
            session.onExit = { continuation.resume(returning: $0) }
        }
        #expect(exit == ExternalSession.Exit(status: 3, wasSignaled: false, wasRequested: false))
        #expect(!exit.isClean)
    }

    @Test func killsAProcessThatIgnoresTerm() async throws {
        let fake = try Fake()
        defer { try? FileManager.default.removeItem(at: fake.folder) }
        let session = try fake.start(["IGNORE_TERM": "1"])
        try await fake.waitUntilStarted()
        let exit = await session.stop(gracePeriod: .milliseconds(300))
        #expect(exit.wasSignaled)
        #expect(exit.status == SIGKILL)
        #expect(exit.wasRequested)
    }

    @Test func stopsSynchronouslyWhenUrsprungQuits() async throws {
        let fake = try Fake()
        defer { try? FileManager.default.removeItem(at: fake.folder) }
        let session = try fake.start(["TERM_STATUS": "0"])
        try await fake.waitUntilStarted()
        let exit = session.stopAndWait(gracePeriod: 5)
        #expect(exit == ExternalSession.Exit(status: 0, wasSignaled: false, wasRequested: true))

        let stubborn = try fake.start(["IGNORE_TERM": "1"])
        try? FileManager.default.removeItem(at: fake.log)
        try await fake.waitUntilStarted()
        #expect(stubborn.stopAndWait(gracePeriod: 0.3)?.wasSignaled == true)
    }
}
