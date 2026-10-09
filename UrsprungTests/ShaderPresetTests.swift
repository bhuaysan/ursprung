// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Metal
import MetalKit
import Testing
@testable import Ursprung

/// A one-pass slang shader with one parameter.
let dimShader = """
    #version 450
    #pragma parameter STRENGTH "  Effect Strength" 0.5 0.0 1.0 0.05
    layout(push_constant) uniform Push { float STRENGTH; } params;
    layout(std140, set = 0, binding = 0) uniform UBO { mat4 MVP; } global;

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
        FragColor = texture(Source, vTexCoord) * params.STRENGTH;
    }
    """

/// `dim.slangp` (the shader above) and `dim-strong.slangp`, which references
/// it with a parameter override.
func writeShaderFixtures(in directory: URL) throws {
    try dimShader.write(to: directory.appending(path: "dim.slang"), atomically: true, encoding: .utf8)
    try "shaders = 1\nshader0 = dim.slang\nscale_type0 = viewport\n"
        .write(to: directory.appending(path: "dim.slangp"), atomically: true, encoding: .utf8)
    try "#reference \"dim.slangp\"\nSTRENGTH = \"0.8\"\n"
        .write(to: directory.appending(path: "dim-strong.slangp"), atomically: true, encoding: .utf8)
}

@Suite("Shader presets (librashader)")
struct ShaderPresetTests {

    /// `$CORE$` picks the preset of the running core, in a referenced preset
    /// too. librashader 0.12.0 drops the wildcards on one of its two ways
    /// to load a preset; `ShaderChain` takes the other for these.
    @Test func wildcardsPickTheCoresVariant() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for (core, strength) in [("CoreA", "0.2"), ("CoreB", "0.9")] {
            try dimShader.replacing("0.5 0.0 1.0", with: "\(strength) 0.0 1.0")
                .write(to: directory.appending(path: "\(core).slang"), atomically: true, encoding: .utf8)
            try "shaders = 1\nshader0 = \(core).slang\n"
                .write(to: directory.appending(path: "\(core).slangp"), atomically: true, encoding: .utf8)
        }
        try "#reference \"$CORE$.slangp\"\n".write(to: directory.appending(path: "core.slangp"), atomically: true, encoding: .utf8)
        try "#reference \"core.slangp\"\n".write(to: directory.appending(path: "outer.slangp"), atomically: true, encoding: .utf8)
        let queue = try #require(MTLCreateSystemDefaultDevice()?.makeCommandQueue())

        for (preset, core, strength) in [("core", "CoreA", Float(0.2)), ("core", "CoreB", 0.9), ("outer", "CoreB", 0.9)] {
            let chain = try ShaderChain(presetAtPath: directory.appending(path: "\(preset).slangp").path, queue: queue,
                                        coreName: core, rotation: 0)
            #expect(chain.parameters.first?.initial == strength, "\(preset) for \(core)")
        }
    }

    @Test func readsDeclaredParameters() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeShaderFixtures(in: directory)

        let parameters = try ShaderPreset.parametersOfPreset(atPath: directory.appending(path: "dim.slangp").path)
        let strength = try #require(parameters.first)
        #expect(parameters.count == 1)
        #expect(strength.name == "STRENGTH")
        #expect(strength.label == "Effect Strength")
        #expect(strength.initial == 0.5)
        #expect(strength.minimum == 0 && strength.maximum == 1)
        #expect(abs(strength.step - 0.05) < 0.0001)
    }

    @Test func referencedPresetsApplyTheirOverrides() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeShaderFixtures(in: directory)

        let parameters = try ShaderPreset.parametersOfPreset(atPath: directory.appending(path: "dim-strong.slangp").path)
        #expect(parameters.map(\.name) == ["STRENGTH"])
        #expect(parameters.first?.initial == 0.8)
    }

    @Test func missingPresetThrows() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect {
            try ShaderPreset.parametersOfPreset(atPath: directory.appending(path: "missing.slangp").path)
        } throws: { error in
            let error = error as NSError
            return error.domain == ShaderErrorDomain && !error.localizedDescription.isEmpty
        }
    }
}

/// Renders through librashader on the GPU, like the player does.
@Suite("Shader chains (librashader)")
struct ShaderChainTests {
    private let device = MTLCreateSystemDefaultDevice()!

