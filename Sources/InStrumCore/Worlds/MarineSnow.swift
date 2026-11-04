import Foundation
import simd

/// Marine snow (spec §7.3): the sea's slow fall of pale flecks, shared by the submarine and the reef. A deterministic,
/// seeded set in a unit volume, x across (0…1, left to right), y up (0 the bottom … 1 the top) and z away from the
/// viewer (0 at the glass … 1 the far side). Each fleck drifts with the current (a little faster or slower than it),
/// sinks slowly (bigger flecks faster), sways on slow eddies and tumbles, glinting as it turns. A fleck that leaves
/// the volume is recycled: out of the bottom (or the top, in an upwelling) it comes back in at the other face,
/// somewhere new and new itself; out of a side it wraps round to the opposite side. Flecks fade in and out near the
/// faces, so nothing pops. 150 / 300 / 400 by quality; every step works in place, so it never allocates.
///
/// A renderer draws `live`: each fleck's `position` (mapped into its own view, e.g. z to distance from the glass),
/// `size` (1 a typical fleck; scale it by distance) and `brightness` (0…1: its pale colour × the tumble × the fades;
/// multiply by the light it is in: the sea's, the lamps').
public struct MarineSnow {
    public struct Fleck: Equatable {
        /// In the unit volume (x across, y up, z away).
        public var position: SIMD3<Float>
        /// 0.5…1.6, 1 a typical fleck: a renderer's size for it at a typical distance.
        public var size: Float
        /// 0…1 now: its paleness × its tumble's glint × the fades near the volume's faces.
        public var brightness: Float
        var albedo: Float
        /// Its own speed through the current (× the current), tumble rate and phase, and eddy phase.
        var drift: Float
        var spin: Float
        var tumble: Float
        var eddy: Float
    }

    /// Flecks drawn at each quality (Smooth draws 150).
    public static func count(_ q: QualityLevel) -> Int { q == .lite ? 150 : (q == .high ? 300 : 400) }
    /// Every fleck, live or waiting: the most any quality draws.
    public static let capacity = 400
    /// How close to a face (of the volume's unit) a fleck fades in or out.
    public static let fadeZone: Float = 0.06

    /// The current (volume units per second: x across, y up, z away); the world sets it as the sea moves.
    public var current = SIMD3<Float>(0.012, 0, 0)
    /// How fast a typical fleck sinks (volume units per second); bigger flecks fall faster.
    public var sinkRate: Float = 0.006

    /// Every fleck, all `capacity` of them, seeded at the start: only the first `count` are live (the rest wait where
    /// they were seeded, so a higher quality brings them in already spread through the volume).
    public private(set) var flecks: [Fleck]
    /// How many are live (follows the quality).
    public private(set) var count: Int
    /// The live flecks, in place (no copy).
    public var live: ArraySlice<Fleck> { flecks[0..<count] }
    /// Flecks recycled so far (out of the bottom or top, or wrapped round a side).
    public private(set) var recycled = 0

    private var rng: SeededRandom
    private var time: Float = 0

    public init(quality: QualityLevel = .high, seed: UInt64 = 0x5EA5_0A0F) {
        var r = SeededRandom(seed: seed)
        var all: [Fleck] = []
        all.reserveCapacity(Self.capacity)
        for _ in 0..<Self.capacity {
            let x = r.unit(), y = r.unit(), z = r.unit()
            all.append(Self.newFleck(&r, at: SIMD3(x, y, z)))
        }
        flecks = all
        count = Self.count(quality)
        rng = r
        for i in 0..<count { flecks[i].brightness = Self.brightness(flecks[i], time: 0) }
    }

    /// Changes how many flecks are live (the others keep their places and wait).
    public mutating func setQuality(_ q: QualityLevel) {
        count = Self.count(q)
    }

    public mutating func step(dt: Double) {
        let s: Float = dt.isFinite ? Float(min(max(dt, 0), 0.25)) : 0
        time += s
        if time > 3600 { time -= 3600 }   // the sways and tumbles are periods of seconds: keep the floats fine
        let cur = SIMD3<Float>(Self.finite(current.x, 0.2), Self.finite(current.y, 0.2), Self.finite(current.z, 0.2))
        let sink = Self.finite(sinkRate, 0.2)
        let t = time
        for i in 0..<count {
            var f = flecks[i]
            if s > 0 {
                // The current (each fleck a little faster or slower), the sinking, and a slow sway on eddies.
                let swayX: Float = sin(t * 0.37 + f.eddy)
                let swayY: Float = 0.6 * sin(t * 0.23 + f.eddy * 1.7)
                let swayZ: Float = cos(t * 0.29 + f.eddy * 0.6)
                let sway = SIMD3<Float>(swayX, swayY, swayZ) * 0.0025
                let fall = SIMD3<Float>(0, -sink * (0.5 + 0.5 * f.size), 0)
                f.position += (cur * f.drift + fall + sway) * s
                if f.position.y < 0 || f.position.y > 1 {
                    // Out of the bottom (or the top, in an upwelling): in again at the other face, somewhere new.
                    let x = rng.unit(), z = rng.unit(), y: Float = f.position.y < 0 ? 1 - 0.01 * rng.unit() : 0.01 * rng.unit()
                    f = Self.newFleck(&rng, at: SIMD3(x, y, z))
                    recycled &+= 1
                }
                if f.position.x < 0 { f.position.x += 1; recycled &+= 1 } else if f.position.x >= 1 { f.position.x -= 1; recycled &+= 1 }
                if f.position.z < 0 { f.position.z += 1; recycled &+= 1 } else if f.position.z >= 1 { f.position.z -= 1; recycled &+= 1 }
                // A huge current could carry a fleck more than a whole volume in one step: hold it inside.
                f.position = f.position.clamped(lowerBound: SIMD3<Float>(repeating: 0), upperBound: SIMD3<Float>(repeating: 0.999_999))
            }
            f.brightness = Self.brightness(f, time: t)
            flecks[i] = f
        }
    }

    // MARK: - Helpers

    private static func finite(_ v: Float, _ limit: Float) -> Float { v.isFinite ? min(max(v, -limit), limit) : 0 }

    /// A new fleck at `p`: mostly small, a few large; pale, some paler.
    private static func newFleck(_ r: inout SeededRandom, at p: SIMD3<Float>) -> Fleck {
        let u = r.unit()
        return Fleck(position: p, size: 0.5 + 1.1 * u * u, brightness: 0, albedo: r.range(0.55, 1),
                     drift: r.range(0.75, 1.25), spin: r.range(0.4, 1.6), tumble: r.range(0, 6.2831853),
                     eddy: r.range(0, 6.2831853))
    }

    /// Paleness × the tumble's glint × the fades near the faces (smooth, 0 on a face).
    private static func brightness(_ f: Fleck, time: Float) -> Float {
        let p = f.position
        let edge = min(min(min(p.x, 1 - p.x), min(p.y, 1 - p.y)), min(p.z, 1 - p.z))
        let k = min(max(edge / fadeZone, 0), 1)
        let fade = k * k * (3 - 2 * k)
        let glint = 0.7 + 0.3 * sin(time * f.spin + f.tumble)
        return f.albedo * glint * fade
    }
}
