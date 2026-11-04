import XCTest
import simd
@testable import InStrumCore

final class RakeLinesTests: XCTestCase {
    private func run(_ r: inout RakeLines, seconds: Double, dt: Double = 1.0 / 30, roles: RoleValues = RoleValues()) {
        for _ in 0..<max(1, Int((seconds / dt).rounded())) { r.step(dt: dt, roles: roles) }
    }

    /// How far the gravel is from the morning's pattern: the RMS of the difference over the whole bed, as a fraction
    /// of the morning pattern's own RMS.
    private func departure(_ r: RakeLines) -> Double {
        var d2 = 0.0, m2 = 0.0
        for (h, m) in zip(r.field.heights, RakeLines.morning) {
            d2 += Double(h - m) * Double(h - m)
            m2 += Double(m) * Double(m)
        }
        return (d2 / m2).squareRoot()
    }

    /// The mean |field − morning| round a stone at `radius`, over the points clear of the islands' rings.
    private func ringDeparture(_ r: RakeLines, stone: Int, radius: Float) -> Float {
        let c = RakeLines.stones[stone].centre
        var sum: Float = 0
        var count = 0
        for a in 0..<90 {
            let t = 2 * Float.pi * Float(a) / 90
            let x = Int(c.x + radius * cos(t)), y = Int(c.y + radius * sin(t))
            guard x >= 0, y >= 0, x < RakeField.width, y < RakeField.height else { continue }
            let i = y * RakeField.width + x
            guard RakeLines.ringMask(RakeLines.islandTable[i]) > 0.99 else { continue }
            sum += abs(r.field.heights[i] - RakeLines.morning[i])
            count += 1
        }
        return count > 0 ? sum / Float(count) : 0
    }

    func testRingsLandRoundTheNearestStone() throws {
        // Five stretches of the keyboard, left to right: each key rakes round the stone nearest it across the bed.
        var previous = 0
        for n in UInt8(21)...UInt8(108) {
            let s = RakeLines.stone(for: n), x = RakeLines.keyX(for: n)
            let nearest = try XCTUnwrap(RakeLines.stones.indices.min(by: {
                abs(RakeLines.stones[$0].position.x - x) < abs(RakeLines.stones[$1].position.x - x)
            }))
            XCTAssertEqual(s, nearest, "note \(n)")
            XCTAssertGreaterThanOrEqual(s, previous, "note \(n): the stretches run left to right")
            previous = s
        }
        XCTAssertEqual(([21, 40, 53, 72, 84] as [UInt8]).map { RakeLines.stone(for: $0) }, [0, 1, 2, 3, 4], "where each stretch begins")
        XCTAssertEqual(([39, 52, 71, 83, 108] as [UInt8]).map { RakeLines.stone(for: $0) }, [0, 1, 2, 3, 4], "and ends")
        XCTAssertEqual(RakeLines.stone(for: 60), 2, "middle C rakes round the tall stone in the middle")

        // Each note's ring lands round its stone at the first radius, and nothing else in the bed moves: within a
        // gravel-width of its groove the gravel blends toward the ring (by the velocity, feathered at the edges and
        // kept off the islands); everywhere else it is the morning's.
        let cases: [(note: UInt8, stone: Int)] = [(30, 0), (45, 1), (60, 2), (77, 3), (96, 4)]
        for (note, stone) in cases {
            var r = RakeLines()
            r.noteOn(note, velocity: 0.8, at: 0)
            r.noteOff(note)   // a short note: its ring, and no rake left going round it
            r.step(dt: 1.0 / 30, roles: RoleValues())
            let ring = try XCTUnwrap(r.rings.last)
            XCTAssertEqual(ring.stone, stone, "note \(note)")
            XCTAssertEqual(ring.radius, RakeLines.firstRingRadius(stone), accuracy: 1e-5)
            XCTAssertFalse(ring.held)
            let centre = RakeLines.stones[stone].centre
            let depth: Float = 0.45 + 0.35 * 0.8, weight: Float = 0.55 + 0.45 * 0.8
            var worst: Float = 0
            var moved = 0
            for y in 0..<RakeField.height {
                for x in 0..<RakeField.width {
                    let i = y * RakeField.width + x
                    let d = simd_length(SIMD2<Float>(Float(x) + 0.5, Float(y) + 0.5) - centre)
                    let e = abs(d - ring.radius)
                    let m = RakeLines.morning[i]
                    var expected = m
                    if e < RakeLines.groove {
                        let k = weight * (1 - RakeLines.smoothstep(2, 4, e)) * RakeLines.ringMask(RakeLines.islandTable[i])
                        expected = m + k * (-depth * cos(2 * .pi * (d - ring.radius) / RakeLines.groove) - m)
                    }
                    worst = max(worst, abs(r.field.heights[i] - expected))
                    if abs(r.field.heights[i] - m) > 0.05 { moved += 1 }
                }
            }
            XCTAssertLessThan(worst, 1e-4, "note \(note): only its ring is raked")
            XCTAssertGreaterThan(moved, 400, "note \(note): and it shows")
            XCTAssertEqual(r.field.version, 1)
            XCTAssertTrue(r.field.dirty)
        }

        // Played again and again, each ring goes one gravel-width further out, starting again after the eighth.
        var r = RakeLines()
        for i in 0..<10 {
            r.noteOn(60, velocity: 0.7, at: Double(i))
            r.noteOff(60)
            r.step(dt: 0.25, roles: RoleValues())
        }
        let first = RakeLines.firstRingRadius(2), g = RakeLines.groove
        XCTAssertEqual(r.rings.map(\.radius), (0..<10).map { first + Float($0 % RakeLines.maxRings) * g })
        // A stone left alone for a while starts again close in.
        r.noteOn(62, velocity: 0.7, at: 60)
        r.noteOff(62)
        r.step(dt: 0.25, roles: RoleValues())
        XCTAssertEqual(r.rings.last?.radius, first)
    }

