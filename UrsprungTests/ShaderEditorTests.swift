// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Metal
import Testing
@testable import Ursprung

private func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
}

@Suite("Shader editor: presets")
struct SlangPresetTests {
    private let full = """
        # comment
        shaders = "2"
        shader0 = "shaders/first.slang"
        alias0 = "FirstPass"
        filter_linear0 = "true"
        wrap_mode0 = "mirrored_repeat"
        mipmap_input0 = "1"
        float_framebuffer0 = "false"
        srgb_framebuffer0 = true
        frame_count_mod0 = "120"
        scale_type0 = "source"
        scale0 = "2.0"
        shader1 = shaders/second.slang
        scale_type_x1 = absolute
        scale_type_y1 = viewport
        scale_x1 = 640
        scale_y1 = "1.000000"
        textures = "MASK;LUT"
        MASK = "textures/mask.png"
        MASK_linear = "true"
        MASK_wrap_mode = "repeat"
        MASK_mipmap = "false"
        LUT = textures/lut.png
        feedback_pass = "0"
        STRENGTH = "0.8"
        """

    @Test func readsEveryPassAndTextureOption() throws {
        let preset = SlangPreset(text: full)
        #expect(preset.passes.count == 2)
        let first = try #require(preset.passes.first)
        #expect(first.shader == "shaders/first.slang")
        #expect(first.alias == "FirstPass")
        #expect(first.filterLinear == true && first.mipmapInput == true)
        #expect(first.floatFramebuffer == false && first.srgbFramebuffer == true)
        #expect(first.wrapMode == .mirroredRepeat)
        #expect(first.frameCountMod == 120)
        #expect(first.scaleTypeX == .source && first.scaleTypeY == .source)
        #expect(first.scaleX == 2 && first.scaleY == 2)
        let second = preset.passes[1]
        #expect(second.scaleTypeX == .absolute && second.scaleTypeY == .viewport)
        #expect(second.scaleX == 640 && second.scaleY == 1)
        #expect(second.filterLinear == nil && second.alias == nil)

        #expect(preset.textures.map(\.name) == ["MASK", "LUT"])
        #expect(preset.textures[0].path == "textures/mask.png")
        #expect(preset.textures[0].linear == true && preset.textures[0].wrapMode == .repeat && preset.textures[0].mipmap == false)
        #expect(preset.textures[1].linear == nil)
        #expect(preset.values == [.init(name: "feedback_pass", value: "0"), .init(name: "STRENGTH", value: "0.8")])
        #expect(preset.problems.isEmpty)
    }

    @Test func writesWhatItReads() {
        let preset = SlangPreset(text: full)
        let text = preset.text()
        #expect(text.hasPrefix("shaders = \"2\"\n\nshader0 = \"shaders/first.slang\"\nalias0 = \"FirstPass\"\n"))
        #expect(text.contains("scale_type0 = \"source\"\nscale0 = \"2\"\n"))
        #expect(text.contains("scale_type_x1 = \"absolute\"\nscale_type_y1 = \"viewport\"\nscale_x1 = \"640\"\nscale_y1 = \"1\"\n"))
        #expect(text.hasSuffix("feedback_pass = \"0\"\nSTRENGTH = \"0.8\"\n"))
        #expect(SlangPreset(text: text).text() == text)
    }

    @Test func keepsValuesItDoesNotUnderstand() {
        let preset = SlangPreset(text: "shaders = 1\nshader0 = a.slang\nwrap_mode0 = sideways\nscale0 = big\n")
        #expect(preset.passes[0].wrapMode == nil && preset.passes[0].scaleX == nil)
        #expect(preset.values.map(\.name) == ["wrap_mode0", "scale0"])
        #expect(SlangPreset(text: preset.text()).values == preset.values)
    }

    @Test func findsProblemsLibrashaderIgnores() {
        let preset = SlangPreset(text: "shaders = 3\nshader0 = a.slang\nalias0 = X\nshader2 = b.slang\nalias2 = X\n")
        #expect(preset.problems.count == 2)
    }

