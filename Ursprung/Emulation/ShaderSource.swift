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
    uint filter;         // 0 sharp, 1 nearest, 2 smooth, 3 scanlines, 4 CRT, 5 curved CRT, 6 LCD
    float2 fillExtent;   // ambient light: half size of a quad that covers the drawable (unrotated)
    float2 overlaySpan;  // bezel image: the part of the image the drawable shows (0…1 per axis)
    float ambientLevel;  // mip level that blurs the frame for the ambient light
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

static float2 rotate(float2 p, float angle) {
    float c = cos(angle), s = sin(angle);
    return float2(p.x * c - p.y * s, p.x * s + p.y * c);
}

vertex VertexOut ursprung_vertex(uint vid [[vertex_id]], constant Uniforms &u [[buffer(0)]]) {
    const float2 corners[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
    const float2 uvs[4] = { float2(0, 1), float2(1, 1), float2(0, 0), float2(1, 0) };

    float2 p = rotate(corners[vid] * u.extent, float(u.rotation) * M_PI_F * 0.5f) / u.viewportHalf;

    VertexOut out;
    out.position = float4(p, 0, 1);
    out.uv = uvs[vid];
    return out;
}

/// The whole drawable, with texture coordinates of the frame scaled to
/// cover it (ambient light).
vertex VertexOut ursprung_ambient_vertex(uint vid [[vertex_id]], constant Uniforms &u [[buffer(0)]]) {
    const float2 corners[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
    float2 q = rotate(corners[vid] * u.viewportHalf, -float(u.rotation) * M_PI_F * 0.5f) / u.fillExtent;

    VertexOut out;
    out.position = float4(corners[vid], 0, 1);
    out.uv = float2(0.5 + 0.5 * q.x, 0.5 - 0.5 * q.y);
    return out;
}

/// The whole drawable, showing the middle of the bezel image.
vertex VertexOut ursprung_overlay_vertex(uint vid [[vertex_id]], constant Uniforms &u [[buffer(0)]]) {
    const float2 corners[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
    float2 p = corners[vid];

    VertexOut out;
    out.position = float4(p, 0, 1);
    out.uv = float2(0.5 + 0.5 * p.x * u.overlaySpan.x, 0.5 - 0.5 * p.y * u.overlaySpan.y);
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

/// How much detail the screen has room for: 0 when a source line is at
/// most 1.5 pixels tall, 1 from 3 pixels on. Effects fade in with it, so
/// small windows are not darkened by lines they can't show.
static float effectStrength(constant Uniforms &u) {
    return clamp((u.outputSize.y / u.textureSize.y - 1.5) / 1.5, 0.0, 1.0);
}

/// A CRT: soft horizontal blur, light beams that widen with brightness, an
/// aperture grille and a little glow.
static float3 crt(texture2d<float> tex, float2 uv, float2 position, constant Uniforms &u) {
    constexpr sampler linearSampler(filter::linear, address::clamp_to_edge);
    float2 texel = uv * u.textureSize;
    float strength = effectStrength(u);
    // Sample the middle of the source line, horizontally a little soft.
    float2 lineUV = float2(uv.x, (floor(texel.y) + 0.5) / u.textureSize.y);
    float dx = 0.35 / u.textureSize.x;
    float3 color = (tex.sample(linearSampler, lineUV - float2(dx, 0)).rgb
                    + 2.0 * tex.sample(linearSampler, lineUV).rgb
                    + tex.sample(linearSampler, lineUV + float2(dx, 0)).rgb) * 0.25;
    float3 linearColor = pow(color, 2.2);
    // Beam profile: bright lines are wider.
    float dy = fract(texel.y) - 0.5;
    float3 width = mix(float3(14.0), float3(5.0), sqrt(linearColor));
    float3 beam = exp(-dy * dy * width) * 1.45;
    linearColor = mix(linearColor, linearColor * beam, strength);
    // Aperture grille: red, green and blue stripes on screen pixels.
    uint stripe = uint(position.x) % 3;
    float3 mask = float3(0.78);
    mask[stripe] = 1.12;
    linearColor *= mix(float3(1.0), mask, strength * 0.9);
    return pow(linearColor, 1.0 / 2.2);
}

/// Bends the picture like the glass of a tube; NaN outside the screen.
static float2 curve(float2 uv) {
    float2 cc = uv * 2.0 - 1.0;
    cc *= 1.0 + float2(cc.y * cc.y * 0.045, cc.x * cc.x * 0.06);
    return cc * 0.5 + 0.5;
}

/// A handheld LCD: each pixel a small square with a thin gap around it.
static float3 lcd(texture2d<float> tex, float2 uv, constant Uniforms &u) {
    constexpr sampler nearestSampler(filter::nearest, address::clamp_to_edge);
    float3 color = tex.sample(nearestSampler, uv).rgb;
    float2 scale = u.outputSize / u.textureSize;
    float strength = clamp((min(scale.x, scale.y) - 2.0) / 2.0, 0.0, 1.0);
    float2 f = fract(uv * u.textureSize);
    float2 edge = smoothstep(0.0, 0.14, f) * smoothstep(0.0, 0.14, 1.0 - f);
    float grid = mix(0.72, 1.0, min(edge.x, edge.y));
    return color * mix(1.0, grid, strength) * mix(1.0, 1.08, strength);
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
            float strength = effectStrength(u);
            color.rgb *= mix(1.0, intensity, strength) * mix(1.0, 1.12, strength);
            break;
        }
        case 4:
            color = float4(crt(tex, in.uv, in.position.xy, u), 1.0);
            break;
        case 5: {
            float2 uv = curve(in.uv);
            if (any(uv < 0.0) || any(uv > 1.0)) return float4(0, 0, 0, 1);
            color = float4(crt(tex, uv, in.position.xy, u), 1.0);
            // Darker, rounded corners.
            float2 d = abs(uv * 2.0 - 1.0);
            float vignette = (1.0 - smoothstep(0.92, 1.0, max(d.x, d.y))) * (1.0 - 0.09 * dot(d, d));
            color.rgb *= vignette;
            break;
        }
        case 6:
            color = float4(lcd(tex, in.uv, u), 1.0);
            break;
        default:
            color = sampleSharp(tex, in.uv, u);
            break;
    }
    return float4(color.rgb, 1.0);
}

/// A blurred, dimmed copy of the frame around it, as if it lit the room.
fragment float4 ursprung_ambient_fragment(VertexOut in [[stage_in]],
                                          texture2d<float> tex [[texture(0)]],
                                          constant Uniforms &u [[buffer(0)]]) {
    constexpr sampler blurSampler(filter::linear, mip_filter::linear, address::mirrored_repeat);
    float3 color = tex.sample(blurSampler, in.uv, level(u.ambientLevel)).rgb;
    return float4(color * 0.42, 1.0);
}

fragment float4 ursprung_overlay_fragment(VertexOut in [[stage_in]],
                                          texture2d<float> image [[texture(0)]]) {
    constexpr sampler linearSampler(filter::linear, address::clamp_to_edge);
    return image.sample(linearSampler, in.uv);
}
"""#
}
