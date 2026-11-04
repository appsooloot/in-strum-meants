import Metal
import simd
import InStrumCore

/// A window between a room and its view (spec §7): panes in rows and columns, bars between them, a frame around.
struct WindowSpec: Equatable {
    enum Material: Equatable { case logWood, paintedSash, paperScreen }

    var columns: Int
    var rows: Int
    /// The bars' width as a fraction of the glass width.
    var bar: Float
    /// NDC x0, y0, x1, y1 of the glass.
    var rect: SIMD4<Float>
    var material: Material
    /// The outer frame's width in NDC x (its height on screen matches it).
    var frameWidth: Float

    /// Columns and rows as the frost field lays them out (it caps them at 12 × 8).
    var layout: (columns: Int, rows: Int) { (min(max(columns, 1), 12), min(max(rows, 1), 8)) }

    /// Each pane in window coordinates (x0, y0, x1, y1: 0…1 across the glass, y up), laid out exactly as the
    /// frost field's panes, so frost never grows under a bar.
    func panes() -> [SIMD4<Float>] {
        let w = Float(FrostField.width), h = Float(FrostField.height)
        return FrostField.paneRects(columns: columns, rows: rows, bar: bar).map {
            SIMD4(Float($0.x0) / w, 1 - Float($0.y1 + 1) / h, Float($0.x1 + 1) / w, 1 - Float($0.y0) / h)
        }
    }

    /// The bars between panes: (lo, hi, kind, 0), where kind 0 is vertical (lo and hi are x) and 1 horizontal (y).
    func bars() -> [SIMD4<Float>] {
        let p = panes()
        let (cols, rws) = layout
        guard p.count == cols * rws else { return [] }
        var out: [SIMD4<Float>] = []
        for c in 0..<(cols - 1) { out.append(SIMD4(p[c].z, p[c + 1].x, 0, 0)) }
        for r in 0..<(rws - 1) { out.append(SIMD4(p[(r + 1) * cols].w, p[r * cols].y, 1, 0)) }
        return out
    }

    /// Window coordinates (0…1, y up) to NDC.
    func ndc(_ w: SIMD2<Float>) -> SIMD2<Float> {
        SIMD2(rect.x, rect.y) + w * SIMD2(rect.z - rect.x, rect.w - rect.y)
    }
}

/// A warm clear patch on the glass, in window coordinates (0…1, y up); the radius is a fraction of the width.
struct GlassPatch: Equatable { var x, y, radius, warmth: Float }

/// The Window Kit's glass and frame (spec §7.2, §7.3): frost thresholded from a grown field (with warm patches,
/// glints and, on High and Ultra, the blurred view it scatters), condensation, drips, stuck flakes and the room's
/// reflection; then the frame and bars in log wood or a painted sash.
@MainActor
final class WindowGlassLayer {
    static let maxFlakes = 40, maxDrips = 12, maxBars = 19, maxPatches = 48
    static func patchCap(_ q: QualityLevel) -> Int { q == .lite ? 24 : 48 }

    /// The share of the glass frosted (an estimate from the field, for tests).
    private(set) var frostCoverage: Float = 0
    private(set) var stuckFlakeCount = 0
    private(set) var dripCount = 0
    private(set) var patchCount = 0
    /// Instance buffers made so far: a ring of three, grown only when too small (never one per frame).
    private(set) var bufferAllocations = 0
    var hasField: Bool { fieldTexture != nil }

    private struct Flake { var x, y, size, life, age, rot: Float }
    private struct Drip { var x, y, bottom, speed, phase, trail, size: Float }

    private let device: MTLDevice
    private let glassPipeline, dropPipeline, framePipeline, blurPipeline: MTLRenderPipelineState
    private let placeholder: MTLTexture
    private var fieldTexture: MTLTexture?
    /// Field cells inside panes, every sixth each way, for the coverage estimate.
    private var samples: [(x: Float, y: Float, arrival: Float)] = []
    private var blurTexture: MTLTexture?
    private var quality: QualityLevel = .high
    private var spec = WindowSpec(columns: 1, rows: 1, bar: 0, rect: SIMD4(-1, -1, 1, 1), material: .logWood, frameWidth: 0.05)
    private var u = [SIMD4<Float>](repeating: .zero, count: 7 + 19 + 48)
    private var time: Double = 0
    private var rng = SeededRandom(seed: 0x6A55_F205)
    private var flakes: [Flake] = []
    private var drips: [Drip] = []
    private var instances: [SIMD4<Float>] = []
    private var ring: [MTLBuffer?] = [nil, nil, nil]
    private var slot = 0
    private var instanceCount = 0
    private var aspect: Float = 16.0 / 9