    @Test func parameterValuesCanBeSetAndRemoved() {
        var preset = SlangPreset(text: "shaders = 1\nshader0 = a.slang\nA = 1\n")
        preset.setValue("2", of: "A")
        preset.setValue("3", of: "B")
        #expect(preset.value(of: "A") == "2" && preset.value(of: "B") == "3")
        preset.setValue(nil, of: "A")
        #expect(preset.values.map(\.name) == ["B"])
    }

    @Test func loadingResolvesReferencesWithAbsolutePaths() throws {
        let folder = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try write("shaders = 2\nshader0 = shaders/a.slang\nshader1 = shaders/b.slang\nfilter_linear1 = false\ntextures = MASK\nMASK = mask.png\nSTRENGTH = 0.5\n",
                  to: folder.appending(path: "base/base.slangp"))
        try write("#reference \"../base/base.slangp\"\nfilter_linear1 = true\nSTRENGTH = 0.9\nTINT = 0.1\n",
                  to: folder.appending(path: "mine/mine.slangp"))

        let preset = try SlangPreset.load(from: folder.appending(path: "mine/mine.slangp"))
        #expect(preset.references.isEmpty)
        #expect(preset.passes.map(\.shader) == [folder.appending(path: "base/shaders/a.slang").standardizedFileURL.path,
                                                folder.appending(path: "base/shaders/b.slang").standardizedFileURL.path])
        #expect(preset.passes[1].filterLinear == true)
        #expect(preset.textures.first?.path == folder.appending(path: "base/mask.png").standardizedFileURL.path)
        #expect(preset.values == [.init(name: "STRENGTH", value: "0.9"), .init(name: "TINT", value: "0.1")])

        // Written elsewhere, the paths become relative to the new place.
        let text = preset.text(relativeTo: folder.appending(path: "mine", directoryHint: .isDirectory))
        #expect(text.contains("shader0 = \"../base/shaders/a.slang\""))
        #expect(text.contains("MASK = \"../base/mask.png\""))

        try write("#reference \"missing.slangp\"\n", to: folder.appending(path: "broken.slangp"))
        #expect(throws: SlangPreset.LoadError.self) { try SlangPreset.load(from: folder.appending(path: "broken.slangp")) }
    }

    /// Reads, writes and resolves every preset of the real libretro pack and
    /// checks with librashader that the written preset means the same:
    /// `TEST_RUNNER_URSPRUNG_SHADER_PACK=<shaders_slang.zip> make test`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["URSPRUNG_SHADER_PACK"] != nil))
    func everyPackPresetRoundTrips() throws {
        let archive = URL(filePath: try #require(ProcessInfo.processInfo.environment["URSPRUNG_SHADER_PACK"]))
        let folder = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try ZipArchive(url: archive).extractAll(to: folder, concurrently: true)

        let presets = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "slangp" }
        var differences: [String] = []
        var checked = 0
        for url in presets {
            let text = try String(contentsOf: url, encoding: .utf8)
            let written = SlangPreset(text: text).text()
            if SlangPreset(text: written).text() != written { differences.append("\(url.lastPathComponent): text") }

            // Same parameters (names and values) from the original and from
            // the resolved preset written next to it.
            // Some lines lack their "=": librashader then skips the next line
            // too, the editor only that one.
            let isMalformed = text.split(whereSeparator: \.isNewline).contains { line in
                let line = line.trimmingCharacters(in: .whitespaces)
                return !line.isEmpty && !line.hasPrefix("#") && !line.hasPrefix("//") && !line.contains("=")
            }
            guard !isMalformed, let original = try? ShaderPreset.parametersOfPreset(atPath: url.path) else { continue }
            guard let resolved = try? SlangPreset.load(from: url) else {
                differences.append("\(url.lastPathComponent): load")
                continue
            }
            let copy = url.deletingLastPathComponent().appending(path: ".roundtrip-\(url.lastPathComponent)")
            try resolved.text(relativeTo: url.deletingLastPathComponent()).write(to: copy, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: copy) }
            let again = try? ShaderPreset.parametersOfPreset(atPath: copy.path)
            if again?.map(\.name) != original.map(\.name) || again?.map(\.initial) != original.map(\.initial) {
                let mismatch = zip(original, again ?? []).first { $0.name != $1.name || $0.initial != $1.initial }
                    .map { "\($0.name)=\($0.initial) → \($1.name)=\($1.initial)" } ?? "count \(original.count) → \(again?.count ?? -1)"
                differences.append("\(url.lastPathComponent): parameters, \(mismatch)")
            }
            // Wildcard examples have no pass count without their wildcards filled in.
            if let passes = SlangPresetFile.passCount(of: url), resolved.passes.count != passes {
                differences.append("\(url.lastPathComponent): passes")
            }
            checked += 1
        }
        print("Shader pack round trip: \(presets.count) presets, \(checked) checked with librashader, \(differences.count) differences")
        for difference in differences.prefix(60) { print("  \(difference)") }
        #expect(presets.count > 2000 && checked > 2500)
        #expect(differences.isEmpty)
    }
}

