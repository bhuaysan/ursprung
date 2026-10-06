// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A RetroArch `.slangp` preset as the shader editor edits it: passes with
/// all their options, lookup textures and parameter values. Loading and
/// rendering always go through librashader; this model only reads and
/// writes the file. Comments are not kept.
nonisolated struct SlangPreset: Hashable, Sendable {
    enum ScaleType: String, CaseIterable, Hashable, Sendable {
        /// A multiple of the previous pass's output.
        case source
        /// A multiple of the final output size.
        case viewport
        /// Pixels.
        case absolute
        /// A multiple of the core's frame.
        case original
    }

    enum WrapMode: String, CaseIterable, Hashable, Sendable {
        case clampToBorder = "clamp_to_border"
        case clampToEdge = "clamp_to_edge"
        case `repeat` = "repeat"
        case mirroredRepeat = "mirrored_repeat"
    }

    /// One shader pass. Options left nil use librashader's defaults.
    struct Pass: Hashable, Sendable, Identifiable {
        var id = UUID()
        /// The `.slang` file, as written in the preset (or absolute after `load(from:)`).
        var shader: String
        /// The name later passes and the shaders use for this pass's output.
        var alias: String?
        var filterLinear: Bool?
        var wrapMode: WrapMode?
        var mipmapInput: Bool?
        var floatFramebuffer: Bool?
        var srgbFramebuffer: Bool?
        var frameCountMod: Int?
        var scaleTypeX: ScaleType?
        var scaleTypeY: ScaleType?
        var scaleX: Double?
        var scaleY: Double?

        init(shader: String) {
            self.shader = shader
        }

        /// A copy with a new identity, e.g. for "Duplicate".
        func duplicated() -> Pass {
            var copy = self
            copy.id = UUID()
            return copy
        }
    }

    /// A lookup texture (`textures = "NAME;…"`) the shaders sample by name.
    struct Texture: Hashable, Sendable, Identifiable {
        var id = UUID()
        var name: String
        /// The image file, as written in the preset (or absolute after `load(from:)`).
        var path: String
        var linear: Bool?
        var wrapMode: WrapMode?
        var mipmap: Bool?

        init(name: String, path: String) {
            self.name = name
            self.path = path
        }
    }

    /// A `key = value` line that is no pass or texture option: parameter
    /// values, and keys Ursprung doesn't know (kept as they are).
    struct Value: Hashable, Sendable {
        var name: String
        var value: String
    }

    var references: [String] = []
    var passes: [Pass] = []
    var textures: [Texture] = []
    var values: [Value] = []

    init(passes: [Pass] = [], textures: [Texture] = [], values: [Value] = []) {
        self.passes = passes
        self.textures = textures
        self.values = values
    }

    // MARK: Reading

    init(text: String) {
        let file = SlangPresetFile(text: text)
        self.init(entries: file.entries)
        references = file.references
    }

    /// Builds the preset from `key = value` pairs in file order.
    init(entries: [(key: String, value: String)]) {
        var values: [String: String] = [:]
        for (key, value) in entries { values[key] = value }

        let textureNames = (values["textures"] ?? "").split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var used: Set<String> = ["shaders", "textures"]

        let declared = values["shaders"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        let highestIndex = entries.compactMap { Self.passKey($0.key)?.index }.max()
        let count = max(0, min(declared ?? (highestIndex.map { $0 + 1 } ?? 0), 1024))
        for index in 0..<count {
            func take(_ name: String) -> String? {
                let key = "\(name)\(index)"
                guard let value = values[key] else { return nil }
                used.insert(key)
                return value
            }
            func takeBool(_ name: String) -> Bool? {
                let key = "\(name)\(index)"
                guard let value = values[key], let flag = Self.bool(value) else { return nil }
                used.insert(key)
                return flag
            }
            func takeEnum<T: RawRepresentable<String>>(_ name: String, as type: T.Type) -> T? {
                let key = "\(name)\(index)"
                guard let value = values[key], let parsed = T(rawValue: value) else { return nil }
                used.insert(key)
                return parsed
            }
            func takeNumber(_ name: String) -> Double? {
                let key = "\(name)\(index)"
                guard let value = values[key], let number = Double(value) else { return nil }
                used.insert(key)
                return number
            }

            var pass = Pass(shader: take("shader") ?? "")
            pass.alias = take("alias").flatMap { $0.isEmpty ? nil : $0 }
            pass.filterLinear = takeBool("filter_linear")
            pass.wrapMode = takeEnum("wrap_mode", as: WrapMode.self)
            pass.mipmapInput = takeBool("mipmap_input")
            pass.floatFramebuffer = takeBool("float_framebuffer")
            pass.srgbFramebuffer = takeBool("srgb_framebuffer")
            pass.frameCountMod = take("frame_count_mod").flatMap { Int($0) }
            // `scale_type` sets both axes; `scale_type_x`/`_y` win over it, as in RetroArch.
            let scaleType = takeEnum("scale_type", as: ScaleType.self)
            pass.scaleTypeX = takeEnum("scale_type_x", as: ScaleType.self) ?? scaleType
            pass.scaleTypeY = takeEnum("scale_type_y", as: ScaleType.self) ?? scaleType
            let scale = takeNumber("scale")
            pass.scaleX = takeNumber("scale_x") ?? scale
            pass.scaleY = takeNumber("scale_y") ?? scale
            passes.append(pass)
        }

        for name in textureNames {
            var texture = Texture(name: name, path: values[name] ?? "")
            used.insert(name)
            if let linear = values["\(name)_linear"].flatMap(Self.bool) {
                texture.linear = linear
                used.insert("\(name)_linear")
            }
            if let wrap = values["\(name)_wrap_mode"].flatMap(WrapMode.init(rawValue:)) {
                texture.wrapMode = wrap
                used.insert("\(name)_wrap_mode")
            }
            if let mipmap = values["\(name)_mipmap"].flatMap(Self.bool) {
                texture.mipmap = mipmap
                used.insert("\(name)_mipmap")
            }
            textures.append(texture)
        }

        self.values = entries.filter { !used.contains($0.key) }.map { Value(name: $0.key, value: $0.value) }
    }

    /// Reads the preset at `url` and the presets it references, as one
    /// preset without references. Paths become absolute, so the result can
    /// be written anywhere. Later lines win, as in RetroArch.
    ///
    /// `wildcards` fill RetroArch's `$NAME$` placeholders in referenced
    /// paths (e.g. `CORE-REQ-ROT` → `CORE-REQ-ROT-90`); like RetroArch, a
    /// path whose filled-in file doesn't exist is used as written.
    static func load(from url: URL, wildcards: [String: String] = defaultWildcards) throws -> SlangPreset {
        var entries = OrderedEntries()
        try collect(url.standardizedFileURL, wildcards: wildcards, into: &entries, depth: 0)
        return SlangPreset(entries: entries.pairs)
    }

    /// An upright game on an unknown core.
    static let defaultWildcards = ["CORE-REQ-ROT": "CORE-REQ-ROT-0", "VID-DRV": "metal", "VID-DRV-PRESET-EXT": "slangp",
                                   "VID-DRV-SHADER-EXT": "slang"]

    enum LoadError: LocalizedError {
        case missingReference(String)
        case tooDeep

        var errorDescription: String? {
            switch self {
            case .missingReference(let path): String(localized: "The preset it is based on is missing: \(path)")
            case .tooDeep: String(localized: "The preset references too many other presets.")
            }
        }
    }

    private static func collect(_ url: URL, wildcards: [String: String], into entries: inout OrderedEntries,
                                depth: Int) throws {
        guard depth < 16 else { throw LoadError.tooDeep }
        let file = try SlangPresetFile(contentsOf: url)
        for reference in file.references {
            guard let referenced = resolveReference(reference, from: url, wildcards: wildcards)
            else { throw LoadError.missingReference(reference) }
            try collect(referenced, wildcards: wildcards, into: &entries, depth: depth + 1)
        }
        let textureNames = Set((file.values["textures"] ?? entries["textures"] ?? "").split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespaces) })
        for (key, value) in file.entries {
            let resolved = SlangPresetFile.resolve(value, from: url)
            if textureNames.contains(key) || passKey(key)?.name == "shader" {
                entries[key] = resolved?.path(percentEncoded: false) ?? value
            } else if Double(value) == nil, let resolved, FileManager.default.fileExists(atPath: resolved.path(percentEncoded: false)) {
                // A texture path for a name a later or earlier preset declares
                // (Mega Bezel's `.params` files): librashader reads it as one.
                entries[key] = resolved.path(percentEncoded: false)
            } else {
                entries[key] = value
            }
        }
    }

    /// The existing file a `#reference` line names: with wildcards filled
    /// in, or else as written.
    private static func resolveReference(_ path: String, from file: URL, wildcards: [String: String]) -> URL? {
        let path = path.replacing("\\", with: "/")
        var candidates = [path]
        if path.contains("$") {
            let filled = wildcards.reduce(path) { $0.replacing("$\($1.key)$", with: $1.value) }
            if filled != path { candidates.insert(filled, at: 0) }
        }
        return candidates.lazy.map { candidate in
            candidate.hasPrefix("/") ? URL(filePath: candidate).standardizedFileURL
                : file.deletingLastPathComponent().appending(path: candidate).standardizedFileURL
        }
        .first { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
    }

    // MARK: Writing

    /// The preset as `.slangp` text, quoted like RetroArch writes it.
    /// Absolute paths are written relative to `directory` when given.
    func text(relativeTo directory: URL? = nil) -> String {
        func path(_ path: String) -> String {
            guard let directory, path.hasPrefix("/") else { return path }
            return ShaderPresetWriter.relativePath(from: directory, to: URL(filePath: path))
        }
        func line(_ key: String, _ value: String) -> String { "\(key) = \"\(value)\"" }

        var sections: [[String]] = []
        if !references.isEmpty { sections.append(references.map { "#reference \"\($0)\"" }) }
        if !passes.isEmpty || references.isEmpty { sections.append([line("shaders", "\(passes.count)")]) }
        for (index, pass) in passes.enumerated() {
            var lines = [line("shader\(index)", path(pass.shader))]
            if let alias = pass.alias, !alias.isEmpty { lines.append(line("alias\(index)", alias)) }
            if let value = pass.filterLinear { lines.append(line("filter_linear\(index)", "\(value)")) }
            if let value = pass.wrapMode { lines.append(line("wrap_mode\(index)", value.rawValue)) }
            if let value = pass.mipmapInput { lines.append(line("mipmap_input\(index)", "\(value)")) }
            if let value = pass.floatFramebuffer { lines.append(line("float_framebuffer\(index)", "\(value)")) }
            if let value = pass.srgbFramebuffer { lines.append(line("srgb_framebuffer\(index)", "\(value)")) }
            if let value = pass.frameCountMod { lines.append(line("frame_count_mod\(index)", "\(value)")) }
            if pass.scaleTypeX == pass.scaleTypeY {
                if let value = pass.scaleTypeX { lines.append(line("scale_type\(index)", value.rawValue)) }
            } else {
                if let value = pass.scaleTypeX { lines.append(line("scale_type_x\(index)", value.rawValue)) }
                if let value = pass.scaleTypeY { lines.append(line("scale_type_y\(index)", value.rawValue)) }
            }
            if pass.scaleX == pass.scaleY {
                if let value = pass.scaleX { lines.append(line("scale\(index)", Self.format(value))) }
            } else {
                if let value = pass.scaleX { lines.append(line("scale_x\(index)", Self.format(value))) }
                if let value = pass.scaleY { lines.append(line("scale_y\(index)", Self.format(value))) }
            }
            sections.append(lines)
        }
        if !textures.isEmpty {
            var lines = [line("textures", textures.map(\.name).joined(separator: ";"))]
            for texture in textures {
                lines.append(line(texture.name, path(texture.path)))
                if let value = texture.linear { lines.append(line("\(texture.name)_linear", "\(value)")) }
                if let value = texture.wrapMode { lines.append(line("\(texture.name)_wrap_mode", value.rawValue)) }
                if let value = texture.mipmap { lines.append(line("\(texture.name)_mipmap", "\(value)")) }
            }
            sections.append(lines)
        }
        if !values.isEmpty { sections.append(values.map { line($0.name, $0.value) }) }
        return sections.map { $0.joined(separator: "\n") }.joined(separator: "\n\n") + "\n"
    }

    /// Up to six decimals, without trailing zeros.
    static func format(_ value: Double) -> String {
        var text = String(format: "%.6f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text == "-0" ? "0" : text
    }

    // MARK: Values

    /// The value the preset sets `name` to, as written.
    func value(of name: String) -> String? {
        values.last { $0.name == name }?.value
    }

    /// Sets a parameter value; nil removes it, so the shader's own value applies.
    mutating func setValue(_ value: String?, of name: String) {
        if let value {
            if let index = values.firstIndex(where: { $0.name == name }) {
                values[index].value = value
            } else {
                values.append(Value(name: name, value: value))
            }
        } else {
            values.removeAll { $0.name == name }
        }
    }

    /// What is wrong with the preset in ways librashader doesn't report.
    var problems: [String] {
        var problems: [String] = []
        for (index, pass) in passes.enumerated() where pass.shader.trimmingCharacters(in: .whitespaces).isEmpty {
            problems.append(String(localized: "Pass \(index + 1) has no shader file."))
        }
        let aliases = passes.compactMap(\.alias).filter { !$0.isEmpty }
        for alias in Set(aliases) where aliases.filter({ $0 == alias }).count > 1 {
            problems.append(String(localized: "More than one pass is called “\(alias)”."))
        }
        for texture in textures where texture.path.trimmingCharacters(in: .whitespaces).isEmpty {
            problems.append(String(localized: "The texture “\(texture.name)” has no image file."))
        }
        return problems
    }

    // MARK: Helpers

    private static let passOptions: Set<String> = [
        "shader", "alias", "filter_linear", "wrap_mode", "mipmap_input", "float_framebuffer", "srgb_framebuffer",
        "frame_count_mod", "scale_type", "scale_type_x", "scale_type_y", "scale", "scale_x", "scale_y",
    ]

    /// "scale_type_x12" → ("scale_type_x", 12); nil for keys that aren't pass options.
    static func passKey(_ key: String) -> (name: String, index: Int)? {
        let digits = key.reversed().prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count < key.count, let index = Int(String(digits.reversed())) else { return nil }
        let name = String(key.dropLast(digits.count))
        return passOptions.contains(name) ? (name, index) : nil
    }

    private static func bool(_ text: String) -> Bool? {
        switch text.lowercased() {
        case "true", "1": true
        case "false", "0": false
        default: nil
        }
    }
}

/// Key/value pairs in first-seen order; setting a key again replaces its value in place.
nonisolated private struct OrderedEntries {
    private(set) var pairs: [(key: String, value: String)] = []
    private var indices: [String: Int] = [:]

    subscript(key: String) -> String? {
        get { indices[key].map { pairs[$0].value } }
        set {
            guard let newValue else { return }
            if let index = indices[key] {
                pairs[index].value = newValue
            } else {
                indices[key] = pairs.count
                pairs.append((key, newValue))
            }
        }
    }
}
