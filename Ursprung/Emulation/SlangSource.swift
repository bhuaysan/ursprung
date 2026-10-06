// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// What the shader editor reads from `.slang` source itself: declared
/// parameters (librashader reports a preset's values, not the shader's
/// own), `#include` files and compile errors.
nonisolated enum SlangSource {
    /// A `#pragma parameter NAME "Label" initial minimum maximum [step]` line.
    struct Parameter: Hashable, Sendable {
        let name: String
        let label: String
        let initial: Float
        let minimum: Float
        let maximum: Float
        let step: Float
    }

    static func parameters(in text: String) -> [Parameter] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            var rest = line.drop { $0 == " " || $0 == "\t" }
            guard rest.hasPrefix("#pragma") else { return nil }
            rest = rest.dropFirst("#pragma".count).drop { $0 == " " || $0 == "\t" }
            guard rest.hasPrefix("parameter") else { return nil }
            rest = rest.dropFirst("parameter".count)
            let name = rest.drop { $0 == " " || $0 == "\t" }.prefix { $0 != " " && $0 != "\t" }
            rest = rest.drop { $0 == " " || $0 == "\t" }.dropFirst(name.count)
            guard !name.isEmpty, let open = rest.firstIndex(of: "\"") else { return nil }
            let afterOpen = rest[rest.index(after: open)...]
            guard let close = afterOpen.firstIndex(of: "\"") else { return nil }
            let label = String(afterOpen[..<close]).trimmingCharacters(in: .whitespaces)
            let numbers = afterOpen[afterOpen.index(after: close)...].split(whereSeparator: { $0 == " " || $0 == "\t" })
                .prefix(4).compactMap { Float($0) }
            guard numbers.count >= 3 else { return nil }
            return Parameter(name: String(name), label: label, initial: numbers[0], minimum: numbers[1],
                             maximum: numbers[2], step: numbers.count > 3 ? numbers[3] : 0)
        }
    }

    /// Paths of `#include "…"` lines, as written.
    static func includes(in text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("#include") else { return nil }
            let parts = trimmed.split(separator: "\"", omittingEmptySubsequences: false)
            return parts.count >= 3 ? String(parts[1]) : nil
        }
    }

    /// The shader at `url` and every file it includes, depth first, each once.
    static func closure(of url: URL) -> [URL] {
        var files: [URL] = []
        var visited: Set<String> = []
        func visit(_ url: URL, depth: Int) {
            guard depth < 32, visited.insert(url.path(percentEncoded: false)).inserted else { return }
            files.append(url)
            guard let data = try? Data(contentsOf: url) else { return }
            for include in includes(in: String(decoding: data, as: UTF8.self)) {
                if let file = SlangPresetFile.resolve(include, from: url),
                   FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) {
                    visit(file, depth: depth + 1)
                }
            }
        }
        visit(url.standardizedFileURL, depth: 0)
        return files
    }

    // MARK: Order

    /// The names of the parameters the passes of the preset at `url`
    /// declare, pass by pass in the order the shaders declare them, each
    /// once. librashader lists a preset's parameters in an order of its own.
    static func declarationOrder(ofPresetAt url: URL,
                                 wildcards: [String: String] = SlangPreset.defaultWildcards) -> [String] {
        guard let preset = try? SlangPreset.load(from: url, wildcards: wildcards) else { return [] }
        var names: [String] = []
        var seen: Set<String> = []
        var read: Set<String> = []
        for pass in preset.passes where pass.shader.hasPrefix("/") {
            for file in closure(of: URL(filePath: pass.shader)) where read.insert(file.path(percentEncoded: false)).inserted {
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                for parameter in parameters(in: text) where seen.insert(parameter.name).inserted {
                    names.append(parameter.name)
                }
            }
        }
        return names
    }

    /// `items` in the order of `names`; items whose name it lacks follow, in their own order.
    static func sorted<Item>(_ items: [Item], by names: [String], name: (Item) -> String) -> [Item] {
        let rank = Dictionary(names.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return items.enumerated()
            .map { (rank: rank[name($0.element)] ?? names.count + $0.offset, item: $0.element) }
            .sorted { $0.rank < $1.rank }
            .map(\.item)
    }

    // MARK: Errors

    /// A compile error glslang reported for a line of a shader or include file.
    struct Diagnostic: Hashable, Sendable {
        /// The file's name without folder, as glslang reports it.
        let fileName: String
        /// 1-based.
        let line: Int
        let message: String
    }

    /// The `ERROR: <file name>:<line>: <message>` lines of a librashader
    /// error, in order and without repeats.
    static func diagnostics(in message: String) -> [Diagnostic] {
        var found: [Diagnostic] = []
        // librashader's message is a Rust debug dump: newlines may be escaped.
        let text = message.replacing("\\n", with: "\n").replacing("\\\"", with: "\"")
        for line in text.split(whereSeparator: \.isNewline) {
            var rest = Substring(line)
            while let range = rest.range(of: "ERROR: ") {
                rest = rest[range.upperBound...]
                let parts = rest.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
                guard parts.count == 3, let number = Int(parts[1].trimmingCharacters(in: .whitespaces)),
                      !parts[0].isEmpty else { continue }
                var text = parts[2].trimmingCharacters(in: .whitespaces)
                // The next error may follow on the same line.
                if let next = text.range(of: "ERROR: ") { text = String(text[..<next.lowerBound]) }
                // Debug dump punctuation after the last message.
                while let last = text.last, " \")]},".contains(last) { text.removeLast() }
                let diagnostic = Diagnostic(fileName: String(parts[0]).trimmingCharacters(in: .whitespaces),
                                            line: number, message: text)
                if !found.contains(diagnostic) { found.append(diagnostic) }
            }
        }
        return found
    }

    /// The first line of a librashader error that isn't a debug dump, for
    /// errors without file and line (a preset key, a missing file).
    static func summary(of message: String) -> String {
        let firstLine = message.split(whereSeparator: \.isNewline).first.map(String.init) ?? message
        return String(firstLine.prefix(400))
    }

    // MARK: Templates

    /// A new pass: passes its input through unchanged, with one parameter to start from.
    static let template = """
        #version 450

        #pragma parameter BRIGHTNESS "Brightness" 1.0 0.0 2.0 0.05

        layout(push_constant) uniform Push {
            vec4 SourceSize;
            vec4 OutputSize;
            uint FrameCount;
            float BRIGHTNESS;
        } params;

        layout(std140, set = 0, binding = 0) uniform UBO {
            mat4 MVP;
        } global;

        #pragma stage vertex
        layout(location = 0) in vec4 Position;
        layout(location = 1) in vec2 TexCoord;
        layout(location = 0) out vec2 vTexCoord;

        void main() {
            gl_Position = global.MVP * Position;
            vTexCoord = TexCoord;
        }

        #pragma stage fragment
        layout(location = 0) in vec2 vTexCoord;
        layout(location = 0) out vec4 FragColor;
        layout(set = 0, binding = 2) uniform sampler2D Source;

        void main() {
            FragColor = vec4(texture(Source, vTexCoord).rgb * params.BRIGHTNESS, 1.0);
        }

        """
}
