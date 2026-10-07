// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation
import ImageIO
import Observation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Why a game cannot be prepared for its core.
nonisolated enum LaunchError: LocalizedError {
    case unsupportedArchive(coreName: String)
    case patchFailed(name: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .unsupportedArchive(let core):
            String(localized: "\(core) can't open .7z archives. Unpack the game or turn it into a .zip file, then rescan.")
        case .patchFailed(let name, let reason):
            String(localized: "The patch “\(name)” couldn't be applied. \(reason) Choose another patch or the original in the game's info panel.")
        }
    }
}

/// Controls the one game that is currently running.
@Observable
final class EmulationSession {
    enum Phase: Equatable {
        case idle
        case preparing(String)
        case running
        /// A standalone emulator runs the game in its own window.
        case external
        case failed(Failure)
    }

    /// Why a launch failed, written as what happened plus what to do.
    struct Failure: Equatable {
        let message: String
        /// The Settings tab that fixes the cause (missing core or BIOS).
        var settingsTab: SettingsTab?
        /// The standalone emulator's log of the failed run.
        var logURL: URL?
    }

    struct Toast: Identifiable, Equatable {
        enum Kind { case info, saved, loaded, warning, screenshot, achievement }
        let id = UUID()
        let text: String
        var kind = Kind.info
        /// A badge shown instead of the symbol (achievements).
        var imageURL: URL?
        var detail: String?
    }

    /// An achievement indicator on screen: a challenge that is running, the
    /// progress of an achievement, or a leaderboard's live value.
    struct AchievementIndicator: Identifiable, Equatable {
        enum Kind { case challenge, progress, tracker }
        let kind: Kind
        let itemID: Int
        var value: String?
        var imageURL: URL?
        var id: String { "\(kind)-\(itemID)" }
    }

    private(set) var phase: Phase = .idle
    private(set) var gameID: PersistentIdentifier?
    /// The library ID of the running game.
    var runningGameID: UUID? { gameUUID }
    private(set) var gameTitle = ""
    private(set) var systemID: String?
    private(set) var coreName = ""
    /// The standalone emulator of the game being launched or running; nil
    /// for libretro cores. Such a game has no player window.
    private(set) var standaloneName: String?
    private(set) var isPaused = false
    private(set) var isFastForwarding = false
    private(set) var isRewinding = false
    /// The Mac keyboard types on the emulated computer's keyboard; keys do
    /// not press RetroPad buttons and hotkeys are off (except Typing).
    private(set) var isTyping = false
    /// The system of the running game has a keyboard of its own.
    private(set) var hasComputerKeyboard = false
    /// The ROM patch the running game was started with.
    private(set) var patchName: String?
    /// Cheats of the running game, applied when enabled.
    private(set) var cheats: [Cheat] = []
    private(set) var supportsCheats = false
    /// The running game as RetroAchievements knows it; nil without achievements.
    private(set) var achievementGame: AchievementGameInfo?
    /// Hardcore restrictions apply: no state loading, rewind or cheats.
    private(set) var isHardcore = false
    private(set) var achievementIndicators: [AchievementIndicator] = []
    /// Bumped when the running game gains a screenshot.
    private(set) var screenshotRevision = 0
    private(set) var toasts: [Toast] = []
    private(set) var slots: [SaveStateSlot] = []
    /// States of the running game and core that newer ones replaced or that were deleted.
    private(set) var history: [SaveStateSlot] = []
    /// Labels of the discs from the game's playlist; empty when it has none.
    private(set) var discLabels: [String?] = []
    /// Whether core option changes apply to the running game only.
    private(set) var usesGameCoreOptions = false
    private(set) var diskCount = 0
    private(set) var currentDisk = 0
    private(set) var measuredFPS: Double = 0
    /// Incremented whenever a core shuts itself down.
    private(set) var coreTerminations = 0
    var isMenuVisible = false {
        didSet {
            guard isMenuVisible != oldValue else { return }
            // While the menu is open, controllers navigate it instead of the game.
            input.routesToMenu = isMenuVisible
            // The menu takes the keyboard, so the player never sees the
            // fast forward key being released.
            if isMenuVisible {
                setFastForward(false)
                isShaderPanelVisible = false
            }
            applyPause()
        }
    }

    /// The shader panel is open at the side of the player. The game keeps
    /// running, so its parameters can be tuned on a moving picture.
    var isShaderPanelVisible = false

    private(set) var core: LibretroCore?
    private var runner: EmulationRunner?
    /// The standalone emulator's process while `phase == .external`.
    private var external: ExternalSession?
    /// Its state folder and log, for cleaning up when it ends.
    private var externalStateFolder: URL?
    private var externalLog: URL?
    private var gameUUID: UUID?
    private var coreID: String?
    /// Where the running game's states live below its folder: the core, or
    /// the core and patch (a patched game keeps its states apart).
    private var stateFolder: String?
    /// The running core and game, recorded in every state's manifest.
    private(set) var stateContext: SaveStateContext?
    private var startedAt: Date?
    private var userPaused = false
    private var appInactive = false
    private var fpsTimer: Timer?
    private var launchContext: ModelContext?
    /// Bumped by every launch and stop so a launch that is still loading
    /// notices it has been superseded.
    private var generation = 0
    private var shutdown: Task<Void, Never>?
    /// Writes the automatic state of the running game; nil when automatic
    /// states are off or while resuming is not settled (see `armAutosave`).
    private var autosave: (@Sendable (LibretroCore) -> Void)?

    let input = InputRouter()
    /// The preset the player renders, with its live parameters.
    let shader = ShaderWorkspace()
    let cores: CoreManager
    let emulators: EmulatorManager
    let bios: BIOSManager
    let achievements: AchievementService

