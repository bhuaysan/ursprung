// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A game file found on disk.
nonisolated struct ScannedROM: Sendable, Hashable {
    let url: URL
    let systemID: String
    let title: String
    let fileName: String
    let fileSize: Int64
    let crc32: String?
    /// Content modification date, so a file replaced at the same path and
    /// size is still noticed.
    var modified: Date? = nil
}

/// The outcome of scanning library folders.
nonisolated struct LibraryScan: Sendable {
    var roms: [ScannedROM] = []
    /// Files and directories that could not be read. Games inside them may
    /// still exist, so the library keeps them.
    var unreadable: [URL] = []

    /// Whether `path` lies in a part of the folders that could not be read.
    func isUnreadable(_ path: String) -> Bool {
        unreadable.contains { url in
            let unreadablePath = url.standardizedFileURL.path(percentEncoded: false)
            return path == unreadablePath || LibraryPaths.isInside(path, folder: unreadablePath)
        }
    }
}

/// Walks library folders and identifies games. Pure and synchronous — call it
/// from a background task.
nonisolated enum LibraryScanner {
    /// Extensions that are never games on their own.
    private static let ignoredExtensions: Set<String> = [
        "txt", "nfo", "diz", "jpg", "jpeg", "png", "gif", "bmp", "pdf", "xml", "dat", "srm", "sav", "state",
        "sub", "sbi", "mds", "db", "ini", "cfg", "json", "html", "md", "doc", "ips", "bps", "ups", "ppf", "log",
    ]

    /// Arcade BIOS / device sets that live next to games but are not games.
    private static let arcadeBIOSSets: Set<String> = [
        "neogeo.zip", "pgm.zip", "skns.zip", "decocass.zip", "isgsm.zip", "nmk004.zip", "ym2608.zip",
        "qsound.zip", "cchip.zip", "bubsys.zip", "namcoc69.zip", "namcoc70.zip", "namcoc75.zip", "coleco.zip",
        "hiscore.dat", "stvbios.zip", "naomi.zip", "awbios.zip", "cpzn1.zip", "cpzn2.zip", "taitofx1.zip",
    ]

    private static let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]

    /// Scans all folders as one library: a file that several (nested) folders
    /// contain is listed once, and a playlist in one folder hides the discs it
    /// references in another.
    static func scan(folders: [URL]) -> LibraryScan {
        var scan = LibraryScan()
        // Outer folders first: a file found through them sees more parent
        // folders that may name its system.
        let roots = folders.map(\.standardizedFileURL).sorted { $0.pathComponents.count < $1.pathComponents.count }
        var files: [(url: URL, root: URL)] = []
        var seen = Set<String>()
        for root in roots {
            for url in enumerateFiles(in: root, unreadable: &scan.unreadable) {
                guard seen.insert(url.path(percentEncoded: false)).inserted else { continue }
                files.append((url, root))
            }
        }

        let referenced = referencedPaths(in: files.map(\.url))
        for (url, root) in files where !referenced.contains(normalized(url)) {
            let folderSystem = system(forDirectory: url.deletingLastPathComponent(), root: root)
            if let rom = identify(url, folderSystem: folderSystem) { scan.roms.append(rom) }
        }
        scan.roms.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return scan
    }

    static func scan(folder root: URL) -> [ScannedROM] {
        scan(folders: [root]).roms
    }

    /// The regular files below `root`. Directories and files that cannot be
    /// read are added to `unreadable` instead of being skipped silently.
    private static func enumerateFiles(in root: URL, unreadable: inout [URL]) -> [URL] {
        var failures: [URL] = []
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                        options: [.skipsHiddenFiles, .skipsPackageDescendants]) { url, _ in
            failures.append(url)
            return true
        }
        guard let enumerator else {
            unreadable.append(root)
            return []
        }
        var files: [URL] = []
        for case let url as URL in enumerator {
            do {
                if try url.resourceValues(forKeys: Set(keys)).isRegularFile == true { files.append(url.standardizedFileURL) }
            } catch {
                failures.append(url)
            }
        }
        unreadable += failures.map(\.standardizedFileURL)
        return files
    }

    private static func identify(_ url: URL, folderSystem: GameSystem?) -> ScannedROM? {
        let name = url.lastPathComponent
        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty, !ignoredExtensions.contains(ext) else { return nil }
        guard let system = detectSystem(for: url, folderSystem: folderSystem) else { return nil }
        if system.archivesAreNative, arcadeBIOSSets.contains(name.lowercased()) { return nil }

        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        var crc: String?
        if ext == "zip", !system.archivesAreNative, let entry = primaryEntry(inZip: url, system: system) {
            crc = Checksum.hex(entry.crc32)
        }
        return ScannedROM(url: url, systemID: system.id, title: TitleFormatter.title(fromFileName: name),
                          fileName: name, fileSize: Int64(values?.fileSize ?? 0), crc32: crc,
                          modified: values?.contentModificationDate)
    }

    // MARK: - System detection

    static func detectSystem(for url: URL, folderSystem: GameSystem?) -> GameSystem? {
        let ext = url.pathExtension.lowercased()
        let candidates = SystemCatalog.candidates(forExtension: ext)
        let isAmbiguous = SystemCatalog.ambiguousExtensions.contains(ext)

        if let folderSystem {
            if candidates.contains(folderSystem) || isAmbiguous { return folderSystem }
        }
        if !isAmbiguous, candidates.count >= 1 {
            return candidates[0]
        }
        if ext == "zip" {
            guard let archive = try? ZipArchive(url: url) else { return nil }
            for entry in archive.files.sorted(by: { $0.uncompressedSize > $1.uncompressedSize }) {
                let inner = SystemCatalog.candidates(forExtension: entry.fileExtension)
                if !SystemCatalog.ambiguousExtensions.contains(entry.fileExtension), let system = inner.first {
                    return system
                }
            }
        }
        return nil
    }

    /// The nearest folder (from the file up to the library root) whose name
    /// identifies a system.
    static func system(forDirectory directory: URL, root: URL) -> GameSystem? {
        var current = directory.standardizedFileURL
        let rootPath = root.standardizedFileURL.path
        while current.path.hasPrefix(rootPath) {
            if let system = SystemCatalog.system(forFolderName: current.lastPathComponent) { return system }
            if current.path == rootPath { break }
            current = current.deletingLastPathComponent()
        }
        return nil
    }

    /// For zipped cartridge games: the entry the core will actually run.
    static func primaryEntry(inZip url: URL, system: GameSystem) -> ZipArchive.Entry? {
        guard let archive = try? ZipArchive(url: url) else { return nil }
        let files = archive.files
        return files.first { system.extensions.contains($0.fileExtension) }
            ?? files.max { $0.uncompressedSize < $1.uncompressedSize }
    }

    // MARK: - Multi-file discs

    /// Normalised paths of files referenced by .cue/.gdi/.m3u/.ccd files, so
    /// individual tracks and the discs of a playlist are not listed as
    /// separate games. References are resolved relative to the file that
    /// makes them, so a playlist can point into sub folders.
    static func referencedPaths(in files: [URL]) -> Set<String> {
        var referenced = Set<String>()
        for url in files {
            let directory = url.deletingLastPathComponent()
            let references: [String]
            switch url.pathExtension.lowercased() {
            case "cue": references = CueSheet.referencedFiles(in: url)
            case "gdi": references = parseGDI(url)
            case "m3u": references = parseM3U(url)
            case "ccd":
                let base = url.deletingPathExtension().lastPathComponent
                references = ["\(base).img", "\(base).sub"]
            default: references = []
            }
            for reference in references {
                let path = reference.replacingOccurrences(of: "\\", with: "/")
                let target = path.hasPrefix("/") ? URL(filePath: path) : directory.appending(path: path)
                referenced.insert(normalized(target))
            }
        }
        return referenced
    }

    /// A path for comparing references: standardised and lower-cased, as
    /// macOS volumes usually ignore case.
    static func normalized(_ url: URL) -> String {
        url.standardizedFileURL.path(percentEncoded: false).lowercased()
    }

    static func parseM3U(_ url: URL) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    static func parseGDI(_ url: URL) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var names: [String] = []
        for line in text.split(whereSeparator: \.isNewline).dropFirst() {
            if let start = line.firstIndex(of: "\""), let end = line[line.index(after: start)...].firstIndex(of: "\"") {
                names.append(String(line[line.index(after: start)..<end]))
            } else {
                let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                if parts.count >= 5 { names.append(String(parts[4])) }
            }
        }
        return names
    }
}

