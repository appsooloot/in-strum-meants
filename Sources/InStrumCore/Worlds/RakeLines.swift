import Foundation
import simd

/// One of the garden's five stones (spec §9.1): five stones in three groups, each group on a moss island.
public struct RakeStone: Equatable {
    /// Its centre on the gravel, in field cells: x 0…256 left to right, y 0 at the far wall … 144 at the veranda.
    public let centre: SIMD2<Float>
    /// Its footprint's radius, in cells.
    public let radius: Float
    /// How tall it stands (1 the tallest).
    public let height: Float
    /// Its moss island: 0 the pair on the left, 1 the tall stone in the middle, 2 the pair on the right.
    public let island: Int

    /// Its centre in bed units: x 0…1 across, y 0…1 from the far wall to the veranda.
    public var position: SIMD2<Float> { SIMD2(centre.x / Float(RakeField.width), centre.y / Float(RakeField.height)) }
}

/// The raked gravel (spec §9.2): a height field the renderer uploads as a texture whenever `version` moves on.
/// Cells are square: the bed is 256 cells across and 144 deep.
public struct RakeField: Equatable {
    public static let width = 256, height = 144

    /// Row-major relief: row 0 at the far wall … row 143 at the veranda, each row left to right. −1 … 1: 0 is level
    /// gravel, +1 the highest ridge a rake leaves, −1 its deepest groove (the morning's lines are ±0.55); 0 under
    /// the stones and the moss.
    public internal(set) var heights: [Float]
    /// Counts the changes (wrapping): upload the texture when this differs from the version you uploaded last; it
    /// stays put while nothing changes.
    public internal(set) var version: Int
    /// The field changed during the last step.
    public internal(set) var dirty: Bool

    init(heights: [Float]) {
        self.heights = heights
        version = 0
        dirty = false
    }

    /// One cell (clamped to the field).
    public func height(x: Int, y: Int) -> Float {
        heights[min(max(y, 0), Self.height - 1) * Self.width + min(max(x, 0), Self.width - 1)]
    }

    /// Bilinear between cell centres; x and y in bed units, 0…1 (clamped).
    public func value(x: Float, y: Float) -> Float {
        let w = Self.width, h = Self.height
        let cx = x.isFinite ? min(max(x, 0), 1) : 0, cy = y.isFinite ? min(max(y, 0), 1) : 0
        let u = min(max(cx * Float(w) - 0.5, 0), Float(w - 1))
        let v = min(max(cy * Float(h) - 0.5, 0), Float(h - 1))
        let x0 = Int(u), y0 = Int(v)
        let x1 = min(x0 + 1, w - 1), y1 = min(y0 + 1, h - 1)
        let tx = u - Float(x0), ty = v - Float(y0)
        let top = heights[y0 * w + x0] + (heights[y0 * w + x1] - heights[y0 * w + x0]) * tx
        let bottom = heights[y1 * w + x0] + (heights[y1 * w + x1] - heights[y1 * w + x0]) * tx
        return top + (bottom - top) * ty
    }
}

/// A ring a note raked round its stone.
public struct RakeRing: Equatable {
    public var id: Int
    public var note: UInt8
    /// The stone it goes round (0…4).
    public var stone: Int
    /// Its groove's radius from the stone's centre, in cells.
    public var radius: Float
    /// How deep the rake cuts it now, 0…1 (it deepens while the note is held).
    public var depth: Float
    /// Seconds since it was raked.
    public var age: Float
    /// The note still sounds (held, or under the pedal): the rake keeps going round, deepening the ring.
    public var held: Bool
    /// Where the rake is on the ring: radians in the field's plane (0 toward +x, π/2 toward the veranda).
    public var rakeAngle: Float
    /// The depth it was first raked to, how long it has been held, and how long since the rake last moved on it.
    var base: Float
    var heldFor: Float = 0
    var quiet: Float = 0
}

/// The sweeping curve a run rakes from one stone to the next: an arc of three grooves from moss to moss.
public struct RakeStroke: Equatable {
    public var id: Int
    /// The stones it runs between.
    public var from: Int, to: Int
    /// The arc, in cells: its circle's centre and radius, and where it starts, bows furthest and ends.
    public var centre: SIMD2<Float>
    public var radius: Float
    public var start: SIMD2<Float>, apex: SIMD2<Float>, end: SIMD2<Float>
    /// 0…1 by the run's velocity.
    public var strength: Float
    /// Seconds since it was raked.
    public var age: Float
}