    /// Two short notes `gap` seconds apart, stepped the same way whatever the gap.
    private func twoNotes(_ a: UInt8, _ b: UInt8, gap: Double) -> RakeLines {
        var r = RakeLines()
        r.noteOn(a, velocity: 0.8, at: 0)
        r.noteOff(a)
        r.step(dt: 0.1, roles: RoleValues())
        r.noteOn(b, velocity: 0.8, at: gap)
        r.noteOff(b)
        r.step(dt: 1.0 / 30, roles: RoleValues())
        return r
    }

    func testRunsRakeACurve() throws {
        // A rising run from the left pair's low stone to the tall stone: one sweeping curve, bowed toward the far wall.
        let quick = twoNotes(45, 60, gap: 0.15), slow = twoNotes(45, 60, gap: 0.6)
        XCTAssertTrue(slow.strokes.isEmpty, "0.6 s apart is not a run")
        XCTAssertEqual(quick.strokes.count, 1)
        let s = try XCTUnwrap(quick.strokes.first)
        XCTAssertEqual([s.from, s.to], [1, 2])
        let edge = RakeLines.mossMargin + RakeLines.groove / 2
        XCTAssertEqual(simd_length(s.start - RakeLines.stones[1].centre), RakeLines.stones[1].radius + edge, accuracy: 1e-3, "from moss")
        XCTAssertEqual(simd_length(s.end - RakeLines.stones[2].centre), RakeLines.stones[2].radius + edge, accuracy: 1e-3, "to moss")
        XCTAssertEqual(simd_length(s.apex - s.centre), s.radius, accuracy: 1e-3)
        XCTAssertLessThan(s.apex.y, (s.start.y + s.end.y) / 2 - 10, "a rising run bows toward the far wall")

        // The two gardens differ by the curve alone: its groove is raked along the arc, and nothing away from it moved.
        let apexAngle = atan2(s.apex.y - s.centre.y, s.apex.x - s.centre.x)
        let half = asin(min(1, simd_length(s.end - s.start) / (2 * s.radius)))
        var along: Float = 0
        for j in 0...20 {
            let a = apexAngle + half * (-0.8 + 1.6 * Float(j) / 20)
            let p = s.centre + SIMD2<Float>(cos(a), sin(a)) * s.radius
            let i = Int(p.y) * RakeField.width + Int(p.x)
            along += abs(quick.field.heights[i] - slow.field.heights[i])
        }
        XCTAssertGreaterThan(along / 21, 0.3, "the curve's groove runs along the arc")
        var strayed: Float = 0
        var changed = 0
        for y in 0..<RakeField.height {
            for x in 0..<RakeField.width {
                let i = y * RakeField.width + x
                let diff = abs(quick.field.heights[i] - slow.field.heights[i])
                if diff > 1e-6 { changed += 1 }
                let d = simd_length(SIMD2<Float>(Float(x) + 0.5, Float(y) + 0.5) - s.centre)
                if abs(d - s.radius) > 2 * RakeLines.groove + 1 { strayed = max(strayed, diff) }
            }
        }
        XCTAssertEqual(strayed, 0, "nothing raked away from the curve")
        XCTAssertGreaterThan(changed, 400)

        // Falling, it bows toward the veranda.
        let fall = try XCTUnwrap(twoNotes(60, 45, gap: 0.15).strokes.first)
        XCTAssertEqual([fall.from, fall.to], [2, 1])
        XCTAssertGreaterThan(fall.apex.y, (fall.start.y + fall.end.y) / 2 + 10, "a falling run bows toward the veranda")
        // Struck together it is a chord or a smudge, not a run; on one stone, or one island, there is no gravel between.
        XCTAssertTrue(twoNotes(45, 60, gap: 0.02).strokes.isEmpty)
        XCTAssertTrue(twoNotes(60, 62, gap: 0.15).strokes.isEmpty)
        XCTAssertTrue(twoNotes(30, 45, gap: 0.15).strokes.isEmpty, "the left pair share an island")
        // A leap across the garden still sweeps from stone to stone.
        let leap = try XCTUnwrap(twoNotes(45, 77, gap: 0.15).strokes.first)
        XCTAssertEqual([leap.from, leap.to], [1, 3])
    }