@Suite("Shader editor: source")
struct SlangSourceTests {
    @Test func readsParameterPragmas() {
        let parameters = SlangSource.parameters(in: """
            #pragma parameter STRENGTH "  Effect Strength" 0.5 0.0 1.0 0.05
              #pragma parameter HEADER "--- Section ---" 0 0 0
            #pragma parameter NOSTEP "No step" 1 0 2
            #pragma parameter BROKEN "Broken"
            // #pragma parameter COMMENTED "x" 1 0 1 1
            """)
        #expect(parameters.map(\.name) == ["STRENGTH", "HEADER", "NOSTEP"])
        #expect(parameters[0].label == "Effect Strength" && parameters[0].initial == 0.5 && parameters[0].step == 0.05)
        #expect(parameters[2].step == 0)
    }

    @Test func followsIncludes() throws {
        let folder = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try write("#include \"../include/common.h\"\n#include \"local.inc\"\n#include \"missing.h\"\n",
                  to: folder.appending(path: "shaders/pass.slang"))
        try write("#include \"deeper.h\"\n", to: folder.appending(path: "include/common.h"))
        try write("// nothing\n", to: folder.appending(path: "include/deeper.h"))
        try write("#include \"../include/common.h\"\n", to: folder.appending(path: "shaders/local.inc"))

        let files = SlangSource.closure(of: folder.appending(path: "shaders/pass.slang")).map(\.lastPathComponent)
        #expect(files == ["pass.slang", "common.h", "deeper.h", "local.inc"])
    }

