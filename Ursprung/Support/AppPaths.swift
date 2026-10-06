// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// File system locations used by Ursprung. Everything lives below
/// `~/Library/Application Support/Ursprung` so users can back it up easily.
nonisolated enum AppPaths {
    static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "Ursprung", directoryHint: .isDirectory)
    }()

    /// Downloaded libretro cores (`*_libretro.dylib`).
    static var cores: URL { directory("Cores") }
    /// BIOS files and core system assets (libretro "system directory").
    static var system: URL { directory("System") }
    /// Battery saves (.srm) and core save directories.
    static var saves: URL { directory("Saves") }
    /// Save states and their thumbnails.
    static var states: URL { directory("States") }
    /// Artwork downloaded from ScreenScraper.
    static var media: URL { directory("Media") }
    /// Screenshots, manuals, ROM patches and cheats, one folder per game (`GameExtras`).
    static var extras: URL { directory("Extras") }
    /// Images framing the game picture, one per system (`<system id>.png`).
    static var bezels: URL { directory("Bezels") }
    /// RetroArch slang shaders: the downloaded pack and the user's own.
    static var shaders: URL { directory("Shaders") }
    /// The libretro `slang-shaders` pack, replaced as a whole on update.
    static var shaderLibrary: URL { shaders.appending(path: "slang-shaders", directoryHint: .isDirectory) }
    /// Presets and shaders the user saved or imported (backed up).
    static var userShaders: URL { shaders.appending(path: "User", directoryHint: .isDirectory) }
    /// The shader editor's working copies, one folder per draft (not backed up).
    static var shaderDrafts: URL { shaders.appending(path: "Drafts", directoryHint: .isDirectory) }
    /// System logos and console photos downloaded from ScreenScraper.
    static var systemMedia: URL {
        let url = media.appending(path: "Systems", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    /// Temporary extraction of zipped ROMs.
    static var extracted: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let url = caches.appending(path: "Ursprung/Extracted", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func directory(_ name: String) -> URL {
        let url = root.appending(path: name, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