    /// An earlier ring round the tall stone, then C5, E5 and G5 (round the right pair's tall stone) at `times`.
    private func ringThenThree(_ times: [Double], _ notes: [UInt8] = [72, 76, 79]) -> RakeLines {
        var r = RakeLines()
        r.noteOn(60, velocity: 0.9, at: 0)
        r.noteOff(60)
        r.step(dt: 0.1, roles: RoleValues())
        run(&r, seconds: 1)
        for (n, t) in zip(notes, times) { r.noteOn(n, velocity: 0.8, at: t) }
        for n in notes { r.noteOff(n) }
        r.step(dt: 1.0 / 30, roles: RoleValues())
        return r
    }

    func testChordsSendAWave() throws {
        var chord = ringThenThree([1.2, 1.22, 1.24])
        var spread = ringThenThree([1.2, 1.3, 1.4])   // the same rings, too far apart to be a chord
        XCTAssertNil(spread.wave)
        let w = try XCTUnwrap(chord.wave)
        let mean = ([72, 76, 79] as [UInt8]).map { RakeLines.keyX(for: $0) }.reduce(0, +) / 3
        XCTAssertEqual(w.origin, mean, accuracy: 1e-5, "from the chord's mean key")
        XCTAssertEqual(w.warm, 1, "a major chord")
        XCTAssertEqual(w.strength, 0.9, accuracy: 1e-5)
        XCTAssertEqual(w.offset, RakeLines.waveSpeed / 30, accuracy: 1e-6)
        XCTAssertTrue(w.brightness > 0 && w.brightness <= 1)

        run(&chord, seconds: 3.5)
        run(&spread, seconds: 3.5)
        let fronts = try XCTUnwrap(chord.wave)
        XCTAssertEqual(fronts.offset, RakeLines.waveSpeed * Float(3.5 + 1.0 / 30), accuracy: 1e-3, "slow: a tenth of the bed a second")
        XCTAssertEqual(fronts.left, fronts.origin - fronts.offset)
        XCTAssertEqual(fronts.right, fronts.origin + fronts.offset)
        XCTAssertTrue((0...1).contains(fronts.brightness))
        // The earlier ring, passed by the left front, is re-raked into fresh lines; the chord's own rings stand.
        let old = ringDeparture(chord, stone: 2, radius: RakeLines.firstRingRadius(2))
        let unswept = ringDeparture(spread, stone: 2, radius: RakeLines.firstRingRadius(2))
        XCTAssertGreaterThan(unswept, 0.4)
        XCTAssertLessThan(old, 0.4 * unswept, "re-raked")
        for k in 0..<3 {
            let radius = RakeLines.firstRingRadius(3) + Float(k) * RakeLines.groove
            XCTAssertEqual(ringDeparture(chord, stone: 3, radius: radius), ringDeparture(spread, stone: 3, radius: radius),
                           accuracy: 1e-5, "the chord's ring \(k) stands")
        }
        // Behind the front the morning's lines are raked fresh and crisp (deeper), to settle back later.
        func rms(_ f: [Float]) -> Float {
            var s: Float = 0
            for y in 4...12 { for x in 115...141 { s += f[y * RakeField.width + x] * f[y * RakeField.width + x] } }
            return s.squareRoot()
        }
        let crisp = rms(chord.field.heights) / rms(RakeLines.morning)
        XCTAssertTrue((1.1...1.3).contains(crisp), "\(crisp)")
        XCTAssertEqual(rms(spread.field.heights) / rms(RakeLines.morning), 1, accuracy: 1e-5)
        // Once both fronts have crossed the bed the wave is done.
        run(&chord, seconds: 4)
        XCTAssertNil(chord.wave)

        // A minor chord's wave is cool; two notes are not a chord.
        var minor = RakeLines()
        for (i, n) in ([69, 72, 76] as [UInt8]).enumerated() { minor.noteOn(n, velocity: 0.8, at: 0.02 * Double(i)) }
        minor.step(dt: 1.0 / 30, roles: RoleValues())
        XCTAssertEqual(minor.wave?.warm, 0)
        var two = RakeLines()
        two.noteOn(60, velocity: 0.8, at: 0)
        two.noteOn(64, velocity: 0.8, at: 0.02)
        two.step(dt: 1.0 / 30, roles: RoleValues())
        XCTAssertNil(two.wave)
    }