    private func texture(width: Int, height: Int, fill: UInt32? = nil, renderTarget: Bool = false) -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height,
                                                                  mipmapped: false)
        descriptor.usage = renderTarget ? [.renderTarget, .shaderRead] : .shaderRead
        descriptor.storageMode = .shared
        let texture = device.makeTexture(descriptor: descriptor)!
        if let fill {
            let pixels = [UInt32](repeating: fill, count: width * height)
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: pixels,
                            bytesPerRow: width * 4)
        }
        return texture
    }

    /// Renders a white frame and returns the BGRA pixel in the output's middle.
    private func renderWhite(with chain: ShaderChain, queue: MTLCommandQueue) throws -> UInt32 {
        let input = texture(width: 4, height: 4, fill: 0xFFFF_FFFF)
        let output = texture(width: 12, height: 8, renderTarget: true)
        let buffer = try #require(queue.makeCommandBuffer())
        let options = ShaderFrameOptions(direction: 1, aspectRatio: 1.5, framesPerSecond: 60,
                                         frameTimeDelta: 16)
        try chain.render(input, to: output, commandBuffer: buffer, frameCount: 1, options: options)
        buffer.commit()
        buffer.waitUntilCompleted()
        var pixel: UInt32 = 0
        output.getBytes(&pixel, bytesPerRow: 12 * 4, from: MTLRegionMake2D(6, 4, 1, 1), mipmapLevel: 0)
        return pixel
    }

    @Test func rendersAPresetAndChangesParametersLive() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeShaderFixtures(in: directory)
        let queue = try #require(device.makeCommandQueue())

        let chain = try ShaderChain(presetAtPath: directory.appending(path: "dim.slangp").path, queue: queue,
                                    coreName: "Test", rotation: 0)
        #expect(chain.passCount == 1)
        #expect(chain.value(forParameter: "STRENGTH") == 0.5)
        #expect(chain.value(forParameter: "MISSING") == nil)

        // White times 0.5 is mid grey in every channel.
        let dimmed = try renderWhite(with: chain, queue: queue)
        for shift in [0, 8, 16] as [UInt32] {
            #expect((126...129).contains((dimmed >> shift) & 0xFF))
        }

        try chain.setValue(1, forParameter: "STRENGTH")
        #expect(try renderWhite(with: chain, queue: queue) & 0x00FF_FFFF == 0x00FF_FFFF)
        #expect(throws: (any Error).self) { try chain.setValue(1, forParameter: "MISSING") }
    }

    @Test func shaderErrorsNameTheFileAndLine() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeShaderFixtures(in: directory)
        try dimShader.replacingOccurrences(of: "params.STRENGTH;", with: "params.STRENGTH")
            .write(to: directory.appending(path: "dim.slang"), atomically: true, encoding: .utf8)
        let queue = try #require(device.makeCommandQueue())

        #expect {
            try ShaderChain(presetAtPath: directory.appending(path: "dim.slangp").path, queue: queue, coreName: nil,
                            rotation: 0)
        } throws: { error in
            let error = error as NSError
            return error.domain == ShaderErrorDomain && error.localizedDescription.contains("dim.slang")
        }
    }
}

/// A two-parameter shader, for presets that change only some parameters.
private let tintShader = dimShader
    .replacing("#pragma parameter STRENGTH \"  Effect Strength\" 0.5 0.0 1.0 0.05",
               with: "#pragma parameter STRENGTH \"Strength\" 0.5 0.0 1.0 0.05\n#pragma parameter TINT \"Tint\" 0.25 0.0 1.0 0.05")
    .replacing("uniform Push { float STRENGTH; }", with: "uniform Push { float STRENGTH; float TINT; }")
    .replacing("* params.STRENGTH;", with: "* params.STRENGTH + params.TINT * 0.0;")

