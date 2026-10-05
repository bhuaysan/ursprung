// SPDX-License-Identifier: GPL-3.0-or-later

import Metal
import MetalKit
import simd

/// Mirrors `Uniforms` in ShaderSource.presentation.
private struct Uniforms {
    var extent: SIMD2<Float>
    var viewportHalf: SIMD2<Float>
    var textureSize: SIMD2<Float>
    var outputSize: SIMD2<Float>
    var rotation: UInt32
    var filter: UInt32
    var fillExtent: SIMD2<Float>
    var overlaySpan: SIMD2<Float>
    var ambientLevel: Float
}

/// Draws the most recent core frame into an MTKView, aspect-correct, with
/// an optional ambient light or bezel image around it.
final class MetalRenderer: NSObject, MTKViewDelegate {
    weak var core: LibretroCore?
    var filter: VideoFilter = .sharp
    var integerScaling = false
    var bezel: BezelStyle = .none
    /// An image drawn over everything, with a transparent hole for the game.
    var bezelImageURL: URL? {
        didSet {
            guard bezelImageURL != oldValue else { return }
            bezelImage = bezelImageURL.flatMap { try? textureLoader.newTexture(URL: $0, options: [.SRGB: false, .origin: MTKTextureLoader.Origin.topLeft]) }
        }
    }

    /// On-screen rectangle of the image in view points (for pointer input).
    private(set) var imageRect: CGRect = .zero

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let ambientPipeline: MTLRenderPipelineState
    private let overlayPipeline: MTLRenderPipelineState
    private let textureLoader: MTKTextureLoader
    private var texture: MTLTexture?
    private var bezelImage: MTLTexture?
    private var lastSerial: UInt64 = 0
    /// The texture's mipmaps are older than its picture.
    private var needsMipmaps = false

    init?(view: MTKView) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: ShaderSource.presentation, options: nil) else { return nil }
        func pipeline(vertex: String, fragment: String, blends: Bool = false) -> MTLRenderPipelineState? {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: vertex)
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            let attachment = descriptor.colorAttachments[0]!
            attachment.pixelFormat = .bgra8Unorm
            if blends {
                attachment.isBlendingEnabled = true
                attachment.sourceRGBBlendFactor = .sourceAlpha
                attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
                attachment.sourceAlphaBlendFactor = .one
                attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try? device.makeRenderPipelineState(descriptor: descriptor)
        }
        guard let main = pipeline(vertex: "ursprung_vertex", fragment: "ursprung_fragment"),
              let ambient = pipeline(vertex: "ursprung_ambient_vertex", fragment: "ursprung_ambient_fragment"),
              let overlay = pipeline(vertex: "ursprung_overlay_vertex", fragment: "ursprung_overlay_fragment", blends: true)
        else { return nil }

        self.device = device
        self.queue = queue
        self.pipeline = main
        self.ambientPipeline = ambient
        self.overlayPipeline = overlay
        self.textureLoader = MTKTextureLoader(device: device)
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
              let buffer = queue.makeCommandBuffer() else { return }

        let showsAmbient = bezel == .ambient && texture?.mipmapLevelCount ?? 0 > 1
        if showsAmbient, needsMipmaps, let texture, let blit = buffer.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: texture)
            blit.endEncoding()
            needsMipmaps = false
        }

        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        if let texture, let core {
            var uniforms = makeUniforms(texture: texture, core: core, drawableSize: view.drawableSize,
                                        scale: view.window?.backingScaleFactor ?? 2, viewSize: view.bounds.size)
            if showsAmbient {
                encoder.setRenderPipelineState(ambientPipeline)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
                encoder.setFragmentTexture(texture, index: 0)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            if let bezelImage {
                encoder.setRenderPipelineState(overlayPipeline)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
                encoder.setFragmentTexture(bezelImage, index: 0)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }
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
                // Mipmaps give the ambient light its blur.
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width,
                                                                          height: height, mipmapped: true)
                descriptor.usage = .shaderRead
                descriptor.storageMode = .shared
                texture = device.makeTexture(descriptor: descriptor)
            }
            texture?.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                             withBytes: pixels, bytesPerRow: pitch)
        }
        needsMipmaps = true
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

        // The ambient light: the frame scaled to cover the whole drawable.
        let fillWidth = max(drawW, drawH * displayAspect), fillHeight = fillWidth / displayAspect
        let fill = rotated ? SIMD2(Float(fillHeight), Float(fillWidth)) : SIMD2(Float(fillWidth), Float(fillHeight))
        let ambientLevel = Float(max(0, log2(Double(max(texture.width, texture.height))) - 3))

        // The bezel image: its middle, scaled to cover the drawable.
        var overlaySpan = SIMD2<Float>(1, 1)
        if let bezelImage {
            let imageW = Double(bezelImage.width), imageH = Double(bezelImage.height)
            let fillScale = max(drawW / imageW, drawH / imageH)
            overlaySpan = SIMD2(Float(drawW / (imageW * fillScale)), Float(drawH / (imageH * fillScale)))
        }

        return Uniforms(extent: extent, viewportHalf: SIMD2(Float(drawW / 2), Float(drawH / 2)),
                        textureSize: SIMD2(Float(texture.width), Float(texture.height)),
                        outputSize: output, rotation: rotation, filter: filter.shaderIndex,
                        fillExtent: fill / 2, overlaySpan: overlaySpan, ambientLevel: ambientLevel)
    }
}

/// Bezel images: one per system, chosen in Settings › Emulation.
nonisolated enum BezelImages {
    static func image(for systemID: String, in directory: URL = AppPaths.bezels) -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.first { $0.deletingPathExtension().lastPathComponent == systemID }
    }

    /// Copies `source` as the system's bezel image, replacing an earlier one.
    static func setImage(_ source: URL, for systemID: String, in directory: URL = AppPaths.bezels) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appending(path: "\(systemID).\(source.pathExtension.lowercased())")
        let staging = directory.appending(path: ".\(UUID().uuidString)")
        try FileManager.default.copyItem(at: source, to: staging)
        try removeImage(for: systemID, in: directory)
        try FileManager.default.moveItem(at: staging, to: target)
    }

    static func removeImage(for systemID: String, in directory: URL = AppPaths.bezels) throws {
        while let existing = image(for: systemID, in: directory) {
            try FileManager.default.removeItem(at: existing)
        }
    }
}