    func testGroovesFadeBack() {
        var r = RakeLines()
        var clock = 0.0
        func play(_ seconds: Double, dt: Double = 1.0 / 30) {
            let n = max(1, Int((seconds / dt).rounded()))
            for _ in 0..<n { r.step(dt: dt, roles: RoleValues()) }
            clock += Double(n) * dt
        }
        // A phrase: a note round every stone (two round the tall one), one held for three seconds, a rising run.
        for n: UInt8 in [30, 45, 60, 62, 77, 96] {
            r.noteOn(n, velocity: 0.8, at: clock)
            play(0.05)
            r.noteOff(n)
            play(0.5)
        }
        r.noteOn(64, velocity: 0.9, at: clock)
        play(3)
        r.noteOff(64)
        play(0.2)
        for n: UInt8 in [45, 60, 77, 96] {
            r.noteOn(n, velocity: 0.85, at: clock)
            play(0.15)
            r.noteOff(n)
        }
        play(0.2)
        XCTAssertEqual(r.strokes.count, 2, "the run swept from stone to stone (not between the right pair)")
        let raked = departure(r)
        XCTAssertGreaterThan(raked, 0.3, "the phrase shows")

        // τ 90 s: e^−1 of it left after 90 s of silence…
        play(90)
        XCTAssertEqual(departure(r) / raked, exp(-1), accuracy: 0.01)
        // …and after 270 s the gravel is within 5% of the morning's pattern (e^−3 of what the phrase raked).
        play(180)
        XCTAssertLessThan(departure(r), 0.05)
        XCTAssertEqual(departure(r) / raked, exp(-3), accuracy: 0.002)
        // Before long it is the morning's pattern exactly, and the field stops changing (nothing more to upload).
        play(600, dt: 0.25)
        XCTAssertEqual(r.field.heights, RakeLines.morning)
        let version = r.field.version
        play(5, dt: 0.25)
        XCTAssertEqual(r.field.version, version)
        XCTAssertFalse(r.field.dirty)

        // Lingering playing doubles τ; the mood's linger scales it.
        let lingers: [(role: Double, scale: Float)] = [(1, 1), (0, 0.7)]
        for (role, scale) in lingers {
            var q = RakeLines()
            q.lingerScale = scale
            var roles = RoleValues()
            roles[.linger] = role
            q.noteOn(60, velocity: 0.8, at: 0)
            q.noteOff(60)
            q.step(dt: 1.0 / 30, roles: roles)
            let start = departure(q)
            run(&q, seconds: 90, roles: roles)
            let tau = 90 * Double(scale) * (role > 0.5 ? 2 : 1)
            XCTAssertEqual(departure(q) / start, exp(-90 / tau), accuracy: 0.01, "linger \(role), scale \(scale)")
        }
    }

