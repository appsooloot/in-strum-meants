import Metal
import CoreGraphics
import simd
import InStrumCore

/// Where weather lands in a world.
enum WeatherSurface { case water(horizonY: Float), ground(horizonY: Float), glass, none }

/// The real-star texture (`StarTexture`, 2048 × 1024 RGBA8), built once per process on a background queue and
/// uploaded on the main actor; every SkyLayer shares it. Until it arrives the sky draws its procedural stars.
@MainActor
final class StarTextureCache {
    static let shared = StarTextureCache()
    /// The uploaded texture (nil until the build lands, or while `withheld`).
    var texture: MTLTexture? { withheld ? nil : built }
    /// Tests: draw every sky as if the texture had not arrived yet (the procedural fallback).
    var withheld = false
    private var built: MTLTexture?
    /// How many times the image has been built (one per process).
    private(set) var builds = 0
    private var device: MTLDevice?

    /// Starts the build the first time any sky asks (later calls do nothing).
    func request(device: MTLDevice) {
        guard self.device == nil else { return }
        self.device = device
        builds += 1
        DispatchQueue.global(qos: .utility).async {
            let bytes = StarTexture.build()
            DispatchQueue.main.async { MainActor.assumeIsolated { StarTextureCache.shared.upload(bytes) } }
        }
    }

    /// Waits (running the main run loop) until the texture has arrived; for previews and tests.
    @discardableResult
    func awaitTexture(timeout: TimeInterval = 5) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while built == nil, Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        return built != nil
    }

    private func upload(_ bytes: [UInt8]) {
        guard let device, built == nil else { return }
        built = Self.makeTexture(device: device, bytes: bytes)
    }

    /// An RGBA8 2048 × 1024 texture from `StarTexture.build(lines:)`'s bytes (nil if the size is wrong).
    static func makeTexture(device: MTLDevice, bytes: [UInt8]) -> MTLTexture? {
        let w = StarTexture.width, h = StarTexture.height
        guard bytes.count == w * h * 4 else { return nil }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
        d.usage = [.shaderRead]
        guard let tex = device.makeTexture(descriptor: d) else { return nil }
        bytes.withUnsafeBytes { raw in
            tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: raw.baseAddress!, bytesPerRow: w * 4)
        }
        return tex
    }
}

/// Draws the Living Sky dome into a world's scene pass (writes depth 1.0, behind everything).
/// The camera looks at a chosen azimuth with the horizon at `horizonY` (NDC).
@MainActor
final class SkyLayer {
    /// Face the equator by default, where the sun and moon cross the sky.
    static func defaultViewAzimuth(latitude: Double) -> Double { latitude < 0 ? 0 : 180 }

    var viewAzimuth: Double?
    var horizonY: Float = -0.33
    var verticalFOV: Double = 60
    /// The view's roll in degrees (a road's gentle curves); 0 keeps the horizon level.
    var roll: Double = 0
    /// Apparent sizes are enlarged for the screen (real: 0.26°), as a long lens would show them.
    var moonRadiusDegrees: Double = 1.25
    var sunRadiusDegrees: Double = 0.9

    /// Aurora ripples from a world's visual (Curtain Lights): position 0…1 along the band, age (s), strength, width.
    /// Up to 8; zero strength is no ripple.
    var ripples = [SIMD4<Float>](repeating: .zero, count: 8)
    /// The aurora's hue shift (−1 cool … +1 warm) and glow (0…1), from a world's visual; zero by default.
    var auroraTint = SIMD2<Float>(0, 0)
    /// Tests: a texture to use instead of the shared one.
    var starTextureOverride: MTLTexture?

    nonisolated static let rippleCount = 8
    /// SkyU's float4 count: 13 + night, aurora, dust and 8 ripples (the MSL struct's size / 16).
    nonisolated static let uniformCount = 24

    private let pipeline: MTLRenderPipelineState
    /// A 1×1 black texture bound while the real stars build, so no pass ever lacks texture 0.
    private let placeholder: MTLTexture
    private var u = [SIMD4<Float>](repeating: .zero, count: 24)

    /// The real stars (nil until the shared background build arrives).
    var starTexture: MTLTexture? {
        if StarTextureCache.shared.withheld { return nil }
        return starTextureOverride ?? StarTextureCache.shared.texture
    }

    /// The SkyU uniforms, for worlds whose shaders reflect the sky (bind at the same index as the dome: 0, and the
    /// stars with `bindStars`). eq0.w says whether the real stars are bound.
    var uniforms: [SIMD4<Float>] {
        var c = u
        c[8].w = starTexture == nil ? 0 : 1
        return c
    }

