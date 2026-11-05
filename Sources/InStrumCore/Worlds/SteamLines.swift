import Foundation

/// A wisp a note sends curling off the tea's steam (bowl coordinates: x 0…1 across the bowl's width; heights 0 at the
/// bowl's rim … 1 the top of the steam).
public struct SteamWisp: Equatable {
    public var id: Int
    public var note: UInt8
    /// Where it curls out to across the bowl: its key's centre, mapped to 0.2…0.8 of the bowl's width.
    public var x: Float
    /// How high its note's velocity sends it: 0.3 + 0.7 × velocity of the steam's height.
    public var height: Float
    /// How high its head has risen now (0…1): toward `height` (τ 0.8 s), and drawn on up toward 1 while held.
    public var rise: Float
    /// Seconds since it left the ribbon.
    public var age: Float
    /// Its brightness while held: 0.35 + 0.65 × velocity, times the mood's reaction (at most 1).
    public var peak: Float
    /// Its brightness now: `peak` while held (or pedalled), fading with τ 3 s (times the mood's linger) once let go.
    public var brightness: Float
    /// Held, or sounding under the pedal.
    public var held: Bool

    /// Its lateral curl off the ribbon: −1 out to the bowl's left (x 0.2) … +1 out to its right (x 0.8).
    public var curl: Float { min(1, max(-1, (x - 0.5) / 0.3)) }
}

/// The rounder cloud a chord puffs up off the tea.
public struct SteamPuff: Equatable {
    /// Across the bowl: the mean place of the chord's keys (0.2…0.8).
    public var x: Float
    /// 1 warm (major), 0 cool (minor), 0.5 otherwise.
    public var warmth: Float
    /// 0…1 now: it swells in over about 0.15 s, then dies away with τ 1.5 s.
    public var strength: Float
    /// Seconds since the chord (it rises and spreads as it ages).
    public var age: Float

    public static let still = SteamPuff(x: 0.5, warmth: 0.5, strength: 0, age: 0)
}

/// A snowflake a hard note knocks off the stone lantern's cap in the garden.
public struct LanternFlake: Equatable {
    public var id: Int
    /// Where along the cap it falls from: 0 the left eave … 1 the right (its key's centre, mapped to 0.1…0.9).
    public var x: Float
    /// When it was knocked off, on the clock the notes come in on (a world's frame `time`).
    public var time: Double
    /// Seconds it has been falling (gone at `SteamLines.flakeLife`).
    public var age: Float
    /// Its note's velocity (0.85…1): a harder note knocks it further out.
    public var velocity: Float
}

/// Steam Lines (spec §8.2): the tea's steam rises from the bowl as two to four soft ribbons. Each note sends a wisp
/// curling off the ribbon toward its key's place across the bowl, as high as its velocity; held (or pedalled) notes
/// keep their wisps drawn upward and brighten the steam; runs draw the melody's contour up the ribbon (the last 12
/// notes' pitches, newest lowest); chords puff a rounder cloud, warm for major and cool for minor; a hard note knocks a
/// snowflake off the stone lantern's cap outside. Deterministic; every brightness it hands out is 0…1 and, while time
/// runs, changes smoothly, for the renderer's `FlashLimiter` (while it is held, what a note makes appears at once, at
/// its bloom, and stays).
public struct SteamLines {
    public static let cap = 24
    public static let maxSpawnsPerStep = 8
    /// Released wisps fade with this time constant (seconds, times the mood's linger); a run's shape relaxes with it too.
    public static let fadeTau = 3.0
    /// A wisp's head rises toward its height (or, held, toward the top of the steam) with this time constant.
    public static let riseTau = 0.8
    /// A note within this long of the previous one carries the run on (and shapes the ribbon).
    public static let runWindow = 0.25
    /// Closer than this, notes are struck together (a chord or a smudge), not a run.
    static let minRunGap = 0.04
    /// The ribbon's path: one lateral offset per note of a run's last 12, from the bowl up.
    public static let pathPoints = 12
    /// A run's contour: each semitone from the run's mean pitch moves its point this far (an octave is the full swing).
    static let semitoneSwing: Float = 1.0 / 12
    /// The ribbon glides toward a run's shape with this time constant (seconds), so it never jumps.
    static let pathGlide = 0.25
    /// Chords: three or more notes within 60 ms.
    static let chordWindow = 0.06
    static let puffRise = 0.15, puffFall = 1.5
    /// While time is held (a step of dt 0) a wisp that left the ribbon since the last step starts risen to its height,
    /// and a chord's puff this old (it swells in over about 0.15 s), at its full strength: else neither would show.
    public static let puffBloomAge: Float = 0.15
    /// The steam brightens while notes sound (τ in, seconds) and settles back in silence (τ out, times the linger).
    static let glowRise = 0.6, glowFall = 3.0
    /// A note at least this hard (velocity 0…1) knocks a snowflake off the lantern's cap; it falls for `flakeLife` s.
    public static let hardNote: Float = 0.85
    public static let flakeLife: Float = 4
    /// The ribbon with no run's shape on it.
    public static let straight = [Float](repeating: 0, count: pathPoints)

