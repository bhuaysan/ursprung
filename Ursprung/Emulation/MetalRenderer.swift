// SPDX-License-Identifier: GPL-3.0-or-later

import Metal
import MetalKit
import OSLog
import QuartzCore
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
    var offset: SIMD2<Float>
}

/// Where the game picture goes in the drawable.
nonisolated struct PresentationLayout: Equatable {
    /// The picture in drawable pixels from the bottom left corner, on
    /// whole pixels so a texture of `outputSize` maps 1:1 onto it.
    let rect: CGRect
    /// Quarter turns counter-clockwise.
    let rotation: Int

    var isRotated: Bool { rotation % 2 == 1 }

    /// The picture's size before rotation: what shader presets render.
    var outputSize: CGSize { isRotated ? CGSize(width: rect.height, height: rect.width) : rect.size }

    /// Fits a frame of `frameWidth` × `frameHeight` texels with the core's
    /// `aspectRatio` (before rotation) into the drawable, centred.
    init(drawableSize: CGSize, frameWidth: Int, frameHeight: Int, aspectRatio: Double, rotation: Int, integerScaling: Bool) {
        self.rotation = max(0, rotation) % 4
        let rotated = self.rotation % 2 == 1
        let aspect = aspectRatio > 0 ? aspectRatio : Double(frameWidth) / Double(max(frameHeight, 1))
        let displayAspect = rotated ? 1 / aspect : aspect

        let drawW = drawableSize.width.rounded(.down), drawH = drawableSize.height.rounded(.down)
        var width = drawW, height = drawW / displayAspect
        if height > drawH { height = drawH; width = drawH * displayAspect }

        if integerScaling {
            let sourceHeight = Double(rotated ? frameWidth : frameHeight)
            let factor = floor(height / sourceHeight)
            if factor >= 1 {
                height = factor * sourceHeight
                width = height * displayAspect
            }
        }

        width = min(max(width.rounded(), 1), max(drawW, 1))
        height = min(max(height.rounded(), 1), max(drawH, 1))
        rect = CGRect(x: ((drawW - width) / 2).rounded(.down), y: ((drawH - height) / 2).rounded(.down),
                      width: width, height: height)
    }
}

/// Draws the most recent core frame into an MTKView, aspect-correct, with
/// an optional ambient light or bezel image around it.
///
/// A RetroArch preset renders the frame into an offscreen texture of the
/// picture's on-screen size (before rotation) first; the frame quad then
/// shows that texture 1:1, rotated, between ambient light and bezel.
final class MetalRenderer: NSObject, MTKViewDelegate {
    weak var core: LibretroCore?
    /// The built-in filter or RetroArch preset the picture is drawn with.
    var selection: ShaderSelection = .builtin(.sharp) {
        didSet {
            guard selection != oldValue else { return }
            applySelection()
        }
    }
    var integerScaling = false
    var bezel: BezelStyle = .none
    /// An image drawn over everything, with a transparent hole for the game.
    var bezelImageURL: URL? {
        didSet {
            guard bezelImageURL != oldValue else { return }
            bezelImage = bezelImageURL.flatMap { try? textureLoader.newTexture(URL: $0, options: [.SRGB: false, .origin: MTKTextureLoader.Origin.topLeft]) }
        }
    }
    /// The game runs backwards; presets with frame history follow it.
    var isRewinding = false
    /// Told when a preset can't be used, with a message for the player.
    var onShaderError: ((String) -> Void)?

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

    /// The compiled preset of `selection`, once it is ready.
    private var chain: ShaderChain?
    /// The preset `chain` was compiled from.
    private var chainPreset: ShaderPresetRef?
    /// The preset compiling in the background; the current chain renders meanwhile.
    private var pendingPreset: ShaderPresetRef?
    /// The chain's output at the picture's size before rotation.
    private var shaderOutput: MTLTexture?
    /// `shaderOutput` is older than the frame, its size or the chain.
    private var needsShaderPass = true
    private var lastShaderPassTime: CFTimeInterval = 0

