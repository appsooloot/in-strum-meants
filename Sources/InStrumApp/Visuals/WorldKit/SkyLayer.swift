import Metal
import CoreGraphics
import simd
import InStrumCore

/// Where weather lands in a world.
enum WeatherSurface { case water(horizonY: Float), ground(horizonY: Float), glass, none }

/// Draws the Living Sky dome into a world's scene pass (writes depth 1.0, behind everything).
/// The camera looks at a chosen azimuth with the horizon at `horizonY` (NDC).
@MainActor
final class SkyLayer {
    /// Face the equator by default, where the sun and moon cross the sky.
    static func defaultViewAzimuth(latitude: Double) -> Double { latitude < 0 ? 0 : 180 }

    var viewAzimuth: Double?
    var horizonY: Float = -0.33
    var verticalFOV: Double = 60
    /// Apparent sizes are enlarged for the screen (real: 0.26°), as a long lens would show them.
    var moonRadiusDegrees: Double = 1.25
    var sunRadiusDegrees: Double = 0.9

    private let pipeline: MTLRenderPipelineState
    private var u = [SIMD4<Float>](repeating: .zero, count: 12)

    init?(device: MTLDevice) {
        guard let lib = try? device.makeLibrary(source: SkyShaders.source, options: nil) else { return nil }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = lib.makeFunction(name: "sky_dome_vertex")
        d.fragmentFunction = lib.makeFunction(name: "sky_dome_fragment")
        d.colorAttachments[0].pixelFormat = RenderStack.sceneFormat
        d.colorAttachments[1].pixelFormat = RenderStack.depthFormat
        guard let p = try? device.makeRenderPipelineState(descriptor: d) else { return nil }
        pipeline = p
    }

    static func enu(_ dir: SkyDirection) -> SIMD3<Float> {
        let az = dir.azimuth * .pi / 180, alt = dir.altitude * .pi / 180
        return SIMD3<Float>(Float(sin(az) * cos(alt)), Float(cos(az) * cos(alt)), Float(sin(alt)))
    }

    /// Camera basis in east-north-up.
    func camera(latitude: Double, aspect: Float) -> (right: SIMD3<Float>, up: SIMD3<Float>, forward: SIMD3<Float>, tanH: Float, tanV: Float) {
        let az = (viewAzimuth ?? Self.defaultViewAzimuth(latitude: latitude)) * .pi / 180
        let tanV = Float(tan(verticalFOV * .pi / 360))
        let pitch = -atan(horizonY * tanV)
        let f0 = SIMD3<Float>(Float(sin(az)), Float(cos(az)), 0), up0 = SIMD3<Float>(0, 0, 1)
        let right = SIMD3<Float>(Float(cos(az)), Float(-sin(az)), 0)
        let forward = f0 * cos(pitch) + up0 * sin(pitch)
        let up = -f0 * sin(pitch) + up0 * cos(pitch)
        return (right, up, forward, tanV * aspect, tanV)
    }

    func update(_ s: SkyState, quality: QualityLevel, size: CGSize, time: Float) {
        let aspect = Float(max(1, size.width) / max(1, size.height))
        let cam = camera(latitude: s.latitude, aspect: aspect)
        let lst = s.siderealDegrees * .pi / 180, lat = s.latitude * .pi / 180
        let east = SIMD3<Float>(Float(-sin(lst)), Float(cos(lst)), 0)
        let north = SIMD3<Float>(Float(-sin(lat) * cos(lst)), Float(-sin(lat) * sin(lst)), Float(cos(lat)))
        let upEq = SIMD3<Float>(Float(cos(lat) * cos(lst)), Float(cos(lat) * sin(lst)), Float(sin(lat)))
        let pixelAngle = 2 * cam.tanV / Float(max(1, size.height))
        u[0] = SIMD4(cam.right, cam.tanH)
        u[1] = SIMD4(cam.up, cam.tanV)
        u[2] = SIMD4(cam.forward, time)
        u[3] = SIMD4(s.zenith, s.starVisibility)
        u[4] = SIMD4(s.horizon, s.cloudCover)
        u[5] = SIMD4(Self.enu(s.sun), Float(s.sun.altitude))
        u[6] = SIMD4(Self.enu(s.moon), Float(s.moonPhase))
        u[7] = SIMD4(Float(s.moonLit), 0.04, Float(moonRadiusDegrees * .pi / 180), Float(sunRadiusDegrees * .pi / 180))
        u[8] = SIMD4(east, 0); u[9] = SIMD4(north, 0); u[10] = SIMD4(upEq, 0)
        u[11] = SIMD4(s.mist, s.wind, quality == .lite ? 2 : 3, pixelAngle)
    }