    init?(device: MTLDevice) {
        guard let lib = try? device.makeLibrary(source: SkyShaders.source, options: nil) else { return nil }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = lib.makeFunction(name: "sky_dome_vertex")
        d.fragmentFunction = lib.makeFunction(name: "sky_dome_fragment")
        d.colorAttachments[0].pixelFormat = RenderStack.sceneFormat
        d.colorAttachments[1].pixelFormat = RenderStack.depthFormat
        guard let p = try? device.makeRenderPipelineState(descriptor: d) else { return nil }
        let pd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        pd.usage = [.shaderRead]
        guard let ph = device.makeTexture(descriptor: pd) else { return nil }
        var black: [UInt8] = [0, 0, 0, 0]
        ph.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &black, bytesPerRow: 4)
        pipeline = p
        placeholder = ph
        StarTextureCache.shared.request(device: device)
    }

    /// Binds the real stars (or the placeholder) at fragment texture 0, for any pass whose shader calls skyRadiance.
    func bindStars(_ e: MTLRenderCommandEncoder) {
        e.setFragmentTexture(starTexture ?? placeholder, index: 0)
    }

    /// Waits (running the main run loop) until the shared star texture has arrived; for previews and tests.
    @discardableResult
    func awaitStars(timeout: TimeInterval = 5) -> Bool { StarTextureCache.shared.awaitTexture(timeout: timeout) }

    /// The aurora's pole-ward azimuth (degrees): north (0°) in the northern hemisphere, south (180°) in the southern,
    /// wandering ±20° over tens of minutes.
    nonisolated static func auroraAzimuth(hemisphere: Float, time: Float) -> Double {
        let t = Double(time)
        let wander = 20 * (0.6 * sin(t * 2 * .pi / 1500) + 0.4 * sin(t * 2 * .pi / 640 + 1.3))
        return (hemisphere >= 0 ? 0 : 180) + wander
    }

    nonisolated static func enu(_ dir: SkyDirection) -> SIMD3<Float> {
        let az = dir.azimuth * .pi / 180, alt = dir.altitude * .pi / 180
        return SIMD3<Float>(Float(sin(az) * cos(alt)), Float(cos(az) * cos(alt)), Float(sin(alt)))
    }

    /// East, north and up as equatorial unit vectors (x toward RA 0, z the north celestial pole): the columns of the
    /// shader's `eq` matrix (equatorial = eq · east-north-up; its transpose turns a star back into east-north-up).
    nonisolated static func equatorialBasis(siderealDegrees: Double, latitude: Double) -> (east: SIMD3<Float>, north: SIMD3<Float>, up: SIMD3<Float>) {
        let lst = siderealDegrees * .pi / 180, lat = latitude * .pi / 180
        let east = SIMD3<Float>(Float(-sin(lst)), Float(cos(lst)), 0)
        let north = SIMD3<Float>(Float(-sin(lat) * cos(lst)), Float(-sin(lat) * sin(lst)), Float(cos(lat)))
        let up = SIMD3<Float>(Float(cos(lat) * cos(lst)), Float(cos(lat) * sin(lst)), Float(sin(lat)))
        return (east, north, up)
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
        guard roll != 0 else { return (right, up, forward, tanV * aspect, tanV) }
        let r = Float(roll * .pi / 180)
        return (right * cos(r) + up * sin(r), up * cos(r) - right * sin(r), forward, tanV * aspect, tanV)
    }

    func update(_ s: SkyState, quality: QualityLevel, size: CGSize, time: Float) {
        let aspect = Float(max(1, size.width) / max(1, size.height))
        let cam = camera(latitude: s.latitude, aspect: aspect)
        let (east, north, upEq) = Self.equatorialBasis(siderealDegrees: s.siderealDegrees, latitude: s.latitude)
        let pixelAngle = 2 * cam.tanV / Float(max(1, size.height))
        u[0] = SIMD4(cam.right, cam.tanH)
        u[1] = SIMD4(cam.up, cam.tanV)
        u[2] = SIMD4(cam.forward, time)
        u[3] = SIMD4(s.zenith, s.starVisibility)
        u[4] = SIMD4(s.horizon, s.cloudCover)
        u[5] = SIMD4(Self.enu(s.sun), Float(s.sun.altitude))
        u[6] = SIMD4(Self.enu(s.moon), Float(s.moonPhase))
        u[7] = SIMD4(Float(s.moonLit), s.earthshine, Float(moonRadiusDegrees * .pi / 180) * s.moonSize, Float(sunRadiusDegrees * .pi / 180) * s.sunSize)
        u[8] = SIMD4(east, 0); u[9] = SIMD4(north, 0); u[10] = SIMD4(upEq, 0)
        // z carries the octave count in its whole part and the rainbow (×0.45) in its fraction; the shader rounds it back.
        u[11] = SIMD4(s.mist, s.wind, (quality == .lite ? 2 : 3) + 0.45 * min(1, max(0, s.rainbow)), pixelAngle)
        u[12] = SIMD4(s.halo, s.dawnPastel, s.gust, s.wetness)
        u[13] = SIMD4(s.aurora, s.auroraStorm, s.constellationLines, s.fireflies)
        let poleAz = Self.auroraAzimuth(hemisphere: s.hemisphere, time: time) * .pi / 180
        u[14] = SIMD4(Float(sin(poleAz)), Float(cos(poleAz)), s.auroraAltitude, s.hemisphere)
        u[15] = SIMD4(s.diamondDust, s.pillar, min(1, max(-1, auroraTint.x)), min(1, max(0, auroraTint.y)))
        for i in 0..<Self.rippleCount { u[16 + i] = i < ripples.count ? ripples[i] : .zero }
    }

    func draw(_ e: MTLRenderCommandEncoder) {
        e.setRenderPipelineState(pipeline)
        uniforms.withUnsafeBytes { e.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0) }
        bindStars(e)
        e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }
}

