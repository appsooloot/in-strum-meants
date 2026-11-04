import Foundation
import simd

/// A patch of plankton a note lights on the bay (x 0…1 across, depth 0 near … 1 far).
public struct GlowPatch: Equatable {
    public var id: Int
    public var note: UInt8
    /// Across the bay: the key's centre, mapped to 0.06…0.94 (drifting slowly with the current).
    public var x: Float
    /// 0.15 + 0.5 × (1 − velocity): hard notes land close.
    public var depth: Float
    /// 0.02 + 0.05 × velocity.
    public var radius: Float
    /// The brightness while lit: 0.4 + 0.6 × velocity (with the mood's reaction on top, capped at 1).
    public var peak: Float
    /// The brightness now (`peak` while held, fading after release), times the night.
    public var brightness: Float
    /// Held (or sounding under the pedal).
    public var held: Bool
}

/// A streak of glow drawn from one note's patch to the next in a run.
public struct GlowWakeLine: Equatable {
    public var id: Int
    /// (x, depth) of the previous patch and of the new one.
    public var from: SIMD2<Float>
    public var to: SIMD2<Float>
    /// Seconds since it was drawn (gone at `GlowWake.wakeLife`).
    public var age: Float
    /// 0…1 when drawn (times the night in what `GlowWake` hands out).
    public var strength: Float
    /// 0…1 now: `strength`, fading out linearly to nothing over `GlowWake.wakeLife`.
    public var brightness: Float { strength * max(0, 1 - age / GlowWake.wakeLife) }
}

/// A fish darting off a fast run's wake: a short bright streak.
public struct Dart: Equatable {
    public var id: Int
    /// (x, depth) where it set off and its unit direction in that plane.
    public var start: SIMD2<Float>
    public var direction: SIMD2<Float>
    /// Seconds since it set off (gone at `GlowWake.dartLife`); it is at start + direction × speed × age.
    public var age: Float
    /// Bay units per second.
    public var speed: Float
    /// 0…1 when it set off (times the night in what `GlowWake` hands out).
    public var strength: Float
    /// 0…1 now: `strength`, fading out linearly to nothing over `GlowWake.dartLife`.
    public var brightness: Float { strength * max(0, 1 - age / GlowWake.dartLife) }
    /// Where it is now.
    public var position: SIMD2<Float> { start + direction * speed * age }
}

/// The wide glow a chord blooms on the water.
public struct GlowPool: Equatable {
    public var x: Float
    public var radius: Float
    /// 0…1, times the night.
    public var strength: Float
    /// 1 brighter (major), 0 a deeper teal (minor), 0.5 otherwise.
    public var warm: Float

    public static let still = GlowPool(x: 0.5, radius: GlowWake.poolRadius, strength: 0, warm: 0.5)
}

/// Glow Wake (spec §9.2): each note lights a patch of plankton where its key sits; it stays lit while held (or
/// pedalled) and fades after release. Runs draw wakes from patch to patch, fast runs send fish darting off them,
/// chords bloom a wide pool. The plankton needs the dark: `nightScale` multiplies every brightness it hands out.
public struct GlowWake {
    public static let cap = 48
    public static let maxSpawnsPerStep = 12
    public static let fadeTau = 2.5, lingerTau = 5.0
    /// A note within this long of the previous one draws a wake.
    public static let runWindow = 0.25
    /// Closer than this, notes are struck together (a chord or a smudge), not a run.
    static let minRunGap = 0.04
    public static let wakeCap = 16, dartCap = 12
    public static let wakeLife: Float = 1.5, dartLife: Float = 0.6
    /// A fast run: at least `fastRunNotes` notes within `fastRunWindow` seconds.
    static let fastRunNotes = 4, fastRunWindow = 1.0
    /// Darts set off at most this often (seconds of playing), so a long run is a shoal, not a blizzard.
    static let dartCooldown = 0.3
    /// Patches drift sideways with the current (bay units per second).
    public static let drift: Float = 0.004
    public static let poolRadius: Float = 0.25
    /// Chords: three or more notes within 60 ms.
    static let chordWindow = 0.06
    static let poolRise = 0.15, poolFall = 1.5

    /// Set by the world each frame: 0 by day … 1 at night (and dulled by rain).
    public var nightScale: Float = 1
    /// The mood's scales (how brightly it reacts; how long released patches linger).
    public var reactionScale: Float = 1
    public var lingerScale: Float = 1

    private var lit: [GlowPatch] = []
    private var wakeLines: [GlowWakeLine] = []
    private var dartList: [Dart] = []
    private var poolState = GlowPool.still
    private var poolTarget: Float = 0

