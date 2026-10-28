import Foundation

/// A warm clear patch a note melts in the frost (window coordinates 0…1, y up; the radius is of the window's height).
public struct FrostPatch: Equatable {
    public var id: Int
    public var note: UInt8
    public var x, y, radius, warmth: Float
    public var held: Bool
}

/// Frost Grow (spec §8.2): holding notes lets the frost creep further over the window while each note melts a warm
/// patch where its key sits; released notes let their patches freeze back over. Chords flare the fire; high notes
/// make the flakes nearest the glass catch the light.
public struct FrostGrow {
    public static let cap = 48
    public static let maxSpawnsPerStep = 12
    public static let levelCap: Float = 0.85
    public static let growTau = 6.0, fallTau = 20.0, glideTau = 2.0, releaseTau = 3.5
    /// Chords: three or more notes within 60 ms.
    static let chordWindow = 0.06
    static let flareRise = 0.15, flareFall = 1.5

    /// The Frost setting (0…1): how far holding notes can grow the frost (to 0.75 × this).
    public var frost: Float = 0.6
    /// The mood's scales (how strongly it reacts; how long released patches stay warm).
    public var reactionScale: Float = 1
    public var lingerScale: Float = 1

    /// The frost level the glass shows (0…`levelCap`).
    public private(set) var level: Float = 0
    public private(set) var patches: [FrostPatch] = []
    /// The fire's flare from chords (0…1).
    public private(set) var flare: Float = 0
    /// The flare's colour: 1 a brighter gold (major), 0 a deeper ember (minor), 0.5 otherwise.
    public private(set) var flareWarm: Float = 0.5
    /// The x of each high note (≥ 72) played since the last step: flakes near there catch the light.
    public private(set) var flakeGlints: [Float] = []

    var nextID = 0
    private var grow: Float = 0
    private var held = Set<UInt8>()
    /// Released while the pedal is down: still sounding, so still holding.
    private var sustained = Set<UInt8>()
    private var pedal = false
    /// Notes waiting for a patch (rationed per step; only the latest `cap` are kept).
    private var queue: [(note: UInt8, velocity: Float)] = []
    private var glintQueue: [Float] = []
    private var recent: [Double] = []
    private var lastChord = -Double.infinity
    private var flareTarget: Float = 0

    public init() {}

    private static let centres: [Float] = (21...108).map { n in
        let k = KeyboardLayout.key(for: UInt8(n))!
        return k.x + k.width / 2
    }

    /// A note's place across the window: its key's centre, mapped to 0.08…0.92.
    public static func x(for note: UInt8) -> Float { 0.08 + 0.84 * centres[Int(min(108, max(21, note))) - 21] }

    // MARK: - Events

    public mutating func noteOn(_ note: UInt8, velocity: Float, at t: Double) {
        let v = velocity.isFinite ? min(max(velocity, 0), 1) : 1
        held.insert(note)
        sustained.remove(note)
        queue.append((note, v))
        if queue.count > Self.cap { queue.removeFirst(queue.count - Self.cap) }
        if note >= 72, glintQueue.count < Self.maxSpawnsPerStep { glintQueue.append(Self.x(for: note)) }
        // A chord: three or more notes within 60 ms (once per chord), coloured by what's held.
        guard t.isFinite else { return }
        recent.append(t)
        while let first = recent.first, t - first > Self.chordWindow { recent.removeFirst() }
        if recent.count >= 3, t - lastChord > Self.chordWindow {
            lastChord = t
            flareTarget = max(flareTarget, min(1, reactionScale.isFinite ? reactionScale : 1))
            switch PlayingAnalyzer.classify(held.union(sustained)) {
            case .major: flareWarm = 1
            case .minor: flareWarm = 0
            default: flareWarm = 0.5
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

    public mutating func step(dt: Double, baseFrost: Float, roles: RoleValues) {
        let step = dt.isFinite ? min(max(dt, 0), 0.25) : 0
        let base = baseFrost.isFinite ? min(max(baseFrost, 0), Self.levelCap) : 0
        let setting = frost.isFinite ? min(max(frost, 0), 1) : 0
        let reaction = reactionScale.isFinite ? min(max(reactionScale, 0), 2) : 1
        let linger = lingerScale.isFinite ? min(max(lingerScale, 0.2), 3) : 1

        // New patches, at most 12 per step; a full window lets its coldest patch go first.
        for (note, v) in queue.prefix(Self.maxSpawnsPerStep) {
            if patches.count >= Self.cap, let coldest = patches.indices.min(by: { Self.score(patches[$0]) < Self.score(patches[$1]) }) {
                patches.remove(at: coldest)
            }
            patches.append(FrostPatch(id: nextID, note: note, x: Self.x(for: note), y: 0.3 + 0.45 * v, radius: 0.025 + 0.05 * v,
                                      warmth: 1, held: true))
            nextID = nextID &+ 1
        }
        queue.removeFirst(min(queue.count, Self.maxSpawnsPerStep))
        flakeGlints = glintQueue
        glintQueue.removeAll(keepingCapacity: true)

        // Held (or pedalled) patches stay warm; released ones cool and freeze over.
        let sounding = held.union(sustained)
        let cool = Float(exp(-step / (Self.releaseTau * Double(linger))))
        for i in patches.indices {
            patches[i].held = sounding.contains(patches[i].note)
            if patches[i].held { patches[i].warmth = 1 } else { patches[i].warmth *= cool }
        }
        patches.removeAll { $0.warmth < 0.02 }

        // The frost grows toward 0.75 × Frost while anything sounds and falls back in silence; the level glides.
        let target: Float = sounding.isEmpty ? 0 : 0.75 * setting * min(1, reaction)
        let tau = target > grow ? Self.growTau : Self.fallTau
        grow += (target - grow) * Float(1 - exp(-step / tau))
        let wanted = min(Self.levelCap, base + grow)
        level += (wanted - level) * Float(1 - exp(-step / Self.glideTau))
        level = min(max(level, 0), Self.levelCap)

        // The flare rises quickly toward its target, which dies away; the flare follows it down.
        flareTarget *= Float(exp(-step / Self.flareFall))
        if flareTarget > flare { flare += (flareTarget - flare) * Float(1 - exp(-step / Self.flareRise)) } else { flare = flareTarget }
        if flare < 1e-4 { flare = 0 }
    }

    static func score(_ p: FrostPatch) -> Float { p.held ? 2 : p.warmth }

    /// The `limit` patches worth drawing when the budget is smaller than the cap: the warmest, in their original order.
    public static func visible(_ p: [FrostPatch], limit: Int) -> [FrostPatch] {
        guard p.count > limit else { return p }
        let keep = Set(p.indices.sorted { score(p[$0]) > score(p[$1]) }.prefix(max(0, limit)))
        return p.indices.filter { keep.contains($0) }.map { p[$0] }
    }
}
