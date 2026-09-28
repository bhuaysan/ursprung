// SPDX-License-Identifier: GPL-3.0-or-later

import Metal
import MetalKit
import simd

/// Mirrors `Uniforms` in Shaders.metal.
private struct Uniforms {
    var extent: SIMD2<Float>
    var viewportHalf: SIMD2<Float>
    var textureSize: SIMD2<Float>
    var outputSize: SIMD2<Float>
    var rotation: UInt32
    var filter: UInt32
}

/// Draws the most recent core frame into an MTKView, aspect-correct.
final class MetalRenderer: NSObject, MTKViewDelegate {
    weak var core: LibretroCore?
    var filter: VideoFilter = .sharp
    var integerScaling = false

    /// On-screen rectangle of the image in view points (for pointer input).
    private(set) var imageRect: CGRect = .zero

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var texture: MTLTexture?
    private var lastSerial: UInt64 = 0

    init?(view: MTKView) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: ShaderSource.presentation, options: nil) else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "ursprung_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "ursprung_fragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }

        self.device = device
        self.queue = queue
        self.pipeline = pipeline
        super.init()

        view.device = device
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 120
        view.delegate = self
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        uploadFrameIfNeeded()
        guard let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }

        if let texture, let core {
            var uniforms = makeUniforms(texture: texture, core: core, drawableSize: view.drawableSize,
                                        scale: view.window?.backingScaleFactor ?? 2, viewSize: view.bounds.size)
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }

    private func uploadFrameIfNeeded() {
        guard let core else { return }
        let serial = core.frameSerial
        guard serial != lastSerial else { return }
        lastSerial = serial
        core.accessLatestFrame { pixels, width, height, pitch in
            if texture?.width != width || texture?.height != height {
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width,
                                                                          height: height, mipmapped: false)
                descriptor.usage = .shaderRead
                descriptor.storageMode = .shared
                texture = device.makeTexture(descriptor: descriptor)
            }
            texture?.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                             withBytes: pixels, bytesPerRow: pitch)
        }
    }

    private func makeUniforms(texture: MTLTexture, core: LibretroCore, drawableSize: CGSize,
                              scale: CGFloat, viewSize: CGSize) -> Uniforms {
        let rotation = UInt32(max(0, core.rotation) % 4)
        let rotated = rotation % 2 == 1
        let aspect = Double(core.aspectRatio)
        let displayAspect = rotated ? 1 / aspect : aspect

        let drawW = Double(drawableSize.width), drawH = Double(drawableSize.height)
        var width = drawW, height = drawW / displayAspect
        if height > drawH { height = drawH; width = drawH * displayAspect }

        if integerScaling {
            let sourceHeight = Double(rotated ? texture.width : texture.height)
            let factor = floor(height / sourceHeight)
            if factor >= 1 {
                height = factor * sourceHeight
                width = height * displayAspect
            }
        }

        imageRect = CGRect(x: (drawW - width) / 2 / scale, y: (drawH - height) / 2 / scale,
                           width: width / scale, height: height / scale)

        // Quad size in pixels before rotation; the shader rotates in pixel
        // space and converts to NDC afterwards.
        let output = rotated ? SIMD2(Float(height), Float(width)) : SIMD2(Float(width), Float(height))
        let extent = output / 2

        let filterIndex: UInt32 = switch filter {
        case .sharp: 0
        case .nearest: 1
        case .smooth: 2
        case .scanlines: 3
        }
        return Uniforms(extent: extent, viewportHalf: SIMD2(Float(drawW / 2), Float(drawH / 2)), textureSize: SIMD2(Float(texture.width), Float(texture.height)),
                        outputSize: output, rotation: rotation, filter: filterIndex)
    }
}