    func draw(_ e: MTLRenderCommandEncoder) {
        e.setRenderPipelineState(pipeline)
        u.withUnsafeBytes { e.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0) }
        e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }
}

/// Rain streaks or snow flakes (instanced), splash rings on water, drops on glass, and lightning
/// exposure requests that go through the flash limiter.
@MainActor
final class WeatherLayer {
    static func baseCount(_ q: QualityLevel) -> Int { q == .lite ? 400 : (q == .high ? 1200 : 2500) }

    var gentle = false
    private(set) var particleCount = 0
    /// Multiply into the world's exposure (1 = no lightning).
    private(set) var exposureBoost: Float = 1

    private struct Drop { var x, y, depth, speed, landY: Float }
    private struct Ring { var x, y, age, size: Float }
    private struct Bead { var x, y, size, speed, wobble: Float }

    private let particlePipeline, ringPipeline: MTLRenderPipelineState
    private var drops: [Drop] = []
    private var rings: [Ring] = []
    private var beads: [Bead] = []
    private var instances: [SIMD4<Float>] = []
    private var ringInstances: [SIMD4<Float>] = []
    private var beadInstances: [SIMD4<Float>] = []
    private var rng = SeededRandom(seed: 0xD20F5)
    private var limiter = FlashLimiter()
    private var kind: Float = 0
    private var tilt: Float = 0
    private var aspect: Float = 16.0 / 9
    private var brightness: Float = 1