    var nextID = 0, nextWakeID = 0, nextDartID = 0
    private var held = Set<UInt8>()
    /// Released while the pedal is down: still sounding, so still lit.
    private var sustained = Set<UInt8>()
    private var pedal = false
    /// Notes waiting for a patch (rationed per step; only the latest `cap` are kept).
    private var queue: [(note: UInt8, velocity: Float, t: Double)] = []
    /// The last patch spawned: when, and where.
    private var last: (t: Double, at: SIMD2<Float>)?
    private var runTimes: [Double] = []
    private var lastDarts = -Double.infinity
    private var chordNotes: [(t: Double, x: Float, v: Float)] = []
    private var lastChord = -Double.infinity
    private var rng = SeededRandom(seed: 0x6C0_3A4E)

    public init() {}

    private static let centres: [Float] = (21...108).map { n in
        let k = KeyboardLayout.key(for: UInt8(n))!
        return k.x + k.width / 2
    }

    /// A note's place across the bay: its key's centre, mapped to 0.06…0.94.
    public static func x(for note: UInt8) -> Float { 0.06 + 0.88 * centres[Int(min(108, max(21, note))) - 21] }

    public static func depth(velocity v: Float) -> Float { 0.15 + 0.5 * (1 - v) }

    // MARK: - What it shows (every brightness times the night)

    private var night: Float { nightScale.isFinite ? min(max(nightScale, 0), 1) : 0 }

    public var patches: [GlowPatch] {
        let n = night
        return lit.map { var p = $0; p.brightness *= n; return p }
    }

    public var wakes: [GlowWakeLine] {
        let n = night
        return wakeLines.map { var w = $0; w.strength *= n; return w }
    }

    public var darts: [Dart] {
        let n = night
        return dartList.map { var d = $0; d.strength *= n; return d }
    }

    public var pool: GlowPool {
        var p = poolState
        p.strength *= night
        return p
    }

    // MARK: - Events

    public mutating func noteOn(_ note: UInt8, velocity: Float, at t: Double) {
        let v = velocity.isFinite ? min(max(velocity, 0), 1) : 1
        let time = t.isFinite ? t : 0
        held.insert(note)
        sustained.remove(note)
        queue.append((note, v, time))
        if queue.count > Self.cap { queue.removeFirst(queue.count - Self.cap) }
        // A chord: three or more notes within 60 ms (once per chord), coloured by what's sounding.
        chordNotes.append((time, Self.x(for: note), v))
        while let first = chordNotes.first, time - first.t > Self.chordWindow { chordNotes.removeFirst() }
        if chordNotes.count >= 3, time - lastChord > Self.chordWindow {
            lastChord = time
            let n = Float(chordNotes.count)
            let meanV = chordNotes.map(\.v).reduce(0, +) / n
            let reaction = reactionScale.isFinite ? min(max(reactionScale, 0), 2) : 1
            poolState.x = chordNotes.map(\.x).reduce(0, +) / n
            poolTarget = max(poolTarget, min(1, (0.6 + 0.4 * meanV) * reaction))
            switch PlayingAnalyzer.classify(held.union(sustained)) {
            case .major: poolState.warm = 1
            case .minor: poolState.warm = 0
            default: poolState.warm = 0.5
            }
        }
    }

    public mutating func noteOff(_ note: UInt8) {
        guard held.remove(note) != nil else { return }
        if pedal { sustained.insert(note) }
    }

    public mutating func setPedal(_ down: Bool) {
        pedal = down
        if !down { sustained.removeAll() }
    }

    public mutating func allNotesOff() {
        held.removeAll()
        sustained.removeAll()
        queue.removeAll()
    }

    // MARK: - Step

