// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The parts of a RetroArch `.slangp` preset that the shader library needs:
/// its `#reference` lines and `key = value` pairs. It counts passes for the
/// browser and finds the files a preset needs when it is imported. Loading
/// and rendering always go through librashader.
nonisolated struct SlangPresetFile: Sendable {
    /// Presets this one builds on, as written (relative to this file).
    var references: [String] = []
    /// Later lines win, as in RetroArch.
    var values: [String: String] = [:]
    /// Every `key = value` line in file order; a repeated key keeps its first place.
    var entries: [(key: String, value: String)] = []

    init(text: String) {
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#reference") {
                let value = Self.value(line.dropFirst("#reference".count))
                if !value.isEmpty { references.append(value) }
                continue
            }
            guard !line.hasPrefix("#"), !line.hasPrefix("//"), let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            let value = Self.value(line[line.index(after: equals)...])
            if values.updateValue(value, forKey: key) == nil {
                entries.append((key, value))
            } else if let index = entries.firstIndex(where: { $0.key == key }) {
                entries[index].value = value
            }
        }
    }

    init(contentsOf url: URL) throws {
        let data = try Data(contentsOf: url)
        self.init(text: String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self))
    }

    /// A value without quotes, or up to a trailing comment.
    private static func value(_ text: Substring) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("\"") {
            let rest = trimmed.dropFirst()
            return String(rest.prefix { $0 != "\"" })
        }
        return String(trimmed.prefix { $0 != "#" }).trimmingCharacters(in: .whitespaces)
    }

    /// Paths of the shader passes (`shader0`, `shader1`, …) in pass order.
    var shaderPaths: [String] {
        values.compactMap { key, value -> (Int, String)? in
            guard key.hasPrefix("shader"), let index = Int(key.dropFirst("shader".count)) else { return nil }
            return (index, value)
        }
        .sorted { $0.0 < $1.0 }
        .map(\.1)
    }

    /// Paths of the lookup textures named in `textures`.
    var texturePaths: [String] {
        (values["textures"] ?? "").split(separator: ";").compactMap { name in
            values[name.trimmingCharacters(in: .whitespaces)]
        }
    }

    // MARK: Files

    /// `path` as written in a preset or shader at `file`. Nil for paths
    /// RetroArch resolves itself (absolute, wildcards), which stay where they are.
    static func resolve(_ path: String, from file: URL) -> URL? {
        let path = path.replacing("\\", with: "/")
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix(":"), !path.contains("$") else { return nil }
        return file.deletingLastPathComponent().appending(path: path).standardizedFileURL
    }

    /// The number of passes of the preset at `url`, following `#reference`.
    static func passCount(of url: URL) -> Int? {
        passCount(of: url, depth: 0)
    }

    private static func passCount(of url: URL, depth: Int) -> Int? {
        guard depth < 16, let preset = try? SlangPresetFile(contentsOf: url) else { return nil }
        if let count = preset.values["shaders"].flatMap({ Int($0) }) { return count }
        for reference in preset.references.reversed() {
            if let referenced = resolve(reference, from: url), let count = passCount(of: referenced, depth: depth + 1) {
                return count
            }
        }
        return nil
    }

    /// Everything the preset at `url` reads: itself, referenced presets,
    /// shaders with their `#include` files, and textures. `missing` lists
    /// relative paths that don't exist.
    static func dependencies(of url: URL) -> (files: [URL], missing: [String]) {
        var collector = DependencyCollector()
        collector.visitPreset(url.standardizedFileURL, depth: 0)
        return (collector.files, collector.missing)
    }
}

nonisolated private struct DependencyCollector {
    var files: [URL] = []
    var missing: [String] = []
    private var visited: Set<String> = []

    mutating func visitPreset(_ url: URL, depth: Int) {
        guard depth < 16, add(url), let preset = try? SlangPresetFile(contentsOf: url) else { return }
        for reference in preset.references {
            if let file = existing(reference, from: url) { visitPreset(file, depth: depth + 1) }
        }
        for shader in preset.shaderPaths {
            if let file = existing(shader, from: url) { visitShader(file, depth: 0) }
        }
        for texture in preset.texturePaths {
            if let file = existing(texture, from: url) { add(file) }
        }
    }

    private mutating func visitShader(_ url: URL, depth: Int) {
        guard depth < 32, add(url), let data = try? Data(contentsOf: url) else { return }
        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("#include") else { continue }
            let parts = trimmed.split(separator: "\"")
            guard parts.count >= 2, let file = existing(String(parts[1]), from: url) else { continue }
            visitShader(file, depth: depth + 1)
        }
    }

    /// The file `path` names, or nil (noted as missing when it should exist).
    private mutating func existing(_ path: String, from file: URL) -> URL? {
        guard let url = SlangPresetFile.resolve(path, from: file) else { return nil }
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            missing.append(path)
            return nil
        }
        return url
    }

    @discardableResult
    private mutating func add(_ url: URL) -> Bool {
        guard visited.insert(url.path(percentEncoded: false)).inserted else { return false }
        files.append(url)
        return true
    }
}
