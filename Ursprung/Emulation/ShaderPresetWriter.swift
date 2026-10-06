// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Saves changed parameters as a RetroArch "simple preset": a `.slangp`
/// that names another preset with `#reference` and overrides some of its
/// parameters. RetroArch loads these too.
nonisolated enum ShaderPresetWriter {
    enum SaveError: LocalizedError {
        case referencesItself(String)

        var errorDescription: String? {
            switch self {
            case .referencesItself(let name):
                String(localized: "“\(name)” is the preset these settings are based on. Choose another name.")
            }
        }
    }

    /// Writes a preset at `target` that references the preset at `source`
    /// (or what it is based on, see `base(of:)`) and sets every parameter
    /// whose value in `values` differs from there.
    static func save(_ values: [String: Float], of source: URL, to target: URL) throws {
        let base = base(of: source)
        guard base.standardizedFileURL.path(percentEncoded: false) != target.standardizedFileURL.path(percentEncoded: false)
        else { throw SaveError.referencesItself(target.deletingPathExtension().lastPathComponent) }
        let parameters = try ShaderPreset.parametersOfPreset(atPath: base.path(percentEncoded: false))
        let overrides = parameters.compactMap { parameter -> (String, Float)? in
            guard let value = values[parameter.name], abs(value - parameter.initial) > 0.000_001 else { return nil }
            return (parameter.name, value)
        }
        let directory = target.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try text(referencing: relativePath(from: directory, to: base), overrides: overrides)
            .write(to: target, atomically: true, encoding: .utf8)
    }

    /// The preset a saved copy builds on. A preset that only references one
    /// other preset and sets some of its parameters is skipped, so saving
    /// over it doesn't make it reference itself and references don't pile up.
    static func base(of url: URL) -> URL {
        var current = url.standardizedFileURL
        for _ in 0..<16 {
            guard let preset = try? SlangPresetFile(contentsOf: current), preset.references.count == 1,
                  preset.values["shaders"] == nil,
                  let referenced = SlangPresetFile.resolve(preset.references[0], from: current) else { break }
            let names = Set((try? ShaderPreset.parametersOfPreset(atPath: referenced.path(percentEncoded: false)))?.map(\.name) ?? [])
            guard preset.values.keys.allSatisfy(names.contains) else { break }
            current = referenced
        }
        return current
    }

    static func text(referencing reference: String, overrides: [(name: String, value: Float)]) -> String {
        var lines = ["#reference \"\(reference)\""]
        lines += overrides.map { "\($0.name) = \"\(format($0.value))\"" }
        return lines.joined(separator: "\n") + "\n"
    }

    /// `file` relative to `directory`, with `/` separators.
    static func relativePath(from directory: URL, to file: URL) -> String {
        let from = directory.standardizedFileURL.pathComponents
        let to = file.standardizedFileURL.pathComponents
        let common = zip(from, to).prefix { $0 == $1 }.count
        return (Array(repeating: "..", count: from.count - common) + to[common...]).joined(separator: "/")
    }

    /// Up to six decimals, without trailing zeros: "2.4", "0.05", "3".
    static func format(_ value: Float) -> String {
        var text = String(format: "%.6f", Double(value))
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text == "-0" ? "0" : text
    }

    /// A file name for a preset named `name`: no path separators or leading dots.
    static func fileName(for name: String) -> String? {
        var name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.lowercased().hasSuffix(".slangp") { name.removeLast(".slangp".count) }
        let cleaned = name.replacing("/", with: "-").replacing(":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = String(cleaned.drop { $0 == "." })
        return trimmed.isEmpty ? nil : trimmed + ".slangp"
    }
}
