import CoreGraphics
import CoreVideo
import Metal
import simd

/// What every Metal frame shares: the device, the pipelines of
/// `RoadTripFrameShaders.metal`, the images already on the GPU and the
/// scratch masks of the strokes. Thread-safe: the export draws several frames
/// at once.
final class RoadTripMetalEngine: @unchecked Sendable {

    /// nil where Metal (or the app's shaders) is not available: the frames
    /// are then drawn by Core Graphics.
    static let shared: RoadTripMetalEngine? = RoadTripMetalEngine()

    let device: MTLDevice
    let queue: MTLCommandQueue
    let quadPipeline: MTLRenderPipelineState
    let segmentPipeline: MTLRenderPipelineState
    let sampler: MTLSamplerState
    private let pixelBufferTextures: CVMetalTextureCache

    /// Each image on the GPU once, mipmapped (a snapshot shrunk onto the
    /// canvas stays clean), bounded by bytes and emptied after an export.
    private let textures: NSCache<CGImage, TextureBox> = {
        let cache = NSCache<CGImage, TextureBox>()
        cache.totalCostLimit = 400 * 1024 * 1024
        return cache
    }()

    private let scratchLock = NSLock()
    private var scratch: [String: [MTLTexture]] = [:]

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let quadVertex = library.makeFunction(name: "quadVertex"),
              let quadFragment = library.makeFunction(name: "quadFragment"),
              let segmentVertex = library.makeFunction(name: "segmentVertex"),
              let segmentFragment = library.makeFunction(name: "segmentFragment") else { return nil }

        // Premultiplied source over.
        let quad = MTLRenderPipelineDescriptor()
        quad.vertexFunction = quadVertex
        quad.fragmentFunction = quadFragment
        let color = quad.colorAttachments[0]!
        color.pixelFormat = .bgra8Unorm
        color.isBlendingEnabled = true
        color.rgbBlendOperation = .add
        color.alphaBlendOperation = .add
        color.sourceRGBBlendFactor = .one
        color.sourceAlphaBlendFactor = .one
        color.destinationRGBBlendFactor = .oneMinusSourceAlpha
        color.destinationAlphaBlendFactor = .oneMinusSourceAlpha

        // A line's coverage per style: the most of its segments, never their sum.
        let segment = MTLRenderPipelineDescriptor()
        segment.vertexFunction = segmentVertex
        segment.fragmentFunction = segmentFragment
        let mask = segment.colorAttachments[0]!
        mask.pixelFormat = .rgba8Unorm
        mask.isBlendingEnabled = true
        mask.rgbBlendOperation = .max
        mask.alphaBlendOperation = .max
        mask.sourceRGBBlendFactor = .one
        mask.destinationRGBBlendFactor = .one
        mask.sourceAlphaBlendFactor = .one
        mask.destinationAlphaBlendFactor = .one

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.mipFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge

