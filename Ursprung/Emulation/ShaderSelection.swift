// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A RetroArch slang preset (`.slangp`), by its path below one of the
/// shader folders.
nonisolated struct ShaderPresetRef: Hashable, Sendable {
    enum Source: String, Sendable {
        /// The downloaded libretro pack (`AppPaths.shaderLibrary`).
        case library
        /// The user's own presets (`AppPaths.userShaders`).
        case user
        /// A preset open in the shader editor (`AppPaths.shaderDrafts`); never stored as a choice.
        case draft
    }

    let source: Source
    /// Relative to the source's folder, with `/` separators.
    let path: String

    /// Nil when `path` is empty or leaves its folder.
    init?(source: Source, path: String) {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.hasPrefix("/"), !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
        else { return nil }
        self.source = source
        self.path = path
    }

    /// The preset's file name without extension, e.g. "crt-royale".
    var name: String { ((path as NSString).lastPathComponent as NSString).deletingPathExtension }

    func url(library: URL = AppPaths.shaderLibrary, user: URL = AppPaths.userShaders,
             drafts: URL = AppPaths.shaderDrafts) -> URL {
        let folder = switch source {
        case .library: library
        case .user: user
        case .draft: drafts
        }
        return folder.appending(path: path, directoryHint: .notDirectory)
    }
}

/// How the game picture is drawn: one of the built-in filters, or a
/// RetroArch preset rendered by librashader.
///
/// Stored as a string in the `videoFilter` keys: built-in filters keep the
/// `VideoFilter` raw values, presets are `preset:<source>/<path>`.
nonisolated enum ShaderSelection: Hashable, Sendable, RawRepresentable {
    case builtin(VideoFilter)
    case preset(ShaderPresetRef)

    private static let presetPrefix = "preset:"

    init?(rawValue: String) {
        if let filter = VideoFilter(rawValue: rawValue) {
            self = .builtin(filter)
            return
        }
        guard rawValue.hasPrefix(Self.presetPrefix) else { return nil }
        let reference = rawValue.dropFirst(Self.presetPrefix.count)
        guard let slash = reference.firstIndex(of: "/"),
              let source = ShaderPresetRef.Source(rawValue: String(reference[..<slash])), source != .draft,
              let preset = ShaderPresetRef(source: source, path: String(reference[reference.index(after: slash)...]))
        else { return nil }
        self = .preset(preset)
    }

    var rawValue: String {
        switch self {
        case .builtin(let filter): filter.rawValue
        case .preset(let preset): "\(Self.presetPrefix)\(preset.source.rawValue)/\(preset.path)"
        }
    }

    /// For menus: the filter's title or the preset's name.
    var title: String {
        switch self {
        case .builtin(let filter): filter.title
        case .preset(let preset): preset.name
        }
    }

    /// Whether a filter setting names a preset of the downloaded pack.
    static func usesLibraryPresets(defaults: UserDefaults = .standard) -> Bool {
        defaults.dictionaryRepresentation().contains { key, value in
            guard key == PrefKey.videoFilter || key.hasPrefix(PrefKey.systemVideoFilter("")),
                  case .preset(let preset)? = (value as? String).flatMap(ShaderSelection.init(rawValue:)) else { return false }
            return preset.source == .library
        }
    }

    /// What a game uses: its own choice, its system's, or the one for all systems.
    static func current(for systemID: String?, gameID: UUID? = nil, defaults: UserDefaults = .standard) -> ShaderSelection {
        let scope = ShaderScope.deciding(gameID: gameID, systemID: systemID, defaults: defaults)
        return scope.selection(defaults: defaults) ?? .builtin(.sharp)
    }
}

/// A level a filter choice is stored at. A game's picture comes from the
/// most specific level that has a readable choice.
nonisolated enum ShaderScope: Hashable, Sendable {
    case game(UUID)
    case system(String)
    case all

    var key: String {
        switch self {
        case .game(let id): PrefKey.gameVideoFilter(id)
        case .system(let id): PrefKey.systemVideoFilter(id)
        case .all: PrefKey.videoFilter
        }
    }

    /// The choice stored at this level; nil when it inherits (or its value is unreadable).
    func selection(defaults: UserDefaults = .standard) -> ShaderSelection? {
        defaults.string(forKey: key).flatMap(ShaderSelection.init(rawValue:))
    }

    /// Stores `selection` at this level; nil inherits from the next one
    /// (for all systems: the default filter).
    func setSelection(_ selection: ShaderSelection?, defaults: UserDefaults = .standard) {
        if let selection {
            defaults.set(selection.rawValue, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    /// Game 2, system 1, all systems 0: a more specific level wins.
    var specificity: Int {
        switch self {
        case .game: 2
        case .system: 1
        case .all: 0
        }
    }

    /// The level whose choice a game uses.
    static func deciding(gameID: UUID?, systemID: String?, defaults: UserDefaults = .standard) -> ShaderScope {
        if let gameID, ShaderScope.game(gameID).selection(defaults: defaults) != nil { return .game(gameID) }
        if let systemID, ShaderScope.system(systemID).selection(defaults: defaults) != nil { return .system(systemID) }
        return .all
    }
}