/// A chord's slow re-raking wave: two fronts running out from where the chord was played, re-raking what was
/// drawn before it into fresh, crisp lines.
public struct RakeWave: Equatable {
    public var id: Int
    /// Where it began across the bed (bed units 0…1: the chord's mean key position).
    public var origin: Float
    /// How far each front has travelled from the origin (bed units; `RakeLines.waveSpeed` a second).
    public var offset: Float
    /// The fronts' soft width (bed units): the gravel is re-raked across it as a front passes.
    public var width: Float
    /// 0…1: how bright the fronts are (rising over 0.4 s, dimming to 0.4 of the chord's strength as they travel).
    /// The renderer passes it through `FlashLimiter`.
    public var brightness: Float
    /// 1 for a major chord, 0 for a minor one, 0.5 otherwise.
    public var warm: Float
    /// 0…1 from the chord's velocity (× the mood's reaction): how much fresher the re-raked lines are.
    public var strength: Float
    /// Seconds since the chord.
    public var age: Float
    /// Cells raked before this epoch are re-raked; the chord's own rings and anything since stand.
    var epoch: UInt32
    /// How far the re-raking has been carried (the offset already applied).
    var swept: Float

    /// The fronts' positions across the bed (bed units; off the bed once they have passed its edges).
    public var left: Float { origin - offset }
    public var right: Float { origin + offset }
}

/// Rake Lines (spec §9.2): the garden's gravel as a 256 × 144 height field. It starts from the morning's pattern:
/// straight lines across the bed, and rings that follow each moss island. Each note rakes a new ring round the stone
/// nearest its key (the five stones take five stretches of the keyboard), one gravel-width further out each time and
/// as deep as it was struck; a held note keeps the rake going round, deepening its ring; a run rakes a sweeping
/// curve from stone to stone; a chord sends a slow wave out across the whole bed from where it was played,
/// re-raking what was drawn before it. The grooves relax back to the morning's pattern (τ 90 s × the mood's linger,
/// twice as long while the playing lingers).
///
/// Deterministic. Each step touches only the cells it rakes; the slow relaxation runs five times a second over the
/// region that has been disturbed, and stops (the field exactly the morning's again) once nothing shows.
public struct RakeLines {
    public static let width = RakeField.width, height = RakeField.height
    /// One gravel-width: ridge to ridge of the rake's lines, in cells.
    public static let groove: Float = 4
    /// How deep the morning's lines are raked.
    public static let morningDepth: Float = 0.55
    /// Level gravel round each island's stones, under the moss (cells).
    public static let mossMargin: Float = 5
    static let morningRings = 3
    /// How far an island's stones blend into one rounded outline (cells).
    public static let islandBlend: Float = 16
    /// Beyond this distance from an island the morning's rings give way to the straight lines (cells); marks are
    /// raked only outside it.
    public static let ringZone: Float = mossMargin + Float(morningRings) * groove + groove / 2
    public static let islands = 3
    public static let stones: [RakeStone] = [
        RakeStone(centre: SIMD2<Float>(44, 74), radius: 7, height: 0.7, island: 0),
        RakeStone(centre: SIMD2<Float>(68, 86), radius: 4.5, height: 0.35, island: 0),
        RakeStone(centre: SIMD2<Float>(123, 56), radius: 9, height: 1, island: 1),
        RakeStone(centre: SIMD2<Float>(172, 84), radius: 6, height: 0.6, island: 2),
        RakeStone(centre: SIMD2<Float>(196, 73), radius: 4.5, height: 0.4, island: 2),
    ]

    /// Rings per stone before they start again at the first; a stone left alone this long starts again too.
    public static let maxRings = 8
    static let restartAfter = 40.0
    /// Notes raked per step (the rest wait; only the latest `queueCap` are kept waiting).
    public static let maxSpawnsPerStep = 12
    static let queueCap = 48
    /// Held rings the rake keeps going round, per step (the latest).
    static let maxHeldPerStep = 12
    /// Rings and strokes kept for the renderer (the field keeps their grooves regardless).
    public static let ringCap = 24, strokeCap = 8
    static let ringShowLife: Float = 6, strokeLife: Float = 6
    /// A note within this long of the previous one (but not struck with it) is a run.
    public static let runWindow = 0.25
    static let minRunGap = 0.04
    /// Chords: three or more notes within 60 ms.
    static let chordWindow = 0.06
    /// The wave's fronts travel this far a second (bed units), re-raking across a band this wide.
    public static let waveSpeed: Float = 0.1
    public static let waveBand: Float = 6 / 256
    /// While time is held (a step of dt 0) a chord's wave born since the last step runs on to this age at once: its
    /// fronts out where 0.4 s takes them, the gravel they passed re-raked, at full brightness (they brighten over
    /// 0.4 s). Else it would never show.
    public static let waveBloomAge: Float = 0.4
    static let freshDepth: Float = 0.25
    static let rerake: Float = 0.85
    /// The grooves' time constant back to the morning (seconds, before the linger).
    public static let fadeTau = 90.0
    static let relaxInterval = 0.2
    static let snapBelow: Float = 1e-3
    /// A held note's rake goes once round its ring in this many seconds, cutting it deeper each time.
    public static let lap: Float = 3
    static let deepenRate: Float = 0.15
    static let heldPass: Float = 0.35
    /// A run's curve bows out by this much of its length.
    static let strokeBow: Float = 0.45