        var cache: CVMetalTextureCache?
        guard let quadPipeline = try? device.makeRenderPipelineState(descriptor: quad),
              let segmentPipeline = try? device.makeRenderPipelineState(descriptor: segment),
              let sampler = device.makeSamplerState(descriptor: samplerDescriptor),
              CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache else { return nil }
        self.device = device
        self.queue = queue
        self.quadPipeline = quadPipeline
        self.segmentPipeline = segmentPipeline
        self.sampler = sampler
        self.pixelBufferTextures = cache
    }

    final class TextureBox {
        let texture: MTLTexture
        init(_ texture: MTLTexture) { self.texture = texture }
    }

    /// `image` on the GPU: its pixels drawn into a BGRA buffer (premultiplied,
    /// device RGB, the frame's own format), copied into a texture whose
    /// smaller levels the GPU then fills. Made once per image.
    func texture(for image: CGImage) -> MTLTexture? {
        if let cached = textures.object(forKey: image) { return cached.texture }
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        let bytesPerRow = width * 4
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: true
        )
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor),
              let bitmap = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              ) else { return nil }
        bitmap.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let pixels = bitmap.data else { return nil }
        // A bitmap context's first row in memory is the image's top: as a texture's.
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: pixels, bytesPerRow: bytesPerRow)
        if texture.mipmapLevelCount > 1,
           let commands = queue.makeCommandBuffer(),
           let blit = commands.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: texture)
            blit.endEncoding()
            commands.commit()
            commands.waitUntilCompleted()
        }
        textures.setObject(TextureBox(texture), forKey: image, cost: bytesPerRow * height * 4 / 3)
        return texture
    }

    /// A Metal view of `pixelBuffer`'s memory (IOSurface-backed: written in
    /// place); nil for a buffer the GPU cannot share.
    func renderTarget(for pixelBuffer: CVPixelBuffer) -> (texture: MTLTexture, keepAlive: CVMetalTexture)? {
        guard CVPixelBufferGetIOSurface(pixelBuffer) != nil else { return nil }
        var wrapped: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil, pixelBufferTextures, pixelBuffer, nil, .bgra8Unorm,
            CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer), 0, &wrapped
        )
        guard status == kCVReturnSuccess, let wrapped, let texture = CVMetalTextureGetTexture(wrapped) else { return nil }
        return (texture, wrapped)
    }

    /// A scratch render target (a stroke's coverage), taken
    /// for one frame and given back.
    func takeScratch(_ format: MTLPixelFormat, width: Int, height: Int) -> MTLTexture? {
        let key = "\(format.rawValue)-\(width)x\(height)"
        scratchLock.lock()
        if let texture = scratch[key]?.popLast() {
            scratchLock.unlock()
            return texture
        }
        scratchLock.unlock()
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        return device.makeTexture(descriptor: descriptor)
    }

    func giveBack(_ texture: MTLTexture) {
        let key = "\(texture.pixelFormat.rawValue)-\(texture.width)x\(texture.height)"
        scratchLock.lock()
        scratch[key, default: []].append(texture)
        scratchLock.unlock()
    }

    /// Lets go of every texture (an export is over).
    func purge() {
        textures.removeAllObjects()
        scratchLock.lock()
        scratch = [:]
        scratchLock.unlock()
        CVMetalTextureCacheFlush(pixelBufferTextures, 0)
    }
}

// MARK: - Canvas

/// One export frame drawn by the GPU, in a single command buffer, straight
/// into the encoder's pixel buffer.
final class RoadTripMetalCanvas: RoadTripFrameCanvas {

    /// `RoadTripFrameShaders.metal`'s `Quad`, field for field.
    struct Quad {
        var origin: SIMD2<Float>
        var axisX: SIMD2<Float>
        var axisY: SIMD2<Float>
        var uvRect: SIMD4<Float>
        var color: SIMD4<Float>
        var size: SIMD2<Float>
        var radius: Float
        var blur: Float
        var margin: Float
        var flags: UInt32
    }

    /// `RoadTripFrameShaders.metal`'s `Segment`.
    struct Segment {
        var a: SIMD2<Float>
        var b: SIMD2<Float>
        var halfWidths: SIMD4<Float>
    }

    static let textured: UInt32 = 1
    static let ellipse: UInt32 = 2
    static let vignetteFlag: UInt32 = 4
    static let strokes: UInt32 = 16

    let size: CGSize
    private let engine: RoadTripMetalEngine
    private let pixelBuffer: CVPixelBuffer
    private let target: MTLTexture
    /// When the buffer cannot be shared: drawn here, copied in at the end.
    private let copiesBack: Bool
    private var keepAlive: CVMetalTexture?
    private let commands: MTLCommandBuffer
    private var encoder: MTLRenderCommandEncoder?
    private var scratch: [MTLTexture] = []
    private var canvasSize: SIMD2<Float>
    /// The styles' colours of the stroke being composited (`kStrokes`).
    private var strokeColors = [SIMD4<Float>](repeating: .zero, count: 3)

    init?(pixelBuffer: CVPixelBuffer, engine: RoadTripMetalEngine) {
        let width = CVPixelBufferGetWidth(pixelBuffer), height = CVPixelBufferGetHeight(pixelBuffer)
        guard let commands = engine.queue.makeCommandBuffer() else { return nil }
        if let shared = engine.renderTarget(for: pixelBuffer) {
            target = shared.texture
            keepAlive = shared.keepAlive
            copiesBack = false
        } else {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .shared
            guard let texture = engine.device.makeTexture(descriptor: descriptor) else { return nil }
            target = texture
            copiesBack = true
        }
        self.engine = engine
        self.pixelBuffer = pixelBuffer
        self.commands = commands
        self.size = CGSize(width: width, height: height)
        self.canvasSize = SIMD2(Float(width), Float(height))
        // The frame starts black, as the Core Graphics one.
        _ = frameEncoder(clear: true)
    }

