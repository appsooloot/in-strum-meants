import Foundation

/// Frost on a window, grown once when a world loads: for each cell of a 384 × 216 grid over the glass, the time
/// (0…1) its frost arrives. Frost shows wherever the arrival is below the frost level, so it advances and retreats
/// along real branches.
///
/// Growth is one bucket-queue Dijkstra with two kinds of step:
/// - **Needles:** from every seed, six crystal arms (60° apart, the set turned at random per seed) shoot straight out
///   and sprout side branches at ±60°, which branch again; side branches grow more slowly.
/// - **Fill:** from every frosted cell, a slow creep to its 8 neighbours fills in between the needles.
/// Seeds: the corners first (the coldest glass, with a small frosted nucleus), then points every 24 cells along
/// each pane's edges, then a few flaws in the glass. A little value noise slows some steps, splitting the fronts
/// into fern-like feathers. Arrivals are normalised so the 95th percentile is 1.
public struct FrostField: Sendable {
    public static let width = 384, height = 216

    /// Row-major, 0…1 (0 on the bars between panes).
    public let arrival: [Float]
    /// Cells where growth started (seed points and corner nuclei), for tests.
    let seedCells: [Int]

    public init(seed: UInt64, columns: Int, rows: Int, bar: Float) {
        self.init(seed: seed, columns: columns, rows: rows, bar: bar, single: false)
    }

    /// One seed at the centre of one pane, its arms unlimited (for tests).
    static func single(seed: UInt64) -> FrostField {
        FrostField(seed: seed, columns: 1, rows: 1, bar: 0, single: true)
    }

    private init(seed: UInt64, columns: Int, rows: Int, bar: Float, single: Bool) {
        var grower = Grower(seed: seed, panes: Self.paneRects(columns: columns, rows: rows, bar: bar))
        grower.plant(single: single)
        grower.run()
        arrival = grower.normalised()
        seedCells = grower.seedCells
    }

    /// Bilinear between cell centres; x and y are 0…1 across the glass (clamped). Bars return 0.
    public func value(x: Float, y: Float) -> Float {
        let w = Self.width, h = Self.height
        let cx = x.isFinite ? min(max(x, 0), 1) : 0, cy = y.isFinite ? min(max(y, 0), 1) : 0
        let u = min(max(cx * Float(w) - 0.5, 0), Float(w - 1))
        let v = min(max(cy * Float(h) - 0.5, 0), Float(h - 1))
        let x0 = Int(u), y0 = Int(v)
        let x1 = min(x0 + 1, w - 1), y1 = min(y0 + 1, h - 1)
        let tx = u - Float(x0), ty = v - Float(y0)
        let top = arrival[y0 * w + x0] + (arrival[y0 * w + x1] - arrival[y0 * w + x0]) * tx
        let bottom = arrival[y1 * w + x0] + (arrival[y1 * w + x1] - arrival[y1 * w + x0]) * tx
        return top + (bottom - top) * ty
    }

    /// One pane's cells, inclusive (rows count down from the top of the glass).
    public struct PaneRect: Equatable, Sendable { public var x0, y0, x1, y1: Int }

    /// Panes filling the glass, separated by bars `bar` wide (a fraction of the width; cells are square).
    public static func paneRects(columns: Int, rows: Int, bar: Float) -> [PaneRect] {
        let cols = min(max(columns, 1), 12), rws = min(max(rows, 1), 8)
        var barCells = 0
        if cols * rws > 1 {
            let wanted = bar.isFinite ? Int((max(bar, 0) * Float(width)).rounded()) : 1
            // Every pane keeps at least 8 cells each way.
            let room = min((width - 8 * cols) / max(cols - 1, 1), (height - 8 * rws) / max(rws - 1, 1))
            barCells = min(max(wanted, 1), max(room, 1))
        }
        let pw = Float(width - (cols - 1) * barCells) / Float(cols)
        let ph = Float(height - (rws - 1) * barCells) / Float(rws)
        var rects: [PaneRect] = []
        for r in 0..<rws {
            for c in 0..<cols {
                let x0 = Int((Float(c) * (pw + Float(barCells))).rounded())
                let y0 = Int((Float(r) * (ph + Float(barCells))).rounded())
                let x1 = Int((Float(c) * (pw + Float(barCells)) + pw).rounded()) - 1
                let y1 = Int((Float(r) * (ph + Float(barCells)) + ph).rounded()) - 1
                rects.append(PaneRect(x0: x0, y0: y0, x1: min(x1, width - 1), y1: min(y1, height - 1)))
            }
        }
        return rects
    }
}