@Suite("Saving shader presets")
struct ShaderPresetWriterTests {
    /// `Shaders/` with the pack's `slang-shaders/tint.slangp` and an empty `User/`.
    private func makeShaders() throws -> (root: URL, pack: URL, user: URL) {
        let root = try makeTemporaryDirectory()
        let pack = root.appending(path: "slang-shaders", directoryHint: .isDirectory)
        let user = root.appending(path: "User", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: pack.appending(path: "misc"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
        try tintShader.write(to: pack.appending(path: "misc/tint.slang"), atomically: true, encoding: .utf8)
        try "shaders = 1\nshader0 = tint.slang\n".write(to: pack.appending(path: "misc/tint.slangp"), atomically: true,
                                                         encoding: .utf8)
        return (root, pack, user)
    }

    private func initials(_ url: URL) throws -> [String: Float] {
        let parameters = try ShaderPreset.parametersOfPreset(atPath: url.path(percentEncoded: false))
        return Dictionary(uniqueKeysWithValues: parameters.map { ($0.name, $0.initial) })
    }

    @Test func savesOnlyChangedParametersAsAReference() throws {
        let (root, pack, user) = try makeShaders()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = user.appending(path: "Mine.slangp")

        try ShaderPresetWriter.save(["STRENGTH": 0.8, "TINT": 0.25], of: pack.appending(path: "misc/tint.slangp"), to: target)

        let text = try String(contentsOf: target, encoding: .utf8)
        #expect(text == "#reference \"../slang-shaders/misc/tint.slangp\"\nSTRENGTH = \"0.8\"\n")
        #expect(try initials(target) == ["STRENGTH": 0.8, "TINT": 0.25])
    }

    @Test func savingOverASavedPresetKeepsOneReference() throws {
        let (root, pack, user) = try makeShaders()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = user.appending(path: "Mine.slangp")
        try ShaderPresetWriter.save(["STRENGTH": 0.8], of: pack.appending(path: "misc/tint.slangp"), to: target)

        // Saved over itself: still based on the pack's preset, with both changes.
        try ShaderPresetWriter.save(["STRENGTH": 0.8, "TINT": 0.6], of: target, to: target)
        let preset = try SlangPresetFile(contentsOf: target)
        #expect(preset.references == ["../slang-shaders/misc/tint.slangp"])
        #expect(try initials(target) == ["STRENGTH": 0.8, "TINT": 0.6])

        // Back to the pack's values: only the reference remains.
        try ShaderPresetWriter.save(["STRENGTH": 0.5, "TINT": 0.25], of: target, to: target)
        #expect(try String(contentsOf: target, encoding: .utf8) == "#reference \"../slang-shaders/misc/tint.slangp\"\n")
    }

    @Test func presetsThatChangeMoreThanParametersStayTheBase() throws {
        let (root, pack, user) = try makeShaders()
        defer { try? FileManager.default.removeItem(at: root) }
        let custom = user.appending(path: "Linear.slangp")
        try "#reference \"../slang-shaders/misc/tint.slangp\"\nfilter_linear0 = true\n"
            .write(to: custom, atomically: true, encoding: .utf8)
        #expect(ShaderPresetWriter.base(of: custom) == custom.standardizedFileURL)
        #expect(ShaderPresetWriter.base(of: pack.appending(path: "misc/tint.slangp"))
                == pack.appending(path: "misc/tint.slangp").standardizedFileURL)

        // Saving over the base itself would make it reference itself.
        #expect(throws: ShaderPresetWriter.SaveError.self) {
            try ShaderPresetWriter.save(["TINT": 1], of: custom, to: custom)
        }
        let copy = user.appending(path: "Linear Tinted.slangp")
        try ShaderPresetWriter.save(["TINT": 1], of: custom, to: copy)
        #expect(try String(contentsOf: copy, encoding: .utf8) == "#reference \"Linear.slangp\"\nTINT = \"1\"\n")
    }

    @Test func formatsNamesPathsAndValues() {
        #expect(ShaderPresetWriter.format(2.4) == "2.4")
        #expect(ShaderPresetWriter.format(0.05) == "0.05")
        #expect(ShaderPresetWriter.format(3) == "3")
        #expect(ShaderPresetWriter.format(-0.0000001) == "0")
        #expect(ShaderPresetWriter.relativePath(from: URL(filePath: "/S/User/A", directoryHint: .isDirectory),
                                                to: URL(filePath: "/S/slang-shaders/crt/x.slangp")) == "../../slang-shaders/crt/x.slangp")
        #expect(ShaderPresetWriter.fileName(for: " CRT: Soft/Warm ") == "CRT- Soft-Warm.slangp")
        #expect(ShaderPresetWriter.fileName(for: "Mine.slangp") == "Mine.slangp")
        #expect(ShaderPresetWriter.fileName(for: "..") == nil)
        #expect(ShaderPresetWriter.fileName(for: "  ") == nil)
    }
}

