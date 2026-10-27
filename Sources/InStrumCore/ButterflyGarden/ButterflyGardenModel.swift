import Foundation
import simd

public struct Butterfly: Equatable {
    /// x 0...1 across, y 0...1 up, z depth 0 near ... 1 far.
    public var position: SIMD3<Float>
    public var size: Float
    public var hue: Float
    public var flapPhase: Float
    /// Wing beats per second (after pedal/linger).
    public var flapRate: Float
    public var style: Int
    public var glow: Float
    public var landed: Bool
    public var homeNote: UInt8?
    /// 0...1 fade in/out.
    public var opacity: Float
}

public struct Bloom: Equatable {
    public var x: Float
    public var openness: Float
    public var hue: Float
    public var age: Float
    public var kind: Int
}

public struct GardenFrame {
    public var butterflies: [Butterfly]
    public var blooms: [Bloom]
    public var keys: [KeyVisual]
    public var sunHeight: Float
    public var rays: Float
    public var mist: Float
    public var breeze: SIMD2<Float>
    public var pollen: Float
    public var petals: Float
    public var fireflies: Float
    /// -1 cool ... +1 warm.
    public var warmth: Float
    public var exposure: Float
    public var spiral: Float
    public var cameraZoom: Float
    public var cameraOffset: SIMD2<Float>
    public var timeOfDay: String
    public var time: Double
}

/// Butterflies born from your notes, hovering on held keys, spiralling on chords,
/// landing on flowers in silence.
public struct ButterflyGardenModel: ThemeModel {
    public typealias Frame = GardenFrame
    public static let id = "butterfly-garden"
    public static let displayName = "Butterfly Garden"

    static let qualityCap: [QualityLevel: Int] = [.lite: 200, .high: 600, .ultra: 1200]
    static let silenceToLand = 4.0
    static let maxBlooms = 120

    private struct Flyer {
        var b: Butterfly
        var velocity: SIMD3<Float>
        var baseFlap: Float
        var age: Float = 0
        var lifespan: Float
        var hoverHeight: Float
        var seed: Float
        var serial: Int
    }

    private var flyers: [Flyer] = []
    private var blooms: [Bloom] = []
    private var pending: [PerformanceEvent] = []
    private var held: [UInt8: Float] = [:]
    private var keyGlow = [Float](repeating: 0, count: 88)
    private var spiral: Float = 0
    private var spiralCentre: Float = 0.5
    private var chordHue: Float = 0.1
    private var sinceNote: Double = 1000
    private var spawnBudget: Double = 1
    private var rng = SeededRandom(seed: 42)
    private var time: Double = 0
    private var serial = 0
    private var melodyX: Float = 0.5
    /// note → index of the butterfly hovering over it.
    private var hovering: [UInt8: Int] = [:]
    private var lastCap = 600

    public init() {}

    public mutating func handle(_ e: PerformanceEvent) { pending.append(e) }

    private static func keyCentre(_ note: UInt8) -> Float? {
        KeyboardLayout.key(for: note).map { $0.x + $0.width / 2 }
    }

