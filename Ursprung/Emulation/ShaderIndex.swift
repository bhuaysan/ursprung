// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Synchronization

/// A preset of the shader library, as the browser lists it.
nonisolated struct ShaderPresetInfo: Hashable, Sendable, Identifiable {
    let ref: ShaderPresetRef
    /// Nil until the preset was read.
    var passes: Int?
    var parameters: Int?
    /// Why librashader can't read the preset (a missing file, a syntax error).
    var problem: String?

    var id: ShaderPresetRef { ref }
    var name: String { ref.name }

    /// The top folder of a pack preset ("crt", "handheld", …); empty for
    /// presets at the top and for the user's own presets.
    var category: String {
        guard ref.source == .library else { return "" }
        let components = ref.path.split(separator: "/")
        return components.count > 1 ? String(components[0]) : ""
    }

    /// The folders between the category and the file, e.g. "Mega_Bezel › Presets".
    var folder: String {
        var components = ref.path.split(separator: "/").dropLast()
        if ref.source == .library, !components.isEmpty { components = components.dropFirst() }
        return components.joined(separator: " › ")
    }

    func matches(_ search: String) -> Bool {
        search.isEmpty || name.localizedStandardContains(search) || folder.localizedStandardContains(search)
            || ShaderIndex.title(ofCategory: category).localizedStandardContains(search)
    }
}

