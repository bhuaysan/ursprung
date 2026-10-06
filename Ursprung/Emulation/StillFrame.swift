// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import QuartzCore
import UniformTypeIdentifiers

/// What `MetalRenderer` draws: the running core's frames, or a still
/// picture for the shader editor.
protocol FrameSource: AnyObject {
    /// Changes whenever there is a new frame.
    var frameSerial: UInt64 { get }
    @discardableResult
    func accessLatestFrame(_ block: (UnsafeRawPointer, Int, Int, Int) -> Void) -> Bool
    /// The picture's intended aspect ratio before rotation; 0 uses the pixel shape.
    var aspectRatio: Float { get }
    /// Quarter turns counter-clockwise.
    var rotation: Int { get }
    var framesPerSecond: Double { get }
    /// Fills `$CORE$` in preset paths.
    var libraryName: String { get }
}

extension LibretroCore: FrameSource {}

/// A still picture (XRGB8888, like a core frame) as a frame source. Its
/// serial advances at 60 Hz, so presets that animate or keep history see
/// time pass; paused, it stands still.
final class StillFrame: FrameSource {
    let width: Int
    let height: Int
    let aspectRatio: Float
    let rotation = 0
    let framesPerSecond = 60.0
    let libraryName: String
    var isPaused = false {
        didSet {
            guard isPaused != oldValue else { return }
            if isPaused { pausedSerial = frameSerial } else { start = CACurrentMediaTime() - Double(pausedSerial) / 60 }
        }
    }

    private let pixels: [UInt32]
    private var start = CACurrentMediaTime()
    private var pausedSerial: UInt64 = 0

    init(pixels: [UInt32], width: Int, height: Int, aspectRatio: Double? = nil, coreName: String = "") {
        precondition(pixels.count == width * height)
        self.pixels = pixels
        self.width = width
        self.height = height
        self.aspectRatio = Float(aspectRatio ?? Double(width) / Double(max(height, 1)))
        libraryName = coreName
    }

    convenience init(_ picture: StillPicture, coreName: String = "") {
        self.init(pixels: picture.pixels, width: picture.width, height: picture.height,
                  aspectRatio: picture.aspectRatio, coreName: coreName)
    }

    var frameSerial: UInt64 {
        isPaused ? pausedSerial : UInt64(max(0, CACurrentMediaTime() - start) * 60) + 1
    }

    /// Advances one frame while paused.
    func step() {
        if isPaused { pausedSerial += 1 }
    }

    @discardableResult
    func accessLatestFrame(_ block: (UnsafeRawPointer, Int, Int, Int) -> Void) -> Bool {
        pixels.withUnsafeBytes { block($0.baseAddress!, width, height, width * 4) }
        return true
    }
}

/// Pixels of a still picture, made off the main thread.
nonisolated struct StillPicture: Sendable {
    let pixels: [UInt32]
    let width: Int
    let height: Int
    /// Nil: the pixel shape.
    var aspectRatio: Double?

    /// `image` at `width` × `height` (its own size when nil), scaled without smoothing.
    init?(image: CGImage, width: Int? = nil, height: Int? = nil, aspectRatio: Double? = nil) {
        let width = max(1, min(width ?? image.width, 4096)), height = max(1, min(height ?? image.height, 4096))
        var pixels = [UInt32](repeating: 0xFF00_0000, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                                              | CGBitmapInfo.byteOrder32Little.rawValue) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.init(pixels: pixels, width: width, height: height, aspectRatio: aspectRatio)
    }

    init(pixels: [UInt32], width: Int, height: Int, aspectRatio: Double? = nil) {
        self.pixels = pixels
        self.width = width
        self.height = height
        self.aspectRatio = aspectRatio
    }

    /// An image file; `width`/`height` set the source resolution.
    static func load(_ url: URL, width: Int? = nil, height: Int? = nil) -> StillPicture? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let png = properties?[kCGImagePropertyPNGDictionary] as? [CFString: Any]
        let aspect = (png?[kCGImagePropertyPNGDescription] as? String).flatMap(ShaderFrameStore.aspectRatio(inDescription:))
        return StillPicture(image: image, width: width, height: height, aspectRatio: aspect)
    }
}