    @Test func listsParametersInDeclarationOrder() throws {
        let folder = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try write("#pragma parameter ZOOM \"Zoom\" 1 0 2 0.1\n#include \"common.h\"\n#pragma parameter ALPHA \"Alpha\" 1 0 1 0.1\n",
                  to: folder.appending(path: "first.slang"))
        try write("#pragma parameter MASK \"Mask\" 1 0 3 1\n", to: folder.appending(path: "common.h"))
        try write("#include \"common.h\"\n#pragma parameter BLUR \"Blur\" 0 0 1 0.1\n#pragma parameter ZOOM \"Zoom\" 1 0 2 0.1\n",
                  to: folder.appending(path: "second.slang"))
        try write("shaders = 2\nshader0 = first.slang\nshader1 = second.slang\n", to: folder.appending(path: "two.slangp"))

        let order = SlangSource.declarationOrder(ofPresetAt: folder.appending(path: "two.slangp"))
        #expect(order == ["ZOOM", "ALPHA", "MASK", "BLUR"])
        #expect(SlangSource.sorted(["UNKNOWN", "BLUR", "MASK", "OTHER", "ZOOM"], by: order, name: { $0 })
                == ["ZOOM", "MASK", "BLUR", "UNKNOWN", "OTHER"])
        #expect(SlangSource.declarationOrder(ofPresetAt: folder.appending(path: "missing.slangp")).isEmpty)
    }

    @Test func readsCompileErrorsFromLibrashader() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeShaderFixtures(in: directory)
        try dimShader.replacingOccurrences(of: "params.STRENGTH;", with: "params.STRENGTH")
            .write(to: directory.appending(path: "dim.slang"), atomically: true, encoding: .utf8)
        let queue = try #require(MTLCreateSystemDefaultDevice()?.makeCommandQueue())

        var message = ""
        do {
            _ = try ShaderChain(presetAtPath: directory.appending(path: "dim.slangp").path, queue: queue, coreName: nil,
                                rotation: 0)
        } catch {
            message = error.localizedDescription
        }
        let diagnostics = SlangSource.diagnostics(in: message)
        let first = try #require(diagnostics.first, "No line in: \(message)")
        #expect(first.fileName == "dim.slang")
        // The missing semicolon is reported on the line after it (the closing brace).
        let lines = dimShader.split(separator: "\n", omittingEmptySubsequences: false)
        let statement = try #require(lines.firstIndex { $0.contains("params.STRENGTH;") }) + 1
        #expect((statement...statement + 1).contains(first.line), "\(diagnostics)")
        #expect(!first.message.isEmpty && !first.message.hasPrefix("ERROR"))
    }

    @Test func readsSeveralErrorsOnEscapedLines() {
        let message = #"Compile(Vertex(Err("ERROR: crt.slang:12: 'x' : undeclared identifier\nERROR: common.h:3: '' : syntax error\nERROR: 2 compilation errors.\n")))"#
        #expect(SlangSource.diagnostics(in: message) == [
            .init(fileName: "crt.slang", line: 12, message: "'x' : undeclared identifier"),
            .init(fileName: "common.h", line: 3, message: "'' : syntax error"),
        ])
    }

    @Test func colorsCommentsPragmasAndWords() {
        let text = """
            #version 450
            #pragma parameter A "Label" 1.0 0.0 2.0 0.1
            #include "inc.h"
            /* block
               comment */ vec4 x = texture(Source, uv) * 2.5e-1; // done
            #pragma optimize(on)
            """
        let tokens = SlangTokenizer.tokens(in: text)
        let source = text as NSString
        let found = tokens.map { (kind: $0.kind, text: source.substring(with: $0.range)) }
        func has(_ kind: SlangTokenizer.Kind, _ text: String) -> Bool { found.contains { $0.kind == kind && $0.text == text } }
        #expect(has(.directive, "#version"))
        #expect(has(.number, "450"))
        #expect(has(.pragma, "#pragma parameter"))
        #expect(has(.string, "\"Label\""))
        #expect(has(.pragma, "#include"))
        #expect(has(.string, "\"inc.h\""))
        #expect(has(.comment, "/* block\n   comment */"))
        #expect(has(.type, "vec4"))
        #expect(has(.builtin, "texture"))
        #expect(has(.number, "2.5e-1"))
        #expect(has(.comment, "// done"))
        #expect(has(.directive, "#pragma"))
        #expect(!found.contains { $0.text == "Source" || $0.text == "x" })
    }
}

@Suite("Shader editor: drafts")
struct ShaderDraftTests {
    /// `Shaders/` with a pack preset whose pass includes a shared file.
    private func makeShaders() throws -> (root: URL, pack: URL, user: URL, drafts: URL) {
        let root = try makeTemporaryDirectory()
        let pack = root.appending(path: "slang-shaders", directoryHint: .isDirectory)
        let user = root.appending(path: "User", directoryHint: .isDirectory)
        let drafts = root.appending(path: "Drafts", directoryHint: .isDirectory)
        try write(dimShader.replacing("#version 450", with: "#version 450\n#include \"../../include/common.h\""),
                  to: pack.appending(path: "crt/shaders/dim.slang"))
        try write("// common\n", to: pack.appending(path: "include/common.h"))
        try write("shaders = 1\nshader0 = shaders/dim.slang\nscale_type0 = viewport\nSTRENGTH = 0.7\n",
                  to: pack.appending(path: "crt/dim.slangp"))
        try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
        return (root, pack, user, drafts)
    }

    @Test func createsADraftThatCompilesFromItsOwnFolder() throws {
        let (root, pack, _, drafts) = try makeShaders()
        defer { try? FileManager.default.removeItem(at: root) }
        let origin = try #require(ShaderPresetRef(source: .library, path: "crt/dim.slangp"))

        let (info, preset) = try ShaderDrafts.create(from: pack.appending(path: "crt/dim.slangp"), name: "dim",
                                                     origin: origin, target: origin, in: drafts)
        #expect(info.originPreset == origin && info.target == nil, "Pack presets are never a save target")
        #expect(preset.passes.count == 1 && preset.value(of: "STRENGTH") == "0.7")
        let text = try String(contentsOf: ShaderDrafts.presetURL(info.id, in: drafts), encoding: .utf8)
        #expect(text.contains("shader0 = \"../../slang-shaders/crt/shaders/dim.slang\""))
        #expect(try ShaderPreset.parametersOfPreset(atPath: ShaderDrafts.presetURL(info.id, in: drafts).path).first?.initial == 0.7)

        let (loaded, loadedPreset) = try ShaderDrafts.load(info.id, in: drafts)
        #expect(loaded.id == info.id && loadedPreset.text() == preset.text())
        #expect(ShaderDrafts.latest(in: drafts) == info.id)
    }