    public mutating func step(dt: Double, params p: ParameterSet, roles: RoleValues, inputs: InputFrame, quality: QualityLevel) -> GardenFrame {
        let fdt = Float(dt)
        time += dt
        for e in pending { apply(e, params: p, roles: roles) }
        pending.removeAll(keepingCapacity: true)
        sinceNote += dt

        let linger = Float(roles[.linger]), motion = Float(roles[.motion]), chaos = Float(roles[.chaos])
        let direction = Float(roles[.direction]), energy = Float(roles[.energy])
        let flocking = Float(p.number("flocking")), breezeStrength = Float(p.number("breeze.strength"))
        let breeze = SIMD2<Float>(Float(p.number("breeze.direction")) * breezeStrength + 0.3 * direction, 0.02 * breezeStrength)
        let landing = sinceNote >= Self.silenceToLand && held.isEmpty
        let lifespan = Float(p.number("lifespan"))

        // Butterflies
        lastCap = min(Int(p.number("butterflies.max")), Self.qualityCap[quality] ?? 600)
        trim(to: lastCap)
        spiral *= Float(pow(0.5, dt / 0.8))
        let flapScale = (1 - 0.6 * linger) * (0.85 + 0.3 * motion)
        for i in flyers.indices {
            var f = flyers[i]
            f.age += fdt
            f.b.flapRate = f.baseFlap * flapScale * (f.b.landed ? 0.1 : 1)
            f.b.flapPhase = (f.b.flapPhase + f.b.flapRate * fdt).truncatingRemainder(dividingBy: 1)
            if let note = f.b.homeNote, held[note] != nil, let x = Self.keyCentre(note) {
                f.b.landed = false
                let target = SIMD3<Float>(x + 0.004 * sin(Float(time) * 2 + f.seed * 6), f.hoverHeight, f.b.position.z)
                f.b.position += (target - f.b.position) * min(1, fdt * 4)
                f.velocity = .zero
            } else if landing {
                f.b.landed = true
                let groundY: Float = 0.1 + 0.03 * f.seed
                let tx = blooms.isEmpty ? f.b.position.x : blooms[Int(f.seed * Float(blooms.count)) % blooms.count].x
                f.b.position += (SIMD3<Float>(tx, groundY, f.b.position.z) - f.b.position) * min(1, fdt * 0.8)
                f.velocity *= 0.9
            } else {
                f.b.landed = false
                let wander = 0.15 + 0.6 * flocking + 0.5 * chaos
                let t = Float(time) + f.seed * 37
                var accel = SIMD3<Float>(sin(t * 1.3) * wander, cos(t * 0.9) * wander * 0.7, sin(t * 0.5) * 0.05)
                let flockY = 0.5 + 0.25 * direction
                accel.y += (flockY - f.b.position.y) * 0.6
                accel.x += breeze.x * 0.5
                if spiral > 0.05 {
                    let c = SIMD2<Float>(spiralCentre, 0.48)
                    let d = SIMD2<Float>(f.b.position.x, f.b.position.y) - c
                    let tangent = SIMD2<Float>(-d.y, d.x)
                    let pull = (0.16 - simd_length(d)) * 2
                    accel.x += (tangent.x * 3 + d.x * pull) * spiral
                    accel.y += (tangent.y * 3 + d.y * pull) * spiral
                }
                f.velocity += accel * fdt
                f.velocity *= max(0, 1 - fdt * 1.2)
                let speedCap: Float = 0.35 + 0.4 * motion + 0.3 * energy
                let s = simd_length(f.velocity)
                if s > speedCap { f.velocity *= speedCap / s }
                f.b.position += f.velocity * fdt
                // keep in view
                if f.b.position.x < 0.02 { f.velocity.x = abs(f.velocity.x) }
                if f.b.position.x > 0.98 { f.velocity.x = -abs(f.velocity.x) }
                f.b.position.y = min(max(f.b.position.y, 0.1), 0.95)
            }
            let fadeIn = min(1, f.age * 4)
            let fadeOut = min(1, max(0, (f.lifespan - f.age) / 1.5))
            f.b.opacity = fadeIn * fadeOut
            f.b.glow = max(f.b.glow * Float(pow(0.5, dt / 1.2)), 0.25)
            flyers[i] = f
        }
        let before = flyers.count
        flyers.removeAll { $0.age >= $0.lifespan && $0.b.homeNote == nil }
        if flyers.count != before { rebuildIndex() }
        _ = lifespan

        // Blooms
        let bloomSpeed = Float(p.number("bloom.speed")), bloomLife = Float(p.number("bloom.lifetime"))
        for i in blooms.indices {
            blooms[i].age += fdt
            let opening = blooms[i].age < bloomLife - 2 ? 1 : -1
            blooms[i].openness = min(1, max(0, blooms[i].openness + Float(opening) * bloomSpeed * 0.6 * fdt * (landing ? 1.5 : 1)))
        }
        blooms.removeAll { $0.age > bloomLife && $0.openness <= 0 }

        // Keys
        let keyHalf = linger > 0.5 ? 1.5 : 0.25
        let fall = Float(pow(0.5, dt / keyHalf))
        for i in 0..<88 {
            let note = UInt8(i + 21)
            if let v = held[note] { keyGlow[i] = max(keyGlow[i] * fall, v * 0.6) } else { keyGlow[i] *= fall }
        }
        let keys = KeyboardLayout.keys().map { k in
            KeyVisual(key: k, pressed: held[k.note] != nil, glow: keyGlow[Int(k.note) - 21])
        }

        // Environment
        let tod = p.choice("time")
        let sunBase: [String: Float] = ["Dawn": 0.18, "Morning": 0.55, "Golden Hour": 0.3, "Dusk": 0.1, "Moonlight": 0.6]
        let night = tod == "Moonlight" || tod == "Dusk"
        let brightness = Float(roles[.brightness])
        let exposure = 0.9 + 0.4 * energy + 0.2 * brightness - (night ? 0.2 : 0)
        let warmthMacro = Float(p.macros[.temperature] ?? 0)
        let melodyFollow = p.choice("camera.motion") == "Follow melody"
        let drift = p.choice("camera.motion") == "Still" ? 0 : Float(0.01)
        return GardenFrame(
            butterflies: flyers.map(\.b),
            blooms: blooms,
            keys: keys,
            sunHeight: (sunBase[tod] ?? 0.3) + 0.1 * direction + 0.05 * Float(p.number("sun.angle")),
            rays: min(1.5, Float(p.number("rays")) * (0.6 + 0.6 * brightness + 0.4 * energy)),
            mist: min(1, Float(p.number("mist")) + 0.6 * Float(roles[.atmosphere])),
            breeze: breeze,
            pollen: Float(p.number("pollen.sparkle")) * (0.5 + Float(roles[.density])),
            petals: Float(p.number("petals")) * (0.5 + 0.5 * chaos + 0.3 * energy),
            fireflies: p.number("fireflies") > 0.5 && night ? (landing ? 1 : 0.5) : 0,
            warmth: max(-1, min(1, Float(roles[.warmth]) + warmthMacro)),
            exposure: exposure,
            spiral: spiral,
            cameraZoom: Float(p.number("camera.zoom")) - 0.08 * Float(roles[.size]),
            cameraOffset: SIMD2<Float>(
                drift * sin(Float(time) * 0.13) + (melodyFollow ? (melodyX - 0.5) * 0.1 : 0),
                drift * cos(Float(time) * 0.11)),
            timeOfDay: tod,
            time: time)
    }

