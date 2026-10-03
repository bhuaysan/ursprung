// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation
import ImageIO
import Observation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Controls the one game that is currently running.
@Observable
final class EmulationSession {
    enum Phase: Equatable {
        case idle
        case preparing(String)
        case running
        case failed(Failure)
    }

    /// Why a launch failed, written as what happened plus what to do.
    struct Failure: Equatable {
        let message: String
        /// The Settings tab that fixes the cause (missing core or BIOS).
        var settingsTab: SettingsTab?
    }

    struct Toast: Identifiable, Equatable {
        enum Kind { case info, saved, loaded, warning }
        let id = UUID()
        let text: String
        var kind = Kind.info
    }

    private(set) var phase: Phase = .idle
    private(set) var gameID: PersistentIdentifier?
    private(set) var gameTitle = ""
    private(set) var systemID: String?
    private(set) var coreName = ""
    private(set) var isPaused = false
    private(set) var isFastForwarding = false
    private(set) var toasts: [Toast] = []
    private(set) var slots: [SaveStateSlot] = []
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
            if isMenuVisible { setFastForward(false) }
            applyPause()
        }
    }

    private(set) var core: LibretroCore?
    private var runner: EmulationRunner?
    private var gameUUID: UUID?
    private var coreID: String?
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

    let input = InputRouter()
    let cores: CoreManager
    let bios: BIOSManager

    init(cores: CoreManager, bios: BIOSManager) {
        self.cores = cores
        self.bios = bios
        input.onMenuButton = { [weak self] in self?.toggleMenu() }
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
                self?.recordPlayTime(context: nil)
            }
        }
    }

    var isActive: Bool { phase != .idle }

    // MARK: - Launch

    func launch(_ game: Game, context: ModelContext) async {
        // Switch straight to "preparing" so the player window stays open while
        // a previous game shuts down.
        generation += 1
        let generation = generation
        // The preparing panel shows the title above the message.
        gameTitle = game.title
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
        input.stickDrivesDPad = !["n64", "psx", "psp", "saturn", "dreamcast", "gamecube", "wii"].contains(system.id)

        let definition = system.core(withID: game.coreID ?? Preferences.coreChoice(for: system.id))
        coreID = definition.id
        coreName = definition.name

        await bios.refresh()
        guard generation == self.generation else { return }
        let missing = bios.missingRequired(for: system)
        if !missing.isEmpty {
            let names = missing.map(\.fileName).joined(separator: ", ")
            phase = .failed(Failure(message: String(localized: "\(system.name) needs BIOS files that are missing: \(names). Import them in Settings → BIOS."),
                                    settingsTab: .bios))
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
            let contentURL = try await prepareContent(for: game, system: system, core: core)
            try checkCurrent(generation)

            let saveDirectory = AppPaths.saves.appending(path: system.id, directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: saveDirectory, withIntermediateDirectories: true)
            core.systemDirectory = AppPaths.system.path(percentEncoded: false)
            core.saveDirectory = saveDirectory.path(percentEncoded: false)
            let batterySave = batterySaveURL(for: game, systemID: system.id, context: context)
            core.saveRAMPath = batterySave.path(percentEncoded: false)
            core.rtcPath = BatterySave.rtcURL(forSave: batterySave).path(percentEncoded: false)
            core.saveErrorHandler = { [weak self] reason in
                MainActor.assumeIsolated {
                    self?.showToast(String(localized: "The battery save couldn't be written. \(reason)"), kind: .warning, duration: 6)
                }
            }
            core.optionOverrides = definition.optionDefaults.merging(Preferences.coreOptions(for: definition.id)) { $1 }
            core.languageCode = Locale.current.language.languageCode?.identifier ?? "en"
            core.messageHandler = { [weak self] message, duration in
                MainActor.assumeIsolated { self?.showToast(message, duration: duration) }
            }

            let runner = EmulationRunner(core: core)
            runner.volume = Float(Preferences.volume)
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
            stateContext = SaveStateContext(coreID: definition.id, coreVersion: core.libraryVersion,
                                            gameCRC32: game.crc32, gameFileName: game.fileName, gameFileSize: game.fileSize)
            input.core = core
            input.reloadMapping()
            startedAt = .now
            phase = .running
            game.lastPlayed = .now
            game.playCount += 1
            try? context.save()
            reloadSlots()
            refreshDiskInfo()
            startFPSTimer()
            applyPause()
            #if DEBUG
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
        guard ext == "zip", !system.archivesAreNative, !core.validExtensions.contains("zip") else { return url }
        return try await Self.extract(zip: url, system: system, into: AppPaths.extracted.appending(path: game.id.uuidString))
    }

    @concurrent
    private static func extract(zip: URL, system: GameSystem, into directory: URL) async throws -> URL {
        guard let entry = LibraryScanner.primaryEntry(inZip: zip, system: system) else { throw ZipArchive.ZipError.corrupt }
        return try ZipArchive.extractCached(entry, from: zip, into: directory)
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
        runner = nil
        core = nil
        stateContext = nil
        startedAt = nil
        isMenuVisible = false
        isFastForwarding = false
    }

    // MARK: - Controls

    func toggleMenu() {
        guard phase == .running else { return }
        isMenuVisible.toggle()
    }

    func togglePause() {
        userPaused.toggle()
        applyPause()
    }

    func setFastForward(_ enabled: Bool) {
        isFastForwarding = enabled
        runner?.fastForward = enabled
    }

    func reset() {
        runner?.performOnEmulationThread { core in core.reset() }
        isMenuVisible = false
        showToast(String(localized: "Reset"))
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
        if paused { input.reset() }
    }

    private func startFPSTimer() {
        fpsTimer?.invalidate()
        fpsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let runner = self.runner else { return }
                self.measuredFPS = runner.measuredFPS
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
            + " controllers=\(input.controllerNames)\n"
        try? state.write(to: directory.appending(path: "session.txt"), atomically: true, encoding: .utf8)
    }
    #endif

    // MARK: - Save states

    func reloadSlots() {
        guard let gameUUID, let coreID else { slots = []; return }
        slots = SaveStateStore.slots(in: AppPaths.states, gameID: gameUUID, coreID: coreID)
    }

    /// Why the state in `slot` may not load or may belong to another file.
    func issues(for slot: SaveStateSlot) -> [SaveStateIssue] {
        stateContext.map { slot.issues(for: $0) } ?? []
    }

    func saveState(slot: Int) {
        guard let runner, let gameUUID, let context = stateContext else { return }
        let directory = SaveStateStore.directory(in: AppPaths.states, gameID: gameUUID, coreID: context.coreID)
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
        guard let runner else { return }
        guard let state = slots.first(where: { $0.slot == slot }), let data = try? Data(contentsOf: state.stateURL) else {
            showToast(String(localized: "No saved state in this slot"))
            return
        }
        let issues = issues(for: state)
        runner.performOnEmulationThread { [weak self] core in
            let success = core.unserializeState(data)
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

    func deleteState(slot: SaveStateSlot) {
        SaveStateStore.delete(slot)
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

    func setCoreOption(_ value: String, for key: String) {
        guard let core, let coreID else { return }
        core.setValue(value, forOption: key)
        Preferences.setCoreOption(value, key: key, for: coreID)
    }

    func resetCoreOptions() {
        guard let core, let coreID else { return }
        Preferences.resetCoreOptions(for: coreID)
        let defaults = SystemCatalog.all.flatMap(\.cores).first { $0.id == coreID }?.optionDefaults ?? [:]
        for option in core.options {
            core.setValue(defaults[option.key] ?? option.defaultValue, forOption: option.key)
        }
        showToast(String(localized: "Core options reset"))
    }

    // MARK: - Toasts

    func showToast(_ text: String, kind: Toast.Kind = .info, duration: TimeInterval = 2.5) {
        let toast = Toast(text: text, kind: kind)
        AccessibilityNotification.Announcement(text).post()
        toasts.append(toast)
        if toasts.count > 3 { toasts.removeFirst() }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            self?.toasts.removeAll { $0.id == toast.id }
        }
    }
}