    @Test func copiesAShaderWithItsIncludesBeforeTheFirstChange() throws {
        let (root, pack, user, drafts) = try makeShaders()
        defer { try? FileManager.default.removeItem(at: root) }
        var (info, preset) = try ShaderDrafts.create(from: pack.appending(path: "crt/dim.slangp"), name: "dim",
                                                     origin: nil, target: nil, in: drafts)
        let original = URL(filePath: preset.passes[0].shader)

        let copy = try ShaderDrafts.ownCopy(of: original, info: &info, in: drafts, library: pack, user: user)
        #expect(copy.path.hasSuffix("files/library/crt/shaders/dim.slang"))
        #expect(info.files.map(\.path) == ["library/crt/shaders/dim.slang", "library/include/common.h"])
        #expect(info.files.first?.origin == original.path)
        #expect(ShaderDrafts.isOwn(copy, id: info.id, in: drafts))
        // A second copy keeps the first (it may have changes) and adds nothing.
        try "changed".write(to: copy, atomically: true, encoding: .utf8)
        #expect(try ShaderDrafts.ownCopy(of: original, info: &info, in: drafts, library: pack, user: user) == copy)
        #expect(try String(contentsOf: copy, encoding: .utf8) == "changed")
        #expect(info.files.count == 2)
        #expect(try ShaderDrafts.ownCopy(of: copy, info: &info, in: drafts, library: pack, user: user) == copy)

        // The pack is untouched, and the copy still compiles with its include.
        try dimShader.replacing("#version 450", with: "#version 450\n#include \"../../include/common.h\"")
            .write(to: copy, atomically: true, encoding: .utf8)
        #expect(try String(contentsOf: original, encoding: .utf8).contains("#include"))
        preset.passes[0].shader = copy.path
        try ShaderDrafts.write(preset, info: info, in: drafts)
        let queue = try #require(MTLCreateSystemDefaultDevice()?.makeCommandQueue())
        _ = try ShaderChain(presetAtPath: ShaderDrafts.presetURL(info.id, in: drafts).path, queue: queue, coreName: nil,
                            rotation: 0)

        let new = try ShaderDrafts.newShader(named: "My Pass", info: &info, in: drafts)
        #expect(new.lastPathComponent == "My Pass.slang")
        #expect(try ShaderDrafts.newShader(named: "My Pass", info: &info, in: drafts).lastPathComponent == "My Pass 2.slang")
    }

    @Test func savesOwnFilesNextToThePreset() throws {
        let (root, pack, user, drafts) = try makeShaders()
        defer { try? FileManager.default.removeItem(at: root) }
        var (info, preset) = try ShaderDrafts.create(from: pack.appending(path: "crt/dim.slangp"), name: "dim",
                                                     origin: nil, target: nil, in: drafts)
        let copy = try ShaderDrafts.ownCopy(of: URL(filePath: preset.passes[0].shader), info: &info, in: drafts,
                                            library: pack, user: user)
        preset.passes[0].shader = copy.path
        preset.passes.append(SlangPreset.Pass(shader: pack.appending(path: "crt/shaders/dim.slang").path))
        let target = user.appending(path: "Mine.slangp")

        try ShaderDrafts.save(preset, info: info, to: target, inPlace: false, in: drafts, user: user)
        let text = try String(contentsOf: target, encoding: .utf8)
        #expect(text.contains("shader0 = \"Mine/crt/shaders/dim.slang\""))
        #expect(text.contains("shader1 = \"../slang-shaders/crt/shaders/dim.slang\""))
        #expect(FileManager.default.fileExists(atPath: user.appending(path: "Mine/include/common.h").path))
        #expect(try ShaderPreset.parametersOfPreset(atPath: target.path).first?.initial == 0.7)

        // Saving in place writes copies of user files back where they came from.
        var (again, reopened) = try ShaderDrafts.create(from: target, name: "Mine", origin: nil,
                                                        target: ShaderPresetRef(source: .user, path: "Mine.slangp"),
                                                        in: drafts)
        #expect(again.target == "Mine.slangp")
        let userCopy = try ShaderDrafts.ownCopy(of: URL(filePath: reopened.passes[0].shader), info: &again, in: drafts,
                                                library: pack, user: user)
        #expect(userCopy.path.hasSuffix("files/user/Mine/crt/shaders/dim.slang"))
        try (dimShader + "\n// edited\n").write(to: userCopy, atomically: true, encoding: .utf8)
        reopened.passes[0].shader = userCopy.path
        try ShaderDrafts.save(reopened, info: again, to: target, inPlace: true, in: drafts, user: user)
        #expect(try String(contentsOf: user.appending(path: "Mine/crt/shaders/dim.slang"), encoding: .utf8).hasSuffix("// edited\n"))
        #expect(try String(contentsOf: target, encoding: .utf8).contains("shader0 = \"Mine/crt/shaders/dim.slang\""))
        #expect(!FileManager.default.fileExists(atPath: user.appending(path: "Mine/Mine").path))
    }