    private mutating func apply(_ e: PerformanceEvent, params p: ParameterSet, roles: RoleValues) {
        switch e {
        case let .noteOn(note, velocity):
            held[note] = velocity
            sinceNote = 0
            guard let x = Self.keyCentre(note) else { return }
            melodyX = x
            if let i = hovering.removeValue(forKey: note) { flyers[i].b.homeNote = nil }
            addBloom(at: x, note: note, params: p)
            guard Double(velocity) >= p.number("spawn.minVelocity") else { return }
            spawnBudget += p.number("spawn.rate")
            guard spawnBudget >= 1 else { return }
            spawnBudget -= 1
            spawn(note: note, x: x, velocity: velocity, params: p, roles: roles)
        case let .noteOff(note):
            held[note] = nil
            if let i = hovering.removeValue(forKey: note) {
                flyers[i].b.homeNote = nil
                flyers[i].velocity = SIMD3<Float>(rng.range(-0.15, 0.15), 0.3, 0)
            }
        case let .release(note, speed):
            for i in flyers.indices.suffix(64) where flyers[i].b.homeNote == nil {
                guard let x = Self.keyCentre(note), abs(flyers[i].b.position.x - x) < 0.01 else { continue }
                flyers[i].velocity.y = 0.2 + 0.6 * speed
                flyers[i].velocity.x *= 1 + 2 * speed
            }
        case let .chord(notes):
            spiral = Float(p.number("chord.spiral"))
            let xs = notes.compactMap(Self.keyCentre)
            if !xs.isEmpty { spiralCentre = xs.reduce(0, +) / Float(xs.count) }
            chordHue = Float((notes.min() ?? 0) % 12) / 12
        case .allNotesOff:
            held.removeAll()
            for i in flyers.indices { flyers[i].b.homeNote = nil }
            hovering.removeAll()
            spiral = 0
            keyGlow = .init(repeating: 0, count: 88)
        case let .pressure(v):
            for i in hovering.values { flyers[i].b.glow = max(flyers[i].b.glow, 0.5 + 0.5 * v) }
        case .pedal, .control, .pitchBend:
            break
        }
    }

