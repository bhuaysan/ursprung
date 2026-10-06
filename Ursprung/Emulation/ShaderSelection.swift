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

    func url(library: URL = AppPaths.shaderLibrary, user: URL = AppPaths.userShaders) -> URL {
        (source == .library ? library : user).appending(path: path, directoryHint: .notDirectory)
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
              let source = ShaderPresetRef.Source(rawValue: String(reference[..<slash])),
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

    /// What a system uses: its own choice, or the one for all systems.
    static func current(for systemID: String?, defaults: UserDefaults = .standard) -> ShaderSelection {
        if let systemID, let raw = defaults.string(forKey: PrefKey.systemVideoFilter(systemID)),
           let selection = ShaderSelection(rawValue: raw) {
            return selection
        }
        return defaults.string(forKey: PrefKey.videoFilter).flatMap(ShaderSelection.init(rawValue:)) ?? .builtin(.sharp)
    }
}