    @Test func savesFilesOfTheSameNameFromThePackAndTheUserApart() throws {
        let (root, pack, user, drafts) = try makeShaders()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(dimShader, to: user.appending(path: "crt/shaders/dim.slang"))
        var (info, preset) = try ShaderDrafts.create(from: pack.appending(path: "crt/dim.slangp"), name: "dim",
                                                     origin: nil, target: nil, in: drafts)
        preset.passes.append(SlangPreset.Pass(shader: user.appending(path: "crt/shaders/dim.slang").path))
        for (index, marker) in ["// pack", "// user"].enumerated() {
            let copy = try ShaderDrafts.ownCopy(of: URL(filePath: preset.passes[index].shader), info: &info, in: drafts,
                                                library: pack, user: user)
            try (String(contentsOf: copy, encoding: .utf8) + "\n\(marker)\n").write(to: copy, atomically: true, encoding: .utf8)
            preset.passes[index].shader = copy.path
        }
        let target = user.appending(path: "Mixed.slangp")

        try ShaderDrafts.save(preset, info: info, to: target, inPlace: false, in: drafts, user: user)
        let saved = try SlangPreset.load(from: target)
        #expect(saved.passes.count == 2 && saved.passes[0].shader != saved.passes[1].shader)
        #expect(try String(contentsOf: URL(filePath: saved.passes[0].shader), encoding: .utf8).hasSuffix("// pack\n"))
        #expect(try String(contentsOf: URL(filePath: saved.passes[1].shader), encoding: .utf8).hasSuffix("// user\n"))
        // Each keeps its layout, so the pack shader's include still resolves.
        #expect(FileManager.default.fileExists(atPath: user.appending(path: "Mixed/library/include/common.h").path))
        #expect(try ShaderPreset.parametersOfPreset(atPath: target.path).first?.initial == 0.7)
    }

    @Test func exportsAPresetThatWorksOnItsOwn() throws {
        let (root, pack, _, drafts) = try makeShaders()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("shaders = 1\nshader0 = shaders/dim.slang\ntextures = MASK\nMASK = mask.png\n",
                  to: pack.appending(path: "crt/masked.slangp"))
        try write("png", to: pack.appending(path: "crt/mask.png"))
        let destination = root.appending(path: "Export/Masked", directoryHint: .isDirectory)

        let exported = try ShaderDrafts.export(pack.appending(path: "crt/masked.slangp"), named: "Masked", to: destination)
        #expect(exported.lastPathComponent == "Masked.slangp")
        let text = try String(contentsOf: exported, encoding: .utf8)
        #expect(text.contains("shader0 = \"crt/shaders/dim.slang\""))
        #expect(text.contains("MASK = \"crt/mask.png\""))
        #expect(FileManager.default.fileExists(atPath: destination.appending(path: "include/common.h").path))
        _ = drafts
    }
}

