// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Metal
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
