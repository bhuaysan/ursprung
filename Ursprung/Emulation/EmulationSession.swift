// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation
import ImageIO
import Observation
import SwiftData
import UniformTypeIdentifiers

/// A save state slot on disk.
nonisolated struct SaveStateSlot: Identifiable, Hashable, Sendable {
    let slot: Int
    let date: Date
    let stateURL: URL
    let thumbnailURL: URL
    var id: Int { slot }
}

/// Controls the one game that is currently running.
@Observable
final class EmulationSession {
    enum Phase: Equatable {
        case idle
        case preparing(String)
        case running
        case failed(String)
    }

    struct Toast: Identifiable, Equatable {
        let id = UUID()
        let text: String
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
        didSet { if isMenuVisible != oldValue { applyPause() } }
    }

    private(set) var core: LibretroCore?
    private var runner: EmulationRunner?
    private var gameUUID: UUID?
    private var coreID: String?
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
        phase = .preparing(String(localized: "Loading \(game.title)…"))
        await shutDownRunner(context: context)
        guard generation == self.generation else { return }
        launchContext = context
        guard let system = game.system else {
            phase = .failed(String(localized: "Unknown system."))
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
            phase = .failed(String(localized: "\(system.name) needs BIOS files that are missing: \(names). Import them in Settings → BIOS."))
            return
        }

        do {
            phase = .preparing(cores.isInstalled(definition)
                ? String(localized: "Starting \(definition.name)…")
                : String(localized: "Downloading \(definition.name)…"))
            let coreURL = try await cores.ensureInstalled(definition)
            try checkCurrent(generation)
            let core = try LibretroCore(path: coreURL.path(percentEncoded: false))

            phase = .preparing(String(localized: "Loading \(game.title)…"))
            let contentURL = try await prepareContent(for: game, system: system, core: core)
            try checkCurrent(generation)

            let saveDirectory = AppPaths.saves.appending(path: system.id, directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: saveDirectory, withIntermediateDirectories: true)
            core.systemDirectory = AppPaths.system.path(percentEncoded: false)
            core.saveDirectory = saveDirectory.path(percentEncoded: false)
            core.saveRAMPath = batterySaveURL(for: game, systemID: system.id, context: context).path(percentEncoded: false)
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
            phase = .failed(error.localizedDescription)
        }
    }

    /// Battery saves are kept per game. A save that older versions stored under
    /// the ROM's file name moves over when that name is unique in the library.
    private func batterySaveURL(for game: Game, systemID: String, context: ModelContext) -> URL {
        let saves = AppPaths.saves
        let baseName = game.saveBaseName
        let url = BatterySave.url(in: saves, systemID: systemID, gameID: game.id, baseName: baseName)
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
              let game = context.model(for: gameID) as? Game else { return }
        game.playTime += Date.now.timeIntervalSince(startedAt)
        try? context.save()
    }

    private func cleanUp() {
        fpsTimer?.invalidate()
        input.core = nil
        input.reset()
        runner = nil
        core = nil
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
        let state = "phase=\(phase) paused=\(isPaused) fps=\(measuredFPS) core=\(coreName) size=\(core.baseWidth)x\(core.baseHeight) aspect=\(core.aspectRatio) hw=\(core.usesHardwareRendering)\n"
        try? state.write(to: directory.appending(path: "session.txt"), atomically: true, encoding: .utf8)
    }
    #endif

    // MARK: - Save states

    private var statesDirectory: URL? {
        gameUUID.map { AppPaths.states.appending(path: $0.uuidString, directoryHint: .isDirectory) }
    }

    func reloadSlots() {
        guard let directory = statesDirectory else { slots = []; return }
        slots = (0...9).compactMap { slot in
            let state = directory.appending(path: "slot\(slot).state")
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: state.path(percentEncoded: false)),
                  let date = attributes[.modificationDate] as? Date else { return nil }
            return SaveStateSlot(slot: slot, date: date, stateURL: state, thumbnailURL: directory.appending(path: "slot\(slot).png"))
        }
    }

    func saveState(slot: Int) {
        guard let runner, let directory = statesDirectory else { return }
        let stateURL = directory.appending(path: "slot\(slot).state")
        let thumbnailURL = directory.appending(path: "slot\(slot).png")
        runner.performOnEmulationThread { [weak self] core in
            let success: Bool
            if let data = core.serializeState() {
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                success = (try? data.write(to: stateURL, options: .atomic)) != nil
                if success, let image = core.copyFrameImage() {
                    Self.writePNG(image, to: thumbnailURL)
                }
            } else {
                success = false
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.reloadSlots()
                    self?.showToast(success ? String(localized: "State saved") : String(localized: "This core does not support save states"))
                }
            }
        }
    }

    func loadState(slot: Int) {
        guard let runner, let directory = statesDirectory else { return }
        let stateURL = directory.appending(path: "slot\(slot).state")
        guard let data = try? Data(contentsOf: stateURL) else {
            showToast(String(localized: "No saved state in this slot"))
            return
        }
        runner.performOnEmulationThread { [weak self] core in
            let success = core.unserializeState(data)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.showToast(success ? String(localized: "State loaded") : String(localized: "The state could not be loaded"))
                    if success { self?.isMenuVisible = false }
                }
            }
        }
    }

    func deleteState(slot: SaveStateSlot) {
        try? FileManager.default.removeItem(at: slot.stateURL)
        try? FileManager.default.removeItem(at: slot.thumbnailURL)
        reloadSlots()
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
                    self?.showToast(success ? String(localized: "Disc \(index + 1) inserted") : String(localized: "Disc could not be changed"))
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

    func showToast(_ text: String, duration: TimeInterval = 2.5) {
        let toast = Toast(text: text)
        toasts.append(toast)
        if toasts.count > 3 { toasts.removeFirst() }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            self?.toasts.removeAll { $0.id == toast.id }
        }
    }
}