    /// The mood's scales (how strongly it reacts; how long released wisps and a run's shape linger).
    public var reactionScale: Float = 1
    public var lingerScale: Float = 1

    public private(set) var wisps: [SteamWisp] = []
    /// The ribbon's lateral offsets up its height (`pathPoints` of them, −1…1, index 0 at the bowl): the latest run's
    /// contour, its newest note lowest, relaxing back to straight.
    public private(set) var ribbonPath = SteamLines.straight
    /// The steam's brightening while notes sound (the pedal counts), 0…1.
    public private(set) var glow: Float = 0
    public private(set) var puff = SteamPuff.still
    /// The latest snowflake knocked off the lantern's cap, while it falls.
    public private(set) var lanternFlake: LanternFlake?
    /// Wisps that left the ribbon on the last step (tests).
    private(set) var lastSpawns = 0

    var nextID = 0, nextFlakeID = 0
    private var held = Set<UInt8>()
    /// Released while the pedal is down: still sounding, so still drawn up.
    private var sustained = Set<UInt8>()
    private var pedal = false
    /// Notes waiting for a wisp (rationed per step; only the latest `cap` are kept).
    private var queue: [(note: UInt8, velocity: Float)] = []
    /// When the last note came, and the run it carries on (its last `pathPoints` notes, oldest first).
    private var lastNote: Double?
    private var run: [UInt8] = []
    /// The shape the ribbon glides toward: the run's contour, relaxing back to straight.
    private var pathTarget = SteamLines.straight
    private var chordNotes: [(t: Double, x: Float, v: Float)] = []
    private var lastChord = -Double.infinity
    private var puffTarget: Float = 0

    public init() {}

    private static let centres: [Float] = (21...108).map { n in
        let k = KeyboardLayout.key(for: UInt8(n))!
        return k.x + k.width / 2
    }

    private static func centre(_ note: UInt8) -> Float { centres[Int(min(108, max(21, note))) - 21] }

    /// A note's place across the bowl: its key's centre, mapped to 0.2…0.8 of the bowl's width.
    public static func x(for note: UInt8) -> Float { 0.2 + 0.6 * centre(note) }

    /// Where along the lantern's cap a note knocks its flake from: its key's centre, mapped to 0.1…0.9.
    public static func capX(for note: UInt8) -> Float { 0.1 + 0.8 * centre(note) }

    /// How many soft ribbons the tea's steam rises in: 2 (a thread) … 4 (a steaming bowl), by the Tea steam setting.
    public static func ribbonCount(steam: Float) -> Int {
        let s = steam.isFinite ? min(max(steam, 0), 1) : 0.6
        return 2 + Int((2 * s).rounded())
    }

    private var reaction: Float { reactionScale.isFinite ? min(max(reactionScale, 0), 2) : 1 }

