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
    static func coreChoice(_ systemID: String) -> String { "coreChoice.\(systemID)" }
    static func coreOptions(_ coreID: String) -> String { "coreOptions.\(coreID)" }
    static func hidGamepadMapping(_ deviceKey: String) -> String { "hidGamepadMapping.\(deviceKey)" }
}

/// Display filter applied when scaling the emulator image.
nonisolated enum VideoFilter: String, CaseIterable, Identifiable, Sendable {
    case sharp, nearest, smooth, scanlines

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sharp: String(localized: "Sharp")
        case .nearest: String(localized: "Pixel Perfect")
        case .smooth: String(localized: "Smooth")
        case .scanlines: String(localized: "Scanlines")
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
    static var videoFilter: VideoFilter { VideoFilter(rawValue: defaults.string(forKey: PrefKey.videoFilter) ?? "") ?? .sharp }
    static var integerScaling: Bool { defaults.bool(forKey: PrefKey.integerScaling) }
    static var volume: Double { defaults.double(forKey: PrefKey.volume) }
    static var pauseInBackground: Bool { defaults.bool(forKey: PrefKey.pauseInBackground) }

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

    // MARK: Backup

    /// Preferences a backup carries. Window state such as the last Settings
    /// tab stays behind; passwords live in the keychain and never get here.
    private static let backedUpKeys: Set<String> = [
        PrefKey.libraryFolders, PrefKey.scraperLanguage, PrefKey.scraperRegion, PrefKey.scraperUsername,
        PrefKey.autoScrape, PrefKey.videoFilter, PrefKey.integerScaling, PrefKey.volume, PrefKey.pauseInBackground,
        PrefKey.showFPS, PrefKey.gridSize, PrefKey.keyboardMapping, PrefKey.librarySort,
    ]
    private static let backedUpPrefixes = ["coreChoice.", "coreOptions.", "hidGamepadMapping."]

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
    /// Keys a backup must not carry are ignored.
    @discardableResult
    static func restore(fromBackup data: Data) -> [URL] {
        guard let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return [] }
        var folders: [URL] = []
        for (key, value) in values where isBackedUp(key) {
            if key == PrefKey.libraryFolders {
                folders = (value as? [String] ?? []).map { URL(filePath: $0, directoryHint: .isDirectory) }
            } else {
                defaults.set(value, forKey: key)
            }
        }
        return folders
    }
}