    private mutating func spawn(note: UInt8, x: Float, velocity v: Float, params p: ParameterSet, roles: RoleValues) {
        let pitch = (Float(note) - 21) / 87
        let sizeMin = Float(p.number("size.min")), sizeMax = Float(p.number("size.max"))
        let size = (sizeMax + (sizeMin - sizeMax) * pitch) * (0.6 + 0.8 * v) * (1 + 0.5 * Float(roles[.size]))
        let hue: Float
        switch p.choice("color.source") {
        case "Chord": hue = chordHue
        case "Velocity": hue = 0.75 - 0.7 * v
        case "Palette": hue = 0.08 + rng.range(-0.04, 0.04)
        default: hue = Float(note % 12) / 12
        }
        let styleChoice = p.choice("wings.style")
        let style: Int
        if styleChoice == "Mix" {
            let variety = Float(p.number("wings.mix"))
            style = rng.unit() < variety ? 1 + Int(rng.unit() * 8) % 8 : 1
        } else {
            style = Self.wingStyles.firstIndex(of: styleChoice) ?? 1
        }
        serial += 1
        let b = Butterfly(position: SIMD3<Float>(x, 0.08, rng.range(0.2, 0.8)), size: size, hue: hue,
                          flapPhase: rng.unit(), flapRate: 0, style: style, glow: v, landed: false,
                          homeNote: p.number("land.onHeld") > 0.5 ? note : nil, opacity: 0)
        flyers.append(Flyer(b: b, velocity: SIMD3<Float>(rng.range(-0.1, 0.1), 0.3 + 0.4 * v, 0),
                            baseFlap: Float(p.number("flutter.speed")) * (4 + 6 * pitch),
                            lifespan: Float(p.number("lifespan")) * rng.range(0.8, 1.2),
                            hoverHeight: 0.15 + 0.15 * v, seed: rng.unit(), serial: serial))
        if b.homeNote != nil { hovering[note] = flyers.count - 1 }
        if flyers.count > lastCap * 2 { trim(to: lastCap) }
    }

    /// Keeps hovering butterflies first, then the newest, up to `cap`.
    private mutating func trim(to cap: Int) {
        guard flyers.count > cap else { return }
        var hover: [Flyer] = [], free: [Flyer] = []
        for f in flyers { if f.b.homeNote != nil { hover.append(f) } else { free.append(f) } }
        let room = max(0, cap - hover.count)
        flyers = (Array(hover.suffix(cap)) + Array(free.suffix(room))).sorted { $0.serial < $1.serial }
        rebuildIndex()
    }

    private mutating func rebuildIndex() {
        hovering.removeAll(keepingCapacity: true)
        for (i, f) in flyers.enumerated() { if let n = f.b.homeNote { hovering[n] = i } }
    }

    private mutating func addBloom(at x: Float, note: UInt8, params p: ParameterSet) {
        let types = ["Mixed", "Roses", "Poppies", "Lotus", "Wildflowers", "Cherry Blossom"]
        let chosen = types.firstIndex(of: p.choice("flowers.types")) ?? 0
        let kind = chosen == 0 ? 1 + Int(rng.unit() * 5) % 5 : chosen
        blooms.append(Bloom(x: x, openness: 0.05, hue: Float(note % 12) / 12, age: 0, kind: kind))
        if blooms.count > Self.maxBlooms { blooms.removeFirst(blooms.count - Self.maxBlooms) }
    }
}