    // MARK: - Events

    public mutating func noteOn(_ note: UInt8, velocity: Float, at t: Double) {
        let v = velocity.isFinite ? min(max(velocity, 0), 1) : 0.7
        held.insert(note)
        sustained.remove(note)
        queue.append((note, v))
        if queue.count > Self.cap { queue.removeFirst(queue.count - Self.cap) }
        guard t.isFinite else { return }

        // A hard note knocks a snowflake off the lantern's cap (the latest one falls).
        if v >= Self.hardNote {
            lanternFlake = LanternFlake(id: nextFlakeID, x: Self.capX(for: note), time: t, age: 0, velocity: v)
            nextFlakeID = nextFlakeID &+ 1
        }

        // A run: notes within 0.25 s of each other (but not struck together) draw the melody's contour up the ribbon.
        // Notes struck together neither carry the run on nor break it; after a pause (or out of order) a new one begins.
        let gap = lastNote.map { t - $0 } ?? .infinity
        if gap >= Self.minRunGap && gap <= Self.runWindow {
            run.append(note)
            if run.count > Self.pathPoints { run.removeFirst(run.count - Self.pathPoints) }
            if run.count >= 2 { shapeRibbon() }
        } else if !(gap >= 0 && gap < Self.minRunGap) {
            run = [note]
        }
        lastNote = t

        // A chord: three or more notes within 60 ms (once per chord), coloured by what's sounding.
        chordNotes.append((t, Self.x(for: note), v))
        while let first = chordNotes.first, t - first.t > Self.chordWindow { chordNotes.removeFirst() }
        if chordNotes.count > Self.cap { chordNotes.removeFirst(chordNotes.count - Self.cap) }   // bounded, whatever the clock
        if chordNotes.count >= 3, t - lastChord > Self.chordWindow {
            lastChord = t
            let n = Float(chordNotes.count)
            let meanV = chordNotes.map(\.v).reduce(0, +) / n
            puffTarget = max(puffTarget, min(1, (0.6 + 0.4 * meanV) * reaction))
            puff.x = chordNotes.map(\.x).reduce(0, +) / n
            puff.age = 0
            switch PlayingAnalyzer.classify(held.union(sustained)) {
            case .major: puff.warmth = 1
            case .minor: puff.warmth = 0
            default: puff.warmth = 0.5
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

    /// Lets every note go (a panic, an unplugged keyboard, a change of visual): no wisp stays drawn up, no queued note
    /// sends one, and the next note starts a new run.
    public mutating func allNotesOff() {
        held.removeAll()
        sustained.removeAll()
        queue.removeAll()
        run.removeAll()
        lastNote = nil
        chordNotes.removeAll()
    }

    /// The run's contour as the ribbon's shape: each note's pitch from the run's mean, newest at the bowl.
    private mutating func shapeRibbon() {
        let mean = Float(run.reduce(0) { $0 + Int($1) }) / Float(run.count)
        var target = Self.straight
        for (i, n) in run.reversed().enumerated() where i < Self.pathPoints {
            target[i] = min(1, max(-1, (Float(n) - mean) * Self.semitoneSwing))
        }
        pathTarget = target
    }

    // MARK: - Step

    public mutating func step(dt: Double, roles: RoleValues) {
        let step = dt.isFinite ? min(max(dt, 0), 0.25) : 0
        let fdt = Float(step)
        let linger = Double(lingerScale.isFinite ? min(max(lingerScale, 0.2), 3) : 1)
        let sounding = held.union(sustained)

        // Wisps age first: held (or pedalled) ones stay at their peak and are drawn on up toward the top of the steam;
        // released ones stop at their velocity's height and fade.
        let fade = Float(exp(-step / (Self.fadeTau * linger)))
        let lift = Float(1 - exp(-step / Self.riseTau))
        for i in wisps.indices {
            wisps[i].age += fdt
            wisps[i].held = sounding.contains(wisps[i].note)
            if wisps[i].held { wisps[i].brightness = wisps[i].peak } else { wisps[i].brightness *= fade }
            let top: Float = wisps[i].held ? 1 : wisps[i].height
            if top > wisps[i].rise { wisps[i].rise += (top - wisps[i].rise) * lift }
        }
        wisps.removeAll { !$0.held && $0.brightness < 0.01 }

        // New wisps, at most 8 per step, leaving the bowl; a full steam lets its dimmest wisp go first.
        lastSpawns = 0
        for (note, v) in queue.prefix(Self.maxSpawnsPerStep) {
            if wisps.count >= Self.cap, let dimmest = wisps.indices.min(by: { Self.score(wisps[$0]) < Self.score(wisps[$1]) }) {
                wisps.remove(at: dimmest)
            }
            let peak = min(1, (0.35 + 0.65 * v) * reaction)
            wisps.append(SteamWisp(id: nextID, note: note, x: Self.x(for: note), height: 0.3 + 0.7 * v, rise: 0, age: 0,
                                   peak: peak, brightness: peak, held: sounding.contains(note)))
            nextID = nextID &+ 1
            lastSpawns += 1
        }
        queue.removeFirst(min(queue.count, Self.maxSpawnsPerStep))
        if step == 0 {
            for i in wisps.indices where wisps[i].age == 0 { wisps[i].rise = max(wisps[i].rise, wisps[i].height) }
        }

        // The ribbon glides toward the run's shape, which relaxes back to straight.
        let relax = Float(exp(-step / (Self.fadeTau * linger)))
        let glide = Float(1 - exp(-step / Self.pathGlide))
        for i in 0..<Self.pathPoints {
            pathTarget[i] *= relax
            ribbonPath[i] += (pathTarget[i] - ribbonPath[i]) * glide
            if abs(pathTarget[i]) < 1e-5, abs(ribbonPath[i]) < 1e-5 { pathTarget[i] = 0; ribbonPath[i] = 0 }
        }

        // The steam brightens while anything sounds (the pedal counts) and settles in silence.
        let wanted: Float = sounding.isEmpty ? 0 : min(1, (0.4 + 0.15 * Float(sounding.count)) * min(1, reaction))
        let tau = wanted > glow ? Self.glowRise : Self.glowFall * linger
        glow += (wanted - glow) * Float(1 - exp(-step / tau))
        glow = min(max(glow, 0), 1)

        // The puff swells in quickly toward its target, which dies away; the puff follows it down.
        puffTarget *= Float(exp(-step / Self.puffFall))
        if puffTarget > puff.strength {
            puff.strength += (puffTarget - puff.strength) * Float(1 - exp(-step / Self.puffRise))
        } else {
            puff.strength = puffTarget
        }
        if puff.strength < 1e-4 { puff.strength = 0; if puffTarget < 1e-4 { puffTarget = 0 } }
        puff.age = min(puff.age + fdt, 600)
        // A chord sets the puff's age back to 0, so a puff at age 0 with a target was called for since the last step.
        if step == 0, puff.age == 0, puffTarget > 0 {
            puff.strength = max(puff.strength, puffTarget)
            puff.age = Self.puffBloomAge
        }

        // The lantern's flake falls, and is gone once it has.
        if var flake = lanternFlake {
            flake.age += fdt
            lanternFlake = flake.age >= Self.flakeLife ? nil : flake
        }
    }

    static func score(_ w: SteamWisp) -> Float { w.held ? 2 + w.brightness : w.brightness }

    /// The `limit` wisps worth drawing when the budget is smaller than the cap: the brightest, in their original order.
    public static func visible(_ w: [SteamWisp], limit: Int) -> [SteamWisp] {
        guard w.count > limit else { return w }
        let keep = Set(w.indices.sorted { score(w[$0]) > score(w[$1]) }.prefix(max(0, limit)))
        return w.indices.filter { keep.contains($0) }.map { w[$0] }
    }
}
