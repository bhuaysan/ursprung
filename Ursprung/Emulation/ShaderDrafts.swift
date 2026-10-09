// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// What a shader editor draft knows besides its preset (`draft.json`).
nonisolated struct ShaderDraftInfo: Codable, Equatable, Sendable {
    /// A shader file the draft has its own copy of, below `files/`.
    struct OwnFile: Codable, Hashable, Sendable {
        /// Below `files/`, with `/` separators.
        var path: String
        /// The file it was copied from; nil for a new file.
        var origin: String?
    }

    var id: UUID
    var name: String
    /// The preset the draft was opened from; Revert goes back to it.
    var origin: String?
    /// The user preset Save writes to (below `User/`); nil until it was
    /// saved once, so Save asks for a name.
    var target: String?
    var files: [OwnFile] = []
    /// Changed since it was opened or saved.
    var isModified = false
    var modified = Date.now

    var originPreset: ShaderPresetRef? {
        guard let origin, case .preset(let preset)? = ShaderSelection(rawValue: origin) else { return nil }
        return preset
    }

    var targetPreset: ShaderPresetRef? {
        target.flatMap { ShaderPresetRef(source: .user, path: $0) }
    }
}

/// The shader editor's working copies in `Shaders/Drafts/<id>/`: `draft.json`,
/// the preset being edited (`preset.slangp`) and `files/`, the draft's own
/// copies of shaders. Pack and user shaders are never edited in place: a
/// shader is copied into the draft with the files it includes before its
/// first change, and only Save writes to the user's folder.
nonisolated enum ShaderDrafts {
    static let presetFileName = "preset.slangp"
    private static let infoFileName = "draft.json"
    private static let filesFolder = "files"

    static func folder(_ id: UUID, in root: URL) -> URL {
        root.appending(path: id.uuidString, directoryHint: .isDirectory)
    }

    static func presetURL(_ id: UUID, in root: URL) -> URL {
        folder(id, in: root).appending(path: presetFileName, directoryHint: .notDirectory)
    }

    static func filesURL(_ id: UUID, in root: URL) -> URL {
        folder(id, in: root).appending(path: filesFolder, directoryHint: .isDirectory)
    }

    /// The preset reference the renderer compiles the draft by.
    static func ref(_ id: UUID) -> ShaderPresetRef {
        ShaderPresetRef(source: .draft, path: "\(id.uuidString)/\(presetFileName)")!
    }

    // MARK: Creating and loading

    /// A new draft with the preset at `source` (references resolved, paths
    /// absolute), or an empty preset.
    static func create(from source: URL?, name: String, origin: ShaderPresetRef?, target: ShaderPresetRef?,
                       in root: URL) throws -> (ShaderDraftInfo, SlangPreset) {
        let preset = try source.map { try SlangPreset.load(from: $0) } ?? SlangPreset()
        let info = ShaderDraftInfo(id: UUID(), name: name, origin: origin.map { ShaderSelection.preset($0).rawValue },
                                   target: target?.source == .user ? target?.path : nil)
        try FileManager.default.createDirectory(at: filesURL(info.id, in: root), withIntermediateDirectories: true)
        try write(preset, info: info, in: root)
        return (info, preset)
    }

    static func load(_ id: UUID, in root: URL) throws -> (ShaderDraftInfo, SlangPreset) {
        let data = try Data(contentsOf: folder(id, in: root).appending(path: infoFileName))
        let info = try JSONDecoder().decode(ShaderDraftInfo.self, from: data)
        return (info, try SlangPreset.load(from: presetURL(id, in: root)))
    }

    /// Writes the preset (paths relative to the draft) and the draft's info.
    static func write(_ preset: SlangPreset, info: ShaderDraftInfo, in root: URL) throws {
        let folder = folder(info.id, in: root)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try preset.text(relativeTo: folder).write(to: presetURL(info.id, in: root), atomically: true, encoding: .utf8)
        try writeInfo(info, in: root)
    }

    static func writeInfo(_ info: ShaderDraftInfo, in root: URL) throws {
        var info = info
        info.modified = .now
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(info).write(to: folder(info.id, in: root).appending(path: infoFileName), options: .atomic)
    }

    /// The draft that was changed last.
    static func latest(in root: URL) -> UUID? {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { folder -> (UUID, Date)? in
            guard let id = UUID(uuidString: folder.lastPathComponent),
                  let data = try? Data(contentsOf: folder.appending(path: infoFileName)),
                  let info = try? JSONDecoder().decode(ShaderDraftInfo.self, from: data) else { return nil }
            return (id, info.modified)
        }
        .max { $0.1 < $1.1 }?.0
    }

    static func remove(_ id: UUID, in root: URL) {
        try? FileManager.default.removeItem(at: folder(id, in: root))
    }

    /// Removes every draft but `keeping`.
    static func removeAll(in root: URL, keeping: UUID? = nil) {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for folder in folders where UUID(uuidString: folder.lastPathComponent).map({ $0 != keeping }) ?? false {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    // MARK: Own files

    /// Whether `url` is one of the draft's own files.
    static func isOwn(_ url: URL, id: UUID, in root: URL) -> Bool {
        url.standardizedFileURL.pathComponents.starts(with: filesURL(id, in: root).standardizedFileURL.pathComponents)
    }

    /// Gives the draft its own copy of `shader` and of every file it
    /// includes, in the same layout, so its `#include` lines keep working.
    /// Files copied before are kept (they may have changes). Returns the copy.
    static func ownCopy(of shader: URL, info: inout ShaderDraftInfo, in root: URL,
                        library: URL, user: URL) throws -> URL {
        let copies = try ownCopies(of: shader, info: &info, in: root, library: library, user: user)
        guard let copy = copies[shader.standardizedFileURL.path(percentEncoded: false)] else {
            throw CocoaError(.fileNoSuchFile)
        }
        return copy
    }

    /// `ownCopy(of:)`, returning for every file `shader` reads (by its path)
    /// the copy the copied shader reads instead. A file may have several
    /// copies (drafts from before this layout kept others); only this tells
    /// which one belongs to the shader.
    static func ownCopies(of shader: URL, info: inout ShaderDraftInfo, in root: URL,
                          library: URL, user: URL) throws -> [String: URL] {
        let originals = SlangSource.closure(of: shader).map(\.standardizedFileURL)
        let files = filesURL(info.id, in: root)
        let (prefix, base) = layout(of: originals.filter { !isOwn($0, id: info.id, in: root) }, library: library, user: user)
        var copies: [String: URL] = [:]
        for file in originals {
            let key = file.path(percentEncoded: false)
            if isOwn(file, id: info.id, in: root) {
                copies[key] = file
                continue
            }
            let path = ([prefix] + file.pathComponents.dropFirst(base.count)).joined(separator: "/")
            let target = files.appending(path: path, directoryHint: .notDirectory).standardizedFileURL
            if !FileManager.default.fileExists(atPath: target.path(percentEncoded: false)) {
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: file, to: target)
                info.files.append(.init(path: path, origin: key))
            }
            copies[key] = target
        }
        guard copies[shader.standardizedFileURL.path(percentEncoded: false)] != nil else {
            throw CocoaError(.fileNoSuchFile)
        }
        return copies
    }

    /// Where the draft keeps its copies of `files`, which include one
    /// another: below `library/` or `user/` by their place in the pack or
    /// the user's folder, so shared include files are copied once, or, when
    /// they aren't all in one of them, below `other/` by their whole path.
    /// One folder for all of them keeps includes like `../common/a.h` working.
    private static func layout(of files: [URL], library: URL, user: URL) -> (prefix: String, base: [String]) {
        for (prefix, folder) in [("library", library), ("user", user)] {
            let base = folder.standardizedFileURL.pathComponents
            if files.allSatisfy({ $0.pathComponents.starts(with: base) && $0.pathComponents.count > base.count }) {
                return (prefix, base)
            }
        }
        return ("other", ["/"])
    }

    /// A new shader from the template in `files/new/`.
    static func newShader(named name: String, info: inout ShaderDraftInfo, in root: URL) throws -> URL {
        let folder = filesURL(info.id, in: root).appending(path: "new", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = ShaderPresetWriter.fileName(for: name).map { ($0 as NSString).deletingPathExtension } ?? "pass"
        var url = folder.appending(path: "\(base).slang")
        var number = 2
        while FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            url = folder.appending(path: "\(base) \(number).slang")
            number += 1
        }
        try SlangSource.template.write(to: url, atomically: true, encoding: .utf8)
        info.files.append(.init(path: "new/\(url.lastPathComponent)", origin: nil))
        return url
    }

    // MARK: Saving

    /// Writes the draft as the user preset `target`. The draft's own files go
    /// to a folder named after the preset next to it; with `inPlace` (saving
    /// over the preset the draft came from), copies of the user's own files
    /// go back where they came from instead.
    static func save(_ preset: SlangPreset, info: ShaderDraftInfo, to target: URL, inPlace: Bool,
                     in root: URL, user: URL) throws {
        let fileManager = FileManager.default
        let directory = target.deletingLastPathComponent()
        let ownFolder = directory.appending(path: target.deletingPathExtension().lastPathComponent,
                                            directoryHint: .isDirectory)
        let files = filesURL(info.id, in: root)
        let userPath = user.standardizedFileURL.pathComponents

        // Where each own file the preset uses ends up: user files back in
        // place, the others below `ownFolder` in their layout. The files it
        // reads that aren't the draft's own are taken: writing over one would
        // change a pass that wasn't edited.
        var destinations: [String: URL] = [:]
        var placed: [String: [String]] = [:]
        var taken: Set<String> = []
        for texture in preset.textures where texture.path.hasPrefix("/") {
            taken.insert(fileSystemKey(URL(filePath: texture.path)))
        }
        for pass in preset.passes where pass.shader.hasPrefix("/") {
            for file in SlangSource.closure(of: URL(filePath: pass.shader)) {
                guard isOwn(file, id: info.id, in: root) else {
                    taken.insert(fileSystemKey(file))
                    continue
                }
                let relative = Array(file.standardizedFileURL.pathComponents
                    .dropFirst(files.standardizedFileURL.pathComponents.count))
                let key = relative.joined(separator: "/")
                guard destinations[key] == nil, placed[key] == nil else { continue }
                let origin = info.files.first { $0.path == key }?.origin.map { URL(filePath: $0) }
                if inPlace, let origin, origin.standardizedFileURL.pathComponents.starts(with: userPath) {
                    destinations[key] = origin
                } else {
                    placed[key] = relative
                }
            }
        }
        // Files from elsewhere sit below `other/` by their whole path: only
        // the part below the folder they all share is kept.
        let otherBase = placed.values.filter { $0.first == "other" }
            .map { Array($0.dropFirst().dropLast()) }
            .reduce(nil as [String]?) { common, folder in
                guard let common else { return folder }
                return Array(zip(common, folder).prefix { $0 == $1 }.map(\.0))
            } ?? []
        // Without the first folder (`library`, `user`, `new` …) unless that
        // makes two files one, e.g. `library/crt/a.slang` and `user/crt/a.slang`.
        func place(dropsFirst: Bool) -> [String: URL] {
            placed.mapValues { relative in
                let inside = relative.first == "other"
                    ? relative.prefix(1) + relative.dropFirst(1 + otherBase.count) : relative[...]
                return inside.dropFirst(dropsFirst ? 1 : 0).reduce(ownFolder) { $0.appending(path: $1) }
            }
        }
        // Files going back in place may be taken: those are the ones edited.
        let backInPlace = destinations.values.map(fileSystemKey)
        func collides(_ below: [String: URL]) -> Bool {
            let keys = backInPlace + below.values.map(fileSystemKey)
            return Set(keys).count != keys.count || below.values.contains { taken.contains(fileSystemKey($0)) }
        }
        var below = place(dropsFirst: true)
        if collides(below) { below = place(dropsFirst: false) }
        guard !collides(below) else { throw CocoaError(.fileWriteFileExists) }
        destinations.merge(below) { first, _ in first }

        for (path, destination) in destinations {
            let source = files.appending(path: path, directoryHint: .notDirectory)
            let data = try Data(contentsOf: source)
            if (try? Data(contentsOf: destination)) == data { continue }
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: destination, options: .atomic)
        }

        var saved = preset
        for index in saved.passes.indices where saved.passes[index].shader.hasPrefix("/") {
            let shader = URL(filePath: saved.passes[index].shader)
            guard isOwn(shader, id: info.id, in: root) else { continue }
            let key = shader.standardizedFileURL.pathComponents
                .dropFirst(files.standardizedFileURL.pathComponents.count).joined(separator: "/")
            if let destination = destinations[key] { saved.passes[index].shader = destination.path(percentEncoded: false) }
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try saved.text(relativeTo: directory).write(to: target, atomically: true, encoding: .utf8)
    }

    /// `url`'s path as the usual (case-insensitive) volumes compare it:
    /// `a.slang` and `A.slang` are one file there, whatever their Unicode form.
    private static func fileSystemKey(_ url: URL) -> String {
        url.standardizedFileURL.path(percentEncoded: false).decomposedStringWithCanonicalMapping.lowercased()
    }

    // MARK: Export

    /// Copies the preset at `presetURL` with every file it reads into the
    /// folder `destination`, which works on its own (also in RetroArch).
    /// Returns the exported preset.
    static func export(_ presetURL: URL, named name: String, to destination: URL) throws -> URL {
        let preset = try SlangPreset.load(from: presetURL)
        let fileManager = FileManager.default
        var files: [URL] = []
        var seen: Set<String> = []
        func add(_ url: URL) {
            if seen.insert(url.standardizedFileURL.path(percentEncoded: false)).inserted { files.append(url.standardizedFileURL) }
        }
        for pass in preset.passes where pass.shader.hasPrefix("/") {
            SlangSource.closure(of: URL(filePath: pass.shader)).forEach(add)
        }
        for texture in preset.textures where texture.path.hasPrefix("/") {
            add(URL(filePath: texture.path))
        }
        let base = files.map { Array($0.deletingLastPathComponent().pathComponents) }
            .reduce(nil as [String]?) { common, folder in
                guard let common else { return folder }
                return Array(zip(common, folder).prefix { $0 == $1 }.map(\.0))
            } ?? []

        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        var mapped: [String: String] = [:]
        for file in files where fileManager.fileExists(atPath: file.path(percentEncoded: false)) {
            let target = file.pathComponents.dropFirst(base.count).reduce(destination) { $0.appending(path: $1) }
            try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: target.path(percentEncoded: false)) { try fileManager.removeItem(at: target) }
            try fileManager.copyItem(at: file, to: target)
            mapped[file.path(percentEncoded: false)] = target.path(percentEncoded: false)
        }
        var exported = preset
        for index in exported.passes.indices {
            let path = URL(filePath: exported.passes[index].shader).standardizedFileURL.path(percentEncoded: false)
            if let target = mapped[path] { exported.passes[index].shader = target }
        }
        for index in exported.textures.indices {
            let path = URL(filePath: exported.textures[index].path).standardizedFileURL.path(percentEncoded: false)
            if let target = mapped[path] { exported.textures[index].path = target }
        }
        let fileName = ShaderPresetWriter.fileName(for: name) ?? "preset.slangp"
        let url = destination.appending(path: fileName, directoryHint: .notDirectory)
        try exported.text(relativeTo: destination).write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
