// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Copies presets into the user's shader folder. A folder is copied as it
/// is, except for links that lead out of it; a single preset takes along the
/// files it reads, in the same layout, so its relative paths keep working.
///
/// A preset can name any file (`../../.ssh/id_rsa`, `../Photos/me.png`), so
/// it only takes along what lies in its package: the deepest folder that
/// holds the preset, the presets it references and their shader passes.
/// Includes and textures outside it are neither read nor copied, links are
/// followed before that check, and only regular files are copied.
nonisolated enum ShaderImport {
    struct Result: Sendable {
        var presets: [ShaderPresetRef] = []
        var failures: [Failure] = []
        /// Files the imported presets refer to that weren't found.
        var missing: [String] = []
    }

    struct Failure: Sendable, Hashable {
        let name: String
        let reason: String
    }

    static func copy(_ urls: [URL], into user: URL) -> Result {
        var result = Result()
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: user, withIntermediateDirectories: true)
        let userPath = user.standardizedFileURL.pathComponents
        for url in urls.map(\.standardizedFileURL) {
            let name = url.lastPathComponent
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory) else {
                result.failures.append(Failure(name: name, reason: String(localized: "The file doesn't exist.")))
                continue
            }
            guard !url.pathComponents.starts(with: userPath) else {
                result.failures.append(Failure(name: name, reason: String(localized: "It is already in your shaders.")))
                continue
            }
            do {
                if isDirectory.boolValue {
                    let presets = presetFiles(below: url)
                    guard !presets.isEmpty else {
                        result.failures.append(Failure(name: name, reason: String(localized: "The folder contains no shader presets (.slangp).")))
                        continue
                    }
                    let destination = uniqueURL(for: name, in: user)
                    let skipped = try copyFolder(url, to: destination)
                    result.presets += presets.compactMap { path in
                        let preset = destination.appending(path: path)
                        guard fileManager.fileExists(atPath: preset.path(percentEncoded: false)) else { return nil }
                        return ref(of: preset, in: user)
                    }
                    if !skipped.isEmpty {
                        let files = skipped.joined(separator: ", ")
                        result.failures.append(Failure(name: name, reason: String(localized: "Links to files outside the folder weren't copied: \(files)")))
                    }
                } else if url.pathExtension.lowercased() == "slangp" {
                    guard let package = package(of: url) else {
                        result.failures.append(Failure(name: name, reason: String(localized: "Its shaders are spread over your whole home folder or disk. Import the folder that holds them instead.")))
                        continue
                    }
                    let (preset, missing, skipped) = try copyPreset(url, from: package, into: user)
                    if let preset { result.presets.append(preset) }
                    result.missing += missing
                    if !skipped.isEmpty {
                        let files = skipped.map(\.lastPathComponent).joined(separator: ", ")
                        result.failures.append(Failure(name: name, reason: String(localized: "Some files it refers to weren't copied, as they aren't shaders or images in its folder: \(files)")))
                    }
                } else {
                    result.failures.append(Failure(name: name, reason: String(localized: "Only shader presets (.slangp) and folders can be imported.")))
                }
            } catch {
                result.failures.append(Failure(name: name, reason: error.localizedDescription))
            }
        }
        return result
    }

    /// Kinds of files presets read: presets, shaders with their includes,
    /// textures.
    private static let shaderFileExtensions: Set<String> = [
        "slangp", "params", "slang", "inc", "h", "hpp", "hlsl", "glsl", "png", "jpg", "jpeg", "bmp", "tga", "gif",
    ]

    /// The preset's package (see above): the deepest folder holding the
    /// preset, the presets it references and their passes, as the real
    /// folder links lead to. Nil when that is the home folder or above, or a
    /// whole volume: then it would let the preset take along almost anything.
    static func package(of preset: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        let files = SlangPresetFile.presetsAndPasses(of: preset)
        let folder = URL(filePath: NSString.path(withComponents: commonDirectory(of: files)), directoryHint: .isDirectory)
            .resolvingSymlinksInPath()
        let home = home.resolvingSymlinksInPath()
        let isVolume = (try? folder.resourceValues(forKeys: [.isVolumeKey]).isVolume) ?? true
        guard !isVolume, !home.pathComponents.starts(with: folder.pathComponents) else { return nil }
        return folder
    }

    /// Whether `file` is a regular file in `package` once links are followed.
    private static func isRegularFile(_ file: URL, in package: URL) -> Bool {
        let real = file.resolvingSymlinksInPath()
        guard (try? real.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return false }
        return real.pathComponents.starts(with: package.pathComponents)
    }

    /// Copies the preset with the files it reads from its `package` into a
    /// new folder named after it. Files outside the package, and files that
    /// aren't shaders or images, stay behind and are returned as skipped.
    private static func copyPreset(_ preset: URL, from package: URL, into user: URL)
        throws -> (ShaderPresetRef?, [String], skipped: [URL]) {
        let preset = preset.standardizedFileURL
        let (dependencies, missing, outside) = SlangPresetFile.dependencies(of: preset) { isRegularFile($0, in: package) }
        let (files, skipped) = dependencies.reduce(into: ([URL](), outside)) { split, file in
            if file == preset || shaderFileExtensions.contains(file.pathExtension.lowercased()) {
                split.0.append(file)
            } else {
                split.1.append(file)
            }
        }
        let base = commonDirectory(of: files)
        let destination = uniqueURL(for: preset.deletingPathExtension().lastPathComponent, in: user)
        let fileManager = FileManager.default
        var copiedPreset: URL?
        for file in files {
            let relative = file.pathComponents.dropFirst(base.count)
            var target = destination
            for component in relative { target = target.appending(path: component) }
            try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            // The file itself, not a link to it.
            try fileManager.copyItem(at: file.resolvingSymlinksInPath(), to: target)
            if file == preset { copiedPreset = target }
        }
        return (copiedPreset.flatMap { ref(of: $0, in: user) }, missing, skipped)
    }

    /// Copies `folder` to `destination` like `copyItem`, except that a link
    /// is replaced by a copy of the file it leads to when that is a regular
    /// file inside `folder`; other links stay behind. Returns their paths
    /// relative to `folder`.
    private static func copyFolder(_ folder: URL, to destination: URL) throws -> [String] {
        let fileManager = FileManager.default
        let source = folder.resolvingSymlinksInPath()
        // Relative paths, without following links to folders.
        guard let enumerator = fileManager.enumerator(atPath: source.path(percentEncoded: false)) else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSURLErrorKey: folder])
        }
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: false)
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey]
        var skipped: [String] = []
        for case let relative as String in enumerator {
            let item = source.appending(path: relative)
            let target = destination.appending(path: relative)
            let values = try item.resourceValues(forKeys: keys)
            if values.isSymbolicLink == true {
                if isRegularFile(item, in: source) {
                    try fileManager.copyItem(at: item.resolvingSymlinksInPath(), to: target)
                } else {
                    skipped.append(relative)
                }
            } else if values.isDirectory == true {
                try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
            } else if values.isRegularFile == true {
                try fileManager.copyItem(at: item, to: target)
            }
        }
        return skipped
    }

    /// Path components of the deepest folder that holds all `files`.
    private static func commonDirectory(of files: [URL]) -> [String] {
        let folders = files.map { Array($0.deletingLastPathComponent().pathComponents) }
        guard var common = folders.first else { return [] }
        for folder in folders.dropFirst() {
            common = Array(zip(common, folder).prefix { $0 == $1 }.map(\.0))
        }
        return common
    }

    /// Relative paths of the presets below `folder`.
    private static func presetFiles(below folder: URL) -> [String] {
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil,
                                                              options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [] }
        let base = folder.standardizedFileURL.pathComponents.count
        return enumerator.compactMap { item in
            guard let url = item as? URL, url.pathExtension.lowercased() == "slangp" else { return nil }
            return url.standardizedFileURL.pathComponents.dropFirst(base).joined(separator: "/")
        }
    }

    private static func ref(of file: URL, in user: URL) -> ShaderPresetRef? {
        let path = file.standardizedFileURL.pathComponents.dropFirst(user.standardizedFileURL.pathComponents.count)
        return ShaderPresetRef(source: .user, path: path.joined(separator: "/"))
    }

    /// `name` in `folder`, numbered ("name 2") when taken.
    private static func uniqueURL(for name: String, in folder: URL) -> URL {
        var candidate = folder.appending(path: name, directoryHint: .isDirectory)
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false)) {
            candidate = folder.appending(path: "\(name) \(number)", directoryHint: .isDirectory)
            number += 1
        }
        return candidate
    }
}
