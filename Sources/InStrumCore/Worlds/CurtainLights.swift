import Foundation

/// One ripple a note sends along the aurora's curtain. It starts at its key's place along the band and spreads
/// outward both ways at `CurtainLights.speed` (the shader draws the two fronts at `position ± offset`).
public struct CurtainRipple: Equatable {
    public var id: Int
    public var note: UInt8
    /// Where it started along the band (0…1; the key's centre mapped to 0.08…0.92).
    public var position: Float
    /// Seconds since the note.
    public var age: Float
    /// How bright it is now (its peak, fading with τ = life / 3).
    public var strength: Float
    /// Its peak strength (0.3 + 0.7 · velocity, times the mood's reaction, at most 1).
    public var peak: Float
    /// How wide each front is along the band (0.04 + 0.08 · velocity).
    public var width: Float

    /// How far each front has travelled from `position` at an age (along the band, 0…1 units).
    public static func offset(at age: Float) -> Float { CurtainLights.speed * max(0, age) }
    /// How far its fronts have travelled now.
    public var offset: Float { Self.offset(at: age) }
}

/// Curtain Lights (spec §8.2): each note sends a ripple along the aurora from its key's place; held notes swell the
/// curtain's glow; chords shift its hue (major warm, minor cool, tense a purple-fringe pulse); intensity speeds its
/// shimmer.
public struct CurtainLights {
    /// Ripples sent to the shader (the strongest, in order).
    public static let cap = 8
    /// Ripples kept alive (the weakest go first beyond this).
    public static let keep = 48
    public static let maxSpawnsPerStep = 6
    /// Along the band, per second.
    public static let speed: Float = 0.12
    /// Seconds a ripple lives (times the mood's linger).
    public static let life: Float = 3.5
    public static let glowRise = 2.0, glowFall = 6.0
    public static let glowCap: Float = 1
    /// The hue glide's time constant (the spec's 1.5 s, trimmed to 1.25 so a chord's hue settles within 0.05 of
    /// its target in 4 s, as the plan's test asks: e^(−4/1.5) = 0.07 would miss it).
    public static let hueTau = 1.25
    /// The tense chord's purple-fringe pulse: up in about 0.15 s, away with τ 0.8 s.
    static let pulseRise: Float = 0.15, pulseFall: Float = 0.8
    /// Chords: three or more notes within 60 ms.
    static let chordWindow = 0.06

    /// The mood's scales (how strong the ripples are; how long they and the glow linger).
    public var reactionScale: Float = 1
    public var lingerScale: Float = 1

    public private(set) var ripples: [CurtainRipple] = []
    /// The curtain's swell from held notes (0…1).
    public private(set) var glow: Float = 0
    /// −1 cool (minor) … +1 warm (major); 0 neutral or tense.
    public private(set) var hueShift: Float = 0
    /// A tense chord's purple-fringe pulse (0…1).
    public private(set) var tensePulse: Float = 0
    /// How fast the curtain shimmers: 1 … 2 with the playing's energy.
    public private(set) var shimmerSpeed: Float = 1
    /// Ripples started by the last step (tests).
    private(set) var lastSpawns = 0

    var nextID = 0
    private var held = Set<UInt8>()
    private var sustained = Set<UInt8>()
    private var pedal = false
    private var queue: [(note: UInt8, velocity: Float)] = []
    private var recent: [Double] = []
    private var lastChord = -Double.infinity
    /// The chord whose hue is showing (cleared when it lets go: the hue glides back to neutral).
    private var chordNotes = Set<UInt8>()
    private var hueTarget: Float = 0
    private var pulseTarget: Float = 0
    /// A tense chord has called for a pulse since the last step (while time is held, it pulses at once at full
    /// strength).
    private var pulseBorn = false

    public init() {}

    private static let centres: [Float] = (21...108).map { n in
        let k = KeyboardLayout.key(for: UInt8(n))!
        return k.x + k.width / 2
    }

    /// A note's place along the band: its key's centre, mapped to 0.08…0.92.
    public static func position(for note: UInt8) -> Float { 0.08 + 0.84 * centres[Int(min(108, max(21, note))) - 21] }

    // MARK: - Events