/// Finds the presets in the shader folders and remembers what librashader
/// said about each in `Shaders/index.json`, so only new or changed presets
/// are read again.
nonisolated enum ShaderIndex {
    /// What is known about a preset file, keyed by its selection raw value.
    struct CacheEntry: Codable, Equatable, Sendable {
        var modified: Double
        var passes: Int?
        var parameters: Int?
        var problem: String?
    }

    struct Cache: Codable, Sendable {
        static let currentVersion = 1
        var version = Cache.currentVersion
        var entries: [String: CacheEntry] = [:]
    }

    /// A preset file found on disk.
    struct Found: Sendable {
        let ref: ShaderPresetRef
        let url: URL
        let modified: Double
    }

    struct Scan: Sendable {
        var presets: [ShaderPresetInfo]
        /// Presets that are new or changed since the cache was written.
        var pending: [Found]
        var found: [Found]
        /// Disk space of the downloaded pack; nil when it isn't there.
        var packSize: Int64?
    }

    /// Lists the presets below `library` and `user`, with what `cache` knows.
    static func scan(library: URL, user: URL, cache: Cache) -> Scan {
        var packSize: Int64?
        var found = files(below: library, source: .library, size: &packSize)
        var ignored: Int64?
        found += files(below: user, source: .user, size: &ignored)

        var presets: [ShaderPresetInfo] = []
        var pending: [Found] = []
        for file in found {
            var info = ShaderPresetInfo(ref: file.ref)
            if let entry = cache.entries[ShaderSelection.preset(file.ref).rawValue], entry.modified == file.modified {
                info.passes = entry.passes
                info.parameters = entry.parameters
                info.problem = entry.problem
            } else {
                pending.append(file)
            }
            presets.append(info)
        }
        presets.sort(by: order)
        return Scan(presets: presets, pending: pending, found: found, packSize: packSize)
    }

    /// Reads `files` with librashader (parse only, no compile), several at
    /// once. Paths below `folders` are shortened in problem messages.
    static func summarize(_ files: [Found], folders: [URL] = []) -> [ShaderPresetRef: CacheEntry] {
        let summaries = Mutex<[ShaderPresetRef: CacheEntry]>([:])
        let prefixes = folders.flatMap { folder in
            let path = folder.path(percentEncoded: false)
            // librashader reports real paths: "/private/var/…" for "/var/…".
            let real = realpath(path, nil).map { pointer in
                defer { free(pointer) }
                return String(cString: pointer)
            }
            return [path, real].compactMap { $0.map { $0.hasSuffix("/") ? $0 : $0 + "/" } }
        }
        .sorted { $0.count > $1.count }
        DispatchQueue.concurrentPerform(iterations: files.count) { index in
            var entry = summary(of: files[index])
            entry.problem = entry.problem.map { problem in prefixes.reduce(problem) { $0.replacing($1, with: "") } }
            summaries.withLock { $0[files[index].ref] = entry }
        }
        return summaries.withLock { $0 }
    }

    static func summary(of file: Found) -> CacheEntry {
        var entry = CacheEntry(modified: file.modified, passes: SlangPresetFile.passCount(of: file.url))
        do {
            entry.parameters = try ShaderPreset.parametersOfPreset(atPath: file.url.path(percentEncoded: false)).count
        } catch {
            // librashader's messages can be long debug dumps; the first line says enough.
            let message = error.localizedDescription.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            entry.problem = String(message.prefix(300))
        }
        return entry
    }

    /// The cache for `found`, with `summaries` added; presets that are gone are dropped.
    static func updated(_ cache: Cache, found: [Found], summaries: [ShaderPresetRef: CacheEntry]) -> Cache {
        var entries: [String: CacheEntry] = [:]
        for file in found {
            let key = ShaderSelection.preset(file.ref).rawValue
            if let entry = summaries[file.ref] ?? cache.entries[key] { entries[key] = entry }
        }
        return Cache(entries: entries)
    }

    static func loadCache(from url: URL) -> Cache {
        guard let data = try? Data(contentsOf: url), let cache = try? JSONDecoder().decode(Cache.self, from: data),
              cache.version == Cache.currentVersion else { return Cache() }
        return cache
    }

    static func save(_ cache: Cache, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(cache).write(to: url, options: .atomic)
    }

    // MARK: Order and titles

    /// The user's presets first, then by category ("Other" last), folder and name.
    static func order(_ lhs: ShaderPresetInfo, _ rhs: ShaderPresetInfo) -> Bool {
        if lhs.ref.source != rhs.ref.source { return lhs.ref.source == .user }
        if lhs.category.isEmpty != rhs.category.isEmpty { return rhs.category.isEmpty }
        for (left, right) in [(lhs.category, rhs.category), (lhs.folder, rhs.folder), (lhs.name, rhs.name)] where left != right {
            return left.localizedStandardCompare(right) == .orderedAscending
        }
        return false
    }

    private static let acronyms: Set<String> = ["3d", "aa", "bfi", "crt", "fxaa", "gpu", "hdr", "lcd", "nes", "ntsc", "pal", "smaa", "vhs"]

    /// "edge-smoothing" → "Edge Smoothing", "subframe-bfi" → "Subframe BFI".
    static func title(ofCategory category: String) -> String {
        guard !category.isEmpty else { return String(localized: "Other") }
        return category.split(whereSeparator: { $0 == "-" || $0 == "_" }).map { word in
            acronyms.contains(word.lowercased()) ? word.uppercased() : word.prefix(1).uppercased() + word.dropFirst()
        }
        .joined(separator: " ")
    }

    // MARK: Helpers

    /// The `.slangp` files below `folder`; `size` becomes the disk space of
    /// all files there, or nil when the folder doesn't exist.
    private static func files(below folder: URL, source: ShaderPresetRef.Source, size: inout Int64?) -> [Found] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .totalFileAllocatedSizeKey]
        guard FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)),
              let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys,
                                                              options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [] }
        let base = folder.standardizedFileURL.pathComponents
        var total: Int64 = 0
        var found: [Found] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
            guard url.pathExtension.lowercased() == "slangp" else { continue }
            let path = url.standardizedFileURL.pathComponents.dropFirst(base.count).joined(separator: "/")
            guard let ref = ShaderPresetRef(source: source, path: path) else { continue }
            found.append(Found(ref: ref, url: url,
                               modified: values.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0))
        }
        size = total
        return found
    }
}