@Suite("Shader workspace")
struct ShaderWorkspaceTests {
    @Test func tracksChangesAndResetsToThePreset() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeShaderFixtures(in: directory)
        let queue = try #require(MTLCreateSystemDefaultDevice()?.makeCommandQueue())
        let chain = try ShaderChain(presetAtPath: directory.appending(path: "dim-strong.slangp").path, queue: queue,
                                    coreName: nil, rotation: 0)
        #expect(chain.parameters.map(\.name) == ["STRENGTH"])
        #expect(chain.parameters.first?.initial == 0.8)

        let workspace = ShaderWorkspace()
        let preset = try #require(ShaderPresetRef(source: .user, path: "dim-strong.slangp"))
        var applied: [(String, Float)] = []
        workspace.compiling(preset)
        #expect(workspace.isCompiling && workspace.preset == nil)
        workspace.loaded(preset, parameters: chain.parameters, values: ["STRENGTH": 0.8], passCount: 1,
                         apply: { applied.append(($0, $1)) }, reload: {})
        #expect(workspace.preset == preset && !workspace.isModified)

        workspace.setValue(0.3, for: "STRENGTH")
        #expect(workspace.isModified && workspace.isModified("STRENGTH"))
        workspace.setValue(0.3, for: "STRENGTH")
        #expect(applied.count == 1, "An unchanged value isn't sent again")

        workspace.resetAll()
        #expect(!workspace.isModified)
        #expect(applied.last?.0 == "STRENGTH" && applied.last?.1 == 0.8)