    init?(device: MTLDevice) {
        guard let lib = try? device.makeLibrary(source: SkyShaders.source, options: nil) else { return nil }
        func make(_ v: String, _ f: String) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: v)
            d.fragmentFunction = lib.makeFunction(name: f)
            d.colorAttachments[0].pixelFormat = RenderStack.sceneFormat
            d.colorAttachments[0].isBlendingEnabled = true
            d.colorAttachments[0].sourceRGBBlendFactor = .one
            d.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            d.colorAttachments[0].sourceAlphaBlendFactor = .one
            d.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            d.colorAttachments[1].pixelFormat = RenderStack.depthFormat
            d.colorAttachments[1].writeMask = []
            return try? device.makeRenderPipelineState(descriptor: d)
        }
        guard let p = make("weather_vertex", "weather_fragment"), let r = make("ring_vertex", "ring_fragment") else { return nil }
        particlePipeline = p; ringPipeline = r
    }

    func update(_ s: SkyState, quality: QualityLevel, size: CGSize, dt: Double, surface: WeatherSurface) {
        let fdt = Float(min(dt, 0.1))
        aspect = Float(max(1, size.width) / max(1, size.height))
        let snowing = s.snow > s.rain
        let amount = max(s.rain, s.snow)
        kind = snowing ? 1 : 0
        let wanted = Int((Float(Self.baseCount(quality)) * amount).rounded())
        tilt = (snowing ? 0.25 : 0.6) * s.wind
        // Night light is dim: weather glints less.
        brightness = 0.25 + 0.75 * min(1, max(0, Float((s.sun.altitude + 6) / 18))) + 0.15 * Float(s.moonLit)
        let horizon: Float? = { if case let .water(y) = surface { return y }; if case let .ground(y) = surface { return y }; return nil }()
        while drops.count < wanted { drops.append(spawn(top: drops.isEmpty, snowing: snowing, horizon: horizon)) }
        if drops.count > wanted { drops.removeLast(drops.count - wanted) }
        particleCount = drops.count

        instances.removeAll(keepingCapacity: true)
        for i in drops.indices {
            var d = drops[i]
            if snowing {
                d.y -= d.speed * fdt
                d.x += (tilt * d.speed + 0.03 * sin(d.y * 9 + d.depth * 20)) * fdt
            } else {
                d.y -= d.speed * fdt
                d.x += tilt * d.speed * fdt / aspect
            }
            if d.y < d.landY {
                if !snowing, case .water = surface, rings.count < (quality == .lite ? 64 : 200) {
                    rings.append(Ring(x: d.x, y: d.landY, age: 0, size: 0.012 + 0.03 * d.depth))
                }
                d = spawn(top: true, snowing: snowing, horizon: horizon)
            }
            if d.x > 1.1 { d.x -= 2.2 } else if d.x < -1.1 { d.x += 2.2 }
            drops[i] = d
            let alpha = (snowing ? 0.85 : 0.22) * (0.35 + 0.65 * d.depth)
            let sizeOrLength = snowing ? (0.003 + 0.009 * d.depth) : (0.03 + 0.06 * d.depth)
            instances.append(SIMD4(d.x, d.y, sizeOrLength, alpha))
        }

        ringInstances.removeAll(keepingCapacity: true)
        rings = rings.compactMap { r in
            var r = r
            r.age += fdt
            guard r.age < 0.6 else { return nil }
            let k = r.age / 0.6
            ringInstances.append(SIMD4(r.x, r.y, r.size * (0.2 + k), 0.6 * (1 - k)))
            return r
        }

        beadInstances.removeAll(keepingCapacity: true)
        if case .glass = surface, s.rain > 0.02 {
            let wantedBeads = Int(Float(quality == .lite ? 40 : 90) * s.rain)
            while beads.count < wantedBeads { beads.append(newBead(anywhere: beads.isEmpty)) }
            if beads.count > wantedBeads { beads.removeLast(beads.count - wantedBeads) }
            for i in beads.indices {
                var b = beads[i]
                b.wobble += fdt
                // Drops cling, then slide in short runs.
                let run = max(0, sin(b.wobble * 1.3 + b.size * 300))
                b.y -= b.speed * run * run * fdt
                if b.y < -1.1 { b = newBead(anywhere: false) }
                beads[i] = b
                beadInstances.append(SIMD4(b.x, b.y, b.size, 0.55))
                beadInstances.append(SIMD4(b.x, b.y + b.size * 3, b.size * 0.35, 0.12))   // the trail it left
            }
        } else {
            beads.removeAll()
        }

        limiter.gentle = gentle
        exposureBoost = limiter.limit(exposure: 1 + 1.2 * s.lightning, sparkle: 0, dt: dt).exposure
    }

    private func spawn(top: Bool, snowing: Bool, horizon: Float?) -> Drop {
        let depth = rng.unit()
        let y = top ? 1.05 + 0.2 * rng.unit() : rng.range(-1, 1.2)
        let landY: Float
        if let h = horizon { landY = h - (h + 1) * (0.05 + 0.95 * depth) } else { landY = -1.1 }
        let speed = snowing ? 0.12 + 0.25 * depth : 1.6 + 1.6 * depth
        return Drop(x: rng.range(-1.1, 1.1), y: y, depth: depth, speed: speed, landY: landY)
    }

    private func newBead(anywhere: Bool) -> Bead {
        Bead(x: rng.range(-1, 1), y: anywhere ? rng.range(-1, 1) : rng.range(0.7, 1.1), size: 0.006 + 0.012 * rng.unit(),
             speed: 0.05 + 0.25 * rng.unit(), wobble: rng.range(0, 6))
    }

    func draw(_ e: MTLRenderCommandEncoder) {
        func drawSet(_ pipeline: MTLRenderPipelineState, _ items: [SIMD4<Float>], kind: Float) {
            guard !items.isEmpty else { return }
            var u = SIMD4<Float>(aspect, kind, tilt, brightness)
            e.setRenderPipelineState(pipeline)
            items.withUnsafeBytes { raw in
                if raw.count <= 4096 { e.setVertexBytes(raw.baseAddress!, length: raw.count, index: 0) }
                else if let buf = e.device.makeBuffer(bytes: raw.baseAddress!, length: raw.count, options: .storageModeShared) {
                    e.setVertexBuffer(buf, offset: 0, index: 0)
                }
            }
            e.setVertexBytes(&u, length: MemoryLayout<SIMD4<Float>>.size, index: 1)
            e.setFragmentBytes(&u, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: items.count)
        }
        drawSet(particlePipeline, instances, kind: kind)
        drawSet(ringPipeline, ringInstances, kind: 0)
        drawSet(particlePipeline, beadInstances, kind: 2)
    }
}

/// The sky and its weather on their own (tests and sky previews).
@MainActor
final class SkyOnlyRenderer: ThemeRenderer {
    let sky: SkyLayer
    let weather: WeatherLayer
    private(set) var post = PostSettings()

    init?(device: MTLDevice) {
        guard let s = SkyLayer(device: device), let w = WeatherLayer(device: device) else { return nil }
        sky = s; weather = w
    }

    func update(_ s: SkyState, quality: QualityLevel, size: CGSize, dt: Double, time: Float, surface: WeatherSurface) {
        sky.horizonY = { if case let .water(y) = surface { return y }; if case let .ground(y) = surface { return y }; return sky.horizonY }()
        sky.update(s, quality: quality, size: size, time: time)
        weather.update(s, quality: quality, size: size, dt: dt, surface: surface)
        post = PostSettings(bloom: 0.35, bloomThreshold: 1.0, dof: 0, focusDepth: 1, grade: 0, grain: 0.02, vignette: 0.25,
                            exposure: weather.exposureBoost, warmth: 0, time: time, quality: quality)
    }

    func render(stack: RenderStack, commandBuffer cb: MTLCommandBuffer) {
        guard let pass = stack.scenePass(clear: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)),
              let e = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        sky.draw(e)
        weather.draw(e)
        e.endEncoding()
    }
}
