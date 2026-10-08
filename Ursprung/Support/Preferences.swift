// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// UserDefaults keys. Views bind with `@AppStorage(PrefKey.…)`, services read
/// through `Preferences`.
nonisolated enum PrefKey {
    static let libraryFolders = "libraryFolders"
    static let scraperLanguage = "scraperLanguage"
    static let scraperRegion = "scraperRegion"
    static let scraperUsername = "scraperUsername"
    static let autoScrape = "autoScrape"
    static let videoFilter = "videoFilter"
    static let integerScaling = "integerScaling"
    static let volume = "volume"
    static let pauseInBackground = "pauseInBackground"
    static let showFPS = "showFPS"
    static let gridSize = "gridSize"
    static let keyboardMapping = "keyboardMapping"
    static let librarySort = "librarySort"
    static let settingsTab = "settingsTab"
    static let autosaveOnQuit = "autosaveOnQuit"
    static let periodicAutosave = "periodicAutosave"
    static let resumeAutomatically = "resumeAutomatically"
    static let controllerMapping = "controllerMapping"
    static let turboButtons = "turboButtons"
    static let hotkeys = "hotkeys"
    static let portAssignments = "portAssignments"
    static let stickDeadZone = "stickDeadZone"
    static let collections = "collections"
    static let libraryViewMode = "libraryViewMode"
    static let groupsVariants = "groupsVariants"
    static let preferredRegions = "preferredRegions"
    static let fastForwardSpeed = "fastForwardSpeed"
    static let rewindEnabled = "rewindEnabled"
    static let rewindBufferSize = "rewindBufferSize"
    static let runAheadFrames = "runAheadFrames"
    static let turboRate = "turboRate"
    static let rumble = "rumble"
    static let bezel = "bezel"
    static let achievementsEnabled = "achievementsEnabled"
    static let achievementsUsername = "achievementsUsername"
    static let achievementsHardcore = "achievementsHardcore"
    static let achievementsShowsProgress = "achievementsShowsProgress"
    /// Standalone emulators (PlayStation 2) open their game window in full screen.
    static let standaloneFullscreen = "standaloneFullscreen"
    /// Favourite RetroArch presets, as `ShaderSelection` raw values.
    static let shaderFavorites = "shaderFavorites"
    static func systemVideoFilter(_ systemID: String) -> String { "videoFilter.\(systemID)" }
    /// A game's own filter or preset; wins over its system's.
    static func gameVideoFilter(_ gameID: UUID) -> String { "\(gameVideoFilterPrefix)\(gameID.uuidString)" }
    static let gameVideoFilterPrefix = "videoFilter.game."
    static func inputProfile(_ systemID: String) -> String { "inputProfile.\(systemID)" }
    static func coreChoice(_ systemID: String) -> String { "coreChoice.\(systemID)" }
    static func coreOptions(_ coreID: String) -> String { "coreOptions.\(coreID)" }
    static func rendererChoice(_ coreID: String) -> String { "rendererChoice.\(coreID)" }
    static func hidGamepadMapping(_ deviceKey: String) -> String { "hidGamepadMapping.\(deviceKey)" }
}

/// Display filter applied when scaling the emulator image.
/// The graphics API the user picked for a core in Settings › Cores.
nonisolated enum RendererChoice: String, CaseIterable, Identifiable, Sendable {
    /// What the catalog recommends for the core.
    case automatic
    case vulkan
    case opengl

    var id: String { rawValue }
}

nonisolated enum VideoFilter: String, CaseIterable, Identifiable, Sendable {
    case sharp, nearest, smooth, scanlines, crt, crtCurved, lcd

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sharp: String(localized: "Sharp")
        case .nearest: String(localized: "Pixel Perfect")
        case .smooth: String(localized: "Smooth")
        case .scanlines: String(localized: "Scanlines")
        case .crt: String(localized: "CRT")
        case .crtCurved: String(localized: "CRT, Curved")
        case .lcd: String(localized: "Handheld LCD")
        }
    }

    /// Index of the filter in the presentation shader.
    var shaderIndex: UInt32 {
        switch self {
        case .sharp: 0
        case .nearest: 1
        case .smooth: 2
        case .scanlines: 3
        case .crt: 4
        case .crtCurved: 5
        case .lcd: 6
        }
    }
}

/// What fills the space around the game picture.
nonisolated enum BezelStyle: String, CaseIterable, Identifiable, Sendable {
    /// Black.
    case none
    /// A blurred, dimmed copy of the picture, as if it lit the room.
    case ambient

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: String(localized: "None")
        case .ambient: String(localized: "Ambient Light")
        }
    }
}