    private static let log = Logger(subsystem: "io.github.bhuaysan.Ursprung", category: "shader")

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
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable else { return }

        let layout = texture.flatMap { texture in
            core.map { core in
                PresentationLayout(drawableSize: view.drawableSize, frameWidth: texture.width, frameHeight: texture.height,
                                   aspectRatio: Double(core.aspectRatio), rotation: core.rotation,
                                   integerScaling: integerScaling)
            }
        }
        if let layout {
            let scale = view.window?.backingScaleFactor ?? 2
            imageRect = CGRect(x: layout.rect.minX / scale, y: layout.rect.minY / scale,
                               width: layout.rect.width / scale, height: layout.rect.height / scale)
        }

        // Command buffers run in commit order: mipmaps, preset, presentation.
        let showsAmbient = bezel == .ambient && texture?.mipmapLevelCount ?? 0 > 1
        if needsMipmaps, showsAmbient || chain != nil, let texture,
           let buffer = queue.makeCommandBuffer(), let blit = buffer.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: texture)
            blit.endEncoding()
            buffer.commit()
            needsMipmaps = false
        }
        let shaded = layout.flatMap { layout in texture.flatMap { shadedPicture(of: $0, size: layout.outputSize) } }

        guard let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        if let texture, let core, let layout {
            var uniforms = makeUniforms(layout: layout, texture: texture, core: core, drawableSize: view.drawableSize)
            if showsAmbient {
                encoder.setRenderPipelineState(ambientPipeline)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
                encoder.setFragmentTexture(texture, index: 0)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }
            var pictureUniforms = uniforms
            if let shaded {
                // Already at output size: show it pixel for pixel.
                pictureUniforms.textureSize = SIMD2(Float(shaded.width), Float(shaded.height))
                pictureUniforms.filter = VideoFilter.nearest.shaderIndex
            }
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBytes(&pictureUniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.setFragmentBytes(&pictureUniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.setFragmentTexture(shaded ?? texture, index: 0)
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
        needsShaderPass = true
    }

    private func makeUniforms(layout: PresentationLayout, texture: MTLTexture, core: LibretroCore,
                              drawableSize: CGSize) -> Uniforms {
        let drawW = Double(drawableSize.width), drawH = Double(drawableSize.height)
        let displayAspect = layout.rect.width / layout.rect.height

        // Quad size in pixels before rotation; the shader rotates in pixel
        // space around the quad's centre, moves it by `offset` and converts
        // to NDC afterwards.
        let output = SIMD2(Float(layout.outputSize.width), Float(layout.outputSize.height))
        let offset = SIMD2(Float(layout.rect.midX - drawW / 2), Float(layout.rect.midY - drawH / 2))

        // The ambient light: the frame scaled to cover the whole drawable.
        let fillWidth = max(drawW, drawH * displayAspect), fillHeight = fillWidth / displayAspect
        let fill = layout.isRotated ? SIMD2(Float(fillHeight), Float(fillWidth)) : SIMD2(Float(fillWidth), Float(fillHeight))
        let ambientLevel = Float(max(0, log2(Double(max(texture.width, texture.height))) - 3))

        // The bezel image: its middle, scaled to cover the drawable.
        var overlaySpan = SIMD2<Float>(1, 1)
        if let bezelImage {
            let imageW = Double(bezelImage.width), imageH = Double(bezelImage.height)
            let fillScale = max(drawW / imageW, drawH / imageH)
            overlaySpan = SIMD2(Float(drawW / (imageW * fillScale)), Float(drawH / (imageH * fillScale)))
        }

        return Uniforms(extent: output / 2, viewportHalf: SIMD2(Float(drawW / 2), Float(drawH / 2)),
                        textureSize: SIMD2(Float(texture.width), Float(texture.height)),
                        outputSize: output, rotation: UInt32(layout.rotation), filter: builtinFilter.shaderIndex,
                        fillExtent: fill / 2, overlaySpan: overlaySpan, ambientLevel: ambientLevel, offset: offset)
    }

    // MARK: - RetroArch presets

    /// The filter used when no preset chain is ready.
    private var builtinFilter: VideoFilter {
        if case .builtin(let filter) = selection { filter } else { .sharp }
    }

    private func applySelection() {
        guard case .preset(let preset) = selection else {
            pendingPreset = nil
            chain = nil
            chainPreset = nil
            shaderOutput = nil
            return
        }
        guard preset != chainPreset, preset != pendingPreset else { return }
        pendingPreset = preset
        let url = preset.url()
        let coreName = core?.libraryName, rotation = core?.rotation ?? 0
        Task { [weak self, queue] in
            var compiled: ShaderChain?
            var failure: Error?
            do {
                compiled = try await Self.compile(url, queue: queue, coreName: coreName, rotation: rotation)
            } catch {
                failure = error
            }
            // A newer selection replaced this one meanwhile.
            guard let self, self.pendingPreset == preset else { return }
            self.pendingPreset = nil
            if let compiled {
                self.chain = compiled
                self.chainPreset = preset
                self.needsShaderPass = true
            } else {
                self.shaderFailed(preset, error: failure)
            }
        }
    }

    /// Parses the preset and compiles its passes, which can take seconds.
    @concurrent
    private static func compile(_ url: URL, queue: MTLCommandQueue, coreName: String?,
                                rotation: Int) async throws -> sending ShaderChain {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: url.path(percentEncoded: false)])
        }
        return try ShaderChain(presetAtPath: url.path(percentEncoded: false), queue: queue, coreName: coreName,
                               rotation: rotation)
    }

    /// Drops the preset: the picture falls back to the Sharp filter.
    private func shaderFailed(_ preset: ShaderPresetRef, error: Error?) {
        Self.log.error("Shader preset \(preset.path, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        chain = nil
        chainPreset = nil
        shaderOutput = nil
        let missing = (error as? CocoaError)?.code == .fileNoSuchFile
        onShaderError?(missing
            ? String(localized: "The shader “\(preset.name)” is missing, so the game uses the Sharp filter.")
            : String(localized: "The shader “\(preset.name)” couldn’t be loaded, so the game uses the Sharp filter."))
    }

    /// Runs the preset on the latest frame when anything changed, and
    /// returns its output; nil without a chain or when it fails.
    private func shadedPicture(of texture: MTLTexture, size: CGSize) -> MTLTexture? {
        guard let chain, let core, let preset = chainPreset else { return nil }
        let width = Int(size.width), height = Int(size.height)
        if shaderOutput?.width != width || shaderOutput?.height != height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width,
                                                                      height: height, mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .private
            shaderOutput = device.makeTexture(descriptor: descriptor)
            needsShaderPass = true
        }
        guard let output = shaderOutput else { return nil }
        guard needsShaderPass else { return output }
        guard let buffer = queue.makeCommandBuffer() else { return nil }

        let now = CACurrentMediaTime()
        let frameTime = lastShaderPassTime > 0 ? min(now - lastShaderPassTime, 1) : 1 / max(core.framesPerSecond, 1)
        let options = ShaderFrameOptions(direction: isRewinding ? -1 : 1,
                                         aspectRatio: core.aspectRatio, framesPerSecond: Float(core.framesPerSecond),
                                         frameTimeDelta: UInt32((frameTime * 1000).rounded()))
        do {
            try chain.render(texture, to: output, commandBuffer: buffer, frameCount: UInt(lastSerial), options: options)
        } catch {
            shaderFailed(preset, error: error)
            return nil
        }
        buffer.commit()
        needsShaderPass = false
        lastShaderPassTime = now
        return output
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
