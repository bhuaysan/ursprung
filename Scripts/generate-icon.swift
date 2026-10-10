#!/usr/bin/env swift
// SPDX-License-Identifier: GPL-3.0-or-later
// Renders the Ursprung app icon (a graphite D-pad on coral) into the asset catalog and docs/icon.png.
//
//   swift Scripts/generate-icon.swift

import AppKit
import CoreGraphics

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "Ursprung/Resources/Assets.xcassets/AppIcon.appiconset")

let space = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: stops.map(\.1) as CFArray, locations: stops.map(\.0))!
}

/// macOS icon grid: 824 pt body as a superellipse (n = 5), close to Apple's continuous corners.
func bodyPath() -> CGPath {
    let path = CGMutablePath()
    let steps = 360, n = 5.0, half = 412.0
    for i in 0..<steps {
        let t = 2 * Double.pi * Double(i) / Double(steps)
        let x = 512 + half * copysign(pow(abs(cos(t)), 2 / n), cos(t))
        let y = 512 + half * copysign(pow(abs(sin(t)), 2 / n), sin(t))
        i == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
    }
    path.closeSubpath()
    return path
}

/// The D-pad: two arms of half width `a` and half length `l`, outer corners rounded by `r`.
func crossPath(a: CGFloat = 112, l: CGFloat = 300, r: CGFloat = 40) -> CGPath {
    let c: CGFloat = 512
    let p = CGMutablePath()
    func corner(_ x: CGFloat, _ y: CGFloat, to end: CGPoint) {
        p.addQuadCurve(to: end, control: CGPoint(x: x, y: y))
    }
    p.move(to: CGPoint(x: c - a, y: c - l + r))
    corner(c - a, c - l, to: CGPoint(x: c - a + r, y: c - l))
    p.addLine(to: CGPoint(x: c + a - r, y: c - l))
    corner(c + a, c - l, to: CGPoint(x: c + a, y: c - l + r))
    p.addLine(to: CGPoint(x: c + a, y: c - a))
    p.addLine(to: CGPoint(x: c + l - r, y: c - a))
    corner(c + l, c - a, to: CGPoint(x: c + l, y: c - a + r))
    p.addLine(to: CGPoint(x: c + l, y: c + a - r))
    corner(c + l, c + a, to: CGPoint(x: c + l - r, y: c + a))
    p.addLine(to: CGPoint(x: c + a, y: c + a))
    p.addLine(to: CGPoint(x: c + a, y: c + l - r))
    corner(c + a, c + l, to: CGPoint(x: c + a - r, y: c + l))
    p.addLine(to: CGPoint(x: c - a + r, y: c + l))
    corner(c - a, c + l, to: CGPoint(x: c - a, y: c + l - r))
    p.addLine(to: CGPoint(x: c - a, y: c + a))
    p.addLine(to: CGPoint(x: c - l + r, y: c + a))
    corner(c - l, c + a, to: CGPoint(x: c - l, y: c + a - r))
    p.addLine(to: CGPoint(x: c - l, y: c - a + r))
    corner(c - l, c - a, to: CGPoint(x: c - l + r, y: c - a))
    p.addLine(to: CGPoint(x: c - a, y: c - a))
    p.closeSubpath()
    return p
}

func trianglePath(center: CGPoint, angle: CGFloat, radius: CGFloat = 46) -> CGPath {
    let p = CGMutablePath()
    for k in 0..<3 {
        let t = (angle + CGFloat(k) * 120) * .pi / 180
        let point = CGPoint(x: center.x + radius * cos(t), y: center.y + radius * sin(t))
        k == 0 ? p.move(to: point) : p.addLine(to: point)
    }
    p.closeSubpath()
    return p
}

func render(size: Int) -> CGImage {
    let s = CGFloat(size), k = s / 1024
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Draw in a 1024 pt, y-down space. Shadows ignore the transform, so their offset and blur are scaled by hand.
    ctx.translateBy(x: 0, y: s)
    ctx.scaleBy(x: k, y: -k)
    func shadow(dy: CGFloat, blur: CGFloat, alpha: CGFloat) {
        ctx.setShadow(offset: CGSize(width: 0, height: -dy * k), blur: blur * k, color: color(0x000000, alpha))
    }

    let body = bodyPath()
    ctx.saveGState()
    shadow(dy: 12, blur: 28, alpha: 0.32)
    ctx.addPath(body)
    ctx.setFillColor(color(0xE5445A))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()
    ctx.drawLinearGradient(gradient([(0, color(0xFF8A7A)), (1, color(0xD92E4C))]),
                           start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])

    // Graphite D-pad with a drop shadow, a top gloss and a hairline edge.
    let cross = crossPath()
    ctx.saveGState()
    shadow(dy: 22, blur: 44, alpha: 0.45)
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.addPath(cross)
    ctx.clip()
    ctx.drawLinearGradient(gradient([(0, color(0x45434B)), (1, color(0x141317))]),
                           start: CGPoint(x: 512, y: 212), end: CGPoint(x: 512, y: 812), options: [])
    ctx.endTransparencyLayer()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(cross)
    ctx.clip()
    ctx.drawLinearGradient(gradient([(0, color(0xFFFFFF, 0.16)), (0.5, color(0xFFFFFF, 0))]),
                           start: CGPoint(x: 512, y: 212), end: CGPoint(x: 512, y: 812), options: [])
    ctx.restoreGState()

    ctx.addPath(cross)
    ctx.setStrokeColor(color(0xFFFFFF, 0.22))
    ctx.setLineWidth(4)
    ctx.strokePath()

    // Embossed direction arrows.
    for (center, angle) in [(CGPoint(x: 512, y: 302), -90), (CGPoint(x: 512, y: 722), 90),
                            (CGPoint(x: 302, y: 512), 180), (CGPoint(x: 722, y: 512), 0)] as [(CGPoint, CGFloat)] {
        let arrow = trianglePath(center: center, angle: angle)
        ctx.saveGState()
        ctx.setAlpha(0.22)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.addPath(arrow)
        ctx.setFillColor(color(0xFFFFFF))
        ctx.fillPath()
        ctx.addPath(arrow)
        ctx.setStrokeColor(color(0xFFFFFF, 0.22))
        ctx.setLineWidth(16)
        ctx.setLineJoin(.round)
        ctx.strokePath()
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    // Centre dimple, lit from above.
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: 454, y: 454, width: 116, height: 116))
    ctx.clip()
    ctx.drawRadialGradient(gradient([(0, color(0x0D0C10)), (0.8, color(0x24222A)), (1, color(0x3A3840))]),
                           startCenter: CGPoint(x: 512, y: 500), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 500), endRadius: 70, options: [.drawsAfterEndLocation])
    ctx.restoreGState()
    ctx.restoreGState()

    // Rim light: bright on the top edge, fading out towards the bottom.
    ctx.saveGState()
    ctx.addPath(body)
    ctx.setLineWidth(4)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(gradient([(0, color(0xFFFFFF, 0.5)), (0.5, color(0xFFFFFF, 0)), (1, color(0xFFFFFF, 0.08))]),
                           start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
    ctx.restoreGState()

    return ctx.makeImage()!
}

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        let rep = NSBitmapImageRep(cgImage: render(size: pixels))
        try! rep.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
    }
}
try! NSBitmapImageRep(cgImage: render(size: 1024)).representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: "docs/icon.png"))
print("Icons written to \(output.path)")
