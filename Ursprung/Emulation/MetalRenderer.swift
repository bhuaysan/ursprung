// SPDX-License-Identifier: GPL-3.0-or-later

import ImageIO
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
    /// The running core, or a still picture in the shader editor.
    weak var source: (any FrameSource)? {
        didSet {
            // Another source's serials say nothing about this one's frames.
            if source !== oldValue { sourceChanged = true }
        }
    }
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
    /// Where a preset's file is; tests use a temporary folder.
    var presetURL: (ShaderPresetRef) -> URL = { $0.url() }
    /// Told when a preset can't be used, with a message for the player.
    var onShaderError: ((String) -> Void)?
    /// Shows the preset's parameters and changes them live.
    var workspace: ShaderWorkspace? {
        didSet {
            guard workspace !== oldValue else { return }
            workspace?.attach { [weak self] in self?.reloadPreset() }
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
    /// The source's latest frame.
    private(set) var texture: MTLTexture?
    private var bezelImage: MTLTexture?
    private var lastSerial: UInt64 = 0
    /// `lastSerial` belongs to an earlier source.
    private var sourceChanged = true
    /// The texture's mipmaps are older than its picture.
    private var needsMipmaps = false

    /// The compiled preset of `selection`, once it is ready.
    private var chain: ShaderChain?
    /// The preset `chain` was compiled from.
    private var chainPreset: ShaderPresetRef?
    /// The preset compiling in the background; the current chain renders meanwhile.
    private var pendingPreset: ShaderPresetRef?
    /// Bumped by every compile, so only the latest one is used.
    private var compileGeneration = 0
    /// A compile runs; compiles can't be stopped, so the next one waits
    /// for it and only the latest of those that wait is started.
    private var isCompiling = false
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

        // The shader editor can render for another screen size and zoom in.
        let tools = workspace?.previewTools ?? ShaderPreviewTools()
        let drawableSize = view.drawableSize
        let layoutSize = tools.outputSize ?? drawableSize
        let layout = texture.flatMap { texture in
            source.map { source in
                PresentationLayout(drawableSize: layoutSize, frameWidth: texture.width, frameHeight: texture.height,
                                   aspectRatio: Double(source.aspectRatio), rotation: source.rotation,
                                   integerScaling: integerScaling)
            }
        }
        if let layout, !tools.changesLayout {
            let scale = view.window?.backingScaleFactor ?? 2
            imageRect = CGRect(x: layout.rect.minX / scale, y: layout.rect.minY / scale,
                               width: layout.rect.width / scale, height: layout.rect.height / scale)
        }

        // Command buffers run in commit order: mipmaps, preset, presentation.
        let showsAmbient = bezel == .ambient && texture?.mipmapLevelCount ?? 0 > 1 && !tools.changesLayout
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
        if let texture, let layout {
            var uniforms = makeUniforms(layout: layout, texture: texture, drawableSize: layoutSize)
            if showsAmbient {
                encoder.setRenderPipelineState(ambientPipeline)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
                encoder.setFragmentTexture(texture, index: 0)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }
            // Scaled into the view: the picture's size on screen relative to the layout.
            var displayScale = 1.0
            if tools.changesLayout {
                let fit = tools.outputSize.map { min(drawableSize.width / $0.width, drawableSize.height / $0.height) } ?? 1
                displayScale = fit * tools.zoom
                let shift = tools.zoom > 1
                    ? SIMD2(Float((tools.focus.x - 0.5) * layout.rect.width), Float((0.5 - tools.focus.y) * layout.rect.height))
                    : .zero
                uniforms.extent *= Float(displayScale)
                uniforms.offset = (uniforms.offset - shift) * Float(displayScale)
                uniforms.viewportHalf = SIMD2(Float(drawableSize.width / 2), Float(drawableSize.height / 2))
            }
            var pictureUniforms = uniforms
            if let shaded {
                // Already at output size: show it pixel for pixel (smoothed when it is scaled down).
                pictureUniforms.textureSize = SIMD2(Float(shaded.width), Float(shaded.height))
                pictureUniforms.filter = (displayScale < 1 ? VideoFilter.smooth : .nearest).shaderIndex
            }
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBytes(&pictureUniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.setFragmentBytes(&pictureUniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.setFragmentTexture(shaded ?? texture, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            if let split = tools.split, shaded != nil,
               let scissor = Self.splitScissor(split, uniforms: uniforms, rotated: layout.isRotated, drawableSize: drawableSize) {
                // The left part without the preset, for comparison.
                encoder.setScissorRect(scissor)
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
                encoder.setFragmentTexture(texture, index: 0)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                encoder.setScissorRect(MTLScissorRect(x: 0, y: 0, width: Int(drawableSize.width), height: Int(drawableSize.height)))
            }
            if let bezelImage, !tools.changesLayout {
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

    /// The part of the drawable left of `split` (0…1 across the picture as
    /// it appears on screen), as a scissor rectangle; nil when empty.
    private static func splitScissor(_ split: Double, uniforms: Uniforms, rotated: Bool,
                                     drawableSize: CGSize) -> MTLScissorRect? {
        let extent = rotated ? SIMD2(uniforms.extent.y, uniforms.extent.x) : uniforms.extent
        let centerX = Double(uniforms.viewportHalf.x + uniforms.offset.x)
        let centerY = Double(uniforms.viewportHalf.y + uniforms.offset.y)
        let left = centerX - Double(extent.x), top = drawableSize.height - (centerY + Double(extent.y))
        let width = Double(extent.x) * 2 * min(max(split, 0), 1)
        let x = max(0, left.rounded()), y = max(0, top.rounded())
        let right = min(drawableSize.width, (left + width).rounded())
        let bottom = min(drawableSize.height, (top + Double(extent.y) * 2).rounded())
        guard right > x, bottom > y else { return nil }
        return MTLScissorRect(x: Int(x), y: Int(y), width: Int(right - x), height: Int(bottom - y))
    }

    private func uploadFrameIfNeeded() {
        guard let source else { return }
        let serial = source.frameSerial
        guard serial != lastSerial || sourceChanged else { return }
        lastSerial = serial
        sourceChanged = false
        source.accessLatestFrame { pixels, width, height, pitch in
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

    private func makeUniforms(layout: PresentationLayout, texture: MTLTexture, drawableSize: CGSize) -> Uniforms {
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

    /// Compiles the selected preset unless it is showing or compiling
    /// already; `reload` compiles it again (its files changed).
    private func applySelection(reload: Bool = false) {
        guard case .preset(let preset) = selection else {
            compileGeneration += 1
            pendingPreset = nil
            chain = nil
            chainPreset = nil
            shaderOutput = nil
            workspace?.useBuiltin()
            return
        }
        guard reload || (preset != chainPreset && preset != pendingPreset) else {
            // Back to the preset that is showing: another one still compiling mustn't replace it.
            if preset == chainPreset, let pendingPreset, pendingPreset != preset {
                compileGeneration += 1
                self.pendingPreset = nil
                workspace?.kept(preset)
            }
            return
        }
        compileGeneration += 1
        pendingPreset = preset
        if preset == chainPreset && chain != nil { workspace?.recompiling() } else { workspace?.compiling(preset) }
        if !isCompiling { startCompile() }
    }

    /// Compiles `pendingPreset` in the background.
    private func startCompile() {
        guard let preset = pendingPreset else { return }
        // A recompile of the preset that is showing keeps showing it, also when it fails.
        let isRecompile = preset == chainPreset && chain != nil
        let generation = compileGeneration
        isCompiling = true
        let url = presetURL(preset)
        let coreName = source?.libraryName, rotation = source?.rotation ?? 0
        Task { [weak self, queue] in
            var compiled: ShaderChain?
            var failure: Error?
            var order: [String] = []
            do {
                compiled = try await Self.compile(url, queue: queue, coreName: coreName, rotation: rotation)
                order = await Self.declarationOrder(url, coreName: coreName, rotation: rotation)
            } catch {
                failure = error
            }
            guard let self else { return }
            self.isCompiling = false
            // A newer selection or change replaced this one meanwhile.
            guard self.compileGeneration == generation else {
                self.startCompile()
                return
            }
            self.pendingPreset = nil
            if let compiled {
                self.chain = compiled
                self.chainPreset = preset
                self.needsShaderPass = true
                let parameters = SlangSource.sorted(compiled.parameters, by: order, name: \.name)
                self.workspace?.loaded(preset, parameters: parameters, values: Self.values(of: compiled),
                                       passCount: compiled.passCount,
                                       apply: { [weak self, weak compiled] name, value in
                                           guard let self, let compiled, self.chain === compiled else { return }
                                           self.setParameter(name, to: value)
                                       },
                                       reload: { [weak self] in self?.reloadPreset() })
            } else if isRecompile, self.chainPreset == preset, self.chain != nil {
                Self.log.error("Shader preset \(preset.path, privacy: .public) failed to recompile: \(String(describing: failure), privacy: .public)")
                self.workspace?.recompileFailed(message: Self.message(for: failure))
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

    /// The parameter names in the order the preset's shaders declare them,
    /// with the wildcards the chain was compiled with.
    @concurrent
    private static func declarationOrder(_ url: URL, coreName: String?, rotation: Int) async -> [String] {
        var wildcards = SlangPreset.defaultWildcards
        wildcards["CORE-REQ-ROT"] = "CORE-REQ-ROT-\((max(rotation, 0) % 4) * 90)"
        if let coreName { wildcards["CORE"] = coreName }
        return SlangSource.declarationOrder(ofPresetAt: url, wildcards: wildcards)
    }

    /// Compiles the selected preset again; the current chain renders meanwhile.
    private func reloadPreset() {
        applySelection(reload: true)
    }

    private static func message(for error: Error?) -> String {
        (error as? CocoaError)?.code == .fileNoSuchFile
            ? String(localized: "The preset file is missing.")
            : (error?.localizedDescription ?? String(localized: "The preset couldn’t be loaded."))
    }

    private static func values(of chain: ShaderChain) -> [String: Float] {
        Dictionary(chain.parameters.map { ($0.name, chain.value(forParameter: $0.name)?.floatValue ?? $0.initial) },
                   uniquingKeysWith: { first, _ in first })
    }

    /// Changes a parameter of the chain; the next frame shows it, also while paused.
    private func setParameter(_ name: String, to value: Float) {
        guard let chain else { return }
        do {
            try chain.setValue(value, forParameter: name)
            needsShaderPass = true
        } catch {
            Self.log.error("Shader parameter \(name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Drops the preset: the picture falls back to the Sharp filter.
    private func shaderFailed(_ preset: ShaderPresetRef, error: Error?) {
        Self.log.error("Shader preset \(preset.path, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        chain = nil
        chainPreset = nil
        shaderOutput = nil
        let missing = (error as? CocoaError)?.code == .fileNoSuchFile
        workspace?.failed(preset, message: Self.message(for: error))
        onShaderError?(missing
            ? String(localized: "The shader “\(preset.name)” is missing, so the game uses the Sharp filter.")
            : String(localized: "The shader “\(preset.name)” couldn’t be loaded, so the game uses the Sharp filter."))
    }

    /// Runs the preset on the latest frame when anything changed, and
    /// returns its output; nil without a chain or when it fails.
    private func shadedPicture(of texture: MTLTexture, size: CGSize) -> MTLTexture? {
        guard let chain, let source, let preset = chainPreset else { return nil }
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
        let frameTime = lastShaderPassTime > 0 ? min(now - lastShaderPassTime, 1) : 1 / max(source.framesPerSecond, 1)
        let options = ShaderFrameOptions(direction: isRewinding ? -1 : 1,
                                         aspectRatio: source.aspectRatio, framesPerSecond: Float(source.framesPerSecond),
                                         frameTimeDelta: UInt32((frameTime * 1000).rounded()))
        do {
            try chain.render(texture, to: output, commandBuffer: buffer, frameCount: UInt(lastSerial), options: options)
        } catch {
            shaderFailed(preset, error: error)
            return nil
        }
        if let workspace {
            let budget = 1 / max(source.framesPerSecond, 1)
            buffer.addCompletedHandler { [weak workspace] buffer in
                let seconds = buffer.gpuEndTime - buffer.gpuStartTime
                Task { @MainActor in workspace?.recordGPUTime(seconds, budget: budget, at: CACurrentMediaTime()) }
            }
        }
        #if DEBUG
        writeDebugSnapshot(of: output, in: buffer)
        #endif
        buffer.commit()
        needsShaderPass = false
        lastShaderPassTime = now
        return output
    }

    #if DEBUG
    /// With URSPRUNG_SNAPSHOT_DIR set, the preset's output is written there
    /// as `<debugSnapshotName>.png` every two seconds; window snapshots
    /// can't show Metal layers.
    var debugSnapshotName: String?
    private var lastDebugSnapshot: CFTimeInterval = 0

    private func writeDebugSnapshot(of texture: MTLTexture, in buffer: MTLCommandBuffer) {
        guard let name = debugSnapshotName, let path = ProcessInfo.processInfo.environment["URSPRUNG_SNAPSHOT_DIR"],
              CACurrentMediaTime() - lastDebugSnapshot >= 2 else { return }
        let width = texture.width, height = texture.height, bytesPerRow = width * 4
        guard let copy = device.makeBuffer(length: bytesPerRow * height, options: .storageModeShared),
              let blit = buffer.makeBlitCommandEncoder() else { return }
        lastDebugSnapshot = CACurrentMediaTime()
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                  sourceSize: MTLSize(width: width, height: height, depth: 1), to: copy, destinationOffset: 0,
                  destinationBytesPerRow: bytesPerRow, destinationBytesPerImage: bytesPerRow * height)
        blit.endEncoding()
        let url = URL(filePath: path, directoryHint: .isDirectory).appending(path: "\(name).png")
        // Only read after the GPU is done with it.
        nonisolated(unsafe) let pixels = copy
        buffer.addCompletedHandler { _ in
            let data = Data(bytes: pixels.contents(), count: bytesPerRow * height)
            let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            guard let provider = CGDataProvider(data: data as CFData),
                  let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                      bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info,
                                      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
                  let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
            else { return }
            CGImageDestinationAddImage(destination, image, nil)
            CGImageDestinationFinalize(destination)
        }
    }
    #endif
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