/// Pictures that show what a shader does to typical retro frames.
nonisolated enum ShaderTestPattern: String, CaseIterable, Identifiable, Sendable {
    case colorBars, grayRamp, dither, pixelGrid, text

    var id: String { rawValue }

    var title: String {
        switch self {
        case .colorBars: String(localized: "Color Bars")
        case .grayRamp: String(localized: "Gray Ramp")
        case .dither: String(localized: "Checkerboard Dither")
        case .pixelGrid: String(localized: "Pixel Grid")
        case .text: String(localized: "Small Text")
        }
    }

    /// Resolutions of typical systems.
    static let sizes: [(width: Int, height: Int)] = [(160, 144), (256, 224), (320, 240), (640, 480)]

    /// The pattern at `width` × `height`; 4:3 except for the Game Boy's 10:9.
    func picture(width: Int, height: Int) -> StillPicture {
        let aspect = width == 160 && height == 144 ? 10.0 / 9.0 : 4.0 / 3.0
        var pixels = [UInt32](repeating: 0xFF00_0000, count: width * height)
        func rgb(_ r: Int, _ g: Int, _ b: Int) -> UInt32 {
            0xFF00_0000 | UInt32(min(max(r, 0), 255)) << 16 | UInt32(min(max(g, 0), 255)) << 8 | UInt32(min(max(b, 0), 255))
        }
        switch self {
        case .colorBars:
            let bars = [rgb(192, 192, 192), rgb(192, 192, 0), rgb(0, 192, 192), rgb(0, 192, 0), rgb(192, 0, 192),
                        rgb(192, 0, 0), rgb(0, 0, 192)]
            let full = [rgb(255, 255, 255), rgb(255, 255, 0), rgb(0, 255, 255), rgb(0, 255, 0), rgb(255, 0, 255),
                        rgb(255, 0, 0), rgb(0, 0, 255)]
            for y in 0..<height {
                for x in 0..<width {
                    let bar = x * bars.count / width
                    pixels[y * width + x] = switch y * 8 / height {
                    case 0..<5: bars[bar]
                    case 5: full[bar]
                    default: rgb(x * 256 / width, x * 256 / width, x * 256 / width)
                    }
                }
            }
        case .grayRamp:
            for y in 0..<height {
                let band = y * 4 / height
                for x in 0..<width {
                    let level = x * 256 / width
                    pixels[y * width + x] = switch band {
                    case 0: rgb(level, level, level)
                    case 1: rgb(level, 0, 0)
                    case 2: rgb(0, level, 0)
                    default: rgb(0, 0, level)
                    }
                }
            }
        case .dither:
            // Left: 1-px checkerboards that blend into a colour on a CRT
            // (Mega Drive "transparency"); right: vertical stripes.
            let pairs = [(rgb(0, 0, 255), rgb(255, 0, 0)), (rgb(0, 0, 0), rgb(255, 255, 255)), (rgb(0, 128, 0), rgb(255, 255, 0))]
            for y in 0..<height {
                let pair = pairs[y * pairs.count / height]
                for x in 0..<width {
                    let odd = x < width / 2 ? (x + y) % 2 == 1 : x % 2 == 1
                    pixels[y * width + x] = odd ? pair.1 : pair.0
                }
            }
        case .pixelGrid:
            for y in 0..<height {
                for x in 0..<width {
                    let line = x % 8 == 0 || y % 8 == 0
                    let dot = x % 8 == 4 && y % 8 == 4
                    pixels[y * width + x] = line ? rgb(255, 255, 255) : dot ? rgb(255, 64, 64) : rgb(24, 24, 48)
                }
            }
        case .text:
            return Self.textPicture(width: width, height: height, aspect: aspect)
        }
        return StillPicture(pixels: pixels, width: width, height: height, aspectRatio: aspect)
    }

    /// Lines of small text in a few colours, drawn without smoothing like a game's font.
    private static func textPicture(width: Int, height: Int, aspect: Double) -> StillPicture {
        var pixels = [UInt32](repeating: 0xFF10_1830, count: width * height)
        pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                                              | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
            context.setShouldAntialias(false)
            context.setAllowsFontSmoothing(false)
            let fontSize = CGFloat(max(8, height / 18))
            let font = CTFontCreateWithName("Menlo-Bold" as CFString, fontSize, nil)
            let lines: [(String, CGColor)] = [
                ("HP 120/120  MP 45", CGColor(red: 1, green: 1, blue: 1, alpha: 1)),
                ("The quick brown fox", CGColor(red: 1, green: 0.85, blue: 0.2, alpha: 1)),
                ("jumps over the lazy", CGColor(red: 0.4, green: 1, blue: 0.5, alpha: 1)),
                ("dog. 0123456789 !?", CGColor(red: 0.5, green: 0.8, blue: 1, alpha: 1)),
                ("> CONTINUE   OPTIONS", CGColor(red: 1, green: 0.4, blue: 0.4, alpha: 1)),
            ]
            var y = CGFloat(height) - fontSize * 1.5
            while y > 0 {
                for (text, color) in lines where y > 0 {
                    let attributed = NSAttributedString(string: text, attributes: [
                        NSAttributedString.Key(kCTFontAttributeName as String): font,
                        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
                    ])
                    let line = CTLineCreateWithAttributedString(attributed)
                    context.textPosition = CGPoint(x: fontSize / 2, y: y)
                    CTLineDraw(line, context)
                    y -= fontSize * 1.25
                }
            }
        }
        return StillPicture(pixels: pixels, width: width, height: height, aspectRatio: aspect)
    }
}

/// Frames captured at the core's own resolution for the shader editor, in
/// `Extras/<game id>/ShaderFrames/`. Screenshots are scaled to the picture's
/// shape, so they show shaders poorly.
nonisolated enum ShaderFrameStore {
    static func directory(in extras: URL, gameID: UUID) -> URL {
        GameExtras.directory(in: extras, gameID: gameID).appending(path: "ShaderFrames", directoryHint: .isDirectory)
    }

    static func frames(in extras: URL, gameID: UUID) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory(in: extras, gameID: gameID),
                                                                  includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension.lowercased() == "png" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// Writes `frame` unscaled, with the picture's aspect ratio in the PNG's description.
    static func save(_ frame: CGImage, aspectRatio: Double, in extras: URL, gameID: UUID, date: Date = .now) throws -> URL {
        let folder = directory(in: extras, gameID: gameID)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let url = GameExtras.available(folder.appending(path: "\(formatter.string(from: date)).png"))
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        let properties = [kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGDescription: description(aspectRatio: aspectRatio)]]
        CGImageDestinationAddImage(destination, frame, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return url
    }

    static func description(aspectRatio: Double) -> String {
        "Ursprung shader frame; aspect \(String(format: "%.6f", aspectRatio))"
    }

    static func aspectRatio(inDescription text: String) -> Double? {
        guard text.hasPrefix("Ursprung shader frame"), let range = text.range(of: "aspect ") else { return nil }
        return Double(text[range.upperBound...].prefix { $0.isNumber || $0 == "." }).flatMap { $0 > 0 ? $0 : nil }
    }
}
