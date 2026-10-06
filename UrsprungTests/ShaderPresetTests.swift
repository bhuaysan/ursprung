// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import Ursprung

/// A one-pass slang shader with one parameter, written next to its preset.
private let dimShader = """
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

@Suite("Shader presets (librashader)")
struct ShaderPresetTests {
    private func writePresets(in directory: URL) throws {
        try dimShader.write(to: directory.appending(path: "dim.slang"), atomically: true, encoding: .utf8)
        try "shaders = 1\nshader0 = dim.slang\nscale_type0 = viewport\n"
            .write(to: directory.appending(path: "dim.slangp"), atomically: true, encoding: .utf8)
        try "#reference \"dim.slangp\"\nSTRENGTH = \"0.8\"\n"
            .write(to: directory.appending(path: "dim-strong.slangp"), atomically: true, encoding: .utf8)
    }

    @Test func readsDeclaredParameters() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writePresets(in: directory)

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
        try writePresets(in: directory)

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
