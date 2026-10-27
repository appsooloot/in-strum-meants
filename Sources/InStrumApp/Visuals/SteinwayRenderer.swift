import Metal
import QuartzCore
import InStrumCore

/// Draws a SteinwayFrame into the render stack.
@MainActor
final class SteinwayRenderer: ThemeRenderer {
    static let keyboardHeight: Float = 0.28
    static let blackKeyLength: Float = 0.62
    static let maxSpotlights = 64

    private let stagePipeline: MTLRenderPipelineState
    private let keyPipeline: MTLRenderPipelineState
    private var stage = [SIMD4<Float>](repeating: .zero, count: 2 + 64)
    private var instances: [SIMD4<Float>] = []
    private var glowColor = SIMD4<Float>(1, 0.706, 0.353, 1)
    private var keyCount = 0
    private var limiter = FlashLimiter()
    private(set) var post = PostSettings()

    init?(device: MTLDevice) {
        guard let library = try? device.makeLibrary(source: MidnightSteinwayShaders.source, options: nil) else { return nil }
        func pipeline(_ vertex: String, _ fragment: String) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: vertex)
            d.fragmentFunction = library.makeFunction(name: fragment)
            d.colorAttachments[0].pixelFormat = RenderStack.sceneFormat
            d.colorAttachments[1].pixelFormat = RenderStack.depthFormat
            return try? device.makeRenderPipelineState(descriptor: d)
        }
        guard let s = pipeline("stage_vertex", "stage_fragment"), let k = pipeline("key_vertex", "key_fragment") else { return nil }
        stagePipeline = s
        keyPipeline = k
    }

    func update(_ f: SteinwayFrame, quality: QualityLevel, gentle: Bool, dt: Double) {
        limiter.gentle = gentle
        let limited = limiter.limit(exposure: f.exposure, sparkle: f.scene.bloom, dt: dt)
        let keyBottom: Float = -0.97
        let keyTop: Float = -1 + 2 * Self.keyboardHeight
        let spots = f.scene.spotlights.sorted { $0.intensity > $1.intensity }.prefix(Self.maxSpotlights)
        stage = [SIMD4<Float>](repeating: .zero, count: 2 + Self.maxSpotlights)
        stage[0] = SIMD4(keyTop, limited.sparkle, f.scene.ambience, Float(spots.count))
        stage[1] = SIMD4(f.spotWidth, f.warmth, f.sheen, f.haze)
        for (i, s) in spots.enumerated() { stage[2 + i] = SIMD4(s.x, s.intensity, 0, 0) }
        glowColor = SIMD4(Float(f.glowColor.r), Float(f.glowColor.g), Float(f.glowColor.b), 1)
        let gap: Float = 0.0015
        instances.removeAll(keepingCapacity: true)
        for k in f.scene.keys {
            let x0 = -0.98 + k.key.x * 1.96 + gap
            let x1 = -0.98 + (k.key.x + k.key.width) * 1.96 - gap
            let y0 = k.key.isBlack ? keyTop - (keyTop - keyBottom) * Self.blackKeyLength : keyBottom
            instances.append(SIMD4(x0, y0, x1, keyTop))
            instances.append(SIMD4(k.key.isBlack ? 1 : 0, k.glow, k.pressed ? 1 : 0, Float(f.finish)))
        }
        keyCount = f.scene.keys.count
        post = PostSettings(bloom: 0.4 + 0.6 * f.bloom, bloomThreshold: 0.7, dof: 0, focusDepth: 0.4, grade: 0,
                            grain: 0.06, vignette: 0.45, exposure: limited.exposure * 1.15, warmth: f.warmth * 0.4,
                            time: Float(f.time), quality: quality)
    }

    func render(stack: RenderStack, commandBuffer cb: MTLCommandBuffer) {
        guard let pass = stack.scenePass(clear: MTLClearColor(red: 0.043, green: 0.035, blue: 0.027, alpha: 1)),
              let e = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        e.setRenderPipelineState(stagePipeline)
        stage.withUnsafeBytes { e.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0) }
        e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        if keyCount > 0 {
            e.setRenderPipelineState(keyPipeline)
            instances.withUnsafeBytes { e.setVertexBytes($0.baseAddress!, length: $0.count, index: 0) }
            e.setFragmentBytes(&glowColor, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: keyCount)
        }
        e.endEncoding()
    }
}