    init?(device: MTLDevice) {
        guard let lib = try? device.makeLibrary(source: WindowKitShaders.source, options: nil) else { return nil }
        func make(_ v: String, _ f: String, blend: Bool, depth: Bool) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: v)
            d.fragmentFunction = lib.makeFunction(name: f)
            d.colorAttachments[0].pixelFormat = RenderStack.sceneFormat
            if blend {
                d.colorAttachments[0].isBlendingEnabled = true
                d.colorAttachments[0].sourceRGBBlendFactor = .one
                d.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
                d.colorAttachments[0].sourceAlphaBlendFactor = .one
                d.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            if depth {
                d.colorAttachments[1].pixelFormat = RenderStack.depthFormat
                if blend { d.colorAttachments[1].writeMask = [] }
            }
            return try? device.makeRenderPipelineState(descriptor: d)
        }
        guard let g = make("glass_vertex", "glass_fragment", blend: true, depth: true),
              let dr = make("glassdrop_vertex", "glassdrop_fragment", blend: true, depth: true),
              let fr = make("frame_vertex", "frame_fragment", blend: false, depth: true),
              let bl = make("glass_fullscreen_vertex", "blur_down_fragment", blend: false, depth: false) else { return nil }
        let pd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 1, height: 1, mipmapped: false)
        pd.usage = [.shaderRead]
        guard let ph = device.makeTexture(descriptor: pd) else { return nil }
        var zero = [UInt16](repeating: 0, count: 4)
        ph.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &zero, bytesPerRow: 8)
        self.device = device
        glassPipeline = g; dropPipeline = dr; framePipeline = fr; blurPipeline = bl; placeholder = ph
    }

    /// Uploads the grown field once (16-bit, 0…1). Until then the glass draws a plain radial fallback.
    func setField(_ f: FrostField) {
        let w = FrostField.width, h = FrostField.height
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Unorm, width: w, height: h, mipmapped: false)
        d.usage = [.shaderRead]
        guard let tex = device.makeTexture(descriptor: d), f.arrival.count == w * h else { return }
        var bits = f.arrival.map { UInt16((min(max($0.isFinite ? $0 : 1, 0), 1) * 65535).rounded()) }
        tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: &bits, bytesPerRow: w * 2)
        fieldTexture = tex
        samples.removeAll()
        for y in stride(from: 3, to: h, by: 6) {
            for x in stride(from: 3, to: w, by: 6) {
                let a = f.arrival[y * w + x]
                // Bars hold 0; corner nuclei are 0 too but lie at pane corners, never on a sample this far in.
                if a > 0 { samples.append(((Float(x) + 0.5) / Float(w), 1 - (Float(y) + 0.5) / Float(h), a)) }
            }
        }
    }

    // MARK: - Update

    func update(spec: WindowSpec, frost: Float, patches: [GlassPatch], condensation: Float, wetDrips: Float, snow: Float,
                reflection: SIMD4<Float>, glint: SIMD4<Float>, quality: QualityLevel, dt: Double,
                outsideLight: SIMD3<Float> = SIMD3(0.75, 0.8, 0.86), aspect: Float = 16.0 / 9, sparkle: Float = 1) {
        func clean(_ v: Float, _ hi: Float = 1) -> Float { v.isFinite ? min(max(v, 0), hi) : 0 }
        func clean3(_ v: SIMD3<Float>, _ hi: Float) -> SIMD3<Float> { SIMD3(clean(v.x, hi), clean(v.y, hi), clean(v.z, hi)) }
        let step = dt.isFinite ? min(max(dt, 0), 0.1) : 0
        let fstep = Float(step)
        self.spec = spec
        self.quality = quality
        self.aspect = aspect.isFinite && aspect > 0.1 ? min(aspect, 10) : 16.0 / 9
        time += step
        let level = clean(frost), cond = clean(condensation), wet = clean(wetDrips), snowing = clean(snow)
        let shown = Array(patches.lazy.filter {
            $0.x.isFinite && $0.y.isFinite && $0.radius.isFinite && $0.radius > 0 && $0.warmth.isFinite
        }.prefix(Self.patchCap(quality)))
        patchCount = shown.count
        let panes = spec.panes(), bars = spec.bars()
        let inside = clean3(SIMD3(glint.x, glint.y, glint.z), 4), outside = clean3(outsideLight, 8)

        u[0] = spec.rect
        u[1] = SIMD4(level, cond, Float(time.truncatingRemainder(dividingBy: 3600)), 0)
        u[2] = SIMD4(inside, clean(glint.w, 2))
        u[3] = SIMD4(clean3(SIMD3(reflection.x, reflection.y, reflection.z), 4), clean(reflection.w, 0.3))
        u[4] = SIMD4(outside, hasField ? 1 : 0)
        let material: Float = spec.material == .logWood ? 0 : 1
        let qualityCode: Float = quality == .lite ? 0 : 1
        u[5] = SIMD4(Float(shown.count), Float(min(bars.count, Self.maxBars)), material, clean(spec.frameWidth, 0.5))
        if spec.material == .paperScreen { u[5].z = 3 }   // paper is material 3 in the shader (its branches stand alone)
        u[6] = SIMD4(self.aspect, qualityCode, clean(sparkle, 2), 0)
        for i in 0..<Self.maxBars { u[7 + i] = i < bars.count ? bars[i] : .zero }
        for i in 0..<Self.maxPatches {
            u[26 + i] = i < shown.count ? SIMD4(shown[i].x, shown[i].y, shown[i].radius, clean(shown[i].warmth)) : .zero
        }
        frostCoverage = coverage(level: level, patches: shown)

        // Stuck flakes: snow landing on the glass as tiny stars that melt in 5–10 s.
        if snowing > 0.2, !panes.isEmpty {
            var expected = 6 * snowing * fstep
            while expected > 0 {
                if rng.unit() < expected, flakes.count < Self.maxFlakes {
                    let p = panes[min(Int(rng.unit() * Float(panes.count)), panes.count - 1)]
                    flakes.append(Flake(x: rng.range(p.x, p.z), y: rng.range(p.y, p.w), size: rng.range(0.004, 0.009),
                                        life: rng.range(5, 10), age: 0, rot: rng.range(0, 1.05)))
                }
                expected -= 1
            }
        }
        for i in flakes.indices { flakes[i].age += fstep }
        flakes.removeAll { $0.age >= $0.life }
        stuckFlakeCount = flakes.count

        // Drips: from the top of the frame while wet (after rain), and now and then from the condensation band.
        if !panes.isEmpty {
            let fromTop = wet > 0.3 ? wet * 0.8 * fstep : 0
            let fromFog = 0.02 * cond * Float(panes.count) * fstep
            if rng.unit() < fromTop + fromFog, drips.count < Self.maxDrips {
                let p = panes[min(Int(rng.unit() * Float(panes.count)), panes.count - 1)]
                let top = rng.unit() * (fromTop + fromFog) < fromTop
                let y = top ? p.w - 0.01 : p.y + cond * 0.22 * (p.w - p.y) * 0.6
                drips.append(Drip(x: rng.range(p.x + 0.01, p.z - 0.01), y: y, bottom: p.y, speed: rng.range(0.08, 0.2),
                                  phase: rng.range(0, 6), trail: 0, size: rng.range(0.0035, 0.006)))
            }
        }
        for i in drips.indices {
            var d = drips[i]
            d.phase += fstep * 1.7
            // Drops cling, then slide in short runs.
            let run = 0.25 + 0.75 * max(0, sin(d.phase))
            let moved = d.speed * run * fstep
            d.y -= moved
            d.trail = min(d.trail + moved, 0.2)
            drips[i] = d
        }
        drips.removeAll { $0.y < $0.bottom - 0.02 }
        dripCount = drips.count

        // This frame's instances, in the next slot of the ring.
        let outsideLuma: Float = simd_dot(outside, SIMD3<Float>(0.2126, 0.7152, 0.0722))
        let insideLuma: Float = simd_dot(inside, SIMD3<Float>(repeating: 0.33))
        let light: Float = 0.35 + 0.65 * min(1, outsideLuma + 0.3 * insideLuma)
        instances.removeAll(keepingCapacity: true)
        let width = spec.rect.z - spec.rect.x, height = spec.rect.w - spec.rect.y
        for f in flakes {
            let p = spec.ndc(SIMD2(f.x, f.y))
            let melt: Float = 1 - max(0, (f.age / f.life - 0.6) / 0.4)
            let size: Float = f.size * width * (0.6 + 0.4 * melt)
            instances.append(SIMD4(p.x, p.y, size, 0.9 * melt))
            instances.append(SIMD4(f.rot, 0, 0, light))
        }
        for d in drips {
            let p = spec.ndc(SIMD2(d.x, d.y))
            instances.append(SIMD4(p.x, p.y, d.size * width, 0.8))
            instances.append(SIMD4(0, 1, d.trail * height, light))
        }
        instanceCount = instances.count / 2
        slot = (slot + 1) % ring.count
        let bytes = instances.count * MemoryLayout<SIMD4<Float>>.stride
        if bytes > 0 {
            if (ring[slot]?.length ?? 0) < bytes {
                ring[slot] = device.makeBuffer(length: max(bytes, 16 * 1024), options: .storageModeShared)
                bufferAllocations += 1
            }
            if let buf = ring[slot] {
                instances.withUnsafeBytes { buf.contents().copyMemory(from: $0.baseAddress!, byteCount: bytes) }
            }
        }
    }

    private func coverage(level: Float, patches: [GlassPatch]) -> Float {
        guard !samples.isEmpty else { return level }
        let squash = Float(FrostField.height) / Float(FrostField.width)
        var frosted = 0
        for s in samples {
            var clearing: Float = 0
            for p in patches {
                let dx = s.x - p.x, dy = (s.y - p.y) * squash
                let d: Float = (dx * dx + dy * dy).squareRoot()
                let c: Float = min(max((d / p.radius - 0.55) / 0.45, 0), 1)
                let m: Float = 1 - c * c * (3 - 2 * c)
                let warmth: Float = min(max(p.warmth, 0), 1)
                clearing = max(clearing, warmth * m)
            }
            if s.arrival < level * (1 - clearing) { frosted += 1 }
        }
        return Float(frosted) / Float(samples.count)
    }

    // MARK: - Drawing

    /// The glass, after the outside (and its weather) is drawn. `blur` is `makeBlur`'s copy of the view (High, Ultra).
    func drawGlass(_ e: MTLRenderCommandEncoder, blur: MTLTexture?) {
        var uu = u
        let useBlur = blur != nil && quality != .lite
        uu[1].w = useBlur ? 1 : 0
        e.setRenderPipelineState(glassPipeline)
        uu.withUnsafeBytes {
            e.setVertexBytes($0.baseAddress!, length: $0.count, index: 0)
            e.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0)
        }
        e.setFragmentTexture(fieldTexture ?? placeholder, index: 0)
        e.setFragmentTexture(useBlur ? blur : placeholder, index: 1)
        e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        if instanceCount > 0, let buf = ring[slot] {
            e.setRenderPipelineState(dropPipeline)
            uu.withUnsafeBytes { e.setVertexBytes($0.baseAddress!, length: $0.count, index: 0) }
            e.setVertexBuffer(buf, offset: 0, index: 1)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: instanceCount)
        }
    }

    /// The frame and bars, over the glass.
    func drawFrame(_ e: MTLRenderCommandEncoder) {
        e.setRenderPipelineState(framePipeline)
        u.withUnsafeBytes {
            e.setVertexBytes($0.baseAddress!, length: $0.count, index: 0)
            e.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0)
        }
        e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }

    /// High and Ultra: a half-resolution copy of the view with a 4-level mip chain (kept and reused), for frosted
    /// glass to scatter. Encode it between the outside's pass and the glass's (`RenderStack.scenePassContinuing`).
    func makeBlur(from source: MTLTexture, commandBuffer cb: MTLCommandBuffer) -> MTLTexture? {
        guard quality != .lite else { return nil }
        let w = max(1, source.width / 2), h = max(1, source.height / 2)
        if blurTexture?.width != w || blurTexture?.height != h {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: RenderStack.sceneFormat, width: w, height: h, mipmapped: true)
            d.mipmapLevelCount = min(4, d.mipmapLevelCount)
            d.usage = [.shaderRead, .renderTarget]
            d.storageMode = .private
            blurTexture = device.makeTexture(descriptor: d)
        }
        guard let blur = blurTexture else { return nil }
        let p = MTLRenderPassDescriptor()
        p.colorAttachments[0].texture = blur
        p.colorAttachments[0].level = 0
        p.colorAttachments[0].loadAction = .dontCare
        p.colorAttachments[0].storeAction = .store
        guard let e = cb.makeRenderCommandEncoder(descriptor: p) else { return nil }
        e.setRenderPipelineState(blurPipeline)
        e.setFragmentTexture(source, index: 0)
        e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        e.endEncoding()
        if blur.mipmapLevelCount > 1, let blit = cb.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: blur)
            blit.endEncoding()
        }
        return blur
    }
}
