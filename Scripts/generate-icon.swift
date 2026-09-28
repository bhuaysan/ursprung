#!/usr/bin/env swift
// SPDX-License-Identifier: GPL-3.0-or-later
// Renders the Ursprung app icon (a pixel "play" glyph) into the asset catalog.
//
//   swift Scripts/generate-icon.swift

import AppKit
import CoreGraphics

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "Ursprung/Resources/Assets.xcassets/AppIcon.appiconset")

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func render(size: Int) -> CGImage {
    let s = CGFloat(size)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: s / 1024, y: s / 1024)

    // macOS icon grid: 824 pt body with ~185 pt continuous corners.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
    ctx.addPath(shape)
    ctx.setFillColor(color(0x17141F))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let background = CGGradient(colorsSpace: space, colors: [color(0x2A2238), color(0x121019)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(background, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    // Soft warm glow behind the glyph.
    let glow = CGGradient(colorsSpace: space, colors: [color(0xFF6A5C, 0.38), color(0xFF6A5C, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 540, y: 512), startRadius: 0,
                           endCenter: CGPoint(x: 540, y: 512), endRadius: 400, options: [])

    // Pixel play triangle on a 9-row grid.
    let cell: CGFloat = 50, gap: CGFloat = 8
    let rows = 9
    let widest = 8
    // Optical centring: a play triangle's mass sits left of its bounding box.
    let originX: CGFloat = 512 - CGFloat(widest) * cell / 2 + 28, originY: CGFloat = 512 - CGFloat(rows) * cell / 2
    let glyph = CGMutablePath()
    for row in 0..<rows {
        let distance = Double(abs(row - rows / 2))
        let columns = max(1, Int((Double(widest) * (1 - distance / 4.5)).rounded()))
        for column in 0..<columns {
            let rect = CGRect(x: originX + CGFloat(column) * cell + gap / 2,
                              y: originY + CGFloat(row) * cell + gap / 2,
                              width: cell - gap, height: cell - gap)
            glyph.addPath(CGPath(roundedRect: rect, cornerWidth: 8, cornerHeight: 8, transform: nil))
        }
    }
    ctx.addPath(glyph)
    ctx.clip()
    let warm = CGGradient(colorsSpace: space, colors: [color(0xFFB36B), color(0xFF5A6E)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(warm, start: CGPoint(x: 340, y: 760), end: CGPoint(x: 700, y: 270), options: [])
    ctx.restoreGState()

    // Hairline highlight on the top edge.
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.setStrokeColor(color(0xFFFFFF, 0.08))
    ctx.setLineWidth(3)
    ctx.strokePath()
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
