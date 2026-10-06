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
