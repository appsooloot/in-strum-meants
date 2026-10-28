import Foundation
import simd

/// A sheer curtain panel (spec §9.2): a grid of points hung from rings on a rod, moved by a slowly varying breeze
/// and by puffs of air, integrated with Verlet at a fixed 120 Hz (the remainder carried over) with six passes of
/// structural and shear constraints. Displacement from rest is clamped, so it can never explode.
///
/// Units are window widths (about a metre): x across the window, y up, z into the room. The top row is pinned.
public struct Cloth {
    public static let substep = 1.0 / 120
    public static let iterations = 6
    public static let maxSubsteps = 8
    /// No point ever strays further than this from where it hangs at rest.
    public static let maxDisplacement: Float = 0.6
    /// Peak push of a puff of strength 1, and of the breeze at wind 1 (m/s²).
    static let puffPush: Float = 2.5, breezePush: Float = 1.5
    /// The breeze and the puffs add up softly toward this push (m/s²), so dense playing in a gale billows the cloth
    /// without ever pinning it on the safety clamp.
    static let maxPush: Float = 3.5

    /// A puff of air from a note: it spreads both ways from `x` (window coordinates) at 1.5 m/s as it ages.
    public struct Puff: Equatable {
        public var x: Float
        public var strength: Float
        public var age: Float
        public init(x: Float, strength: Float, age: Float) { self.x = x; self.strength = strength; self.age = age }
    }

    public let columns: Int, rows: Int
    public private(set) var positions: [SIMD3<Float>]
    public let restPositions: [SIMD3<Float>]
    /// Substeps taken by the last `step` (tests).
    private(set) var lastSubsteps = 0
    /// Simulated seconds (the breeze field's clock).
    var time = 0.0

    private var p: [Float], q: [Float]
    private let r: [Float]
    private let pinned: [Bool]
    private let ca: [Int32], cb: [Int32]
    private let rest: [Float]
    private let seedA: Float, seedB: Float
    private var carry = 0.0
    private var pushZ: [Float], pushX: [Float]

    public init(columns: Int = 24, rows: Int = 32, width: Float, height: Float, origin: SIMD3<Float>, seed: UInt64) {
        let cols = max(2, columns), rws = max(2, rows)
        self.columns = cols; self.rows = rws
        var rng = SeededRandom(seed: seed &* 0x9E37_79B9 &+ 0xC107)
        seedA = rng.range(0, 100); seedB = rng.range(0, 100)
        let w = width.isFinite ? max(width, 0.01) : 0.5, h = height.isFinite ? max(height, 0.01) : 1
        // Gathered on its rings: shallow folds along the rod.
        var rp: [SIMD3<Float>] = []
        rp.reserveCapacity(cols * rws)
        for j in 0..<rws {
            for i in 0..<cols {
                let fold = 0.022 * sin(Float(i) * 2 * .pi * 6 / Float(cols - 1))
                rp.append(origin + SIMD3(w * Float(i) / Float(cols - 1), -h * Float(j) / Float(rws - 1), fold))
            }
        }
        restPositions = rp
        positions = rp
        var flat = [Float](repeating: 0, count: rp.count * 3)
        for (k, v) in rp.enumerated() { flat[3 * k] = v.x; flat[3 * k + 1] = v.y; flat[3 * k + 2] = v.z }
        p = flat; q = flat; r = flat
        pinned = (0..<rp.count).map { $0 < cols }
        // Constraints in coloured batches (no two in a batch share a point): each batch's solves are independent,
        // which keeps the six passes cheap.
        var a: [Int32] = [], b: [Int32] = [], len: [Float] = []
        func add(_ i: Int, _ k: Int) {
            a.append(Int32(i)); b.append(Int32(k)); len.append(simd_length(rp[k] - rp[i]))
        }
        for par in 0..<2 { for j in 0..<rws { for i in stride(from: par, to: cols - 1, by: 2) { add(j * cols + i, j * cols + i + 1) } } }
        for par in 0..<2 { for j in stride(from: par, to: rws - 1, by: 2) { for i in 0..<cols { add(j * cols + i, (j + 1) * cols + i) } } }
        for par in 0..<2 { for j in stride(from: par, to: rws - 1, by: 2) { for i in 0..<(cols - 1) { add(j * cols + i, (j + 1) * cols + i + 1) } } }
        for par in 0..<2 { for j in stride(from: par, to: rws - 1, by: 2) { for i in 0..<(cols - 1) { add(j * cols + i + 1, (j + 1) * cols + i) } } }
        ca = a; cb = b; rest = len
        pushZ = [Float](repeating: 0, count: cols)
        pushX = [Float](repeating: 0, count: cols)
    }

    /// Advances by `dt` in fixed 120 Hz substeps (at most 8; a longer gap is dropped, not caught up).
    /// `wind` is 0…2 (the sky's wind, doubled with the window open).
    public mutating func step(dt: Double, wind: Float, puffs: [Puff]) {
        lastSubsteps = 0
        guard dt.isFinite, dt > 0 else { return }
        let breeze = wind.isFinite ? min(max(wind, 0), 2) : 0
        let usable = puffs.filter { $0.x.isFinite && $0.strength.isFinite && $0.age.isFinite && $0.age >= 0 }
            .map { Puff(x: $0.x, strength: min(max($0.strength, 0), 1.5), age: $0.age) }
        carry += min(dt, Self.substep * Double(Self.maxSubsteps))
        var n = 0
        while carry >= Self.substep && n < Self.maxSubsteps {
            substep(breeze: breeze, puffs: usable)
            carry -= Self.substep
            n += 1
        }
        if n == Self.maxSubsteps { carry = min(carry, Self.substep) }
        lastSubsteps = n
        for k in 0..<positions.count { positions[k] = SIMD3(p[3 * k], p[3 * k + 1], p[3 * k + 2]) }
    }