nonisolated enum CueSheet {
    /// File names referenced by `FILE "…" BINARY` lines.
    static func referencedFiles(in url: URL) -> [String] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        var files: [String] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.uppercased().hasPrefix("FILE ") else { continue }
            let rest = line.dropFirst(5)
            if rest.hasPrefix("\""), let end = rest.dropFirst().firstIndex(of: "\"") {
                files.append(String(rest[rest.index(after: rest.startIndex)..<end]))
            } else if let name = rest.split(separator: " ").first {
                files.append(String(name))
            }
        }
        return files.map { ($0 as NSString).lastPathComponent }
    }
}

nonisolated enum TitleFormatter {
    private static let articles = ["The", "A", "An", "Der", "Die", "Das", "Le", "La", "Les", "El", "Il"]

    /// "Legend of Zelda, The - A Link to the Past (U) [!].smc"
    ///   → "The Legend of Zelda - A Link to the Past"
    static func title(fromFileName fileName: String) -> String {
        var name = (fileName as NSString).deletingPathExtension
        name = name.replacingOccurrences(of: "_", with: " ")
        name = name.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression)
        name = name.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)

        // Move trailing articles to the front: "Legend of Zelda, The - …"
        for article in articles {
            let pattern = "^(.+?), \(article)( - .+|: .+)?$"
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
               let head = Range(match.range(at: 1), in: name) {
                let tail = Range(match.range(at: 2), in: name).map { String(name[$0]) } ?? ""
                name = "\(article) \(name[head])\(tail)"
                break
            }
        }
        return name.isEmpty ? fileName : name
    }
}
