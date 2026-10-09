// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// An emulator that can run one or more systems: usually a libretro core,
/// downloaded from the libretro buildbot on first use (see `CoreManager`),
/// or a standalone emulator that runs as its own process.
nonisolated struct CoreDefinition: Sendable, Hashable, Identifiable {
    /// Buildbot base name, e.g. `snes9x` for `snes9x_libretro.dylib`; for a
    /// standalone emulator its `StandaloneEmulator.id`.
    let id: String
    let name: String
    /// Frontend defaults for core options (user choices override these).
    var optionDefaults: [String: String] = [:]
    /// The graphics API Ursprung asks the core for unless the user picks
    /// another one (Settings › Cores).
    var renderer: HardwareRenderer = .opengl
    /// Option defaults for when the core renders with Vulkan, on top of
    /// `optionDefaults`; nil for cores without a Vulkan renderer.
    var vulkanOptionDefaults: [String: String]? = nil
    /// Optional asset archive extracted into the system directory
    /// (e.g. PPSSPP fonts & shaders).
    var systemAssets: URL? = nil
    var experimental: Bool = false
    var backend: CoreBackend = .libretro

    /// The libretro dylib; only meaningful for `.libretro`.
    var fileName: String { "\(id)_libretro.dylib" }

    var standalone: StandaloneEmulator? {
        if case .standalone(let emulator) = backend { emulator } else { nil }
    }

    var isLibretro: Bool { standalone == nil }

    /// Whether the core can render with Vulkan, so the user can choose.
    var supportsVulkan: Bool { vulkanOptionDefaults != nil }

    /// The frontend defaults for the core rendering with `renderer`.
    func optionDefaults(for renderer: HardwareRenderer) -> [String: String] {
        guard renderer == .vulkan, let vulkanOptionDefaults else { return optionDefaults }
        return optionDefaults.merging(vulkanOptionDefaults) { $1 }
    }

    /// The renderer the user's `choice` asks for, whether or not this Mac
    /// can provide it.
    func wantedRenderer(for choice: RendererChoice) -> HardwareRenderer {
        guard supportsVulkan else { return .opengl }
        return switch choice {
        case .automatic: renderer
        case .vulkan: .vulkan
        case .opengl: .opengl
        }
    }

    /// The renderer a game of this core starts with: the wanted one, or
    /// OpenGL where there is no Vulkan.
    func renderer(for choice: RendererChoice, vulkanAvailable: Bool) -> HardwareRenderer {
        let wanted = wantedRenderer(for: choice)
        return wanted == .vulkan && !vulkanAvailable ? .opengl : wanted
    }
}

/// A graphics API Ursprung gives cores that render on the GPU. Vulkan runs
/// through MoltenVK (docs/VULKAN_PLAN.md).
nonisolated enum HardwareRenderer: String, Sendable, Hashable, CaseIterable {
    case opengl
    case vulkan

    /// Product names, the same in every language.
    var name: String {
        switch self {
        case .opengl: "OpenGL"
        case .vulkan: "Vulkan"
        }
    }

    var graphicsAPI: GraphicsAPI {
        switch self {
        case .opengl: .openGL
        case .vulkan: .vulkan
        }
    }
}

/// How Ursprung runs a core.
nonisolated enum CoreBackend: Sendable, Hashable {
    /// Loaded in-process and presented in the player window.
    case libretro
    /// A separate application Ursprung downloads, configures and launches.
    case standalone(StandaloneEmulator)
}

/// An emulator that runs as its own process with its own window (see
/// docs/STANDALONE_PLAN.md). Ursprung pins one tested release.
nonisolated struct StandaloneEmulator: Sendable, Hashable, Identifiable {
    nonisolated struct Release: Sendable, Hashable {
        /// Release tag on GitHub, e.g. `nightly-20261006`.
        let tag: String
        let assetName: String
        /// SHA-256 of the asset, lower-case hex.
        let sha256: String
        /// Source commit; also the installation folder name.
        let commit: String
    }

    let id: String
    let name: String
    /// GitHub `owner/repository` the release is downloaded from.
    let repository: String
    let release: Release
    /// Developer ID team the app must be signed by.
    let teamIdentifier: String
    /// The executable inside the installed `.app`, relative to the bundle.
    let executable: String
    /// Save state format version of the pinned release; states with another
    /// major version cannot be loaded. Installed versions record theirs
    /// (`EmulatorManager.saveStateVersion(of:)`): check against that one.
    let saveStateVersion: UInt32

    var downloadURL: URL {
        URL(string: "https://github.com/\(repository)/releases/download/\(release.tag)/\(release.assetName)")!
    }

    var sourceURL: URL { URL(string: "https://github.com/\(repository)")! }
}

/// A folder in the system directory that must hold at least one BIOS dump
/// of a kind, under any file name — for systems whose dumps exist in many
/// versions (PlayStation 2).
nonisolated struct BIOSFolder: Sendable, Hashable {
    nonisolated enum Kind: Sendable, Hashable {
        case playStation2
    }

    /// Path relative to the system directory.
    let path: String
    let kind: Kind
    /// Cores that cannot start without a dump.
    let requiredBy: Set<String>

    func isRequired(forCore coreID: String) -> Bool {
        requiredBy.contains(coreID)
    }
}

/// A BIOS / firmware file expected in the libretro system directory.
nonisolated struct BIOSFile: Sendable, Hashable, Identifiable {
    /// Path relative to the system directory (may contain a sub folder).
    let fileName: String
    let md5: String?
    let required: Bool
    var note: String? = nil
    /// Required files that share a group are alternatives, e.g. region
    /// variants: one of them suffices. Required files without a group are
    /// all needed.
    var group: String? = nil
    /// Cores that need the file although `required` is false, e.g. the
    /// PlayStation cores without a built-in BIOS.
    var requiredBy: Set<String> = []

    var id: String { fileName }

    /// Whether `coreID` cannot start without this file (or its alternatives).
    func isRequired(forCore coreID: String) -> Bool {
        required || requiredBy.contains(coreID)
    }
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
    var biosFolder: BIOSFolder? = nil
    /// True for systems whose games ship as .zip sets (arcade) — archives are
    /// passed to the core as-is instead of being extracted.
    var archivesAreNative: Bool = false
    /// Accent used for generated placeholder artwork.
    var accent: UInt32 = 0x6E6E73
    /// Aspect ratio (width / height) of typical box art, used for grid cards.
    var boxAspect: Double = 0.72

    var defaultCore: CoreDefinition { cores[0] }

    /// Its folder in the folder structure, e.g. “Super Nintendo”.
    var folderName: String { SystemCatalog.folderNames[id] ?? shortName }

    /// Whether ROM patches (IPS, UPS, BPS) can be applied to its games.
    var supportsPatches: Bool { SystemCatalog.supportsPatches(self) }

    func core(withID id: String?) -> CoreDefinition {
        cores.first { $0.id == id } ?? defaultCore
    }

    static func == (lhs: GameSystem, rhs: GameSystem) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