    /// The mood's scales, set by the world each frame (how deep the rake cuts; how long the grooves linger).
    public var reactionScale: Float = 1
    public var lingerScale: Float = 1

    public internal(set) var field: RakeField
    /// The latest rings and run curves (the renderer may highlight fresh gravel and the moving rake with them).
    public private(set) var rings: [RakeRing] = []
    public private(set) var strokes: [RakeStroke] = []
    /// The chord's wave while it crosses the bed.
    public private(set) var wave: RakeWave?
    /// Notes raked in the last step (tests).
    private(set) var lastSpawns = 0

    var nextRingID = 0, nextStrokeID = 0, nextWaveID = 0

    private struct Pending { var note: UInt8; var velocity: Float; var t: Double; var epoch: UInt32 }
    private struct Box { var x0, y0, x1, y1: Int }
    /// The field and its tables while a step works on them.
    private struct Canvas {
        let h: UnsafeMutableBufferPointer<Float>
        let ep: UnsafeMutableBufferPointer<UInt32>
        let island: UnsafeBufferPointer<Float>
        let morning: UnsafeBufferPointer<Float>
    }

    /// Which note last raked each cell (a count of note-ons, wrapping): a chord's wave re-rakes only older cells.
    private var cellEpoch: [UInt32]
    private var epoch: UInt32 = 0
    private var held = Set<UInt8>()
    private var sustained = Set<UInt8>()
    private var pedal = false
    private var queue: [Pending] = []
    /// The ring each note raked last (only that one deepens while the note is held).
    private var currentRing: [UInt8: Int] = [:]
    private var ringIndex = [Int](repeating: 0, count: 5)
    private var lastRingTime = [Double](repeating: -.infinity, count: 5)
    private var last: (t: Double, stone: Int, note: UInt8)?
    private var chordNotes: [(t: Double, x: Float, v: Float, epoch: UInt32)] = []
    private var lastChord = -Double.infinity
    private var relaxClock = 0.0
    /// The region raked since the field was last the morning's.
    private var box: Box?
    private var changed = false

    public init() {
        field = RakeField(heights: Self.morning)
        cellEpoch = [UInt32](repeating: 0, count: Self.width * Self.height)
    }

    // MARK: - The garden's layout

    private static let centres: [Float] = (21...108).map { n in
        let k = KeyboardLayout.key(for: UInt8(n))!
        return k.x + k.width / 2
    }

    /// A note's place across the bed (bed units 0…1): its key's centre on the 88-key keyboard.
    public static func keyX(for note: UInt8) -> Float { centres[Int(min(108, max(21, note))) - 21] }

    private static let stoneTable: [Int] = (21...108).map { n -> Int in
        let x = RakeLines.keyX(for: UInt8(n))
        var best = 0
        for s in RakeLines.stones.indices {
            if abs(RakeLines.stones[s].position.x - x) < abs(RakeLines.stones[best].position.x - x) { best = s }
        }
        return best
    }

    /// The stone a note rakes round: the one nearest its key across the bed.
    public static func stone(for note: UInt8) -> Int { stoneTable[Int(min(108, max(21, note))) - 21] }

    /// A stone's first ring (cells): one gravel-width outside its own morning rings.
    public static func firstRingRadius(_ stone: Int) -> Float {
        stones[min(max(stone, 0), stones.count - 1)].radius + ringZone + groove / 2
    }

    /// How far a point (in cells) lies outside the nearest moss island: the distance to its stones' footprints, each
    /// island's stones blended into one rounded outline (negative under a stone).
    public static func islandDistance(cellX x: Float, cellY y: Float) -> Float {
        var best = Float.infinity
        for island in 0..<islands {
            var d: Float?
            for s in stones where s.island == island {
                let e = simd_length(SIMD2(x, y) - s.centre) - s.radius
                if let a = d { d = smoothMin(a, e, islandBlend) } else { d = e }
            }
            if let d { best = min(best, d) }
        }
        return best
    }