    init(cores: CoreManager, emulators: EmulatorManager, bios: BIOSManager, achievements: AchievementService) {
        self.cores = cores
        self.emulators = emulators
        self.bios = bios
        self.achievements = achievements
        input.onMenuButton = { [weak self] in self?.toggleMenu() }
        shader.onTooSlow = { [weak self] preset in
            // The shader editor shows the GPU time itself.
            guard let self, shader.editorPreset == nil else { return }
            showToast(String(localized: "“\(preset.name)” is too demanding for this Mac’s GPU, so the game stutters."),
                      kind: .warning, duration: 5)
        }
        achievements.client.eventHandler = { [weak self] event in
            MainActor.assumeIsolated { self?.handleAchievementEvent(event) }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setAppInactive(true) }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setAppInactive(false) }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                // Flush battery saves and play time before the process exits.
                self?.runner?.stopAndWait()
                if let external = self?.external {
                    let exit = external.stopAndWait()
                    self?.finishExternal(cleanExit: exit?.isClean ?? false, context: nil)
                }
                self?.recordPlayTime(context: nil)
            }
        }
    }

    var isActive: Bool { phase != .idle }

    // MARK: - Launch

    /// Starts `game`. With `resume`, it continues from the automatic state
    /// saved when it last stopped, if the core can; with `state`, from that
    /// save state.
    func launch(_ game: Game, context: ModelContext, resume: Bool = false, state: SaveStateSlot? = nil) async {
        // Switch straight to "preparing" so the player window stays open while
        // a previous game shuts down.
        generation += 1
        let generation = generation
        // The preparing panel shows the title above the message.
        gameTitle = game.title
        standaloneName = game.system.map { $0.core(withID: game.coreID ?? Preferences.coreChoice(for: $0.id)) }?.standalone?.name
        phase = .preparing(String(localized: "Loading game…"))
        await shutDownRunner(context: context)
        guard generation == self.generation else { return }
        launchContext = context
        guard let system = game.system else {
            phase = .failed(Failure(message: String(localized: "Unknown system.")))
            return
        }

        gameID = game.persistentModelID
        gameUUID = game.id
        gameTitle = game.title
        systemID = system.id
        isMenuVisible = false
        userPaused = false
        toasts = []
        input.stickDrivesDPad = !["n64", "psx", "psp", "ps2", "saturn", "dreamcast", "gamecube", "wii"].contains(system.id)

        let definition = system.core(withID: game.coreID ?? Preferences.coreChoice(for: system.id))
        coreID = definition.id
        coreName = definition.name

        // Tracks may have been added or removed since the last scan.
        let missingTracks = LibraryScanner.missingTracks(of: game.fileURL)
        if game.missingTracks != missingTracks {
            game.missingTracks = missingTracks
            try? context.save()
        }
        if !game.missingTracks.isEmpty {
            phase = .failed(Failure(message: String(localized: "Files of this disc are missing: \(game.missingTracks.joined(separator: ", ")). Put them next to “\(game.fileName)”, then rescan.")))
            return
        }

        await bios.refresh()
        guard generation == self.generation else { return }
        let missing = bios.missingDescriptions(for: system, coreID: definition.id)
        if !missing.isEmpty {
            let names = missing.joined(separator: ", ")
            phase = .failed(Failure(message: String(localized: "\(definition.name) needs BIOS files that are missing: \(names). Import them in Settings → BIOS, or choose another core."),
                                    settingsTab: .bios))
            return
        }

        if let emulator = definition.standalone {
            await launch(game, in: emulator, system: system, resume: resume, context: context, generation: generation)
            return
        }

        // Errors until the core is loaded are fixed in Settings → Cores.
        var settingsTab: SettingsTab? = .cores
        do {
            phase = .preparing(cores.isInstalled(definition)
                ? String(localized: "Starting \(definition.name)…")
                : String(localized: "Downloading \(definition.name)…"))
            let coreURL = try await cores.ensureInstalled(definition)
            try checkCurrent(generation)
            let core = try LibretroCore(path: coreURL.path(percentEncoded: false))
            settingsTab = nil

            phase = .preparing(String(localized: "Loading game…"))
            var contentURL = try await prepareContent(for: game, system: system, core: core)
            try checkCurrent(generation)
            var contentCRC = game.crc32
            let patch = system.supportsPatches ? PatchStore.active(in: AppPaths.extras, gameID: game.id) : nil
            if let patch {
                do {
                    let patched = try await Self.patch(contentURL, with: patch,
                                                       into: AppPaths.extracted.appending(path: "\(game.id.uuidString)-patched"))
                    contentURL = patched.url
                    contentCRC = patched.crc
                } catch {
                    throw LaunchError.patchFailed(name: patch.deletingPathExtension().lastPathComponent,
                                                  reason: error.localizedDescription)
                }
                try checkCurrent(generation)
            }
            let patchFolder = patch.map(PatchStore.saveFolderName(for:))

            let saveDirectory = AppPaths.saves.appending(path: system.id, directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: saveDirectory, withIntermediateDirectories: true)
            core.systemDirectory = AppPaths.system.path(percentEncoded: false)
            core.saveDirectory = saveDirectory.path(percentEncoded: false)
            var batterySave = batterySaveURL(for: game, systemID: system.id, context: context)
            if let patchFolder {
                // A hack must not write over the original's save.
                batterySave = batterySave.deletingLastPathComponent().appending(path: "Patches", directoryHint: .isDirectory)
                    .appending(path: patchFolder, directoryHint: .isDirectory).appending(path: batterySave.lastPathComponent)
            }
            core.saveRAMPath = batterySave.path(percentEncoded: false)
            core.rtcPath = BatterySave.rtcURL(forSave: batterySave).path(percentEncoded: false)
            core.saveErrorHandler = { [weak self] reason in
                MainActor.assumeIsolated {
                    self?.showToast(String(localized: "The battery save couldn't be written. \(reason)"), kind: .warning, duration: 6)
                }
            }
            let gameOptions = game.coreOptions(for: definition.id)
            usesGameCoreOptions = gameOptions != nil
            core.optionOverrides = definition.optionDefaults
                .merging(Preferences.coreOptions(for: definition.id)) { $1 }
                .merging(gameOptions ?? [:]) { $1 }
            core.languageCode = Locale.current.language.languageCode?.identifier ?? "en"
            core.messageHandler = { [weak self] message, duration in
                MainActor.assumeIsolated { self?.showToast(message, duration: duration) }
            }

            let stateContext = SaveStateContext(coreID: definition.id, coreVersion: core.libraryVersion,
                                                gameCRC32: contentCRC, gameFileName: game.fileName, gameFileSize: game.fileSize)
            let stateFolder = patchFolder.map { "\(definition.id)/Patches/\($0)" } ?? definition.id
            let autosaveDirectory = SaveStateStore.directory(in: AppPaths.states, gameID: game.id, coreID: stateFolder)
            let consoleID = AchievementService.consoleID(for: system.id)
            // Hardcore forbids continuing from a state; the game starts fresh.
            let expectsHardcore = achievements.isActive && Preferences.achievementsHardcore && consoleID != nil
            core.turboPeriod = Preferences.turboRate
            core.rumbleHandler = { [weak self] port, strong, strength in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.input.setRumble(port: port, strong: strong, strength: strength) }
                }
            }

            let runner = EmulationRunner(core: core)
            runner.volume = Float(Preferences.volume)
            applyPlaybackSettings(to: runner, hardcore: expectsHardcore)
            let writeAutosave: (@Sendable (LibretroCore) -> Void)? = Preferences.autosaveOnQuit
                ? { @Sendable core in Self.writeAutosave(of: core, context: stateContext, in: autosaveDirectory) }
                : nil
            let resumeState = expectsHardcore ? nil : state
                ?? (resume ? SaveStateStore.autosave(in: AppPaths.states, gameID: game.id, coreID: stateFolder) : nil)
            if expectsHardcore, state != nil || resume, SaveStateStore.autosave(in: AppPaths.states, gameID: game.id, coreID: stateFolder) != nil {
                showToast(String(localized: "Hardcore mode starts games from the beginning."), duration: 4)
            }
            if resumeState == nil { runner.willUnloadHandler = writeAutosave }
            runner.terminationHandler = { [weak self] in
                MainActor.assumeIsolated { self?.handleUnexpectedTermination() }
            }
            // Register the runner before the (slow, blocking) game load starts,
            // so a launch or stop that arrives meanwhile waits for it to finish.
            self.runner = runner
            let path = contentURL.path(percentEncoded: false)
            let error: Error? = await withCheckedContinuation { continuation in
                runner.start(withGamePath: path) { error in continuation.resume(returning: error) }
            }
            // Stopped or replaced while the game was loading: whoever
            // superseded this launch is shutting the runner down.
            guard generation == self.generation else { return }
            if let error {
                self.runner = nil
                throw error
            }

            self.core = core
            self.stateContext = stateContext
            cores.recordVersion(core.libraryVersion, for: definition)
            self.stateFolder = stateFolder
            patchName = patch?.deletingPathExtension().lastPathComponent
            hasComputerKeyboard = system.kind == .computer
            isHardcore = expectsHardcore
            supportsCheats = core.supportsCheats
            cheats = CheatStore.cheats(in: AppPaths.extras, gameID: game.id)
            applyCheats()
            autosave = resumeState == nil ? writeAutosave : nil
            input.core = core
            input.isTurboActive = true
            input.profile = InputProfile.resolved(gameProfile: game.inputProfileData, systemID: system.id)
            startedAt = .now
            phase = .running
            game.lastPlayed = .now
            game.playCount += 1
            try? context.save()
            reloadSlots()
            discLabels = game.fileURL.pathExtension.lowercased() == "m3u"
                ? (DiscPlaylist.read(game.fileURL)?.entries.map(\.label) ?? []) : []
            refreshDiskInfo()
            startFPSTimer()
            applyPause()
            if let resumeState { continueFromAutosave(resumeState, then: writeAutosave) }
            if achievements.isActive, let consoleID {
                loadAchievements(path: path, consoleID: consoleID, core: core, runner: runner, hardcore: expectsHardcore)
            }
            #if DEBUG
            if ProcessInfo.processInfo.environment["URSPRUNG_DEBUG_PLAY"] != nil {
                // Development aid: screenshot, rewind and fast forward, then quit.
                Task {
                    try? await Task.sleep(for: .seconds(5)); takeScreenshot()
                    try? await Task.sleep(for: .seconds(1)); setRewinding(true)
                    try? await Task.sleep(for: .seconds(2)); setRewinding(false)
                    try? await Task.sleep(for: .seconds(1)); setFastForward(true)
                    try? await Task.sleep(for: .seconds(2)); setFastForward(false)
                    try? await Task.sleep(for: .seconds(2)); NSApp.terminate(nil)
                }
            }
            if ProcessInfo.processInfo.environment["URSPRUNG_DEBUG_STATES"] != nil {
                // Development aid: exercise save, load and termination automatically.
                Task {
                    try? await Task.sleep(for: .seconds(4)); saveState(slot: 1)
                    try? await Task.sleep(for: .seconds(2)); loadState(slot: 1)
                    try? await Task.sleep(for: .seconds(2)); NSApp.terminate(nil)
                }
            }
            #endif
        } catch {
            guard generation == self.generation, !(error is CancellationError) else { return }
            phase = .failed(Failure(message: error.localizedDescription, settingsTab: settingsTab))
        }
    }

    /// Battery saves are kept per game. A save that older versions stored under
    /// the ROM's file name moves over when that name is unique in the library.
    private func batterySaveURL(for game: Game, systemID: String, context: ModelContext) -> URL {
        let saves = AppPaths.saves
        let baseName = game.saveBaseName
        let url = BatterySave.url(in: saves, systemID: systemID, gameID: game.id, baseName: baseName)
        // After a rename the game's save still carries the old file name.
        BatterySave.adoptRenamed(at: url)
        let siblings = ((try? context.fetch(FetchDescriptor<Game>(predicate: #Predicate { $0.systemID == systemID }))) ?? [])
            .filter { $0.saveBaseName == baseName }
        BatterySave.migrateLegacy(to: url,
                                  legacy: BatterySave.legacyURL(in: saves, systemID: systemID, baseName: baseName),
                                  isUnambiguous: siblings.count == 1)
        return url
    }

    private func checkCurrent(_ generation: Int) throws {
        if generation != self.generation { throw CancellationError() }
    }

    /// Resolves the file handed to the core, extracting zipped cartridges if
    /// the core cannot read archives itself.
    private func prepareContent(for game: Game, system: GameSystem, core: LibretroCore) async throws -> URL {
        let url = game.fileURL
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: url.path(percentEncoded: false)])
        }
        let ext = url.pathExtension.lowercased()
        if ext == "7z", !system.archivesAreNative, !core.validExtensions.contains("7z") {
            // Ursprung unpacks zip archives only.
            throw LaunchError.unsupportedArchive(coreName: coreName)
        }
        guard ext == "zip", !system.archivesAreNative, !core.validExtensions.contains("zip") else { return url }
        return try await Self.extract(zip: url, system: system, into: AppPaths.extracted.appending(path: game.id.uuidString))
    }

    @concurrent
    private static func extract(zip: URL, system: GameSystem, into directory: URL) async throws -> URL {
        guard let entry = LibraryScanner.primaryEntry(inZip: zip, system: system) else { throw ZipArchive.ZipError.corrupt }
        return try ZipArchive.extractCached(entry, from: zip, into: directory)
    }

    /// Writes the patched ROM to the cache; the original stays untouched.
    @concurrent
    private static func patch(_ rom: URL, with patch: URL, into directory: URL) async throws -> (url: URL, crc: String) {
        let url = try PatchStore.patchedCopy(of: rom, with: patch, into: directory)
        return (url, Checksum.hex(try Checksum.crc(of: url)))
    }

    // MARK: - Standalone emulators

    /// Starts `game` in a standalone emulator (docs/STANDALONE_PLAN.md):
    /// installs it if needed, checks what would make it show an error dialog,
    /// writes its settings and launches it in its own window.
    private func launch(_ game: Game, in emulator: StandaloneEmulator, system: GameSystem, resume: Bool,
                        context: ModelContext, generation: Int) async {
        var settingsTab: SettingsTab? = .cores
        do {
            phase = .preparing(emulators.isInstalled(emulator)
                ? String(localized: "Starting \(emulator.name)…")
                : String(localized: "Downloading \(emulator.name)…"))
            let app = try await emulators.ensureInstalled(emulator)
            try checkCurrent(generation)
            settingsTab = nil

            let stateFolder = SaveStateStore.directory(in: AppPaths.states, gameID: game.id, coreID: emulator.id)
            // The metadata region, when the disc does not tell which BIOS it wants.
            let fallbackRegion: PS2BIOS.Region = switch Preferences.scraperRegion {
            case "us": .usa
            case "jp": .japan
            default: .europe
            }
            let logFolder = emulators.logFolder(for: emulator)
            let request = ARMSX2Launch.Request(
                app: app, executable: emulator.executable,
                dataFolder: emulators.dataFolder(for: emulator),
                logFile: logFolder.appending(path: "last-run.log"),
                pineFolder: URL(filePath: NSTemporaryDirectory()).appending(path: "Ursprung-PINE", directoryHint: .isDirectory),
                game: game.fileURL,
                biosFolder: AppPaths.system.appending(path: system.biosFolder?.path ?? "", directoryHint: .isDirectory),
                dumps: system.biosFolder.map(bios.dumps(in:)) ?? [],
                fallbackRegion: fallbackRegion,
                memoryCardFolder: AppPaths.saves.appending(path: system.id, directoryHint: .isDirectory)
                    .appending(path: game.id.uuidString, directoryHint: .isDirectory),
                saveStateFolder: stateFolder,
                snapshotFolder: ScreenshotStore.directory(in: AppPaths.extras, gameID: game.id),
                resume: resume,
                saveStateOnShutdown: Preferences.autosaveOnQuit,
                fullscreen: Preferences.standaloneFullscreen,
                saveStateVersion: emulator.saveStateVersion)
            let launch = try await Self.prepare(request)
            try checkCurrent(generation)

            let external = try ExternalSession(executable: launch.executable, arguments: launch.arguments,
                                               environment: launch.environment,
                                               output: logFolder.appending(path: "last-run-output.log"))
            external.onExit = { [weak self] exit in self?.externalDidExit(exit) }
            self.external = external
            externalStateFolder = stateFolder
            externalLog = launch.logFile
            startedAt = .now
            phase = .external
            game.lastPlayed = .now
            game.playCount += 1
            try? context.save()
            #if DEBUG
            if ProcessInfo.processInfo.environment["URSPRUNG_DEBUG_PLAY"] != nil {
                // Development aid: quit the emulator like the Quit button, then Ursprung.
                Task {
                    try? await Task.sleep(for: .seconds(20)); await stop(context: nil)
                    try? await Task.sleep(for: .seconds(2)); NSApp.terminate(nil)
                }
            }
            #endif
        } catch {
            guard generation == self.generation, !(error is CancellationError) else { return }
            phase = .failed(Failure(message: error.localizedDescription, settingsTab: settingsTab))
        }
    }

    @concurrent
    private static func prepare(_ request: ARMSX2Launch.Request) async throws -> ARMSX2Launch {
        try ARMSX2Launch.prepare(request, environment: ProcessInfo.processInfo.environment)
    }

    /// The emulator ended without Ursprung asking: the user quit it, or it crashed.
    private func externalDidExit(_ exit: ExternalSession.Exit) {
        // A stop or another launch is finishing the session.
        guard shutdown == nil, !exit.wasRequested else { return }
        let log = externalLog
        let name = coreName
        finishExternal(cleanExit: exit.isClean, context: nil)
        guard !exit.isClean else {
            phase = .idle
            return
        }
        let reason = log.flatMap { try? String(contentsOf: $0, encoding: .utf8) }.flatMap(ARMSX2Launch.errorMessage(inLog:))
        let message = reason.map { String(localized: "\(name) quit unexpectedly: \($0)") }
            ?? String(localized: "\(name) quit unexpectedly. Its log may tell why.")
        phase = .failed(Failure(message: message, logURL: log))
    }

    /// Records the play time and drops a resume state the session did not
    /// write. After a crash the old one is the best there is, so it stays.
    private func finishExternal(cleanExit: Bool, context: ModelContext?) {
        recordPlayTime(context: context)
        if cleanExit, let folder = externalStateFolder, let startedAt {
            ARMSX2States.removeStaleResumeState(in: folder, olderThan: startedAt)
        }
        external = nil
        externalStateFolder = nil
        externalLog = nil
        startedAt = nil
    }

    /// Brings the standalone emulator's window to the front.
    func showExternalWindow() {
        external?.activate()
    }

    /// Closes a failure shown in the library instead of the player window.
    func dismissFailure() {
        if case .failed = phase { phase = .idle }
    }

    // MARK: - Stop

    func stop(context: ModelContext?) async {
        generation += 1
        let generation = generation
        await shutDownRunner(context: context)
        // A game launched while this one was shutting down keeps the player.
        if generation == self.generation { phase = .idle }
    }

    /// Stops the running game. Concurrent callers share one shutdown, so the
    /// runner is stopped once and a new game waits until the old one is gone.
    private func shutDownRunner(context: ModelContext?) async {
        if let shutdown { return await shutdown.value }
        if let external {
            let task = Task {
                let exit = await external.stop()
                finishExternal(cleanExit: exit.isClean, context: context)
                shutdown = nil
            }
            shutdown = task
            return await task.value
        }
        guard let runner else { return }
        fpsTimer?.invalidate()
        let task = Task {
            await withCheckedContinuation { continuation in
                runner.stop { continuation.resume() }
            }
            recordPlayTime(context: context)
            cleanUp()
            shutdown = nil
        }
        shutdown = task
        await task.value
    }

    private func handleUnexpectedTermination() {
        recordPlayTime(context: nil)
        cleanUp()
        phase = .idle
        coreTerminations += 1
    }

    private func recordPlayTime(context: ModelContext?) {
        guard let startedAt, let gameID, let context = context ?? launchContext,
              let game = context.existingGame(gameID) else { return }
        game.playTime += Date.now.timeIntervalSince(startedAt)
        try? context.save()
    }

    private func cleanUp() {
        fpsTimer?.invalidate()
        input.core = nil
        input.reset()
        input.stopRumble()
        input.reloadMapping()
        if achievementGame != nil || achievements.client.isGameLoaded { achievements.client.unloadGame() }
        runner = nil
        core = nil
        stateContext = nil
        stateFolder = nil
        autosave = nil
        startedAt = nil
        isMenuVisible = false
        isShaderPanelVisible = false
        shader.useBuiltin()
        isFastForwarding = false
        isRewinding = false
        isTyping = false
        patchName = nil
        cheats = []
        achievementGame = nil
        achievementIndicators = []
        isHardcore = false
    }

    // MARK: - Controls

    /// Opens or closes the game menu; with the shader panel open, closes the panel.
    func toggleMenu() {
        guard phase == .running else { return }
        if isShaderPanelVisible {
            isShaderPanelVisible = false
        } else {
            isMenuVisible.toggle()
        }
    }

    /// Shows or hides the shader panel; showing it closes the game menu.
    func toggleShaderPanel() {
        guard phase == .running else { return }
        if isShaderPanelVisible {
            isShaderPanelVisible = false
        } else {
            isMenuVisible = false
            isShaderPanelVisible = true
        }
    }

    func togglePause() {
        userPaused.toggle()
        applyPause()
    }

    /// While paused, advances the game by one frame (for the shader editor).
    func stepFrame() {
        guard phase == .running, isPaused else { return }
        runner?.stepFrame()
    }

    func setFastForward(_ enabled: Bool) {
        isFastForwarding = enabled
        runner?.fastForward = enabled
    }

    func toggleFastForward() {
        setFastForward(!isFastForwarding)
    }

    /// Runs the game backwards while `enabled` (the Rewind key is held).
    func setRewinding(_ enabled: Bool) {
        guard let runner else { return }
        if enabled {
            if isHardcore {
                return showToast(String(localized: "Rewind is off in hardcore mode."), kind: .warning)
            }
            guard Preferences.rewindEnabled else {
                return showToast(String(localized: "Rewind is off. Turn it on in Settings › Emulation."), duration: 4)
            }
            if runner.rewindAvailability == .unsupported {
                return showToast(String(localized: "\(coreName) can't rewind this game."), kind: .warning)
            }
        }
        guard enabled != isRewinding else { return }
        isRewinding = enabled
        runner.isRewinding = enabled
    }

    /// Turbo buttons of the controls fire repeatedly, or not.
    func toggleTurbo() {
        guard input.profile.turboMask != 0 else {
            return showToast(String(localized: "No turbo buttons are set. Choose them in Settings › Controls."), duration: 4)
        }
        input.isTurboActive.toggle()
        showToast(input.isTurboActive ? String(localized: "Turbo on") : String(localized: "Turbo off"))
    }

    /// Switches the Mac keyboard between typing on the emulated computer and
    /// playing with the key bindings.
    func toggleTyping() {
        guard let core, hasComputerKeyboard || core.wantsKeyboard else { return }
        isTyping.toggle()
        input.reset()
        core.releaseAllKeys()
        let key = input.hotkeys.bindings[.typing]?.label
        if isTyping {
            showToast(key.map { String(localized: "The keyboard types on the computer. Press \($0) to play with keys again.") }
                      ?? String(localized: "The keyboard types on the computer."), duration: 4)
        } else {
            showToast(String(localized: "Keys play the game again."))
        }
    }

    /// A key of the emulated computer keyboard, while typing.
    func typeKey(_ event: NSEvent, isDown: Bool) {
        guard let core, isTyping, let key = EmulatedKeyboard.retroKey(forKeyCode: event.keyCode) else { return }
        let character = isDown && event.type != .flagsChanged ? EmulatedKeyboard.character(of: event) : 0
        core.setKey(key, pressed: isDown, character: character, modifiers: EmulatedKeyboard.modifiers(event.modifierFlags))
    }

    func reset() {
        runner?.performOnEmulationThread { [achievements] core in
            core.reset()
            achievements.client.resetGame()
        }
        isMenuVisible = false
        showToast(String(localized: "Reset"))
    }

    // MARK: - Playback settings

    /// Fast forward speed, rewind and run-ahead from Settings, for the running
    /// game too (Settings may change them while it plays).
    func reloadPlaybackSettings() {
        guard let runner else { return }
        applyPlaybackSettings(to: runner, hardcore: isHardcore)
        core?.turboPeriod = Preferences.turboRate
        if !Preferences.rewindEnabled { setRewinding(false) }
    }

    private func applyPlaybackSettings(to runner: EmulationRunner, hardcore: Bool) {
        runner.fastForwardSpeed = Preferences.fastForwardSpeed
        runner.rewindEnabled = Preferences.rewindEnabled && !hardcore
        runner.rewindBufferMegabytes = Preferences.rewindBufferSize
        runner.runAheadFrames = Preferences.runAheadFrames
    }

    // MARK: - Screenshots

    func takeScreenshot() {
        guard let core, let gameUUID, let frame = core.copyFrameImage() else { return }
        let aspect = Double(core.aspectRatio)
        let rotation = core.rotation
        let url = ScreenshotStore.newURL(in: AppPaths.extras, gameID: gameUUID)
        Task {
            do {
                try await Self.saveScreenshot(frame, aspect: aspect, rotation: rotation, to: url)
                screenshotRevision += 1
                showToast(String(localized: "Screenshot saved"), kind: .screenshot)
            } catch {
                showToast(String(localized: "The screenshot couldn't be saved. \(error.localizedDescription)"), kind: .warning, duration: 5)
            }
        }
    }

    /// Bumped when the running game gains a frame for the shader editor.
    private(set) var shaderFrameRevision = 0

    /// Saves the picture at the core's own resolution, for the shader
    /// editor's still preview (screenshots are scaled to the picture's shape).
    func captureShaderFrame() {
        guard let core, let gameUUID, let frame = core.copyFrameImage() else { return }
        let aspect = Double(core.aspectRatio)
        Task {
            do {
                try await Self.saveShaderFrame(frame, aspectRatio: aspect, gameID: gameUUID)
                shaderFrameRevision += 1
                showToast(String(localized: "Frame captured for the shader editor"), kind: .screenshot)
            } catch {
                showToast(String(localized: "The frame couldn't be saved. \(error.localizedDescription)"), kind: .warning, duration: 5)
            }
        }
    }

    @concurrent
    private static func saveShaderFrame(_ frame: CGImage, aspectRatio: Double, gameID: UUID) async throws {
        _ = try ShaderFrameStore.save(frame, aspectRatio: aspectRatio, in: AppPaths.extras, gameID: gameID)
    }

    /// Screenshots were deleted or added outside the player.
    func noteScreenshotsChanged() {
        screenshotRevision += 1
    }

    @concurrent
    private static func saveScreenshot(_ frame: CGImage, aspect: Double, rotation: Int, to url: URL) async throws {
        guard let image = ScreenshotStore.render(frame, aspectRatio: aspect, rotation: rotation) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try ScreenshotStore.writePNG(image, to: url)
    }

    // MARK: - Cheats

    /// Replaces the running game's cheats and applies them.
    func setCheats(_ cheats: [Cheat]) {
        guard let gameUUID else { return }
        self.cheats = cheats
        do {
            try CheatStore.save(cheats, in: AppPaths.extras, gameID: gameUUID)
        } catch {
            showToast(String(localized: "The cheats couldn't be saved. \(error.localizedDescription)"), kind: .warning, duration: 5)
        }
        applyCheats()
    }

    /// Hands the cheats to the core: all of them in order, each enabled or not.
    private func applyCheats() {
        guard let runner, supportsCheats else { return }
        let cheats = isHardcore ? [] : cheats
        runner.performOnEmulationThread { core in
            core.resetCheats()
            for (index, cheat) in cheats.enumerated() {
                core.setCheatAt(UInt(index), enabled: cheat.isEnabled, code: cheat.code)
            }
        }
    }

    func setVolume(_ volume: Double) {
        runner?.volume = Float(volume)
    }

    private func setAppInactive(_ inactive: Bool) {
        appInactive = inactive
        // The fast forward key may be released in another app.
        if inactive { setFastForward(false) }
        applyPause()
    }

    private func applyPause() {
        let paused = userPaused || isMenuVisible || (appInactive && Preferences.pauseInBackground)
        isPaused = paused
        runner?.isPaused = paused
        if paused {
            input.reset()
            input.stopRumble()
            core?.releaseAllKeys()
            setRewinding(false)
        }
    }

    private func startFPSTimer() {
        fpsTimer?.invalidate()
        var ticks = 0
        fpsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let runner = self.runner else { return }
                self.measuredFPS = runner.measuredFPS
                ticks += 1
                if ticks % Int(Self.periodicAutosaveInterval) == 0, Preferences.periodicAutosave, !self.isPaused {
                    self.autosaveNow()
                }
                #if DEBUG
                self.writeDebugSnapshot()
                #endif
            }
        }
    }

    #if DEBUG
    /// With URSPRUNG_SNAPSHOT_DIR set, the current frame and session state are
    /// written there once per second (Metal layers cannot be snapshotted).
    private func writeDebugSnapshot() {
        guard let path = ProcessInfo.processInfo.environment["URSPRUNG_SNAPSHOT_DIR"], let core else { return }
        let directory = URL(filePath: path, directoryHint: .isDirectory)
        if let image = core.copyFrameImage() { Self.writePNG(image, to: directory.appending(path: "frame.png")) }
        let state = "phase=\(phase) paused=\(isPaused) fps=\(measuredFPS) core=\(coreName) size=\(core.baseWidth)x\(core.baseHeight) aspect=\(core.aspectRatio) hw=\(core.usesHardwareRendering)"
            + " controllers=\(input.controllerNames)"
            + " rewind=\(runner.map { "\($0.rewindAvailability.rawValue)/\(String(format: "%.1f", $0.rewindSeconds))s" } ?? "-") rewinding=\(isRewinding)"
            + " ff=\(isFastForwarding) runAhead=\(Preferences.runAheadFrames) cheats=\(supportsCheats) patch=\(patchName ?? "-")"
            + " shader=\(shader.status) gpu=\(shader.gpuTime.map { String(format: "%.2fms", $0 * 1000) } ?? "-")"
            + " budget=\(shader.frameBudget.map { String(format: "%.2fms", $0 * 1000) } ?? "-") tooSlow=\(shader.isTooSlow)"
            + " params=\(shader.parameters.prefix(6).map { "\($0.name)=\(shader.values[$0.name] ?? $0.initial)" })\n"
        try? state.write(to: directory.appending(path: "session.txt"), atomically: true, encoding: .utf8)
    }
    #endif

    // MARK: - Automatic state

    /// Seconds between automatic states while playing, when enabled.
    static let periodicAutosaveInterval: TimeInterval = 300

    /// Saves the automatic state on the emulation thread; silent, as it
    /// happens in the background. A failed write keeps the previous state.
    nonisolated static func writeAutosave(of core: LibretroCore, context: SaveStateContext, in directory: URL) {
        guard core.supportsSaveStates, let data = core.serializeState() else { return }
        do {
            try SaveStateStore.writeAutosave(data, manifest: context.manifest(), in: directory)
            if let image = core.copyFrameImage() { writePNG(image, to: directory.appending(path: "autosave.png")) }
        } catch {
            // The previous automatic state is still there.
        }
    }

    private func autosaveNow() {
        guard let runner, let autosave else { return }
        runner.performOnEmulationThread(autosave)
    }

    /// How often resuming is tried again: some cores reject a state until
    /// they have run a few frames.
    private static let resumeAttempts = 4

    /// Loads the automatic state right after the game started. Until that
    /// has worked or finally failed, no automatic state is written, so
    /// quitting meanwhile keeps the state instead of saving the game's
    /// beginning over it. If the core rejects the state, the game simply
    /// runs from the start.
    private func continueFromAutosave(_ state: SaveStateSlot, then writeAutosave: (@Sendable (LibretroCore) -> Void)?,
                                      attempt: Int = 1) {
        let generation = generation
        if let context = stateContext, state.issues(for: context).contains(.differentGameFile) {
            // A state of another revision may crash the core or corrupt the game.
            armAutosave(writeAutosave)
            showToast(state.isAutosave
                      ? String(localized: "The automatic state belongs to a different version of the game file, so the game starts from the beginning.")
                      : String(localized: "The save state belongs to a different version of the game file, so the game starts from the beginning."),
                      kind: .warning, duration: 6)
            return
        }
        guard let runner, let data = try? Data(contentsOf: state.stateURL) else { return armAutosave(writeAutosave) }
        runner.performOnEmulationThread { [weak self, achievements] core in
            let success = core.unserializeState(data)
            if success { achievements.client.stateLoaded() }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, generation == self.generation, self.runner === runner else { return }
                    if success {
                        self.armAutosave(writeAutosave)
                        self.showToast(state.isAutosave ? String(localized: "Continued where you left off")
                                                        : String(localized: "State loaded"), kind: .loaded)
                    } else if attempt < Self.resumeAttempts {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            MainActor.assumeIsolated {
                                guard generation == self.generation, self.runner === runner else { return }
                                self.continueFromAutosave(state, then: writeAutosave, attempt: attempt + 1)
                            }
                        }
                    } else {
                        self.armAutosave(writeAutosave)
                        self.showToast(state.isAutosave
                                       ? String(localized: "The game couldn't continue where you left off, so it starts from the beginning.")
                                       : String(localized: "The save state couldn't be loaded, so the game starts from the beginning."),
                                       kind: .warning, duration: 5)
                    }
                }
            }
        }
    }

    /// From now on the running game writes its automatic state when it stops
    /// (and every few minutes, if enabled).
    private func armAutosave(_ writeAutosave: (@Sendable (LibretroCore) -> Void)?) {
        autosave = writeAutosave
        runner?.willUnloadHandler = writeAutosave
    }

    // MARK: - Save states

    func reloadSlots() {
        guard let gameUUID, let stateFolder else {
            slots = []
            history = []
            return
        }
        slots = SaveStateStore.slots(in: AppPaths.states, gameID: gameUUID, coreID: stateFolder)
        history = SaveStateStore.history(in: AppPaths.states, gameID: gameUUID, coreID: stateFolder)
    }

    /// Why the state in `slot` may not load or may belong to another file.
    func issues(for slot: SaveStateSlot) -> [SaveStateIssue] {
        stateContext.map { slot.issues(for: $0) } ?? []
    }

    func saveState(slot: Int) {
        guard let runner, let gameUUID, let context = stateContext, let stateFolder else { return }
        let directory = SaveStateStore.directory(in: AppPaths.states, gameID: gameUUID, coreID: stateFolder)
        runner.performOnEmulationThread { [weak self] core in
            let message: String
            var kind = Toast.Kind.warning
            if !core.supportsSaveStates {
                message = String(localized: "This core does not support save states")
            } else if let data = core.serializeState() {
                do {
                    try SaveStateStore.write(data, manifest: context.manifest(), slot: slot, in: directory)
                    if let image = core.copyFrameImage() {
                        Self.writePNG(image, to: directory.appending(path: "slot\(slot).png"))
                    }
                    message = String(localized: "State saved")
                    kind = .saved
                } catch {
                    message = String(localized: "The state couldn't be saved. \(error.localizedDescription)")
                }
            } else {
                message = String(localized: "The core couldn't create a save state right now. Try again in a moment.")
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.reloadSlots()
                    self?.showToast(message, kind: kind, duration: kind == .saved ? 2.5 : 5)
                }
            }
        }
    }

    func loadState(slot: Int) {
        guard let state = slots.first(where: { $0.slot == slot }) else {
            showToast(String(localized: "No saved state in this slot"))
            return
        }
        loadState(state)
    }

    /// Loads any state of the running game and core, e.g. one from the history.
    func loadState(_ state: SaveStateSlot) {
        guard let runner else { return }
        if isHardcore {
            return showToast(String(localized: "Loading states is off in hardcore mode."), kind: .warning)
        }
        guard let data = try? Data(contentsOf: state.stateURL) else {
            showToast(String(localized: "No saved state in this slot"))
            return
        }
        let issues = issues(for: state)
        runner.performOnEmulationThread { [weak self, achievements] core in
            let success = core.unserializeState(data)
            if success { achievements.client.stateLoaded() }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if success {
                        if let note = issues.first.map(Self.loadedNote) {
                            self.showToast(note, kind: .warning, duration: 5)
                        } else {
                            self.showToast(String(localized: "State loaded"), kind: .loaded)
                        }
                        self.isMenuVisible = false
                    } else {
                        let reason = issues.first.map(Self.failureReason) ?? ""
                        self.showToast([String(localized: "The state could not be loaded."), reason].joined(separator: " ")
                            .trimmingCharacters(in: .whitespaces), kind: .warning, duration: 6)
                    }
                }
            }
        }
    }

    /// A deleted slot's state goes into the history.
    func deleteState(slot: SaveStateSlot) {
        do {
            try SaveStateStore.discard(slot)
        } catch {
            showToast(String(localized: "The state couldn't be deleted. \(error.localizedDescription)"), kind: .warning, duration: 5)
        }
        reloadSlots()
    }

    func renameState(_ state: SaveStateSlot, to name: String?) {
        do {
            try SaveStateStore.rename(state, to: name)
        } catch {
            showToast(String(localized: "The state couldn't be renamed. \(error.localizedDescription)"), kind: .warning, duration: 5)
        }
        reloadSlots()
    }

    /// Puts a state from the history back into its slot (or `slot`).
    func restoreState(_ entry: SaveStateSlot, toSlot slot: Int? = nil) {
        guard let gameUUID, let stateFolder else { return }
        let target = slot ?? entry.slot
        do {
            try SaveStateStore.restore(entry, toSlot: target,
                                       in: SaveStateStore.directory(in: AppPaths.states, gameID: gameUUID, coreID: stateFolder))
            showToast(target == 0 ? String(localized: "Restored as Quick Save") : String(localized: "Restored to slot \(target)"),
                      kind: .saved)
        } catch {
            showToast(String(localized: "The state couldn't be restored. \(error.localizedDescription)"), kind: .warning, duration: 5)
        }
        reloadSlots()
    }

    /// A short description of an issue, e.g. for a slot's help text.
    static func describe(_ issue: SaveStateIssue) -> String {
        switch issue {
        case .unknownOrigin: String(localized: "Saved by an earlier version of Ursprung, possibly with another core.")
        case .coreVersion(let version): String(localized: "Saved with core version \(version).")
        case .differentGameFile: String(localized: "Saved from a different version of the game file.")
        }
    }

    private static func loadedNote(_ issue: SaveStateIssue) -> String {
        String(localized: "State loaded. \(describe(issue)) If the game misbehaves, restart it.")
    }

    private static func failureReason(_ issue: SaveStateIssue) -> String {
        switch issue {
        case .unknownOrigin: String(localized: "It was probably made with another core.")
        case .coreVersion(let version): String(localized: "It was saved with core version \(version); the installed version can't read it.")
        case .differentGameFile: String(localized: "It was saved from a different version of the game file.")
        }
    }

    nonisolated private static func writePNG(_ image: CGImage, to url: URL) {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }

    // MARK: - Discs

    func refreshDiskInfo() {
        runner?.performOnEmulationThread { [weak self] core in
            let count = core.diskCount
            let current = core.currentDiskIndex
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.diskCount = count
                    self?.currentDisk = current
                }
            }
        }
    }

    func insertDisk(_ index: Int) {
        runner?.performOnEmulationThread { [weak self] core in
            let success = core.insertDisk(at: index)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if success {
                        self?.showToast(String(localized: "Disc \(index + 1) inserted"))
                    } else {
                        self?.showToast(String(localized: "Disc could not be changed"), kind: .warning)
                    }
                    self?.refreshDiskInfo()
                }
            }
        }
    }

    // MARK: - Core options

    private var runningGame: Game? {
        guard let gameID, let context = launchContext else { return nil }
        return context.existingGame(gameID)
    }

    func setCoreOption(_ value: String, for key: String) {
        guard let core, let coreID else { return }
        core.setValue(value, forOption: key)
        if usesGameCoreOptions, let game = runningGame {
            var options = game.coreOptions(for: coreID) ?? [:]
            options[key] = value
            game.setCoreOptions(options, for: coreID)
            try? launchContext?.save()
        } else {
            Preferences.setCoreOption(value, key: key, for: coreID)
        }
    }

    /// Switches core option changes between the running game and every game
    /// of the core. Leaving the game's own options brings back the core's.
    func setUsesGameCoreOptions(_ enabled: Bool) {
        guard let coreID, let game = runningGame, enabled != usesGameCoreOptions else { return }
        usesGameCoreOptions = enabled
        if enabled {
            game.setCoreOptions([:], for: coreID)
        } else {
            game.setCoreOptions(nil, for: coreID)
            applyCoreLevelOptions()
        }
        try? launchContext?.save()
    }

    func resetCoreOptions() {
        guard let coreID else { return }
        if usesGameCoreOptions, let game = runningGame {
            game.setCoreOptions([:], for: coreID)
            try? launchContext?.save()
        } else {
            Preferences.resetCoreOptions(for: coreID)
        }
        applyCoreLevelOptions()
        showToast(String(localized: "Core options reset"))
    }

    /// The values every game of the core uses: frontend defaults and the user's choices.
    private func applyCoreLevelOptions() {
        guard let core, let coreID else { return }
        let defaults = SystemCatalog.all.flatMap(\.cores).first { $0.id == coreID }?.optionDefaults ?? [:]
        let values = defaults.merging(Preferences.coreOptions(for: coreID)) { $1 }
        for option in core.options {
            core.setValue(values[option.key] ?? option.defaultValue, forOption: option.key)
        }
    }

    // MARK: - Achievements

    /// Identifies the running game for RetroAchievements and starts
    /// evaluating its achievements every frame.
    private func loadAchievements(path: String, consoleID: Int, core: LibretroCore, runner: EmulationRunner, hardcore: Bool) {
        let client = achievements.client
        guard AchievementClient.isCore(core.libraryName, allowedForConsole: consoleID) else {
            isHardcore = false
            applyPlaybackSettings(to: runner, hardcore: false)
            return showToast(String(localized: "RetroAchievements doesn't support \(coreName) for this system. Choose another core to earn achievements."),
                             kind: .warning, duration: 6)
        }
        var hardcore = hardcore
        if hardcore {
            let options = Dictionary(core.options.map { ($0.key, core.value(forOption: $0.key) ?? $0.defaultValue) },
                                     uniquingKeysWith: { first, _ in first })
            if let option = AchievementClient.disallowedOption(forCore: core.libraryName, console: consoleID, options: options) {
                hardcore = false
                let title = core.options.first { $0.key == option }?.title ?? option
                showToast(String(localized: "Hardcore mode is off for this game: the core option “\(title)” isn't allowed."),
                          kind: .warning, duration: 6)
            }
        }
        setHardcore(hardcore, runner: runner)
        client.hardcoreEnabled = hardcore
        runner.frameHandler = { [client] core, ranFrame in
            if ranFrame { client.doFrame(with: core) } else { client.idle(with: core) }
        }
        let generation = generation
        client.loadGame(atPath: path, consoleID: consoleID) { [weak self] game, error in
            MainActor.assumeIsolated {
                guard let self, generation == self.generation, self.runner === runner else { return }
                if let error {
                    self.setHardcore(false, runner: runner)
                    self.showToast(String(localized: "Achievements couldn't be loaded. \(error.localizedDescription)"),
                                   kind: .warning, duration: 5)
                } else if let game, game.achievementCount > 0 {
                    self.achievementGame = game
                    self.showToast(String(localized: "Achievements: \(game.unlockedCount) of \(game.achievementCount) unlocked"),
                                   kind: .achievement, duration: 4, imageURL: game.imageURL.flatMap(URL.init(string:)),
                                   detail: hardcore ? String(localized: "Hardcore") : nil)
                } else {
                    // No achievements: no reason for hardcore restrictions.
                    self.setHardcore(false, runner: runner)
                }
            }
        }
    }

    private func setHardcore(_ hardcore: Bool, runner: EmulationRunner) {
        guard hardcore != isHardcore else { return }
        isHardcore = hardcore
        applyPlaybackSettings(to: runner, hardcore: hardcore)
        if hardcore { setRewinding(false) }
        applyCheats()
    }

    /// The achievements of the running game, freshly read.
    func achievementList() -> [AchievementInfo] {
        achievementGame == nil ? [] : achievements.client.achievements
    }

    private func handleAchievementEvent(_ event: AchievementEvent) {
        guard phase == .running else { return }
        let image = event.imageURL.flatMap(URL.init(string:))
        let itemID = Int(event.itemID)
        switch event.kind {
        case .unlocked:
            showToast(event.title, kind: .achievement, duration: 5, imageURL: image,
                      detail: String(localized: "Achievement unlocked · \(event.points) points"))
            refreshAchievementGame()
        case .gameCompleted:
            showToast(isHardcore ? String(localized: "Mastered \(event.title)") : String(localized: "Completed \(event.title)"),
                      kind: .achievement, duration: 6, imageURL: image)
        case .subsetCompleted:
            showToast(String(localized: "Completed \(event.title)"), kind: .achievement, duration: 5, imageURL: image)
        case .leaderboardStarted:
            showToast(event.title, duration: 3, detail: String(localized: "Leaderboard attempt started"))
        case .leaderboardFailed:
            showToast(event.title, duration: 3, detail: String(localized: "Leaderboard attempt failed"))
        case .leaderboardSubmitted:
            showToast(event.title, duration: 4, detail: event.value.map { String(localized: "Submitted \($0)") })
        case .challengeShown:
            setIndicator(AchievementIndicator(kind: .challenge, itemID: itemID, imageURL: image))
        case .challengeHidden:
            achievementIndicators.removeAll { $0.kind == .challenge && $0.itemID == itemID }
        case .progressShown:
            if Preferences.achievementsShowsProgress {
                achievementIndicators.removeAll { $0.kind == .progress }
                setIndicator(AchievementIndicator(kind: .progress, itemID: itemID, value: event.value, imageURL: image))
            }
        case .progressHidden:
            achievementIndicators.removeAll { $0.kind == .progress }
        case .trackerShown, .trackerUpdated:
            setIndicator(AchievementIndicator(kind: .tracker, itemID: itemID, value: event.value))
        case .trackerHidden:
            achievementIndicators.removeAll { $0.kind == .tracker && $0.itemID == itemID }
        case .serverError:
            showToast(String(localized: "RetroAchievements reported a problem. \(event.detail ?? "")"), kind: .warning, duration: 5)
        case .disconnected:
            showToast(String(localized: "RetroAchievements can't be reached. Unlocks are sent when the connection is back."),
                      kind: .warning, duration: 5)
        case .reconnected:
            showToast(String(localized: "RetroAchievements is reachable again."))
        case .resetRequired:
            reset()
        @unknown default:
            break
        }
    }

    private func setIndicator(_ indicator: AchievementIndicator) {
        if let index = achievementIndicators.firstIndex(where: { $0.id == indicator.id }) {
            achievementIndicators[index] = indicator
        } else {
            achievementIndicators.append(indicator)
        }
    }

    private func refreshAchievementGame() {
        if achievementGame != nil { achievementGame = achievements.client.gameInfo }
    }

    // MARK: - Toasts

    func showToast(_ text: String, kind: Toast.Kind = .info, duration: TimeInterval = 2.5, imageURL: URL? = nil,
                   detail: String? = nil) {
        let toast = Toast(text: text, kind: kind, imageURL: imageURL, detail: detail)
        AccessibilityNotification.Announcement([text, detail].compactMap { $0 }.joined(separator: ", ")).post()
        toasts.append(toast)
        if toasts.count > 3 { toasts.removeFirst() }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            self?.toasts.removeAll { $0.id == toast.id }
        }
    }
}