@Suite("Shader editor: sources")
struct ShaderEditorSourceTests {
    @Test func aReplacedShaderLeavesTheOldFileAlone() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let shaders = ShaderLibrary(root: root.appending(path: "Shaders", directoryHint: .isDirectory),
                                    defaults: UserDefaults(suiteName: "UrsprungTests.ShaderEditor.\(UUID().uuidString)")!)
        let original = shaders.libraryDirectory.appending(path: "crt/shaders/dim.slang")
        try write(dimShader, to: original)
        try write("shaders = 1\nshader0 = shaders/dim.slang\n", to: shaders.libraryDirectory.appending(path: "crt/dim.slangp"))
        let other = root.appending(path: "Elsewhere/other.slang")
        try write(dimShader, to: other)
        let session = EmulationSession(cores: CoreManager(coresDirectory: root, systemDirectory: root),
                                       bios: BIOSManager(systemDirectory: root), achievements: AchievementService())
        let editor = ShaderEditor(session: session, shaders: shaders)
        editor.openPreset(try #require(ShaderPresetRef(source: .library, path: "crt/dim.slangp")))
        let pass = try #require(editor.selectedPassID)
        #expect(editor.tabs.map(\.url) == [original.standardizedFileURL])

        // Choose Another Shader: the old shader's tab closes, the new one opens.
        editor.updatePass(pass) { $0.shader = other.path }
        #expect(editor.tabs.map(\.url) == [other.standardizedFileURL])

        // A tab of a file the pass no longer reads never writes to it.
        editor.openSource(original, for: pass)
        let stale = try #require(editor.selectedTabID)
        #expect(editor.sourceChanged(stale, text: "broken") == nil)
        #expect(try String(contentsOf: original, encoding: .utf8) == dimShader)

        // The pass's own tab edits a copy in the draft.
        let tab = try #require(editor.tabs.first { $0.url == other.standardizedFileURL })
        let copy = try #require(editor.sourceChanged(tab.id, text: dimShader + "\n// edited\n"))
        #expect(copy != other.standardizedFileURL)
        #expect(editor.selectedPass.map { URL(filePath: $0.shader).standardizedFileURL } == copy)
        #expect(try String(contentsOf: other, encoding: .utf8) == dimShader)
    }
}

@Suite("Shader editor: still pictures")
struct StillPictureTests {
    @Test func testPatternsHaveTheirSizeAndShape() {
        for pattern in ShaderTestPattern.allCases {
            for size in ShaderTestPattern.sizes {
                let picture = pattern.picture(width: size.width, height: size.height)
                #expect(picture.pixels.count == size.width * size.height)
                #expect(picture.aspectRatio == (size.width == 160 ? 10.0 / 9.0 : 4.0 / 3.0))
            }
        }
        // Not a blank picture: colour bars have several colours.
        let bars = ShaderTestPattern.colorBars.picture(width: 256, height: 224)
        #expect(Set(bars.pixels).count > 7)
        #expect(bars.pixels.allSatisfy { $0 >> 24 == 0xFF })
    }

    @Test func capturedFramesKeepTheirAspectRatio() throws {
        let extras = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: extras) }
        let gameID = UUID()
        let picture = ShaderTestPattern.pixelGrid.picture(width: 256, height: 224)
        let source = try #require(cgImage(picture))
        #expect(StillPicture(image: source)?.pixels == picture.pixels)

        let url = try ShaderFrameStore.save(source, aspectRatio: 4.0 / 3.0, in: extras, gameID: gameID)
        #expect(ShaderFrameStore.frames(in: extras, gameID: gameID).map(\.lastPathComponent) == [url.lastPathComponent])
        let loaded = try #require(StillPicture.load(url))
        #expect(loaded.width == 256 && loaded.height == 224)
        #expect(abs((loaded.aspectRatio ?? 0) - 4.0 / 3.0) < 0.0001)
        #expect(loaded.pixels == picture.pixels)

        let frame = StillFrame(loaded)
        frame.isPaused = true
        let serial = frame.frameSerial
        frame.step()
        #expect(frame.frameSerial == serial + 1)
    }

    private func cgImage(_ picture: StillPicture) -> CGImage? {
        var pixels = picture.pixels
        return pixels.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: picture.width, height: picture.height, bitsPerComponent: 8,
                      bytesPerRow: picture.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)?
                .makeImage()
        }
    }
}
