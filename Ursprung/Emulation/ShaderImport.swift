// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Copies presets into the user's shader folder. A folder is copied as it
/// is; a single preset takes along every file it reads, in the same layout,
/// so its relative paths keep working.
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
                    try fileManager.copyItem(at: url, to: destination)
                    result.presets += presets.compactMap { ref(of: destination.appending(path: $0), in: user) }
                } else if url.pathExtension.lowercased() == "slangp" {
                    let (preset, missing) = try copyPreset(url, into: user)
                    if let preset { result.presets.append(preset) }
                    result.missing += missing
                } else {
                    result.failures.append(Failure(name: name, reason: String(localized: "Only shader presets (.slangp) and folders can be imported.")))
                }
            } catch {
                result.failures.append(Failure(name: name, reason: error.localizedDescription))
            }
        }
        return result
    }

    /// Copies the preset with the files it reads into a new folder named after it.
    private static func copyPreset(_ preset: URL, into user: URL) throws -> (ShaderPresetRef?, [String]) {
        let (files, missing) = SlangPresetFile.dependencies(of: preset)
        let base = commonDirectory(of: files)
        let destination = uniqueURL(for: preset.deletingPathExtension().lastPathComponent, in: user)
        let fileManager = FileManager.default
        var copiedPreset: URL?
        for file in files {
            let relative = file.pathComponents.dropFirst(base.count)
            var target = destination
            for component in relative { target = target.appending(path: component) }
            try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.copyItem(at: file, to: target)
            if file == preset.standardizedFileURL { copiedPreset = target }
        }
        return (copiedPreset.flatMap { ref(of: $0, in: user) }, missing)
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
