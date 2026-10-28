import Foundation

/// One glowing line written into the wet sand.
public struct TideLine: Equatable {
    public var note: UInt8
    /// Across the shore (the key's centre, 0…1).
    public var x: Float
    /// Up the sand: 0 at the waterline … 1 at the top of the wet sand.
    public var y: Float
    /// Its length across the shore (0.04…0.16 by velocity).
    public var length: Float
    public var strength: Float
    public var hue: Float
    public var age: Float
    /// 0 → 1 while it's traced (about 0.3 s).
    public var drawn: Float
    /// Written with the pedal down: survives its first wash as a faint trace.
    public var deep: Bool
    /// 0 → 1 while a wash erases it.
    public var washed: Float
    public var held: Bool
    /// The wash is over it right now (a new wash only counts once the sand has drained).
    var wet = false
}

/// Tide Lines: every note writes a glowing line into the wet sand at its key's place along the shore; the
/// next wave's wash erases what it reaches. The pedal writes deeper lines that survive one wash; chords make
/// the next wave break in golden foam.
public struct TideLines {
    public static let cap = 48
    static let chordWindow = 0.06
    /// Chord colours: warm gold for major, rose for minor, a cool pale for tense.
    public static let majorHue: Float = 0.11, minorHue: Float = 0.95, tenseHue: Float = 0.6

    public private(set) var lines: [TideLine] = []
    /// Foam on the latest break (0…1), fading over about 1.5 s.
    public private(set) var foam: Float = 0
    /// A chord is waiting for the next wave.
    public private(set) var chordPending = false

    /// Settings (0…1) and the mood's scales, set by the world each frame.
    public var glow: Float = 0.6
    public var linger: Float = 0.5
    public var foamAmount: Float = 0.6
    public var reactionScale: Float = 1
    public var lingerScale: Float = 1

    private var held = Set<UInt8>()
    private var recent: [Double] = []
    private var lastChord = -1.0
    private var pendingStrength: Float = 0
    /// The golden foam the last break called for (foam swells toward it, then both fade).
    private var foamTarget: Float = 0
    /// Where the wash was at the last step (a line written under it waits for the next wash).
    private var lastFront: Float = 0
    private var hue: Float = TideLines.majorHue
    private var rng = SeededRandom(seed: 0x71DE)

    public init() {}

    private static let centres: [Float] = (21...108).map { n in
        let k = KeyboardLayout.key(for: UInt8(n))!
        return k.x + k.width / 2
    }

    public static func x(for note: UInt8) -> Float { centres[Int(min(108, max(21, note))) - 21] }

    public mutating func noteOn(_ note: UInt8, velocity: UInt8, pedal: Bool, at t: Double) {
        held.insert(note)
        guard (21...108).contains(note) else { return }
        let v = Float(min(127, velocity)) / 127
        var line = TideLine(note: note, x: Self.x(for: note), y: rng.range(0.25, 0.65), length: 0.04 + 0.12 * v,
                            strength: v * (0.5 + glow) * reactionScale, hue: hue, age: 0, drawn: 0, deep: pedal,
                            washed: 0, held: true)
        line.wet = lastFront >= line.y
        if lines.count >= Self.cap {
            // Make room: the faintest line goes.
            var worst = 0, worstScore = Float.infinity
            for (i, l) in lines.enumerated() where Self.score(l) < worstScore { worst = i; worstScore = Self.score(l) }
            lines.remove(at: worst)
        }
        lines.append(line)
        // A chord: three or more notes within 60 ms (once per chord).
        recent.append(t)
        while let first = recent.first, t - first > Self.chordWindow { recent.removeFirst() }
        if recent.count >= 3, t - lastChord > Self.chordWindow {
            lastChord = t
            chordPending = true
            pendingStrength = max(pendingStrength, v)
        }
    }

    public mutating func noteOff(_ note: UInt8) {
        held.remove(note)
        for i in lines.indices where lines[i].note == note { lines[i].held = false }
    }

    public mutating func allNotesOff() {
        held.removeAll()
        for i in lines.indices { lines[i].held = false }
    }

    static func score(_ l: TideLine) -> Float { l.strength * (1 - l.washed) }

    /// The `limit` lines worth drawing when the budget is smaller than the cap: the strongest stay, in order.
    public static func visible(_ lines: [TideLine], limit: Int) -> [TideLine] {
        guard lines.count > limit else { return lines }
        let keep = Set(lines.indices.sorted { score(lines[$0]) > score(lines[$1]) }.prefix(max(0, limit)))
        return lines.indices.filter { keep.contains($0) }.map { lines[$0] }
    }

    public mutating func step(dt: Double, washFront: Float, breaks: [Wave], roles: RoleValues) {
        let fdt = Float(max(0, dt))
        switch PlayingAnalyzer.classify(held) {
        case .major: hue = Self.majorHue
        case .minor: hue = Self.minorHue
        case .tense: hue = Self.tenseHue
        default: break
        }
        // A chord's own lines take its colour (they were written a moment before it could be heard as one).
        for i in lines.indices where Double(lines[i].age) < Self.chordWindow { lines[i].hue = hue }
        // A chord's foam rides the next wave, swelling in over a fifth of a second (never a flash).
        if !breaks.isEmpty, chordPending {
            let s = breaks.map(\.strength).max() ?? 0.5
            foamTarget = max(foamTarget, foamAmount * (0.5 + 0.5 * max(s, pendingStrength)))
            chordPending = false
            pendingStrength = 0
        }
        foamTarget *= exp(-fdt / 1.5)
        foam += (foamTarget - foam) * (1 - exp(-fdt / 0.08))
        let fade = 6 * (0.5 + linger) * lingerScale
        for i in lines.indices {
            var l = lines[i]
            l.age += fdt
            l.drawn = min(1, l.drawn + fdt / 0.3)
            if !l.held { l.strength *= exp(-fdt / max(0.5, fade)) }
            let covered = washFront >= l.y
            if covered && !l.wet {
                // A new wash reaches the line: a deep one becomes a faint trace, any other starts to go.
                if l.deep && l.washed == 0 { l.deep = false; l.strength *= 0.25 } else if l.washed == 0 { l.washed = 1e-4 }
            }
            l.wet = covered
            if l.washed > 0 { l.washed = min(1, l.washed + fdt / 0.5) }
            lines[i] = l
        }
        lastFront = washFront
        lines.removeAll { $0.washed >= 1 || $0.strength < 0.005 }
    }
}