// MARK: - Growth

private struct Grower {
    /// A needle's growing tip.
    struct Tip { var x, y, dx, dy, left, nextBranch: Float; var generation: Int; var rng: SeededRandom }

    static let fillCost: Float = 5        // the creep between needles, per cell
    static let sideSlowness: Float = 1.6  // each branch generation grows this much more slowly
    static let quantum: Float = 0.25      // bucket width (every step costs at least 1)

    let w = FrostField.width, h = FrostField.height
    let panes: [FrostField.PaneRect]
    var rng: SeededRandom
    var dist: [Float]
    var done: [Bool]
    var open: [Bool]
    var tipOf: [Int32]
    var noise: [Float]
    var tips: [Tip] = []
    var seedCells: [Int] = []
    /// Bucket queue as linked lists: head per bucket, then each entry's cell and next entry.
    var head: [Int32] = []
    var entryCell: [Int32] = []
    var entryNext: [Int32] = []
    /// The raw time that normalises to 1 when placing seeds (the field is renormalised afterwards).
    let scale: Float

    init(seed: UInt64, panes: [FrostField.PaneRect]) {
        self.panes = panes
        rng = SeededRandom(seed: seed &* 0x2545_F491_4F6C_DD1D &+ 0x51)
        let n = w * h
        dist = [Float](repeating: .infinity, count: n)
        done = [Bool](repeating: false, count: n)
        open = [Bool](repeating: false, count: n)
        tipOf = [Int32](repeating: -1, count: n)
        noise = [Float](repeating: 0, count: n)
        for p in panes {
            for y in p.y0...p.y1 { for x in p.x0...p.x1 { open[y * w + x] = true } }
        }
        // Two octaves of value noise, 12 and 6 cells across.
        let noiseSeed = seed ^ 0xF205
        for y in 0..<h {
            for x in 0..<w {
                noise[y * w + x] = 0.67 * Self.valueNoise(Float(x) / 12, Float(y) / 12, noiseSeed)
                    + 0.33 * Self.valueNoise(Float(x) / 6, Float(y) / 6, noiseSeed &+ 1)
            }
        }
        var smallest: Float = 0
        for p in panes { smallest += Float(min(p.x1 - p.x0, p.y1 - p.y0)) }
        scale = smallest / Float(max(panes.count, 1)) * 1.2
        entryCell.reserveCapacity(n * 6)
        entryNext.reserveCapacity(n * 6)
        head.reserveCapacity(4096)
    }

    // MARK: Seeds