    // MARK: Operations

    func fill(_ rect: CGRect, color: RoadTripRGBA, rotation: Double) {
        var quad = Self.quad(rect, rotation: rotation)
        quad.color = Self.premultiplied(color)
        drawQuads([quad], texture: nil)
    }

    func draw(_ image: CGImage, in rect: CGRect, source: CGRect, alpha: Double, rotation: Double, mask: RoadTripMask) {
        guard alpha > 0, let texture = engine.texture(for: image) else { return }
        var quad = Self.quad(rect, rotation: rotation)
        quad.uvRect = SIMD4(Float(source.minX), Float(source.minY), Float(source.width), Float(source.height))
        quad.color = SIMD4(repeating: Float(alpha))
        quad.flags = Self.textured
        switch mask {
        case .none: break
        case .roundedRect(let radius): quad.radius = Float(radius)
        case .ellipse: quad.flags |= Self.ellipse
        }
        drawQuads([quad], texture: texture)
    }

    func circle(center: CGPoint, radius: CGFloat, color: RoadTripRGBA) {
        var quad = Self.quad(CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2), rotation: 0)
        quad.color = Self.premultiplied(color)
        quad.flags = Self.ellipse
        drawQuads([quad], texture: nil)
    }

    func circleShadow(in rect: CGRect, blur: CGFloat, color: RoadTripRGBA) {
        var quad = Self.quad(rect, rotation: 0)
        quad.color = Self.premultiplied(color)
        quad.flags = Self.ellipse
        // A Gaussian blur of `blur` reaches about its width out on each side.
        quad.blur = Float(blur) * 0.6
        quad.margin = Float(blur) * 1.2
        drawQuads([quad], texture: nil)
    }

    func stroke(_ lines: [[CGPoint]], styles: [(color: RoadTripRGBA, width: CGFloat)], alpha: Double) {
        guard alpha > 0, !styles.isEmpty else { return }
        // Up to three styles share one pass: their coverages in red, green, blue.
        let used = Array(styles.prefix(3))
        var halfWidths = SIMD4<Float>(repeating: 0)
        var colors = [SIMD4<Float>](repeating: .zero, count: 3)
        for (i, style) in used.enumerated() {
            halfWidths[i] = Float(style.width) / 2
            colors[i] = Self.premultiplied(style.color)
        }
        var segments: [Segment] = []
        var minPoint = SIMD2<Float>(repeating: .greatestFiniteMagnitude)
        var maxPoint = SIMD2<Float>(repeating: -.greatestFiniteMagnitude)
        for line in lines where line.count >= 2 {
            for i in 1..<line.count {
                let a = SIMD2(Float(line[i - 1].x), Float(line[i - 1].y))
                let b = SIMD2(Float(line[i].x), Float(line[i].y))
                segments.append(Segment(a: a, b: b, halfWidths: halfWidths))
                minPoint = simd_min(minPoint, simd_min(a, b))
                maxPoint = simd_max(maxPoint, simd_max(a, b))
            }
        }
        guard !segments.isEmpty else { return }
        // Only where the lines are: their bounds, grown by the widest style.
        let reach = halfWidths.max() + 2
        let bounds = CGRect(
            x: CGFloat(minPoint.x - reach), y: CGFloat(minPoint.y - reach),
            width: CGFloat(maxPoint.x - minPoint.x + 2 * reach), height: CGFloat(maxPoint.y - minPoint.y + 2 * reach)
        ).integral.intersection(CGRect(origin: .zero, size: size))
        guard !bounds.isEmpty,
              let mask = engine.takeScratch(.rgba8Unorm, width: target.width, height: target.height),
              let buffer = segments.withUnsafeBytes({ engine.device.makeBuffer(bytes: $0.baseAddress!, length: $0.count) })
        else { return }
        scratch.append(mask)

        endEncoder()
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = mask
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let maskEncoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        maskEncoder.setScissorRect(MTLScissorRect(
            x: Int(bounds.minX), y: Int(bounds.minY), width: Int(bounds.width), height: Int(bounds.height)
        ))
        maskEncoder.setRenderPipelineState(engine.segmentPipeline)
        maskEncoder.setVertexBuffer(buffer, offset: 0, index: 0)
        maskEncoder.setVertexBytes(&canvasSize, length: MemoryLayout<SIMD2<Float>>.size, index: 1)
        maskEncoder.setFragmentBuffer(buffer, offset: 0, index: 0)
        maskEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: segments.count)
        maskEncoder.endEncoding()

        // The styles over one another, faded as one, onto the frame.
        var quad = Self.quad(bounds, rotation: 0)
        quad.margin = 0
        quad.uvRect = SIMD4(
            Float(bounds.minX / size.width), Float(bounds.minY / size.height),
            Float(bounds.width / size.width), Float(bounds.height / size.height)
        )
        quad.color = SIMD4(0, 0, 0, Float(alpha))
        quad.flags = Self.strokes
        strokeColors = colors
        drawQuads([quad], texture: mask)
        strokeColors = [SIMD4<Float>](repeating: .zero, count: 3)
    }

    func vignette() {
        var quad = Self.quad(CGRect(origin: .zero, size: size), rotation: 0)
        quad.flags = Self.vignetteFlag
        drawQuads([quad], texture: nil)
    }

    func finish() {
        endEncoder()
        if copiesBack {
            commands.commit()
            commands.waitUntilCompleted()
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
                target.getBytes(base, bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                                from: MTLRegionMake2D(0, 0, target.width, target.height), mipmapLevel: 0)
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        } else {
            commands.commit()
            commands.waitUntilCompleted()
        }
        keepAlive = nil
        for texture in scratch { engine.giveBack(texture) }
        scratch = []
    }

    // MARK: Encoding

    private func frameEncoder(clear: Bool = false) -> MTLRenderCommandEncoder? {
        if let encoder { return encoder }
        encoder = encoder(on: target, clear: clear)
        return encoder
    }

    private func encoder(on texture: MTLTexture, clear: Bool) -> MTLRenderCommandEncoder? {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = clear ? .clear : .load
        pass.colorAttachments[0].clearColor = MTLClearColor(
            red: 0, green: 0, blue: 0, alpha: texture === target ? 1 : 0
        )
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        encoder.setRenderPipelineState(engine.quadPipeline)
        encoder.setFragmentSamplerState(engine.sampler, index: 0)
        return encoder
    }

    private func endEncoder() {
        encoder?.endEncoding()
        encoder = nil
    }

    private func drawQuads(_ quads: [Quad], texture: MTLTexture?) {
        guard let encoder = frameEncoder() else { return }
        for quad in quads { encode(quad, texture: texture, on: encoder) }
    }

    private func encode(_ quad: Quad, texture: MTLTexture?, on encoder: MTLRenderCommandEncoder) {
        var quad = quad
        encoder.setVertexBytes(&quad, length: MemoryLayout<Quad>.stride, index: 0)
        encoder.setVertexBytes(&canvasSize, length: MemoryLayout<SIMD2<Float>>.size, index: 1)
        encoder.setFragmentBytes(&quad, length: MemoryLayout<Quad>.stride, index: 0)
        encoder.setFragmentBytes(&canvasSize, length: MemoryLayout<SIMD2<Float>>.size, index: 1)
        strokeColors.withUnsafeBytes { encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 2) }
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    /// The quad of `rect` tilted `rotation` (clockwise, y down) about its
    /// center, its edges antialiased.
    private static func quad(_ rect: CGRect, rotation: Double) -> Quad {
        let c = Float(cos(rotation)), s = Float(sin(rotation))
        let w = Float(rect.width), h = Float(rect.height)
        let axisX = SIMD2(c, s) * w
        let axisY = SIMD2(-s, c) * h
        let center = SIMD2(Float(rect.midX), Float(rect.midY))
        return Quad(
            origin: center - axisX / 2 - axisY / 2, axisX: axisX, axisY: axisY,
            uvRect: SIMD4(0, 0, 1, 1), color: SIMD4(0, 0, 0, 0), size: SIMD2(w, h),
            radius: 0, blur: 0, margin: 1, flags: 0
        )
    }

    private static func premultiplied(_ color: RoadTripRGBA) -> SIMD4<Float> {
        let a = Float(color.alpha)
        return SIMD4(Float(color.red) * a, Float(color.green) * a, Float(color.blue) * a, a)
    }
}
