// SPDX-License-Identifier: GPL-3.0-or-later

import Testing
@testable import Ursprung

/// Frames read back from Vulkan cores, converted into the player's BGRA8.
struct PixelConversionTests {
    /// Converts one row of `source` pixels and returns them as BGRA8 words.
    private func convert<T>(_ layout: URPixelLayout, _ source: [T]) -> [UInt32] {
        let bytesPerPixel = Int(URPixelLayoutBytesPerPixel(layout))
        let width = source.count * MemoryLayout<T>.stride / bytesPerPixel
        var output = [UInt32](repeating: 0, count: width)
        let converted = source.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { out in
                URConvertPixelsToBGRA8(layout, input.baseAddress, input.count, out.baseAddress!.assumingMemoryBound(to: UInt8.self),
                                       UInt32(width), 1)
            }
        }
        #expect(converted)
        return output
    }

    @Test func eightBitLayouts() {
        // Memory order R, G, B, A = 0x11, 0x22, 0x33, 0x44.
        #expect(convert(URPixelLayoutR8G8B8A8, [UInt32(0x4433_2211)]) == [0xFF11_2233])
        // Memory order B, G, R, A: already BGRA; alpha becomes opaque.
        #expect(convert(URPixelLayoutB8G8R8A8, [UInt32(0x0011_2233)]) == [0xFF11_2233])
    }

    @Test func tenBitLayouts() {
        // R = 0x3FF, G = 0x200, B = 0x004 (10 bits each); the top 8 bits survive.
        let r: UInt32 = 0x3FF, g: UInt32 = 0x200, b: UInt32 = 0x004
        #expect(convert(URPixelLayoutA2B10G10R10, [(3 << 30) | (b << 20) | (g << 10) | r]) == [0xFFFF_8001])
        #expect(convert(URPixelLayoutA2R10G10B10, [(3 << 30) | (r << 20) | (g << 10) | b]) == [0xFFFF_8001])
    }

    @Test func sixteenBitLayouts() {
        // Pure red, green and blue.
        #expect(convert(URPixelLayoutR5G6B5, [UInt16(0xF800), 0x07E0, 0x001F]) == [0xFFFF_0000, 0xFF00_FF00, 0xFF00_00FF])
        #expect(convert(URPixelLayoutA1R5G5B5, [UInt16(0xFC00), 0x83E0, 0x001F]) == [0xFFFF_0000, 0xFF00_FF00, 0xFF00_00FF])
        #expect(convert(URPixelLayoutR5G5B5A1, [UInt16(0xF801), 0x07C0, 0x003E]) == [0xFFFF_0000, 0xFF00_FF00, 0xFF00_00FF])
    }

    @Test func halfFloatsAreClamped() {
        // R = 1.0, G = 0.5, B = -1.0 (clamped to 0), A = 1.0; then R = 2.0 (clamped to 1).
        let pixels: [Float16] = [1.0, 0.5, -1.0, 1.0, 2.0, 0.0, 0.0, 1.0]
        #expect(convert(URPixelLayoutR16G16B16A16Float, pixels) == [0xFFFF_8000, 0xFFFF_0000])
    }

    @Test func unsupportedLayoutsFail() {
        var output: UInt32 = 0
        let source: UInt32 = 0
        let converted = withUnsafeBytes(of: source) { input in
            withUnsafeMutableBytes(of: &output) { out in
                URConvertPixelsToBGRA8(URPixelLayoutUnsupported, input.baseAddress, 4,
                                       out.baseAddress!.assumingMemoryBound(to: UInt8.self), 1, 1)
            }
        }
        #expect(!converted)
        #expect(URPixelLayoutBytesPerPixel(URPixelLayoutUnsupported) == 0)
    }
}