nonisolated enum Preferences {
    private static var defaults: UserDefaults { .standard }

    static func registerDefaults() {
        let languageCode = Locale.current.language.languageCode?.identifier ?? "en"
        let region: String = switch Locale.current.region?.identifier {
        case "US", "CA": "us"
        case "JP": "jp"
        default: "eu"
        }
        defaults.register(defaults: [
            PrefKey.scraperLanguage: ["de", "fr", "es", "it", "pt"].contains(languageCode) ? languageCode : "en",
            PrefKey.scraperRegion: region,
            PrefKey.autoScrape: true,
            PrefKey.videoFilter: VideoFilter.sharp.rawValue,
            PrefKey.integerScaling: false,
            PrefKey.volume: 1.0,
            PrefKey.pauseInBackground: true,
            PrefKey.showFPS: false,
            PrefKey.gridSize: 180.0,
            PrefKey.autosaveOnQuit: true,
            PrefKey.periodicAutosave: false,
            PrefKey.resumeAutomatically: true,
            PrefKey.stickDeadZone: 0.15,
            PrefKey.groupsVariants: true,
            PrefKey.fastForwardSpeed: 4.0,
            PrefKey.rewindEnabled: false,
            PrefKey.rewindBufferSize: 256,
            PrefKey.runAheadFrames: 0,
            PrefKey.turboRate: 3,
            PrefKey.rumble: true,
            PrefKey.bezel: BezelStyle.none.rawValue,
            PrefKey.achievementsEnabled: false,
            PrefKey.achievementsHardcore: false,
            PrefKey.achievementsShowsProgress: true,
            PrefKey.standaloneFullscreen: true,
        ])
    }

    static var libraryFolders: [URL] {
        get { (defaults.stringArray(forKey: PrefKey.libraryFolders) ?? []).map { URL(filePath: $0, directoryHint: .isDirectory) } }
        set { defaults.set(newValue.map { $0.path(percentEncoded: false) }, forKey: PrefKey.libraryFolders) }
    }

    static var scraperLanguage: String { defaults.string(forKey: PrefKey.scraperLanguage) ?? "en" }
    static var scraperRegion: String { defaults.string(forKey: PrefKey.scraperRegion) ?? "eu" }
    static var scraperUsername: String { defaults.string(forKey: PrefKey.scraperUsername) ?? "" }
    static var autoScrape: Bool { defaults.bool(forKey: PrefKey.autoScrape) }
    static var integerScaling: Bool { defaults.bool(forKey: PrefKey.integerScaling) }
    static var volume: Double { defaults.double(forKey: PrefKey.volume) }
    static var pauseInBackground: Bool { defaults.bool(forKey: PrefKey.pauseInBackground) }
    static var autosaveOnQuit: Bool { defaults.bool(forKey: PrefKey.autosaveOnQuit) }
    static var periodicAutosave: Bool { defaults.bool(forKey: PrefKey.periodicAutosave) }
    static var resumeAutomatically: Bool { defaults.bool(forKey: PrefKey.resumeAutomatically) }
    static var stickDeadZone: Float { Float(defaults.double(forKey: PrefKey.stickDeadZone)) }
    /// Times normal speed; 0 is as fast as possible.
    static var fastForwardSpeed: Double { defaults.double(forKey: PrefKey.fastForwardSpeed) }
    static var rewindEnabled: Bool { defaults.bool(forKey: PrefKey.rewindEnabled) }
    /// Megabytes of memory for rewinding.
    static var rewindBufferSize: Int { defaults.integer(forKey: PrefKey.rewindBufferSize) }
    static var runAheadFrames: Int { defaults.integer(forKey: PrefKey.runAheadFrames) }
    /// Frames a turbo button stays pressed and released.
    static var turboRate: Int { max(1, defaults.integer(forKey: PrefKey.turboRate)) }
    static var rumble: Bool { defaults.bool(forKey: PrefKey.rumble) }
    static var bezel: BezelStyle { BezelStyle(rawValue: defaults.string(forKey: PrefKey.bezel) ?? "") ?? .none }
    static var achievementsEnabled: Bool { defaults.bool(forKey: PrefKey.achievementsEnabled) }
    static var achievementsUsername: String { defaults.string(forKey: PrefKey.achievementsUsername) ?? "" }
    static var achievementsHardcore: Bool { defaults.bool(forKey: PrefKey.achievementsHardcore) }
    static var achievementsShowsProgress: Bool { defaults.bool(forKey: PrefKey.achievementsShowsProgress) }
    static var standaloneFullscreen: Bool { defaults.bool(forKey: PrefKey.standaloneFullscreen) }

    /// The user's collections in sidebar order, including empty ones.
    static var collections: [String] {
        get { defaults.stringArray(forKey: PrefKey.collections) ?? [] }
        set { defaults.set(newValue, forKey: PrefKey.collections) }
    }

    static func coreChoice(for systemID: String) -> String? {
        defaults.string(forKey: PrefKey.coreChoice(systemID))
    }

    static func setCoreChoice(_ coreID: String?, for systemID: String) {
        defaults.set(coreID, forKey: PrefKey.coreChoice(systemID))
    }

    /// User-changed core option values, persisted per core.
    static func coreOptions(for coreID: String) -> [String: String] {
        defaults.dictionary(forKey: PrefKey.coreOptions(coreID)) as? [String: String] ?? [:]
    }

    static func setCoreOption(_ value: String, key: String, for coreID: String) {
        var options = coreOptions(for: coreID)
        options[key] = value
        defaults.set(options, forKey: PrefKey.coreOptions(coreID))
    }

    static func resetCoreOptions(for coreID: String) {
        defaults.removeObject(forKey: PrefKey.coreOptions(coreID))
    }

    static func rendererChoice(for coreID: String) -> RendererChoice {
        RendererChoice(rawValue: defaults.string(forKey: PrefKey.rendererChoice(coreID)) ?? "") ?? .automatic
    }

    static func setRendererChoice(_ choice: RendererChoice, for coreID: String) {
        if choice == .automatic {
            defaults.removeObject(forKey: PrefKey.rendererChoice(coreID))
        } else {
            defaults.set(choice.rawValue, forKey: PrefKey.rendererChoice(coreID))
        }
    }

    // MARK: Backup

    /// Preferences a backup carries. Window state such as the last Settings
    /// tab stays behind; passwords live in the keychain and never get here.
    private static let backedUpKeys: Set<String> = [
        PrefKey.libraryFolders, PrefKey.scraperLanguage, PrefKey.scraperRegion, PrefKey.scraperUsername,
        PrefKey.autoScrape, PrefKey.videoFilter, PrefKey.integerScaling, PrefKey.volume, PrefKey.pauseInBackground,
        PrefKey.showFPS, PrefKey.gridSize, PrefKey.keyboardMapping, PrefKey.librarySort,
        PrefKey.autosaveOnQuit, PrefKey.periodicAutosave, PrefKey.resumeAutomatically,
        PrefKey.controllerMapping, PrefKey.turboButtons, PrefKey.hotkeys, PrefKey.portAssignments, PrefKey.stickDeadZone,
        PrefKey.collections, PrefKey.libraryViewMode, PrefKey.groupsVariants,
        PrefKey.fastForwardSpeed, PrefKey.rewindEnabled, PrefKey.rewindBufferSize, PrefKey.runAheadFrames,
        PrefKey.turboRate, PrefKey.rumble, PrefKey.bezel, PrefKey.achievementsEnabled, PrefKey.achievementsUsername,
        PrefKey.achievementsHardcore, PrefKey.achievementsShowsProgress, PrefKey.shaderFavorites,
    ]
    private static let backedUpPrefixes = ["coreChoice.", "coreOptions.", "hidGamepadMapping.", "inputProfile.", "rendererChoice.",
                                           "videoFilter."]

    private static func isBackedUp(_ key: String) -> Bool {
        backedUpKeys.contains(key) || backedUpPrefixes.contains { key.hasPrefix($0) }
    }

    /// The backed-up preferences as a property list.
    static func backupData() throws -> Data {
        let values = defaults.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "") ?? [:]
        let selected = values.filter { isBackedUp($0.key) }
        return try PropertyListSerialization.data(fromPropertyList: selected, format: .xml, options: 0)
    }

    /// Applies preferences from a backup and returns its library folders,
    /// which the caller adds to the current ones instead of replacing them.
    /// Keys a backup must not carry are ignored. A game's own settings move
    /// to the ID `gameIDs` restores it as; those of games the backup doesn't
    /// restore are dropped.
    @discardableResult
    static func restore(fromBackup data: Data, gameIDs: [UUID: UUID], into store: UserDefaults = .standard) -> [URL] {
        guard let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return [] }
        var folders: [URL] = []
        for (key, value) in values where isBackedUp(key) {
            if key == PrefKey.libraryFolders {
                folders = (value as? [String] ?? []).map { URL(filePath: $0, directoryHint: .isDirectory) }
            } else if key == PrefKey.collections {
                // Like the games, collections are added to the current ones.
                let current = store.stringArray(forKey: PrefKey.collections) ?? []
                store.set(current + (value as? [String] ?? []).filter { !current.contains($0) }, forKey: PrefKey.collections)
            } else if key.hasPrefix(PrefKey.gameVideoFilterPrefix) {
                guard let id = UUID(uuidString: String(key.dropFirst(PrefKey.gameVideoFilterPrefix.count))),
                      let restored = gameIDs[id] else { continue }
                store.set(value, forKey: PrefKey.gameVideoFilter(restored))
            } else {
                store.set(value, forKey: key)
            }
        }
        return folders
    }
}