/// Rain streaks or snow flakes (instanced), splash rings on water, drops on glass, blowing-snow streamers, a humid
/// night's fireflies, diamond dust's crystals, and lightning exposure requests that go through the flash limiter.
@MainActor
final class WeatherLayer {
    static func baseCount(_ q: QualityLevel) -> Int { q == .lite ? 400 : (q == .high ? 1200 : 2500) }
    static func streamerCap(_ q: QualityLevel) -> Int { q == .lite ? 60 : 150 }
    static func fireflyCap(_ q: QualityLevel) -> Int { q == .lite ? 60 : (q == .high ? 150 : 250) }
    static func crystalCap(_ q: QualityLevel) -> Int { q == .lite ? 150 : (q == .high ? 400 : 800) }
    /// Fireflies keep to the lower 55% of the view (NDC y below this).
    static let fireflyTop: Float = 0.1

    var gentle = false
    private(set) var particleCount = 0
    /// Ground streamers drawn this frame (blizzard gusts only).
    private(set) var streamerCount = 0
    /// Fireflies (humid nights, over ground or water) and diamond-dust crystals drawn this frame.
    private(set) var fireflyCount = 0
    private(set) var crystalCount = 0
    /// Instance buffers made so far: a ring of three, grown only when too small (never one per frame).
    private(set) var bufferAllocations = 0
    private var ring: [MTLBuffer?] = [nil, nil, nil]
    private var slot = 0
    /// Multiply into the world's exposure (1 = no lightning).
    private(set) var exposureBoost: Float = 1

    private struct Drop { var x, y, depth, speed, landY: Float }
    private struct Ring { var x, y, age, size: Float }
    private struct Bead { var x, y, size, speed, wobble: Float }
    private struct Streamer { var x, y, length, speed, alpha: Float }
    /// A firefly: position, heading (radians), speed (NDC/s), blink rate (Hz), on-time (s), blink phase (s), size (px).
    private struct Firefly { var x, y, heading, speed, rate, onTime, phase, size: Float }
    /// A crystal: position, fall speed (NDC/s), twinkle rate (Hz) and phase, size (px).
    private struct Crystal { var x, y, speed, rate, phase, size: Float }