    static func smoothMin(_ a: Float, _ b: Float, _ k: Float) -> Float {
        let h = max(k - abs(a - b), 0) / k
        return min(a, b) - h * h * k / 4
    }

    static func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = min(1, max(0, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    /// Where marks may be raked: clear of every island's moss and morning rings (0 inside, easing to 1 outside).
    static func ringMask(_ island: Float) -> Float { smoothstep(ringZone - groove / 2, ringZone + groove / 2, island) }

    /// Where a run's curve may run: clear of the moss.
    static func mossMask(_ island: Float) -> Float { smoothstep(mossMargin, mossMargin + groove / 2, island) }

    /// A hand-raked line's slight meander (cells along y), by x.
    static func wobble(_ x: Float) -> Float {
        0.35 * sin(2 * .pi * x / 97) + 0.2 * sin(2 * .pi * x / 41 + 1.3)
    }

    /// The morning's relief at a cell centre: level under the moss, rings following the island out to `ringZone`,
    /// then straight lines across the bed (the two blended over a gravel-width).
    static func morningRelief(x: Float, y: Float, island d: Float) -> Float {
        guard d >= mossMargin else { return 0 }
        let g = groove
        let lines = -morningDepth * cos(2 * .pi * (y + wobble(x)) / g)
        let ring = -morningDepth * cos(2 * .pi * (d - mossMargin) / g) * smoothstep(mossMargin, mossMargin + g / 2, d)
        let w = 1 - smoothstep(ringZone - g / 2, ringZone + g / 2, d)
        return w * ring + (1 - w) * lines
    }

    /// `islandDistance` at every cell centre (row-major, as the field).
    static let islandTable: [Float] = {
        let w = RakeLines.width, h = RakeLines.height
        var t = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w { t[y * w + x] = RakeLines.islandDistance(cellX: Float(x) + 0.5, cellY: Float(y) + 0.5) }
        }
        return t
    }()

    /// The morning's pattern, as the field (row-major, row 0 at the far wall).
    public static let morning: [Float] = {
        let w = RakeLines.width, h = RakeLines.height
        let island = RakeLines.islandTable
        var m = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                m[y * w + x] = RakeLines.morningRelief(x: Float(x) + 0.5, y: Float(y) + 0.5, island: island[y * w + x])
            }
        }
        return m
    }()

    // MARK: - Events

    public mutating func noteOn(_ note: UInt8, velocity: Float, at t: Double) {
        let v = velocity.isFinite ? min(max(velocity, 0), 1) : 0.7
        let at = t.isFinite ? t : 0
        epoch &+= 1
        held.insert(note)
        sustained.remove(note)
        queue.append(Pending(note: note, velocity: v, t: at, epoch: epoch))
        if queue.count > Self.queueCap { queue.removeFirst(queue.count - Self.queueCap) }
        // A chord: three or more notes within 60 ms (once per chord) send a wave from their mean place.
        chordNotes.append((at, Self.keyX(for: note), v, epoch))
        while let first = chordNotes.first, at - first.t > Self.chordWindow || chordNotes.count > 16 { chordNotes.removeFirst() }
        guard chordNotes.count >= 3, at - lastChord > Self.chordWindow else { return }
        lastChord = at
        let n = Float(chordNotes.count)
        let origin = chordNotes.map(\.x).reduce(0, +) / n
        let meanV = chordNotes.map(\.v).reduce(0, +) / n
        let reaction = reactionScale.isFinite ? min(max(reactionScale, 0), 2) : 1
        let warm: Float
        switch PlayingAnalyzer.classify(held.union(sustained)) {
        case .major: warm = 1
        case .minor: warm = 0
        default: warm = 0.5
        }
        wave = RakeWave(id: nextWaveID, origin: origin, offset: 0, width: Self.waveBand, brightness: 0, warm: warm,
                        strength: min(1, (0.5 + 0.5 * meanV) * reaction), age: 0, epoch: chordNotes[0].epoch,
                        swept: -Self.waveBand / 2)
        nextWaveID = nextWaveID &+ 1
    }

    public mutating func noteOff(_ note: UInt8) {
        guard held.remove(note) != nil else { return }
        if pedal { sustained.insert(note) }
    }

    public mutating func setPedal(_ down: Bool) {
        pedal = down
        if !down { sustained.removeAll() }
    }

    /// Lets every note go (a panic, an unplugged keyboard, a change of visual): the rakes stop, waiting notes are
    /// dropped; what is raked stays and relaxes.
    public mutating func allNotesOff() {
        held.removeAll()
        sustained.removeAll()
        queue.removeAll()
    }

    // MARK: - Step

    public mutating func step(dt: Double, roles: RoleValues) {
        let step = dt.isFinite ? min(max(dt, 0), 0.25) : 0
        let fdt = Float(step)
        changed = false
        lastSpawns = 0
        let sounding = held.union(sustained)
        for i in rings.indices {
            rings[i].age += fdt
            rings[i].held = sounding.contains(rings[i].note) && currentRing[rings[i].note] == rings[i].id
            if rings[i].held { rings[i].quiet = 0 } else { rings[i].quiet += fdt }
        }
        rings.removeAll { !$0.held && $0.quiet > Self.ringShowLife }
        for i in strokes.indices { strokes[i].age += fdt }
        strokes.removeAll { $0.age > Self.strokeLife }

        // Work on the field in place: lift its storage out so the buffers below are its only owners.
        var heights = field.heights
        field.heights = []
        var epochs = cellEpoch
        cellEpoch = []
        heights.withUnsafeMutableBufferPointer { h in
            epochs.withUnsafeMutableBufferPointer { ep in
                Self.islandTable.withUnsafeBufferPointer { island in
                    Self.morning.withUnsafeBufferPointer { morning in
                        let canvas = Canvas(h: h, ep: ep, island: island, morning: morning)
                        rakeWaiting(canvas, sounding: sounding)
                        rakeHeld(canvas, dt: fdt)
                        sweepWave(canvas, dt: fdt)
                        relax(canvas, dt: step, roles: roles)
                    }
                }
            }
        }
        field.heights = heights
        cellEpoch = epochs
        field.dirty = changed
        if changed { field.version &+= 1 }
    }

    /// Up to 12 waiting notes: a ring each round its stone, and a curve from the last stone when it is a run.
    private mutating func rakeWaiting(_ c: Canvas, sounding: Set<UInt8>) {
        let batch = min(queue.count, Self.maxSpawnsPerStep)
        guard batch > 0 else { return }
        let reaction = reactionScale.isFinite ? min(max(reactionScale, 0), 2) : 1
        for p in queue.prefix(batch) {
            let s = Self.stone(for: p.note)
            if p.t - lastRingTime[s] > Self.restartAfter { ringIndex[s] = 0 }
            let k = ringIndex[s] % Self.maxRings
            ringIndex[s] = k + 1
            lastRingTime[s] = p.t
            let radius = Self.firstRingRadius(s) + Float(k) * Self.groove
            let depth = min(1, (0.45 + 0.35 * p.velocity) * reaction)
            rakeRing(c, centre: Self.stones[s].centre, radius: radius, depth: depth, weight: 0.55 + 0.45 * p.velocity,
                     epoch: p.epoch)
            // A note struck again: its earlier ring stops deepening (the new one has the rake now).
            if let old = currentRing[p.note], let j = rings.firstIndex(where: { $0.id == old }) { rings[j].held = false }
            if rings.count >= Self.ringCap { rings.remove(at: rings.firstIndex(where: { !$0.held }) ?? 0) }
            rings.append(RakeRing(id: nextRingID, note: p.note, stone: s, radius: radius, depth: depth, age: 0,
                                  held: sounding.contains(p.note), rakeAngle: .pi / 2, base: depth))
            currentRing[p.note] = nextRingID
            nextRingID = nextRingID &+ 1
            lastSpawns += 1
            if let prev = last, prev.stone != s, p.t - prev.t >= Self.minRunGap, p.t - prev.t <= Self.runWindow {
                rakeStroke(c, from: prev.stone, to: s, rising: p.note > prev.note, velocity: p.velocity,
                           reaction: reaction, epoch: p.epoch)
            }
            last = (p.t, s, p.note)
        }
        queue.removeFirst(batch)
    }

    /// Held rings: the rake keeps going round, cutting each one deeper as it passes (each cell once a lap).
    private mutating func rakeHeld(_ c: Canvas, dt: Float) {
        guard dt > 0 else { return }
        let sweep = 2 * Float.pi / Self.lap * dt
        var raked = 0
        for i in rings.indices.reversed() where rings[i].held {
            guard raked < Self.maxHeldPerStep else { break }
            raked += 1
            rings[i].heldFor += dt
            let depth = min(1, rings[i].base + Self.deepenRate * rings[i].heldFor)
            rings[i].depth = depth
            let from = rings[i].rakeAngle
            rakeArc(c, centre: Self.stones[rings[i].stone].centre, radius: rings[i].radius, from: from, sweep: sweep,
                    depth: depth, weight: Self.heldPass, epoch: epoch)
            var next = from + sweep
            if next >= 2 * .pi { next -= 2 * .pi }
            rings[i].rakeAngle = next
        }
    }

    /// The groove of a ring at `d` from its centre: −depth at the radius, a ridge either side.
    @inline(__always)
    private static func ringTarget(_ d: Float, _ r: Float, _ depth: Float) -> Float {
        -depth * cos(2 * .pi * (d - r) / groove)
    }

    /// Rakes a whole ring: the cells within a gravel-width of a groove at `radius` round `centre` blend toward the
    /// ring, as far as the islands allow.
    private mutating func rakeRing(_ c: Canvas, centre: SIMD2<Float>, radius r: Float, depth: Float, weight: Float, epoch: UInt32) {
        let g = Self.groove, w = Self.width, hgt = Self.height
        let outer = r + g, inner = max(0, r - g)
        let y0 = max(0, Int((centre.y - outer).rounded(.down))), y1 = min(hgt - 1, Int((centre.y + outer).rounded(.up)))
        guard y0 <= y1 else { return }
        var minX = w, maxX = -1, minY = hgt, maxY = -1
        for y in y0...y1 {
            let dy = Float(y) + 0.5 - centre.y
            guard abs(dy) < outer else { continue }
            let a = (outer * outer - dy * dy).squareRoot()
            let b = abs(dy) < inner ? (inner * inner - dy * dy).squareRoot() : 0
            // The row crosses the annulus in [cx − a, cx − b] and [cx + b, cx + a] (one span when it misses the hole).
            let spans = b > 0 ? 2 : 1
            for side in 0..<spans {
                let lo = side == 0 ? centre.x - a : centre.x + b
                let hi = spans == 1 ? centre.x + a : (side == 0 ? centre.x - b : centre.x + a)
                let x0 = max(0, Int((lo - 0.5).rounded(.up))), x1 = min(w - 1, Int((hi - 0.5).rounded(.down)))
                guard x0 <= x1 else { continue }
                for x in x0...x1 {
                    let dx = Float(x) + 0.5 - centre.x
                    let d = (dx * dx + dy * dy).squareRoot()
                    let e = abs(d - r)
                    guard e < g else { continue }
                    let i = y * w + x
                    let k = weight * (1 - Self.smoothstep(g / 2, g, e)) * Self.ringMask(c.island[i])
                    guard k > 0 else { continue }
                    c.h[i] += k * (Self.ringTarget(d, r, depth) - c.h[i])
                    c.ep[i] = epoch
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        if maxX >= 0 { touch(minX, minY, maxX, maxY) }
    }

    /// Rakes the part of a ring the rake crossed this step: the angles in (from, from + sweep].
    private mutating func rakeArc(_ c: Canvas, centre: SIMD2<Float>, radius r: Float, from: Float, sweep: Float,
                                  depth: Float, weight: Float, epoch: UInt32) {
        guard sweep > 0, sweep < .pi else { return }
        let g = Self.groove, w = Self.width, hgt = Self.height
        var lo = SIMD2<Float>(repeating: .infinity), hi = SIMD2<Float>(repeating: -.infinity)
        for j in 0...2 {
            let a = from + sweep * Float(j) / 2
            for edge in 0...1 {
                let p = centre + SIMD2(cos(a), sin(a)) * (edge == 0 ? r - g : r + g)
                lo = simd_min(lo, p); hi = simd_max(hi, p)
            }
        }
        let pad = 1 + (r + g) * (1 - cos(sweep / 2))
        let x0 = max(0, Int((lo.x - pad).rounded(.down))), x1 = min(w - 1, Int((hi.x + pad).rounded(.up)))
        let y0 = max(0, Int((lo.y - pad).rounded(.down))), y1 = min(hgt - 1, Int((hi.y + pad).rounded(.up)))
        guard x0 <= x1, y0 <= y1 else { return }
        let twoPi = 2 * Float.pi
        var minX = w, maxX = -1, minY = hgt, maxY = -1
        for y in y0...y1 {
            let dy = Float(y) + 0.5 - centre.y
            for x in x0...x1 {
                let dx = Float(x) + 0.5 - centre.x
                let d = (dx * dx + dy * dy).squareRoot()
                let e = abs(d - r)
                guard e < g else { continue }
                var rel = (atan2(dy, dx) - from).truncatingRemainder(dividingBy: twoPi)
                if rel < 0 { rel += twoPi }
                guard rel > 0, rel <= sweep else { continue }
                let i = y * w + x
                let k = weight * (1 - Self.smoothstep(g / 2, g, e)) * Self.ringMask(c.island[i])
                guard k > 0 else { continue }
                c.h[i] += k * (Self.ringTarget(d, r, depth) - c.h[i])
                c.ep[i] = epoch
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        if maxX >= 0 { touch(minX, minY, maxX, maxY) }
    }

    /// A run's sweeping curve: an arc of three grooves from the first stone's moss to the second's, bowed toward the
    /// far wall when the run rises and toward the veranda when it falls. It crosses the islands' rings, not the moss.
    private mutating func rakeStroke(_ c: Canvas, from a: Int, to b: Int, rising: Bool, velocity v: Float,
                                     reaction: Float, epoch: UInt32) {
        let g = Self.groove, w = Self.width, hgt = Self.height
        let ca = Self.stones[a].centre, cb = Self.stones[b].centre
        let between = cb - ca
        let distance = simd_length(between)
        guard distance > 1e-3 else { return }
        let u = between / distance
        let p0 = ca + u * (Self.stones[a].radius + Self.mossMargin + g / 2)
        let p1 = cb - u * (Self.stones[b].radius + Self.mossMargin + g / 2)
        let chord = p1 - p0
        let length = simd_length(chord)
        guard length >= 3 * g else { return }   // stones on one island: no gravel between them
        var n = SIMD2<Float>(-chord.y, chord.x) / length
        if abs(n.y) > 1e-6 {
            if (n.y < 0) != rising { n = -n }
        } else if (n.x > 0) != rising {
            n = -n
        }
        let sag = Self.strokeBow * length
        let radius = (length * length / 4 + sag * sag) / (2 * sag)
        let mid = (p0 + p1) / 2
        let centre = mid - n * (radius - sag)
        let apexPoint = mid + n * sag
        let apex = atan2(apexPoint.y - centre.y, apexPoint.x - centre.x)
        let half = asin(min(1, length / (2 * radius)))
        let arc = 2 * radius * half
        var lo = SIMD2<Float>(repeating: .infinity), hi = SIMD2<Float>(repeating: -.infinity)
        for j in 0...8 {
            let t = apex + half * (Float(j) / 4 - 1)
            let p = centre + SIMD2(cos(t), sin(t)) * radius
            lo = simd_min(lo, p); hi = simd_max(hi, p)
        }
        let pad = 2 * g + 1
        let x0 = max(0, Int((lo.x - pad).rounded(.down))), x1 = min(w - 1, Int((hi.x + pad).rounded(.up)))
        let y0 = max(0, Int((lo.y - pad).rounded(.down))), y1 = min(hgt - 1, Int((hi.y + pad).rounded(.up)))
        let depth = min(1, (0.45 + 0.35 * v) * reaction), weight = 0.5 + 0.4 * v
        if x0 <= x1, y0 <= y1 {
            let twoPi = 2 * Float.pi
            var minX = w, maxX = -1, minY = hgt, maxY = -1
            for y in y0...y1 {
                let dy = Float(y) + 0.5 - centre.y
                for x in x0...x1 {
                    let dx = Float(x) + 0.5 - centre.x
                    let e = (dx * dx + dy * dy).squareRoot() - radius
                    guard abs(e) <= 2 * g else { continue }
                    var off = (atan2(dy, dx) - apex).truncatingRemainder(dividingBy: twoPi)
                    if off > .pi { off -= twoPi } else if off <= -.pi { off += twoPi }
                    guard abs(off) <= half else { continue }
                    let along = radius * (off + half)
                    let i = y * w + x
                    let across = 1 - Self.smoothstep(1.25 * g, 2 * g, abs(e))
                    let ends = Self.smoothstep(0, 2 * g, along) * Self.smoothstep(0, 2 * g, arc - along)
                    let k = weight * across * ends * Self.mossMask(c.island[i])
                    guard k > 0 else { continue }
                    c.h[i] += k * (-depth * cos(twoPi * e / g) - c.h[i])
                    c.ep[i] = epoch
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                }
            }
            if maxX >= 0 { touch(minX, minY, maxX, maxY) }
        }
        if strokes.count >= Self.strokeCap { strokes.removeFirst(strokes.count - Self.strokeCap + 1) }
        strokes.append(RakeStroke(id: nextStrokeID, from: a, to: b, centre: centre, radius: radius, start: p0,
                                  apex: apexPoint, end: p1, strength: min(1, (0.5 + 0.5 * v) * reaction), age: 0))
        nextStrokeID = nextStrokeID &+ 1
    }

    /// How much of the re-raking a column `distance` from the origin has had once the fronts are `offset` out.
    static func reraked(_ offset: Float, _ distance: Float) -> Float {
        rerake * smoothstep(0, 1, (offset - distance) / waveBand + 0.5)
    }

    /// The chord's wave: both fronts move out; the columns they pass are re-raked into fresh lines (what was raked
    /// before the chord), eased across the band so no seam is left.
    private mutating func sweepWave(_ c: Canvas, dt: Float) {
        guard var wave else { return }
        // Held, a wave born since the last step runs on to its bloom (re-raking what its fronts pass on the way).
        let dt = dt == 0 && wave.age == 0 ? Self.waveBloomAge : dt
        wave.age += dt
        wave.offset += Self.waveSpeed * dt
        let band = Self.waveBand, w = Self.width, hgt = Self.height
        let reach = max(wave.origin, 1 - wave.origin) + band / 2
        wave.brightness = wave.strength * Self.smoothstep(0, 0.4, wave.age) * (1 - 0.6 * min(1, wave.offset / reach))
        let fresh = 1 + Self.freshDepth * wave.strength
        let nearest = max(0, wave.swept - band / 2), farthest = wave.offset + band / 2
        for side in 0..<2 {
            let sign: Float = side == 0 ? -1 : 1
            let a = wave.origin + sign * nearest, b = wave.origin + sign * farthest
            let x0 = max(0, Int((min(a, b) * Float(w) - 0.5).rounded(.down)))
            let x1 = min(w - 1, Int((max(a, b) * Float(w) - 0.5).rounded(.up)))
            guard x0 <= x1 else { continue }
            for x in x0...x1 {
                let u = (Float(x) + 0.5) / Float(w)
                // Each column belongs to one side (the origin's to the right).
                if (u >= wave.origin) != (side == 1) { continue }
                let distance = abs(u - wave.origin)
                let before = Self.reraked(wave.swept, distance), after = Self.reraked(wave.offset, distance)
                guard after > before + 1e-6 else { continue }
                let k = (after - before) / (1 - before)
                for y in 0..<hgt {
                    let i = y * w + x
                    guard Int32(bitPattern: c.ep[i] &- wave.epoch) < 0 else { continue }
                    c.h[i] += k * (fresh * c.morning[i] - c.h[i])
                }
                touch(x, 0, x, hgt - 1)
            }
        }
        wave.swept = wave.offset
        self.wave = wave.offset >= reach ? nil : wave
    }

    /// The grooves relax back to the morning's pattern, five times a second over the disturbed region; once nothing
    /// shows (every cell within 0.001) the field is the morning's again and stays still.
    private mutating func relax(_ c: Canvas, dt: Double, roles: RoleValues) {
        guard let b = box else { relaxClock = 0; return }
        relaxClock += dt
        guard relaxClock >= Self.relaxInterval else { return }
        let linger = lingerScale.isFinite ? Double(min(max(lingerScale, 0.2), 3)) : 1
        let tau = Self.fadeTau * linger * (roles[.linger] > 0.5 ? 2 : 1)
        let k = Float(exp(-relaxClock / tau))
        relaxClock = 0
        let w = Self.width
        var worst: Float = 0
        for y in b.y0...b.y1 {
            for x in b.x0...b.x1 {
                let i = y * w + x
                let dev = (c.h[i] - c.morning[i]) * k
                c.h[i] = c.morning[i] + dev
                worst = max(worst, abs(dev))
            }
        }
        if worst < Self.snapBelow {
            for y in b.y0...b.y1 {
                for x in b.x0...b.x1 { c.h[y * w + x] = c.morning[y * w + x] }
            }
            box = nil
        }
        changed = true
    }

    private mutating func touch(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) {
        let a = max(0, x0), b = max(0, y0), c = min(Self.width - 1, x1), d = min(Self.height - 1, y1)
        guard a <= c, b <= d else { return }
        if let old = box {
            box = Box(x0: min(old.x0, a), y0: min(old.y0, b), x1: max(old.x1, c), y1: max(old.y1, d))
        } else {
            box = Box(x0: a, y0: b, x1: c, y1: d)
        }
        changed = true
    }
}
