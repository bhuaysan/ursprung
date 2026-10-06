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
        if isOwn(shader, id: info.id, in: root) { return shader.standardizedFileURL }
        let files = filesURL(info.id, in: root)
        var copy: URL?
        for file in SlangSource.closure(of: shader) where !isOwn(file, id: info.id, in: root) {
            let path = ownPath(for: file, library: library, user: user)
            let target = files.appending(path: path, directoryHint: .notDirectory)
            if !FileManager.default.fileExists(atPath: target.path(percentEncoded: false)) {
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: file, to: target)
                info.files.append(.init(path: path, origin: file.path(percentEncoded: false)))
            }
            if copy == nil { copy = target }
        }
        guard let copy else { throw CocoaError(.fileNoSuchFile) }
        return copy
    }

    /// Where the draft keeps its copy of `file`: by its place in the pack
    /// or the user's folder, so shared include files are copied once.
    private static func ownPath(for file: URL, library: URL, user: URL) -> String {
        let components = file.standardizedFileURL.pathComponents
        for (prefix, folder) in [("library", library), ("user", user)] {
            let base = folder.standardizedFileURL.pathComponents
            if components.starts(with: base), components.count > base.count {
                return ([prefix] + components.dropFirst(base.count)).joined(separator: "/")
            }
        }
        // Elsewhere: one folder per original folder, so names don't clash.
        let folder = file.deletingLastPathComponent().path(percentEncoded: false)
        let hash = folder.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
        return "other/\(String(hash, radix: 36))/\(file.lastPathComponent)"
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
        // place, the others below `ownFolder` in their layout.
        var destinations: [String: URL] = [:]
        var placed: [String: [String]] = [:]
        for pass in preset.passes where pass.shader.hasPrefix("/") {
            let shader = URL(filePath: pass.shader)
            guard isOwn(shader, id: info.id, in: root) else { continue }
            for file in SlangSource.closure(of: shader) where isOwn(file, id: info.id, in: root) {
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
        // Without the first folder (`library`, `user`, `new` …) unless that
        // makes two files one, e.g. `library/crt/a.slang` and `user/crt/a.slang`.
        func place(dropsFirst: Bool) -> [String: URL] {
            placed.mapValues { relative in relative.dropFirst(dropsFirst ? 1 : 0).reduce(ownFolder) { $0.appending(path: $1) } }
        }
        func isDistinct(_ urls: some Collection<URL>) -> Bool {
            Set(urls.map { $0.standardizedFileURL.path(percentEncoded: false) }).count == urls.count
        }
        var below = place(dropsFirst: true)
        if !isDistinct(Array(destinations.values) + below.values) { below = place(dropsFirst: false) }
        destinations.merge(below) { first, _ in first }
        guard isDistinct(destinations.values) else { throw CocoaError(.fileWriteFileExists) }

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