        workspace.useBuiltin()
        #expect(workspace.status == .builtin && workspace.parameters.isEmpty)
        workspace.setValue(1, for: "STRENGTH")
        #expect(applied.count == 2, "Nothing is sent without a preset")
    }

    @Test func returningToTheShowingPresetDropsAnotherCompile() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeShaderFixtures(in: directory)
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: 8, height: 8))
        let renderer = try #require(MetalRenderer(view: view))
        renderer.presetURL = { directory.appending(path: $0.path) }
        let workspace = ShaderWorkspace()
        renderer.workspace = workspace
        let dim = try #require(ShaderPresetRef(source: .user, path: "dim.slangp"))
        let strong = try #require(ShaderPresetRef(source: .user, path: "dim-strong.slangp"))

        renderer.selection = .preset(dim)
        for _ in 0..<500 where workspace.status != .ready(dim) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(workspace.status == .ready(dim))

        // A → B → A before B finished compiling.
        renderer.selection = .preset(strong)
        renderer.selection = .preset(dim)
        #expect(workspace.status == .ready(dim))
        let count = workspace.compileCount
        for _ in 0..<200 where workspace.compileCount == count { try await Task.sleep(for: .milliseconds(10)) }
        #expect(workspace.status == .ready(dim), "B's compile doesn't replace A")
        #expect(workspace.values["STRENGTH"] == 0.5)
    }

    /// A picture whose core name can change, as when another game starts.
    private final class NamedSource: FrameSource {
        var libraryName: String
        var rotation = 0
        let frameSerial: UInt64 = 1
        let aspectRatio: Float = 1
        let framesPerSecond: Double = 60
        init(_ name: String) { libraryName = name }
        func accessLatestFrame(_ block: (UnsafeRawPointer, Int, Int, Int) -> Void) -> Bool {
            var pixel: UInt32 = 0xFF80_8080
            withUnsafeBytes(of: &pixel) { block($0.baseAddress!, 1, 1, 4) }
            return true
        }
    }

    /// `$CORE$` and `$CORE-REQ-ROT$` pick a preset's variant: a compile for
    /// one core or rotation isn't used for another, and the showing preset
    /// follows them (B7 of the 2026-10-07 re-review).
    @Test func presetsFollowTheCoreAndRotationTheyAreCompiledFor() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeShaderFixtures(in: directory)
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: 8, height: 8))
        let renderer = try #require(MetalRenderer(view: view))
        var started = 0
        renderer.presetURL = { started += 1; return directory.appending(path: $0.path) }
        let workspace = ShaderWorkspace()
        renderer.workspace = workspace
        let source = NamedSource("CoreA")
        renderer.source = source
        let preset = try #require(ShaderPresetRef(source: .user, path: "dim.slangp"))
        func waitForCompiles(_ count: Int) async throws {
            for _ in 0..<500 where started < count || workspace.status != .ready(preset) {
                try await Task.sleep(for: .milliseconds(10))
            }
        }

        // The core changes while its compile runs: compiled again for the new one.
        renderer.selection = .preset(preset)
        source.libraryName = "CoreB"
        try await waitForCompiles(2)
        #expect(started == 2 && workspace.status == .ready(preset))

        // The rotation changes while the preset shows.
        source.rotation = 1
        renderer.draw(in: view)
        try await waitForCompiles(3)
        #expect(started == 3 && workspace.status == .ready(preset))

        // Nothing changed: no compile.
        renderer.draw(in: view)
        try await Task.sleep(for: .milliseconds(200))
        #expect(started == 3)
    }

    @Test func reloadsWhileCompilingWaitForItAndRunOnce() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeShaderFixtures(in: directory)
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: 8, height: 8))
        let renderer = try #require(MetalRenderer(view: view))
        var started = 0
        renderer.presetURL = { started += 1; return directory.appending(path: $0.path) }
        let workspace = ShaderWorkspace()
        renderer.workspace = workspace
        let strong = try #require(ShaderPresetRef(source: .user, path: "dim-strong.slangp"))
        renderer.selection = .preset(strong)
        for _ in 0..<500 where workspace.status != .ready(strong) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(workspace.status == .ready(strong) && started == 1)

        // Edits faster than a compile, e.g. typing with a heavy preset.
        try "#reference \"dim.slangp\"\nSTRENGTH = \"0.3\"\n"
            .write(to: directory.appending(path: "dim-strong.slangp"), atomically: true, encoding: .utf8)
        for _ in 0..<10 { workspace.reloadPreset() }
        for _ in 0..<500 where workspace.status != .ready(strong) || workspace.values["STRENGTH"] != 0.3 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(workspace.values["STRENGTH"] == 0.3, "The latest change is compiled")
        try await Task.sleep(for: .milliseconds(200))
        #expect(started == 3, "The first reload and the latest of those that waited")
    }

    @Test func arrowKeysMoveTheZoomedPictureWithinItsEdges() {
        var tools = ShaderPreviewTools()
        tools.pan(x: 1, y: 1)
        #expect(tools.focus == CGPoint(x: 0.5, y: 0.5), "Nothing to move without zoom")

        tools.zoom = 4
        tools.pan(x: 1, y: -2)
        #expect(tools.focus == CGPoint(x: 0.5 + 1.0 / 32, y: 0.5 - 2.0 / 32), "A step is an eighth of what shows")
        tools.pan(x: -100, y: 100)
        #expect(tools.focus == CGPoint(x: 0, y: 1))
    }

    @Test func warnsOnceWhenAPresetIsTooSlowForTheFrameRate() throws {
        let workspace = ShaderWorkspace()
        let preset = try #require(ShaderPresetRef(source: .library, path: "crt/heavy.slangp"))
        var warnings: [ShaderPresetRef] = []
        workspace.onTooSlow = { warnings.append($0) }
        workspace.loaded(preset, parameters: [], values: [:], passCount: 1, apply: { _, _ in }, reload: {})
        let budget = 1.0 / 60
        var time = 0.0
        func record(_ seconds: Double) {
            time += 0.6
            workspace.recordGPUTime(seconds, budget: budget, at: time)
        }

        record(0.030)
        #expect(!workspace.isTooSlow, "One slow average is a hiccup")
        #expect(workspace.gpuTime == 0.030 && workspace.frameBudget == budget)
        record(0.030)
        #expect(workspace.isTooSlow && workspace.tooSlowDetail != nil)
        #expect(warnings == [preset])
        record(0.010)
        #expect(workspace.isTooSlow)
        record(0.010)
        #expect(!workspace.isTooSlow && workspace.tooSlowDetail == nil)
        record(0.030)
        record(0.030)
        #expect(workspace.isTooSlow)
        #expect(warnings.count == 1, "A preset warns once")

        workspace.useBuiltin()
        #expect(!workspace.isTooSlow && workspace.gpuTime == nil)
    }
}