    mutating func plant(single: Bool) {
        if single, let p = panes.first {
            seed(x: Float((p.x0 + p.x1 + 1) / 2), y: Float((p.y0 + p.y1 + 1) / 2), at: 0, reach: .infinity)
            return
        }
        for p in panes {
            let span = Float(min(p.x1 - p.x0, p.y1 - p.y0))
            // Corners: a small frosted quarter disc (the coldest glass), then a crystal from the corner itself.
            for (cx, cy) in [(p.x0, p.y0), (p.x1, p.y0), (p.x0, p.y1), (p.x1, p.y1)] {
                for dy in -4...4 {
                    for dx in -4...4 where dx * dx + dy * dy <= 16 {
                        let x = cx + dx, y = cy + dy
                        guard x >= p.x0, x <= p.x1, y >= p.y0, y <= p.y1 else { continue }
                        seedCells.append(y * w + x)
                        relax(y * w + x, 0, tip: -1)
                    }
                }
                seed(x: Float(cx), y: Float(cy), at: 0, reach: span * 0.58)
            }
            // Along the edges, every 24 cells.
            var x = p.x0 + 24
            while x < p.x1 - 12 {
                seed(x: Float(x), y: Float(p.y0), at: rng.range(0.05, 0.15) * scale, reach: span * rng.range(0.33, 0.52))
                seed(x: Float(x), y: Float(p.y1), at: rng.range(0.05, 0.15) * scale, reach: span * rng.range(0.33, 0.52))
                x += 24
            }
            var y = p.y0 + 24
            while y < p.y1 - 12 {
                seed(x: Float(p.x0), y: Float(y), at: rng.range(0.05, 0.15) * scale, reach: span * rng.range(0.33, 0.52))
                seed(x: Float(p.x1), y: Float(y), at: rng.range(0.05, 0.15) * scale, reach: span * rng.range(0.33, 0.52))
                y += 24
            }
            // Flaws in the glass, kept away from the centre.
            let flaws = 3 + Int(rng.unit() * 3.999)
            let mx = Float(p.x0 + p.x1) / 2, my = Float(p.y0 + p.y1) / 2
            let hx = Float(p.x1 - p.x0) / 2, hy = Float(p.y1 - p.y0) / 2
            for _ in 0..<flaws {
                let a = rng.range(0, 2 * .pi), r = rng.range(0.55, 0.95)
                seed(x: mx + cos(a) * r * hx, y: my + sin(a) * r * hy, at: rng.range(0.2, 0.4) * scale,
                     reach: span * rng.range(0.13, 0.26))
            }
        }
    }

    /// A crystal at a cell: six arms from its centre, turned by a random angle.
    private mutating func seed(x: Float, y: Float, at time: Float, reach: Float) {
        let theta = rng.range(0, .pi / 3)
        let cx = Int(x.rounded(.down)), cy = Int(y.rounded(.down))
        guard cx >= 0, cy >= 0, cx < w, cy < h, open[cy * w + cx] else { return }
        seedCells.append(cy * w + cx)
        relax(cy * w + cx, time, tip: -1)
        for k in 0..<6 {
            let a = theta + Float(k) * .pi / 3
            let tip = Tip(x: Float(cx) + 0.5, y: Float(cy) + 0.5, dx: cos(a), dy: sin(a),
                          left: reach * rng.range(0.6, 1), nextBranch: rng.range(4, 9), generation: 0,
                          rng: SeededRandom(seed: rng.next()))
            advance(tip, from: cy * w + cx, at: time)
        }
    }

    // MARK: Queue

    private mutating func push(_ cell: Int, _ d: Float) {
        let b = Int(d / Self.quantum)
        while head.count <= b { head.append(-1) }
        entryCell.append(Int32(cell))
        entryNext.append(head[b])
        head[b] = Int32(entryCell.count - 1)
    }

    private mutating func relax(_ cell: Int, _ d: Float, tip: Int) {
        guard open[cell], !done[cell], d < dist[cell] else { return }
        dist[cell] = d
        tipOf[cell] = Int32(tip)
        push(cell, d)
    }

    /// Moves a tip out of its current cell (one unit step at a time) and offers it the next cell.
    private mutating func advance(_ tip: Tip, from cell: Int, at time: Float) {
        var t = tip
        let cx = cell % w, cy = cell / w
        var steps: Float = 0, nx = cx, ny = cy
        repeat {
            t.x += t.dx; t.y += t.dy; steps += 1
            nx = Int(t.x.rounded(.down)); ny = Int(t.y.rounded(.down))
        } while nx == cx && ny == cy
        guard nx >= 0, ny >= 0, nx < w, ny < h else { return }
        let next = ny * w + nx
        var slowness: Float = 1
        for _ in 0..<t.generation { slowness *= Self.sideSlowness }
        let d = time + steps * slowness * (1 + 0.5 * noise[next])
        // A tip that runs into frost that's already there (or the frame) stops.
        guard open[next], !done[next], d < dist[next] else { return }
        t.left -= steps
        tips.append(t)
        relax(next, d, tip: tips.count - 1)
    }