    /// Value noise along one axis, from a hashed sine.
    private static func noise(_ x: Float, _ seed: Float) -> Float {
        func h(_ v: Float) -> Float { let s = sin(v * 127.1 + seed * 311.7) * 43758.5453; return s - s.rounded(.down) }
        let i = x.rounded(.down), f = x - i
        let u = f * f * (3 - 2 * f)
        return h(i) + (h(i + 1) - h(i)) * u
    }

    private mutating func substep(breeze: Float, puffs: [Puff]) {
        time += Self.substep
        let t = Float(time.truncatingRemainder(dividingBy: 10_000))
        let h2 = Float(Self.substep * Self.substep)
        let cols = columns
        // The pushes on each column: the breeze (a slowly varying field in x and time) and the puffs passing by.
        let sway = 0.3 * breeze * (Self.noise(t * 0.2, seedB) - 0.5)
        for i in 0..<cols {
            let x = r[3 * i]
            let field = 0.35 + 0.45 * Self.noise(x * 1.3 + t * 0.35, seedA) + 0.2 * Self.noise(x * 3.1 + t * 0.9, seedB)
            var z = Self.breezePush * breeze * field
            for puff in puffs {
                let spread = 1.5 * puff.age
                let d1 = x - puff.x - spread, d2 = x - puff.x + spread
                z += Self.puffPush * puff.strength * (exp(-d1 * d1 / 0.02) + exp(-d2 * d2 / 0.02))
            }
            pushZ[i] = Self.maxPush * (1 - exp(-max(0, z) / Self.maxPush))
            pushX[i] = sway
        }
        let count = positions.count
        let damping: Float = 0.985
        let maxD2 = Self.maxDisplacement * Self.maxDisplacement
        p.withUnsafeMutableBufferPointer { P in
            q.withUnsafeMutableBufferPointer { Q in
                r.withUnsafeBufferPointer { R in
                    pinned.withUnsafeBufferPointer { pin in
                        // Verlet: carry the velocity (damped), add gravity and the pushes.
                        for k in 0..<count where !pin[k] {
                            let col = k % cols
                            let x = P[3 * k], y = P[3 * k + 1], z = P[3 * k + 2]
                            P[3 * k] = x + (x - Q[3 * k]) * damping + pushX[col] * h2
                            P[3 * k + 1] = y + (y - Q[3 * k + 1]) * damping - 9.8 * h2
                            P[3 * k + 2] = z + (z - Q[3 * k + 2]) * damping + pushZ[col] * h2
                            Q[3 * k] = x; Q[3 * k + 1] = y; Q[3 * k + 2] = z
                        }
                        // Six passes over the structural and shear constraints.
                        ca.withUnsafeBufferPointer { A in
                            cb.withUnsafeBufferPointer { B in
                                rest.withUnsafeBufferPointer { L in
                                    for _ in 0..<Self.iterations {
                                        for c in 0..<A.count {
                                            let a = Int(A[c]), b = Int(B[c])
                                            let wa: Float = pin[a] ? 0 : 1, wb: Float = pin[b] ? 0 : 1
                                            let ws = wa + wb
                                            if ws == 0 { continue }
                                            let dx = P[3 * b] - P[3 * a], dy = P[3 * b + 1] - P[3 * a + 1], dz = P[3 * b + 2] - P[3 * a + 2]
                                            let len = (dx * dx + dy * dy + dz * dz).squareRoot()
                                            if len < 1e-6 { continue }
                                            let k = (len - L[c]) / (len * ws)
                                            P[3 * a] += dx * k * wa; P[3 * a + 1] += dy * k * wa; P[3 * a + 2] += dz * k * wa
                                            P[3 * b] -= dx * k * wb; P[3 * b + 1] -= dy * k * wb; P[3 * b + 2] -= dz * k * wb
                                        }
                                    }
                                }
                            }
                        }
                        // Safety: clamp each point's displacement from rest (and stop it there); reset anything not finite.
                        for k in 0..<count {
                            let dx = P[3 * k] - R[3 * k], dy = P[3 * k + 1] - R[3 * k + 1], dz = P[3 * k + 2] - R[3 * k + 2]
                            let d2 = dx * dx + dy * dy + dz * dz
                            if !d2.isFinite {
                                for e in 0..<3 { P[3 * k + e] = R[3 * k + e]; Q[3 * k + e] = R[3 * k + e] }
                            } else if d2 > maxD2 {
                                let s = Self.maxDisplacement / d2.squareRoot()
                                P[3 * k] = R[3 * k] + dx * s; P[3 * k + 1] = R[3 * k + 1] + dy * s; P[3 * k + 2] = R[3 * k + 2] + dz * s
                                Q[3 * k] = P[3 * k]; Q[3 * k + 1] = P[3 * k + 1]; Q[3 * k + 2] = P[3 * k + 2]
                            }
                        }
                    }
                }
            }
        }
    }
}
