// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A libretro core that can run one or more systems. Cores are downloaded
/// from the libretro buildbot on first use (see `CoreManager`).
nonisolated struct CoreDefinition: Sendable, Hashable, Identifiable {
    /// Buildbot base name, e.g. `snes9x` for `snes9x_libretro.dylib`.
    let id: String
    let name: String
    /// Frontend defaults for core options (user choices override these).
    var optionDefaults: [String: String] = [:]
    /// Optional asset archive extracted into the system directory
    /// (e.g. PPSSPP fonts & shaders).
    var systemAssets: URL? = nil
    var experimental: Bool = false

    var fileName: String { "\(id)_libretro.dylib" }
}

/// A BIOS / firmware file expected in the libretro system directory.
nonisolated struct BIOSFile: Sendable, Hashable, Identifiable {
    /// Path relative to the system directory (may contain a sub folder).
    let fileName: String
    let md5: String?
    let required: Bool
    var note: String? = nil

    var id: String { fileName }
}

nonisolated struct GameSystem: Sendable, Hashable, Identifiable {
    enum Kind: String, Sendable {
        case console, handheld, arcade, computer
    }

    /// Stable identifier stored in the library database.
    let id: String
    let name: String
    let shortName: String
    let manufacturer: String
    let year: Int
    let kind: Kind
    /// ScreenScraper `systemeid`.
    let screenScraperID: Int
    /// Lower-case file extensions without dot.
    let extensions: Set<String>
    /// Normalised folder names that identify this system (for ambiguous
    /// extensions such as .bin/.iso/.cue/.zip).
    let folderAliases: Set<String>
    /// Available cores, the first one is the default.
    let cores: [CoreDefinition]
    var bios: [BIOSFile] = []
    /// True for systems whose games ship as .zip sets (arcade) — archives are
    /// passed to the core as-is instead of being extracted.
    var archivesAreNative: Bool = false
    /// Accent used for generated placeholder artwork.
    var accent: UInt32 = 0x6E6E73
    /// Aspect ratio (width / height) of typical box art, used for grid cards.
    var boxAspect: Double = 0.72

    var defaultCore: CoreDefinition { cores[0] }

    func core(withID id: String?) -> CoreDefinition {
        cores.first { $0.id == id } ?? defaultCore
    }

    static func == (lhs: GameSystem, rhs: GameSystem) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