    public mutating func noteOn(_ note: UInt8, velocity: Float, at t: Double) {
        let v = velocity.isFinite ? min(max(velocity, 0), 1) : 0.7
        held.insert(note)
        sustained.remove(note)
        queue.append((note, v))
        if queue.count > Self.keep { queue.removeFirst(queue.count - Self.keep) }
        guard t.isFinite else { return }
        recent.append(t)
        while let first = recent.first, t - first > Self.chordWindow { recent.removeFirst() }
        if recent.count >= 3, t - lastChord > Self.chordWindow {
            lastChord = t
            let sounding = held.union(sustained)
            switch PlayingAnalyzer.classify(sounding) {
            case .major: hueTarget = 1; chordNotes = sounding
            case .minor: hueTarget = -1; chordNotes = sounding
            case .tense: hueTarget = 0; chordNotes = sounding; pulseTarget = 1; pulseBorn = true
            default: break
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

    /// Lets every note go (a panic, an unplugged keyboard, a change of visual): no new ripples, the glow settles.
    public mutating func allNotesOff() {
        held.removeAll()
        sustained.removeAll()
        queue.removeAll()
    }

    // MARK: - Step

    public mutating func step(dt: Double, roles: RoleValues) {
        let step = dt.isFinite ? Float(min(max(dt, 0), 0.25)) : 0
        let reaction = reactionScale.isFinite ? min(max(reactionScale, 0.2), 2) : 1
        let linger = lingerScale.isFinite ? min(max(lingerScale, 0.2), 3) : 1
        let sounding = held.union(sustained)

        // Ripples age, fade and go; then at most 6 new ones (a full list lets its weakest go first).
        let lifetime = Self.life * linger, fadeTau = lifetime / 3
        for i in ripples.indices {
            ripples[i].age += step
            ripples[i].strength = ripples[i].peak * exp(-ripples[i].age / fadeTau)
        }
        ripples.removeAll { $0.age > lifetime || $0.strength < 0.005 }
        lastSpawns = 0
        let batch = queue.prefix(Self.maxSpawnsPerStep)
        for (note, v) in batch {
            if ripples.count >= Self.keep, let weakest = ripples.indices.min(by: { ripples[$0].strength < ripples[$1].strength }) {
                ripples.remove(at: weakest)
            }
            let peak = min(1, (0.3 + 0.7 * v) * reaction)
            ripples.append(CurtainRipple(id: nextID, note: note, position: Self.position(for: note), age: 0,
                                         strength: peak, peak: peak, width: 0.04 + 0.08 * v))
            nextID = nextID &+ 1
            lastSpawns += 1
        }
        queue.removeFirst(batch.count)

        // The glow swells while anything sounds (the pedal counts) and settles in silence.
        let wanted: Float = sounding.isEmpty ? 0 : min(Self.glowCap, (0.45 + 0.2 * Float(sounding.count)) * min(1, reaction))
        let tau = Float(wanted > glow ? Self.glowRise : Self.glowFall * Double(linger))
        glow += (wanted - glow) * (1 - exp(-step / tau))
        glow = min(max(glow, 0), Self.glowCap)

        // The hue glides toward the chord's; when the chord lets go it glides back to neutral.
        if !chordNotes.isEmpty, chordNotes.isDisjoint(with: sounding) {
            chordNotes.removeAll()
            hueTarget = 0
        }
        hueShift += (hueTarget - hueShift) * (1 - exp(-step / Float(Self.hueTau)))
        hueShift = min(max(hueShift, -1), 1)

        // The tense pulse rises quickly toward its target, which dies away; the pulse follows it down.
        pulseTarget *= exp(-step / Self.pulseFall)
        if pulseTarget > tensePulse { tensePulse += (pulseTarget - tensePulse) * (1 - exp(-step / Self.pulseRise)) } else { tensePulse = pulseTarget }
        if step == 0, pulseBorn { tensePulse = max(tensePulse, pulseTarget) }
        pulseBorn = false
        if tensePulse < 1e-4 { tensePulse = 0; if pulseTarget < 1e-4 { pulseTarget = 0 } }

        let energy = roles[.energy]
        shimmerSpeed = 1 + Float(energy.isFinite ? min(max(energy, 0), 1) : 0)
    }

    /// The `limit` ripples worth sending to the shader: the strongest, in their original order.
    public static func visible(_ r: [CurtainRipple], limit: Int) -> [CurtainRipple] {
        guard r.count > limit else { return r }
        let chosen = Set(r.indices.sorted { r[$0].strength > r[$1].strength }.prefix(max(0, limit)))
        return r.indices.filter { chosen.contains($0) }.map { r[$0] }
    }
}