    private let particlePipeline, ringPipeline: MTLRenderPipelineState
    private var drops: [Drop] = []
    private var rings: [Ring] = []
    private var beads: [Bead] = []
    private var instances: [SIMD4<Float>] = []
    private var ringInstances: [SIMD4<Float>] = []
    private var beadInstances: [SIMD4<Float>] = []
    private var streamers: [Streamer] = []
    private var streamerInstances: [SIMD4<Float>] = []
    private var fireflies: [Firefly] = []
    private var fireflyInstances: [SIMD4<Float>] = []
    private var crystals: [Crystal] = []
    private var crystalInstances: [SIMD4<Float>] = []
    private var clock: Float = 0
    private var pixelNDC: Float = 2.0 / 360
    private var rng = SeededRandom(seed: 0xD20F5)
    private var limiter = FlashLimiter()
    /// 0 rain streaks, 1 snow flakes (tests check a cold world never rains).
    private(set) var kind: Float = 0
    /// Sideways drift per unit of fall: snow leans harder in gusts.
    private(set) var tilt: Float = 0
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
        tilt = (snowing ? 0.25 + 1.2 * s.gust : 0.6) * s.wind
        let gustSpeed: Float = snowing ? 1 + s.gust : 1
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
                d.y -= d.speed * gustSpeed * fdt
                d.x += (tilt * d.speed * gustSpeed + 0.03 * sin(d.y * 9 + d.depth * 20)) * fdt
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

        // Blowing snow: long thin wisps racing across the lower third of the view in blizzard gusts.
        streamerInstances.removeAll(keepingCapacity: true)
        if s.snow > 0.9 && s.gust > 0.2 {
            let wantedStreamers = Int(Float(Self.streamerCap(quality)) * min(1, (s.gust - 0.2) / 0.6))
            while streamers.count < wantedStreamers { streamers.append(newStreamer(anywhere: streamers.isEmpty)) }
            if streamers.count > wantedStreamers { streamers.removeLast(streamers.count - wantedStreamers) }
            let dir: Float = tilt >= 0 ? 1 : -1
            for i in streamers.indices {
                var st = streamers[i]
                st.x += dir * st.speed * (0.6 + 0.8 * s.gust) * fdt
                if st.x > 1.3 || st.x < -1.3 { st = newStreamer(anywhere: false); st.x = -1.25 * dir }
                streamers[i] = st
                streamerInstances.append(SIMD4(st.x, st.y, st.length, st.alpha * s.gust))
            }
        } else {
            streamers.removeAll()
        }
        streamerCount = streamerInstances.count

        clock += fdt
        if clock > 3600 { clock -= 3600 }   // blink phases are fractions of a period of a few seconds; keep floats fine
        pixelNDC = 2 / Float(max(1, size.height))
        updateFireflies(s, quality: quality, dt: fdt, ground: horizon != nil)
        updateCrystals(s, quality: quality, dt: fdt)