    /// Review focus: hours of playing leave the field bounded, and silence brings it back to the morning exactly.
    func testFieldStaysBounded() {
        // An hour of busy playing, seeded: about two notes a second held up to 4 s, chords, 64-note bursts, the pedal.
        var rng = SeededRandom(seed: 0x6A_2DE9)
        var r = RakeLines()
        var clock = 0.0
        var held: [(note: UInt8, until: Double)] = []
        let dt = 0.25
        var maxRings = 0, maxStrokes = 0
        var bounded = true
        for step in 0..<Int(3600 / dt) {
            let roll = rng.unit()
            if roll < 0.45 {
                let note = UInt8(21 + Int(rng.unit() * 87.99))
                r.noteOn(note, velocity: rng.range(0.2, 1), at: clock)
                held.append((note, clock + Double(rng.range(0.05, 4))))
            } else if roll < 0.47 {
                let root = UInt8(36 + Int(rng.unit() * 48))
                for (i, k) in ([0, 4, 7] as [UInt8]).enumerated() {
                    r.noteOn(root + k, velocity: 0.8, at: clock + 0.01 * Double(i))
                    held.append((root + k, clock + 1.5))
                }
            } else if roll < 0.471 {
                for i in 0..<64 {
                    r.noteOn(UInt8(21 + i), velocity: 1, at: clock + 0.001 * Double(i))
                    held.append((UInt8(21 + i), clock + 0.5))
                }
            } else if roll < 0.48 {
                r.setPedal(rng.unit() < 0.5)
            }
            for h in held where h.until <= clock { r.noteOff(h.note) }
            held.removeAll { $0.until <= clock }
            r.step(dt: dt, roles: RoleValues())
            clock += dt
            maxRings = max(maxRings, r.rings.count)
            maxStrokes = max(maxStrokes, r.strokes.count)
            if step % 60 == 0, !r.field.heights.allSatisfy({ $0.isFinite && abs($0) <= 1 + 1e-5 }) {
                bounded = false
                break
            }
        }
        XCTAssertTrue(bounded, "every groove finite and within ±1")
        XCTAssertLessThanOrEqual(maxRings, RakeLines.ringCap)
        XCTAssertLessThanOrEqual(maxStrokes, RakeLines.strokeCap)

        // Silence, everything let go: well within 14 minutes the gravel is the morning's again, and it stays still.
        r.setPedal(false)
        for h in held { r.noteOff(h.note) }
        for _ in 0..<Int(14 * 60 / dt) { r.step(dt: dt, roles: RoleValues()) }
        XCTAssertEqual(r.field.heights, RakeLines.morning)
        XCTAssertNil(r.wave)
        XCTAssertTrue(r.rings.isEmpty && r.strokes.isEmpty)
        let version = r.field.version
        for _ in 0..<8 { r.step(dt: dt, roles: RoleValues()) }
        XCTAssertEqual(r.field.version, version, "nothing to upload while nothing changes")
        XCTAssertFalse(r.field.dirty)
    }

    func testBurstIsRationed() {
        var r = RakeLines()
        for i in 0..<2000 { r.noteOn(UInt8(21 + i % 88), velocity: 0.9, at: Double(i) * 0.0005) }
        var raked = 0
        for _ in 0..<10 {
            r.step(dt: 1.0 / 60, roles: RoleValues())
            XCTAssertLessThanOrEqual(r.lastSpawns, RakeLines.maxSpawnsPerStep)
            XCTAssertLessThanOrEqual(r.rings.count, RakeLines.ringCap)
            XCTAssertLessThanOrEqual(r.strokes.count, RakeLines.strokeCap)
            raked += r.lastSpawns
        }
        XCTAssertEqual(raked, 48, "12 a step, and only the latest 48 kept waiting")
        XCTAssertTrue(r.field.heights.allSatisfy { $0.isFinite && abs($0) <= 1 })
        XCTAssertNotNil(r.wave, "a burst is a chord too")
    }

    func testIdsWrap() throws {
        var r = RakeLines()
        r.nextRingID = Int.max - 2
        r.nextStrokeID = Int.max - 1
        r.nextWaveID = Int.max
        r.field.version = Int.max
        // A run up and back across the stones: six rings and three curves (none between the right pair).
        for (i, n) in ([45, 60, 77, 96, 77, 60] as [UInt8]).enumerated() {
            r.noteOn(n, velocity: 0.6, at: Double(i) * 0.15)
            r.step(dt: 0.15, roles: RoleValues())
            r.noteOff(n)
        }
        XCTAssertEqual(r.rings.map(\.id), [Int.max - 2, Int.max - 1, Int.max, Int.min, Int.min + 1, Int.min + 2])
        XCTAssertEqual(r.strokes.map(\.id), [Int.max - 1, Int.max, Int.min])
        XCTAssertEqual(r.strokes.map { [$0.from, $0.to] }, [[1, 2], [2, 3], [3, 2]])
        XCTAssertEqual(r.field.version, Int.min + 5, "the field's version wraps too")
        // Two chords, two waves: the second's id past Int.max.
        var ids: [Int] = []
        for k in 0..<2 {
            let t = 2 + Double(k)
            for (i, n) in ([60, 64, 67] as [UInt8]).enumerated() { r.noteOn(n, velocity: 0.7, at: t + 0.01 * Double(i)) }
            r.step(dt: 0.1, roles: RoleValues())
            let wave = try XCTUnwrap(r.wave)
            ids.append(wave.id)
        }
        XCTAssertEqual(ids, [Int.max, Int.min])
    }
}
