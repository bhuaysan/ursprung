// SPDX-License-Identifier: GPL-3.0-or-later
// Presentation shaders, compiled at runtime so building Ursprung does not
// require Xcode's optional Metal toolchain download.

enum ShaderSource {
    static let presentation = #"""
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float2 extent;       // half size of the (unrotated) quad in pixels
    float2 viewportHalf; // half size of the drawable in pixels
    float2 textureSize;  // frame size in texels
    float2 outputSize;   // on-screen size of the frame in pixels (unrotated)
    uint rotation;       // multiples of 90° counter-clockwise
    uint filter;         // 0 sharp, 1 nearest, 2 smooth, 3 scanlines
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex VertexOut ursprung_vertex(uint vid [[vertex_id]], constant Uniforms &u [[buffer(0)]]) {
    const float2 corners[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
    const float2 uvs[4] = { float2(0, 1), float2(1, 1), float2(0, 0), float2(1, 0) };

    float2 p = corners[vid] * u.extent;
    float angle = float(u.rotation) * M_PI_F * 0.5f;
    float c = cos(angle), s = sin(angle);
    p = float2(p.x * c - p.y * s, p.x * s + p.y * c) / u.viewportHalf;

    VertexOut out;
    out.position = float4(p, 0, 1);
    out.uv = uvs[vid];
    return out;
}

/// Sharp bilinear: integer prescale with nearest neighbour, then bilinear
/// interpolation only at texel borders. Crisp pixels without shimmering at
/// non-integer scale factors.
static float4 sampleSharp(texture2d<float> tex, float2 uv, constant Uniforms &u) {
    constexpr sampler linearSampler(filter::linear, address::clamp_to_edge);
    float2 texel = uv * u.textureSize;
    float2 scale = max(floor(u.outputSize / u.textureSize), float2(1.0));
    float2 base = floor(texel);
    float2 center = fract(texel) - 0.5;
    float2 range = 0.5 - 0.5 / scale;
    float2 f = (center - clamp(center, -range, range)) * scale + 0.5;
    return tex.sample(linearSampler, (base + f) / u.textureSize);
}

fragment float4 ursprung_fragment(VertexOut in [[stage_in]],
                                  texture2d<float> tex [[texture(0)]],
                                  constant Uniforms &u [[buffer(0)]]) {
    constexpr sampler nearestSampler(filter::nearest, address::clamp_to_edge);
    constexpr sampler linearSampler(filter::linear, address::clamp_to_edge);

    float4 color;
    switch (u.filter) {
        case 1:
            color = tex.sample(nearestSampler, in.uv);
            break;
        case 2:
            color = tex.sample(linearSampler, in.uv);
            break;
        case 3: {
            color = sampleSharp(tex, in.uv, u);
            // Soft scanlines: darken the border between source lines.
            float line = fract(in.uv.y * u.textureSize.y);
            float intensity = mix(0.62, 1.0, sin(line * M_PI_F));
            float strength = clamp((u.outputSize.y / u.textureSize.y - 1.5) / 1.5, 0.0, 1.0);
            color.rgb *= mix(1.0, intensity, strength) * mix(1.0, 1.12, strength);
            break;
        }
        default:
            color = sampleSharp(tex, in.uv, u);
            break;
    }
    return float4(color.rgb, 1.0);
}
"""#
}
