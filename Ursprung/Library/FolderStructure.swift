// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Folders for games and BIOS files that Ursprung creates when the user asks
/// for them (first launch, File menu), so games only need to be copied in:
///
///     Ursprung/
///     ├── Read Me.txt
///     ├── ROMs/        a library folder, one sub folder per system
///     └── BIOS/        files put here are imported (`BIOSManager.watch`)
///
/// The scanner recognises the system folders by name (`GameSystem.folderName`).
/// BIOS lies next to ROMs, not inside, so its files never show up as
/// unrecognized games. Existing folders and files are never replaced.
nonisolated enum FolderStructure {
    static let rootName = "Ursprung"
    static let romsName = "ROMs"
    static let biosName = "BIOS"

    /// `~/Ursprung`: not in Documents, which iCloud may sync.
    static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: rootName, directoryHint: .isDirectory)
    }

    static func roms(in root: URL) -> URL { root.appending(path: romsName, directoryHint: .isDirectory) }
    static func bios(in root: URL) -> URL { root.appending(path: biosName, directoryHint: .isDirectory) }

    static var readMeName: String { String(localized: "Read Me.txt") }

    /// Creates what is missing below `root`: the ROMs and BIOS folders, the
    /// read me and a folder for every system in `systems`. Returns the IDs
    /// of the systems the structure now has folders for.
    @discardableResult
    static func create(at root: URL, systems: [GameSystem] = SystemCatalog.all) throws -> Set<String> {
        let fm = FileManager.default
        try fm.createDirectory(at: bios(in: root), withIntermediateDirectories: true)
        try createSystemFolders(systems, in: roms(in: root))
        let readMe = root.appending(path: readMeName)
        if !fm.fileExists(atPath: readMe.path(percentEncoded: false)) {
            try Data(readMeText.utf8).write(to: readMe, options: .withoutOverwriting)
        }
        return Set(systems.map(\.id))
    }

    /// Gives systems that `laidOut` does not list (new in this version) their
    /// folder. Folders the user deleted stay deleted, and nothing happens
    /// while the structure is gone or on a drive that is not connected.
    /// Returns `laidOut` with the systems added.
    static func addNewSystems(at root: URL, laidOut: Set<String>,
                              systems: [GameSystem] = SystemCatalog.all) throws -> Set<String> {
        let roms = roms(in: root)
        let new = systems.filter { !laidOut.contains($0.id) }
        guard !new.isEmpty, FileManager.default.fileExists(atPath: roms.path(percentEncoded: false)) else { return laidOut }
        try createSystemFolders(new, in: roms)
        return laidOut.union(new.map(\.id))
    }

    private static func createSystemFolders(_ systems: [GameSystem], in roms: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: roms, withIntermediateDirectories: true)
        // A folder the user renamed to another name of the same system
        // (“SNES”) still counts.
        let present = Set(((try? fm.contentsOfDirectory(atPath: roms.path(percentEncoded: false))) ?? [])
            .compactMap { SystemCatalog.system(forFolderName: $0)?.id })
        for system in systems where !present.contains(system.id) {
            try fm.createDirectory(at: roms.appending(path: system.folderName, directoryHint: .isDirectory),
                                   withIntermediateDirectories: true)
        }
    }

    private static var readMeText: String {
        String(localized: """
        Ursprung — game folders

        ROMs
        Put each game into the folder of its system, for example Super Nintendo games into “ROMs/Super Nintendo”. \
        Ursprung adds them to the library as soon as they arrive. Sub folders are fine, for example one per disc game. \
        Cartridge games may be zipped; arcade games stay zipped as they are.

        BIOS
        Put BIOS files here under any name. Ursprung recognizes them and copies them to where the emulators expect \
        them. Settings › BIOS shows which ones are still missing.

        Folders you don't need can be deleted. Only use games and BIOS files from hardware you own.
        """)
    }
}