    public mutating func step(dt: Double, roles: RoleValues) {
        let step = dt.isFinite ? min(max(dt, 0), 0.25) : 0
        let fdt = Float(step)
        let reaction = reactionScale.isFinite ? min(max(reactionScale, 0), 2) : 1
        let linger = lingerScale.isFinite ? min(max(lingerScale, 0.2), 3) : 1

        // Age and fade the wakes and darts first, so this step's new ones start fresh.
        for i in wakeLines.indices { wakeLines[i].age += fdt }
        wakeLines.removeAll { $0.age >= Self.wakeLife }
        for i in dartList.indices { dartList[i].age += fdt }
        dartList.removeAll { $0.age >= Self.dartLife }

        // New patches, at most 12 per step; a full bay lets its dimmest patch go first.
        for (note, v, t) in queue.prefix(Self.maxSpawnsPerStep) {
            if lit.count >= Self.cap, let dimmest = lit.indices.min(by: { Self.score(lit[$0]) < Self.score(lit[$1]) }) {
                lit.remove(at: dimmest)
            }
            let peak = min(1, (0.4 + 0.6 * v) * reaction)
            let patch = GlowPatch(id: nextID, note: note, x: Self.x(for: note), depth: Self.depth(velocity: v),
                                  radius: 0.02 + 0.05 * v, peak: peak, brightness: peak, held: true)
            nextID = nextID &+ 1
            lit.append(patch)
            spawnWake(to: patch, v: v, at: t)
        }
        queue.removeFirst(min(queue.count, Self.maxSpawnsPerStep))

        // Held (or pedalled) patches stay lit; released ones fade (twice as slowly when lingering). All drift.
        let sounding = held.union(sustained)
        let tau = (roles[.linger] > 0.5 ? Self.lingerTau : Self.fadeTau) * Double(linger)
        let fade = Float(exp(-step / tau))
        for i in lit.indices {
            lit[i].held = sounding.contains(lit[i].note)
            if lit[i].held { lit[i].brightness = lit[i].peak } else { lit[i].brightness *= fade }
            lit[i].x = min(1, lit[i].x + Self.drift * fdt)
        }
        lit.removeAll { !$0.held && $0.brightness < 0.01 }

        // The pool swells in quickly toward its target, which dies away; the pool follows it down.
        poolTarget *= Float(exp(-step / Self.poolFall))
        if poolTarget > poolState.strength {
            poolState.strength += (poolTarget - poolState.strength) * Float(1 - exp(-step / Self.poolRise))
        } else {
            poolState.strength = poolTarget
        }
        if poolState.strength < 1e-4 { poolState.strength = 0 }
    }

    /// A wake (and on a fast run, darts) from the previous patch to this one, if it came within the run window.
    private mutating func spawnWake(to patch: GlowPatch, v: Float, at t: Double) {
        let here = SIMD2<Float>(patch.x, patch.depth)
        defer { last = (t, here) }
        runTimes.append(t)
        while let first = runTimes.first, t - first > Self.fastRunWindow { runTimes.removeFirst() }
        // Notes struck together (closer than `minRunGap`) are a chord, not a run: they bloom, they don't streak.
        guard let prev = last, t - prev.t >= Self.minRunGap, t - prev.t <= Self.runWindow else { return }
        let strength = min(1, (0.5 + 0.5 * v) * (reactionScale.isFinite ? min(max(reactionScale, 0), 2) : 1))
        if wakeLines.count >= Self.wakeCap { wakeLines.removeFirst(wakeLines.count - Self.wakeCap + 1) }
        wakeLines.append(GlowWakeLine(id: nextWakeID, from: prev.at, to: here, age: 0, strength: strength))
        nextWakeID = nextWakeID &+ 1

        // A fast run: 1–3 fish dart off the wake, angled away from it.
        guard runTimes.count >= Self.fastRunNotes, t - lastDarts >= Self.dartCooldown else { return }
        lastDarts = t
        let along = here - prev.at
        let len = simd_length(along)
        let base = len > 1e-5 ? along / len : SIMD2<Float>(1, 0)
        let count = 1 + Int(rng.unit() * 2.999)
        for _ in 0..<count {
            let side: Float = rng.unit() < 0.5 ? -1 : 1
            let a = side * rng.range(0.35, 1.1)
            let dir = SIMD2<Float>(base.x * cos(a) - base.y * sin(a), base.x * sin(a) + base.y * cos(a))
            if dartList.count >= Self.dartCap { dartList.removeFirst(dartList.count - Self.dartCap + 1) }
            dartList.append(Dart(id: nextDartID, start: here, direction: dir, age: 0, speed: rng.range(0.25, 0.45),
                                 strength: min(1, strength + 0.2)))
            nextDartID = nextDartID &+ 1
        }
    }

    static func score(_ p: GlowPatch) -> Float { p.held ? 2 + p.brightness : p.brightness }

    /// The `limit` patches worth drawing when the budget is smaller than the cap: the brightest, in their original order.
    public static func visible(_ p: [GlowPatch], limit: Int) -> [GlowPatch] {
        guard p.count > limit else { return p }
        let keep = Set(p.indices.sorted { score(p[$0]) > score(p[$1]) }.prefix(max(0, limit)))
        return p.indices.filter { keep.contains($0) }.map { p[$0] }
    }
}