    mutating func run() {
        let dx8 = [1, 1, 0, -1, -1, -1, 0, 1], dy8 = [0, 1, 1, 1, 0, -1, -1, -1]
        let len8: [Float] = [1, 1.414_213_6, 1, 1.414_213_6, 1, 1.414_213_6, 1, 1.414_213_6]
        var b = 0
        while b < head.count {
            var e = head[b]
            head[b] = -1
            while e >= 0 {
                let cell = Int(entryCell[Int(e)])
                e = entryNext[Int(e)]
                if done[cell] { continue }
                let d = dist[cell]
                if Int(d / Self.quantum) != b { continue }
                done[cell] = true
                let x = cell % w, y = cell / w
                for k in 0..<8 {
                    let nx = x + dx8[k], ny = y + dy8[k]
                    guard nx >= 0, ny >= 0, nx < w, ny < h else { continue }
                    let n = ny * w + nx
                    relax(n, d + len8[k] * Self.fillCost * (1 + 0.6 * noise[n]), tip: -1)
                }
                let ti = Int(tipOf[cell])
                guard ti >= 0 else { continue }
                var tip = tips[ti]
                guard tip.left > 0 else { continue }
                tip.nextBranch -= 1
                if tip.generation < 2 && tip.nextBranch <= 0 {
                    tip.nextBranch = tip.rng.range(4, 9) * (tip.generation == 0 ? 1 : 0.7)
                    for side: Float in [-1, 1] {
                        if tip.rng.unit() < 0.25 { continue }
                        let ca: Float = 0.5, sa = side * 0.866_025_4
                        let branch = Tip(x: tip.x, y: tip.y, dx: tip.dx * ca - tip.dy * sa, dy: tip.dx * sa + tip.dy * ca,
                                         left: tip.left * tip.rng.range(0.3, 0.6), nextBranch: tip.rng.range(3, 6),
                                         generation: tip.generation + 1, rng: SeededRandom(seed: tip.rng.next()))
                        advance(branch, from: cell, at: d)
                    }
                }
                advance(tip, from: cell, at: d)
            }
            b += 1
        }
    }

    // MARK: Result

    func normalised() -> [Float] {
        var reached: [Float] = []
        reached.reserveCapacity(w * h)
        for i in 0..<(w * h) where open[i] && dist[i].isFinite { reached.append(dist[i]) }
        reached.sort()
        let p95 = reached.isEmpty ? 1 : max(reached[min(Int(Float(reached.count) * 0.95), reached.count - 1)], 1e-6)
        var out = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) where open[i] {
            out[i] = dist[i].isFinite ? min(dist[i] / p95, 1) : 1
        }
        return out
    }

    // MARK: Noise

    private static func hash(_ x: Int, _ y: Int, _ seed: UInt64) -> Float {
        var h = UInt64(UInt32(truncatingIfNeeded: x)) &* 0x9E37_79B1
        h ^= UInt64(UInt32(truncatingIfNeeded: y)) &* 0x85EB_CA77
        h ^= seed &* 0xC2B2_AE3D_27D4_EB4F
        h ^= h >> 33
        h = h &* 0xFF51_AFD7_ED55_8CCD
        h ^= h >> 33
        return Float(h >> 40) / Float(1 << 24)
    }

    static func valueNoise(_ x: Float, _ y: Float, _ seed: UInt64) -> Float {
        let xf = x.rounded(.down), yf = y.rounded(.down)
        let xi = Int(xf), yi = Int(yf)
        let fx = x - xf, fy = y - yf
        let u = fx * fx * (3 - 2 * fx), v = fy * fy * (3 - 2 * fy)
        let a = hash(xi, yi, seed), b = hash(xi + 1, yi, seed)
        let c = hash(xi, yi + 1, seed), d = hash(xi + 1, yi + 1, seed)
        let top = a + (b - a) * u, bottom = c + (d - c) * u
        return top + (bottom - top) * v
    }
}
