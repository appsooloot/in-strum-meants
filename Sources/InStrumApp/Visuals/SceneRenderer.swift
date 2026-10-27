import MetalKit
import QuartzCore
import InStrumCore

/// Draws a VisualScene each frame. Runs on the display thread; never touches audio.
final class SceneRenderer: NSObject, MTKViewDelegate {
    static let keyboardHeight: Float = 0.28      // fraction of the view
    static let blackKeyLength: Float = 0.62      // fraction of white key length
    static let maxSpotlights = 64

    private let model: AppModel
    private let queue: MTLCommandQueue
    private let stagePipeline: MTLRenderPipelineState
    private let keyPipeline: MTLRenderPipelineState
    private var scene = MidnightSteinwayScene()
    private var lastTime = CACurrentMediaTime()

    init?(view: MTKView, model: AppModel) {
        guard let device = view.device, let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: MidnightSteinwayShaders.source, options: nil)
        else { return nil }
        func pipeline(_ vertex: String, _ fragment: String) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: vertex)
            d.fragmentFunction = library.makeFunction(name: fragment)
            d.colorAttachments[0].pixelFormat = view.colorPixelFormat
            return try? device.makeRenderPipelineState(descriptor: d)
        }
        guard let stage = pipeline("stage_vertex", "stage_fragment"),
              let keys = pipeline("key_vertex", "key_fragment") else { return nil }
        self.model = model
        self.queue = queue
        self.stagePipeline = stage
        self.keyPipeline = keys
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let dt = min(0.1, now - lastTime)
        lastTime = now
        for event in model.drainEvents() { scene.handle(event) }
        let frame = scene.step(dt: dt, intensity: model.intensity, audioLevel: model.audioLevel)

        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }

        let keyBottom: Float = -0.97
        let keyTop: Float = -1 + 2 * Self.keyboardHeight

        // Stage: params + up to 64 spotlights, brightest first.
        let spots = frame.spotlights.sorted { $0.intensity > $1.intensity }.prefix(Self.maxSpotlights)
        var stage = [SIMD4<Float>](repeating: .zero, count: 1 + Self.maxSpotlights)
        stage[0] = SIMD4(keyTop, frame.bloom, frame.ambience, Float(spots.count))
        for (i, s) in spots.enumerated() { stage[1 + i] = SIMD4(s.x, s.intensity, 0, 0) }
        encoder.setRenderPipelineState(stagePipeline)
        stage.withUnsafeBytes { encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0) }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        // Keys: one instanced quad each.
        let gap: Float = 0.0015
        var instances: [SIMD4<Float>] = []
        instances.reserveCapacity(frame.keys.count * 2)
        for k in frame.keys {
            let x0 = -0.98 + k.key.x * 1.96 + gap
            let x1 = -0.98 + (k.key.x + k.key.width) * 1.96 - gap
            let y0 = k.key.isBlack ? keyTop - (keyTop - keyBottom) * Self.blackKeyLength : keyBottom
            instances.append(SIMD4(x0, y0, x1, keyTop))
            instances.append(SIMD4(k.key.isBlack ? 1 : 0, k.glow, k.pressed ? 1 : 0, 0))
        }
        encoder.setRenderPipelineState(keyPipeline)
        instances.withUnsafeBytes { encoder.setVertexBytes($0.baseAddress!, length: $0.count, index: 0) }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: frame.keys.count)

        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }
}