        limiter.gentle = gentle
        exposureBoost = limiter.limit(exposure: 1 + 1.2 * s.lightning, sparkle: 0, dt: dt).exposure
    }

    /// A humid night's fireflies: a slow random walk low in the view, each blinking on its own beat.
    private func updateFireflies(_ s: SkyState, quality: QualityLevel, dt: Float, ground: Bool) {
        fireflyInstances.removeAll(keepingCapacity: true)
        let amount = min(1, max(0, s.fireflies))
        let wanted = ground ? Int((Float(Self.fireflyCap(quality)) * amount).rounded()) : 0
        while fireflies.count < wanted { fireflies.append(newFirefly()) }
        if fireflies.count > wanted { fireflies.removeLast(fireflies.count - wanted) }
        fireflyCount = fireflies.count
        let top = Self.fireflyTop
        for i in fireflies.indices {
            var f = fireflies[i]
            f.heading = (f.heading + rng.range(-2.5, 2.5) * dt).remainder(dividingBy: 2 * .pi)   // −π…π
            f.x += cos(f.heading) * f.speed * dt / aspect
            f.y += sin(f.heading) * f.speed * dt
            // Turn back softly at the edges of the low band.
            if f.y > top { f.y = top; f.heading = -abs(f.heading) }
            if f.y < -0.98 { f.y = -0.98; f.heading = abs(f.heading) }
            if f.x > 1.05 { f.x -= 2.1 } else if f.x < -1.05 { f.x += 2.1 }
            fireflies[i] = f
            // A square-ish blink: on for `onTime` once per period, with soft 80 ms edges.
            let period = 1 / f.rate
            var t = (clock + f.phase).truncatingRemainder(dividingBy: period)
            if t < 0 { t += period }
            let edge: Float = 0.08
            let on = min(1, max(0, t / edge)) * min(1, max(0, (f.onTime - t) / edge))
            guard on > 0.001 else { continue }
            let alpha = on * (gentle ? 0.55 : 0.9)
            fireflyInstances.append(SIMD4(f.x, f.y, f.size * pixelNDC, alpha))
        }
    }

    /// Diamond dust: tiny crystals over the whole view, falling very slowly, drifting with the wind, twinkling.
    private func updateCrystals(_ s: SkyState, quality: QualityLevel, dt: Float) {
        crystalInstances.removeAll(keepingCapacity: true)
        let amount = min(1, max(0, s.diamondDust))
        let wanted = Int((Float(Self.crystalCap(quality)) * amount).rounded())
        while crystals.count < wanted { crystals.append(newCrystal(anywhere: true)) }
        if crystals.count > wanted { crystals.removeLast(crystals.count - wanted) }
        crystalCount = crystals.count
        let drift = 0.04 * s.wind + 0.01
        for i in crystals.indices {
            var c = crystals[i]
            c.y -= c.speed * dt
            c.x += drift * (0.6 + 0.8 * c.speed / 0.03) * dt / aspect
            if c.y < -1.05 { c = newCrystal(anywhere: false) }
            if c.x > 1.05 { c.x -= 2.1 } else if c.x < -1.05 { c.x += 2.1 }
            crystals[i] = c
            let tw = 0.5 + 0.5 * sin((clock * c.rate + c.phase) * 2 * .pi)
            let glint = tw * tw * tw   // mostly faint, now and then a bright glint
            let alpha = (0.15 + 0.85 * glint) * (gentle ? 0.5 : 0.9)
            crystalInstances.append(SIMD4(c.x, c.y, c.size * pixelNDC, alpha))
        }
    }

    private func newFirefly() -> Firefly {
        Firefly(x: rng.range(-1, 1), y: rng.range(-0.95, Self.fireflyTop), heading: rng.range(0, 2 * .pi),
                speed: rng.range(0.02, 0.06), rate: rng.range(0.4, 1.1), onTime: rng.range(0.25, 0.5),
                phase: rng.range(0, 3), size: rng.range(3, 6))
    }

    private func newCrystal(anywhere: Bool) -> Crystal {
        Crystal(x: rng.range(-1.05, 1.05), y: anywhere ? rng.range(-1, 1.05) : rng.range(1.0, 1.05), speed: rng.range(0.01, 0.03),
                rate: rng.range(2, 6), phase: rng.range(0, 1), size: rng.range(1, 3))
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

    private func newStreamer(anywhere: Bool) -> Streamer {
        Streamer(x: anywhere ? rng.range(-1.2, 1.2) : rng.range(-1.3, 1.3), y: rng.range(-0.98, -0.36),
                 length: rng.range(0.15, 0.45), speed: rng.range(0.8, 1.6), alpha: rng.range(0.10, 0.28))
    }

    func draw(_ e: MTLRenderCommandEncoder) {
        // Fireflies make their own light; crystals catch what there is (a little even on a dark night).
        let sets: [(MTLRenderPipelineState, [SIMD4<Float>], Float, Float)] = [
            (particlePipeline, instances, kind, brightness), (ringPipeline, ringInstances, 0, brightness),
            (particlePipeline, beadInstances, 2, brightness), (particlePipeline, streamerInstances, 3, brightness),
            (particlePipeline, fireflyInstances, 4, 2.2), (particlePipeline, crystalInstances, 5, max(0.7, brightness) * 1.6),
        ]
        // This frame's slot in the ring holds all six sets (256-byte aligned); it grows only when too small.
        func aligned(_ n: Int) -> Int { (n + 255) / 256 * 256 }
        let total = sets.reduce(0) { $0 + aligned($1.1.count * MemoryLayout<SIMD4<Float>>.stride) }
        guard total > 0 else { return }
        slot = (slot + 1) % ring.count
        if (ring[slot]?.length ?? 0) < total {
            ring[slot] = e.device.makeBuffer(length: max(total, 64 * 1024), options: .storageModeShared)
            bufferAllocations += 1
        }
        guard let buf = ring[slot] else { return }
        var offset = 0
        for (pipeline, items, kind, light) in sets where !items.isEmpty {
            let bytes = items.count * MemoryLayout<SIMD4<Float>>.stride
            items.withUnsafeBytes { raw in (buf.contents() + offset).copyMemory(from: raw.baseAddress!, byteCount: bytes) }
            var u = SIMD4<Float>(aspect, kind, tilt, light)
            e.setRenderPipelineState(pipeline)
            e.setVertexBuffer(buf, offset: offset, index: 0)
            e.setVertexBytes(&u, length: MemoryLayout<SIMD4<Float>>.size, index: 1)
            e.setFragmentBytes(&u, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: items.count)
            offset += aligned(bytes)
        }
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
