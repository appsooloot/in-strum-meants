import Foundation
import simd

/// A ring spreading on the water from where a note fell.
public struct Ripple: Equatable {
    /// 0…1 across the lake (the key's place on the keyboard).
    public var x: Float
    /// 0 near … 1 far (low notes fall nearer).
    public var depth: Float
    public var age: Float
    public var strength: Float
    public var lifetime: Float
}

/// A firefly lifted off the water by a chord.
public struct Firefly: Equatable {
    /// x 0…1 across, y height above the water 0…1, z depth 0 near … 1 far.
    public var position: SIMD3<Float>
    public var age: Float
    public var hue: Float
    /// Seconds it lives (4–6).
    public var lifetime: Float
    var drift: SIMD3<Float>

    public static func == (a: Firefly, b: Firefly) -> Bool { a.position == b.position && a.age == b.age && a.hue == b.hue }
}

/// Lake Ripples: every note drops a ring on the moonlit water; held notes make the moon path glitter;
/// chords lift fireflies.
public struct LakeRipples {
    public static let cap = 64
    public static let fireflyCap = 40
    static let chordWindow = 0.05

    /// Keyboard position (key centre 0…1) → place across the lake.
    public static func lakeX(keyCentre: Float) -> Float { keyCentre }

    public private(set) var ripples: [Ripple] = []
    public private(set) var fireflies: [Firefly] = []
    public private(set) var glitter: Float = 0

    /// Settings (0…1) and the mood's scales, set by the world each frame.
    public var size: Float = 0.5
    public var linger: Float = 0.5
    public var fireflyAmount: Float = 0.6
    public var reactionScale: Float = 1
    public var lingerScale: Float = 1

    private var held = Set<UInt8>()
    private var recent: [(t: Double, x: Float)] = []
    private var lastChord = -1.0
    private var pendingFireflies: [(x: Float, depth: Float)] = []
    private var rng = SeededRandom(seed: 0x1A4E)

    public init() {}

    private static let centres: [Float] = (21...108).map { n in
        let k = KeyboardLayout.key(for: UInt8(n))!
        return k.x + k.width / 2
    }

    static func depth(for note: UInt8) -> Float {
        let pitch = (Float(min(108, max(21, note))) - 21) / 87
        return 0.08 + 0.84 * pitch
    }

    public mutating func noteOn(_ note: UInt8, velocity: UInt8, pedal: Bool, at t: Double) {
        held.insert(note)
        guard (21...108).contains(note) else { return }
        let x = Self.lakeX(keyCentre: Self.centres[Int(note) - 21])
        let v = Float(min(127, velocity)) / 127
        var life: Float = 2.5 * (pedal ? 1.8 : 1) * (0.6 + linger) * lingerScale
        life = max(0.5, life)
        let ripple = Ripple(x: x, depth: Self.depth(for: note), age: 0, strength: v * (0.5 + size) * reactionScale, lifetime: life)
        if ripples.count >= Self.cap {
            // Make room: the faintest (oldest, weakest) ring goes.
            var worst = 0, worstScore = Float.infinity
            for (i, r) in ripples.enumerated() {
                let score = r.strength * (1 - r.age / r.lifetime)
                if score < worstScore { worst = i; worstScore = score }
            }
            ripples.remove(at: worst)
        }
        ripples.append(ripple)

        // A chord: three or more notes within 50 ms lift fireflies (once per chord).
        recent.append((t, x))
        while let first = recent.first, t - first.t > Self.chordWindow { recent.removeFirst() }
        if recent.count >= 3, t - lastChord > Self.chordWindow {
            lastChord = t
            let mean = recent.map(\.x).reduce(0, +) / Float(recent.count)
            pendingFireflies.append((mean, Self.depth(for: note)))
        }
    }

    /// The `limit` rings worth drawing when the budget is smaller than the cap (RED stub: the newest).
    public static func visible(_ ripples: [Ripple], limit: Int) -> [Ripple] { Array(ripples.suffix(limit)) }

    public mutating func noteOff(_ note: UInt8) { held.remove(note) }

    public mutating func allNotesOff() { held.removeAll() }

    public mutating func step(dt: Double, roles: RoleValues) {
        let fdt = Float(max(0, dt))
        for i in ripples.indices { ripples[i].age += fdt }
        ripples.removeAll { $0.age >= $0.lifetime }

        let target = min(1, Float(held.count) / 4)
        glitter += (target - glitter) * (1 - exp(-fdt / 0.35))

        if fireflyAmount > 0.01 {
            for p in pendingFireflies {
                let n = 2 + Int(rng.unit() * 3.99 * min(1, fireflyAmount + 0.25))
                for _ in 0..<min(5, n) where fireflies.count < Self.fireflyCap {
                    let pos = SIMD3<Float>(min(1, max(0, p.x + rng.range(-0.06, 0.06))), rng.range(0.02, 0.08), min(1, max(0, p.depth + rng.range(-0.1, 0.1))))
                    let drift = SIMD3<Float>(rng.range(-0.03, 0.03), rng.range(0.025, 0.06), rng.range(-0.02, 0.02))
                    fireflies.append(Firefly(position: pos, age: 0, hue: rng.range(0.12, 0.2), lifetime: rng.range(4, 6), drift: drift))
                }
            }
        }
        pendingFireflies.removeAll()
        let wander = Float(roles[.motion])
        for i in fireflies.indices {
            var f = fireflies[i]
            f.age += fdt
            let phase = f.age * 1.7 + f.hue * 40
            f.position += (f.drift + SIMD3<Float>(0.02 * sin(phase) * (1 + wander), 0.01 * cos(phase * 1.3), 0)) * fdt
            fireflies[i] = f
        }
        fireflies.removeAll { $0.age >= $0.lifetime }
    }
}
