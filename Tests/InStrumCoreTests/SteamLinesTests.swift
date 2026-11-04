import XCTest
@testable import InStrumCore

final class SteamLinesTests: XCTestCase {
    private func run(_ s: inout SteamLines, seconds: Double, dt: Double = 1.0 / 60) {
        for _ in 0..<Int((seconds / dt).rounded()) { s.step(dt: dt, roles: RoleValues()) }
    }

    /// Each note sends a wisp off the steam at its key's place across the bowl (0.2…0.8: the ribbon's lateral curl),
    /// as high as its velocity.
    func testWispsFollowTheKeys() throws {
        var s = SteamLines()
        s.noteOn(21, velocity: 1, at: 0)
        s.noteOn(108, velocity: 1, at: 0.5)
        s.step(dt: 1.0 / 60, roles: RoleValues())
        let low = try XCTUnwrap(s.wisps.first { $0.note == 21 }), high = try XCTUnwrap(s.wisps.first { $0.note == 108 })
        XCTAssertEqual(low.x, 0.2, accuracy: 0.01, "the lowest key curls out to the bowl's left")
        XCTAssertEqual(high.x, 0.8, accuracy: 0.01, "the highest to its right")
        XCTAssertEqual(low.curl, -1, accuracy: 0.03)
        XCTAssertEqual(high.curl, 1, accuracy: 0.03)
        XCTAssertEqual(low.height, 1, accuracy: 1e-5, "a hard note sends its wisp to the top of the steam")
        XCTAssertEqual(low.peak, 1, accuracy: 1e-5)
        XCTAssertEqual(low.brightness, 1, accuracy: 1e-5)
        XCTAssertEqual(low.rise, 0, "it has only just left the bowl")
        XCTAssertTrue(low.held)
        s.noteOn(60, velocity: 0, at: 1)
        s.step(dt: 1.0 / 60, roles: RoleValues())
        let soft = try XCTUnwrap(s.wisps.first { $0.note == 60 })
        XCTAssertEqual(soft.height, 0.3, accuracy: 1e-5, "a soft note's wisp stays low")
        XCTAssertEqual(soft.brightness, 0.35, accuracy: 1e-5)
        XCTAssertEqual(soft.x, SteamLines.x(for: 60), accuracy: 1e-6)
        // Across the bowl in keyboard order.
        let xs = [36, 48, 60, 64, 72, 84, 96].map { SteamLines.x(for: UInt8($0)) }
        XCTAssertEqual(xs, xs.sorted())
        XCTAssertTrue(xs.allSatisfy { (0.2...0.8).contains($0) })
        XCTAssertEqual(SteamLines.x(for: 0), SteamLines.x(for: 21), "out-of-range notes take the end keys")

        // Let go at once, each wisp climbs to its velocity's height and no further.
        var two = SteamLines()
        two.noteOn(48, velocity: 1, at: 0)
        two.noteOn(84, velocity: 0.2, at: 0.5)
        two.step(dt: 1.0 / 60, roles: RoleValues())
        two.noteOff(48); two.noteOff(84)
        run(&two, seconds: 4)
        let hard = try XCTUnwrap(two.wisps.first { $0.note == 48 }), gentle = try XCTUnwrap(two.wisps.first { $0.note == 84 })
        XCTAssertEqual(gentle.height, 0.3 + 0.7 * 0.2, accuracy: 1e-5)
        for w in [hard, gentle] {
            XCTAssertLessThanOrEqual(w.rise, w.height + 1e-6)
            XCTAssertGreaterThan(w.rise, 0.95 * w.height)
        }
        XCTAssertGreaterThan(hard.rise, gentle.rise + 0.4, "the harder note's wisp rises higher")
        XCTAssertLessThan(hard.curl, 0, "a low note curls left")
        XCTAssertGreaterThan(gentle.curl, 0, "a high one right")

        // Deterministic: the same notes, the same wisps.
        func wisps() -> [SteamWisp] {
            var d = SteamLines()
            for i in 0..<10 { d.noteOn(UInt8(50 + 3 * i), velocity: 0.1 * Float(i), at: Double(i) * 0.2); d.step(dt: 0.2, roles: RoleValues()) }
            return d.wisps
        }
        XCTAssertEqual(wisps(), wisps())
    }

    /// Held notes (and the pedal) keep their wisps drawn upward, at their peak, and brighten the steam; let go, the
    /// wisp stops at its velocity's height and fades with τ 3 s, and the steam settles.
    func testHeldNotesLiftTheSteam() throws {
        var held = SteamLines()
        held.noteOn(64, velocity: 0.5, at: 0)
        run(&held, seconds: 4)
        let w = try XCTUnwrap(held.wisps.first)
        XCTAssertTrue(w.held)
        XCTAssertEqual(w.peak, 0.35 + 0.65 * 0.5, accuracy: 1e-5)
        XCTAssertEqual(w.brightness, w.peak, accuracy: 1e-6, "at its peak while held")
        XCTAssertGreaterThan(w.rise, 0.95, "drawn on up toward the top of the steam")
        XCTAssertGreaterThan(held.glow, 0.5, "the steam brightens")

        var brief = SteamLines()
        brief.noteOn(64, velocity: 0.5, at: 0)
        brief.step(dt: 1.0 / 60, roles: RoleValues())
        brief.noteOff(64)
        run(&brief, seconds: 3)
        let b = try XCTUnwrap(brief.wisps.first)
        XCTAssertFalse(b.held)
        XCTAssertEqual(b.height, 0.65, accuracy: 1e-5)
        XCTAssertLessThanOrEqual(b.rise, b.height + 1e-6, "let go, it stops at its velocity's height")
        XCTAssertLessThan(b.rise, w.rise - 0.25)
        // τ 3 s ± 10%: e^(−3/2.7) … e^(−3/3.3) of its peak.
        XCTAssertGreaterThan(b.brightness, b.peak * Float(exp(-3 / 2.7)))
        XCTAssertLessThan(b.brightness, b.peak * Float(exp(-3 / 3.3)))
        XCTAssertLessThan(brief.glow, 0.05)

        held.noteOff(64)
        run(&held, seconds: 15)
        XCTAssertTrue(held.wisps.isEmpty, "gone once it has faded")
        XCTAssertLessThan(held.glow, 0.01, "and the steam has settled")

        // The pedal keeps a released note's wisp drawn up and the steam bright until it comes up.
        var p = SteamLines()
        p.setPedal(true)
        p.noteOn(60, velocity: 0.5, at: 0)
        run(&p, seconds: 0.2)
        p.noteOff(60)
        run(&p, seconds: 5)
        let pw = try XCTUnwrap(p.wisps.first)
        XCTAssertTrue(pw.held, "sounding under the pedal")
        XCTAssertEqual(pw.brightness, pw.peak, accuracy: 1e-6)
        XCTAssertGreaterThan(pw.rise, 0.95)
        XCTAssertGreaterThan(p.glow, 0.5)
        p.setPedal(false)
        run(&p, seconds: 3)
        let up = try XCTUnwrap(p.wisps.first)
        XCTAssertFalse(up.held)
        XCTAssertLessThan(up.brightness, 0.5 * up.peak)
        XCTAssertLessThan(p.glow, 0.3)

        // A panic lets everything go, the pedal's notes too.
        var panic = SteamLines()
        panic.setPedal(true)
        panic.noteOn(60, velocity: 0.5, at: 0)
        run(&panic, seconds: 0.2)
        panic.allNotesOff(); panic.setPedal(false)
        run(&panic, seconds: 1)
        XCTAssertTrue(panic.wisps.allSatisfy { !$0.held })
    }

    /// Runs (notes within 0.25 s) draw the melody's contour up the ribbon: the last 12 notes' pitches, newest lowest.
    func testRunsShapeTheRibbon() {
        func play(_ notes: [UInt8], gap: Double, settle: Double) -> SteamLines {
            var s = SteamLines()
            for (i, n) in notes.enumerated() {
                s.noteOn(n, velocity: 0.6, at: Double(i) * gap)
                run(&s, seconds: gap)
            }
            run(&s, seconds: settle)
            return s
        }
        let rising: [UInt8] = [60, 62, 64, 65, 67, 69, 71, 72, 74, 76, 77, 79]
        var up = play(rising, gap: 0.15, settle: 0.5)
        XCTAssertEqual(up.ribbonPath.count, SteamLines.pathPoints)
        XCTAssertGreaterThan(up.ribbonPath[0], 0.3, "the newest, highest note leaves the bowl to one side")
        XCTAssertLessThan(up.ribbonPath[11], -0.3, "the oldest, lowest has risen to the top on the other")
        for i in 0..<11 { XCTAssertGreaterThan(up.ribbonPath[i], up.ribbonPath[i + 1], "the contour at \(i)") }
        XCTAssertTrue(up.ribbonPath.allSatisfy { abs($0) <= 1 })

        let down = play(rising.reversed(), gap: 0.15, settle: 0.5)
        XCTAssertLessThan(down.ribbonPath[0], -0.3, "a falling run leans the other way")
        XCTAssertGreaterThan(down.ribbonPath[11], 0.3)
        for i in 0..<11 { XCTAssertLessThan(down.ribbonPath[i], down.ribbonPath[i + 1], "the contour at \(i)") }

        // Only the last 12 notes count: a 20-note run ends where its last 12 alone would.
        let long = (50...69).map { UInt8($0) }
        var a = SteamLines(), b = SteamLines()
        for (i, n) in long.enumerated() {
            a.noteOn(n, velocity: 0.6, at: Double(i) * 0.15)
            if i >= 8 { b.noteOn(n, velocity: 0.6, at: Double(i) * 0.15) }
            run(&a, seconds: 0.15); run(&b, seconds: 0.15)
        }
        run(&a, seconds: 2); run(&b, seconds: 2)
        for i in 0..<SteamLines.pathPoints { XCTAssertEqual(a.ribbonPath[i], b.ribbonPath[i], accuracy: 0.01, "point \(i)") }
        XCTAssertGreaterThan(a.ribbonPath[0], 0.15, "still shaped after 2 s")

        // A short run sits low on the ribbon; the rest stays straight.
        let four = play([60, 64, 67, 72], gap: 0.15, settle: 0)
        XCTAssertGreaterThan(four.ribbonPath[0], 0.2)
        XCTAssertEqual(Array(four.ribbonPath[4...]), [Float](repeating: 0, count: 8))

        // Notes half a second apart are not a run; nor is a chord.
        XCTAssertEqual(play(rising, gap: 0.5, settle: 0).ribbonPath, SteamLines.straight)

        // In silence the ribbon relaxes back to straight.
        run(&up, seconds: 15)
        XCTAssertLessThan(up.ribbonPath.map { abs($0) }.max() ?? 1, 0.01)
    }

    /// Chords (three notes within 60 ms) puff a rounder cloud at their keys' mean place: warm for major, cool for minor.
    func testChordsPuff() {
        func chord(_ notes: [UInt8]) -> SteamLines {
            var s = SteamLines()
            for (t, n) in zip([0, 0.02, 0.05], notes) { s.noteOn(n, velocity: 0.8, at: t) }
            run(&s, seconds: 0.3)
            return s
        }
        var major = chord([60, 64, 67])
        XCTAssertGreaterThan(major.puff.strength, 0.5)
        XCTAssertEqual(major.puff.warmth, 1, "warm for major")
        let mean = (SteamLines.x(for: 60) + SteamLines.x(for: 64) + SteamLines.x(for: 67)) / 3
        XCTAssertEqual(major.puff.x, mean, accuracy: 1e-5)
        XCTAssertEqual(major.puff.age, 0.3, accuracy: 0.02)
        XCTAssertEqual(major.ribbonPath, SteamLines.straight, "a chord puffs; it does not draw a run")
        XCTAssertEqual(major.wisps.count, 3, "and each of its notes still sends a wisp")
        run(&major, seconds: 8)
        XCTAssertLessThan(major.puff.strength, 0.05, "it dies away")

        let minor = chord([57, 60, 64])
        XCTAssertGreaterThan(minor.puff.strength, 0.5)
        XCTAssertEqual(minor.puff.warmth, 0, "cool for minor")
        XCTAssertEqual(chord([60, 66, 71]).puff.warmth, 0.5, "a tense chord is neither")

        var single = SteamLines()
        single.noteOn(60, velocity: 1, at: 0)
        run(&single, seconds: 0.3)
        XCTAssertEqual(single.puff.strength, 0)
        var two = SteamLines()
        two.noteOn(60, velocity: 0.8, at: 0); two.noteOn(64, velocity: 0.8, at: 0.02)
        run(&two, seconds: 0.3)
        XCTAssertEqual(two.puff.strength, 0, "two notes are not a chord")

        // It swells in smoothly (for the flash limiter), never past 1.
        var swell = SteamLines()
        for (t, n) in zip([0, 0.02, 0.05], [60, 64, 67] as [UInt8]) { swell.noteOn(n, velocity: 1, at: t) }
        var last: Float = 0, biggestJump: Float = 0
        for _ in 0..<60 {
            swell.step(dt: 1.0 / 60, roles: RoleValues())
            biggestJump = max(biggestJump, swell.puff.strength - last)
            last = swell.puff.strength
            XCTAssertLessThanOrEqual(swell.puff.strength, 1)
        }
        XCTAssertLessThan(biggestJump, 0.15, "no step is a flash")
    }

    /// A MIDI burst sends at most 8 wisps a step and keeps 24 at most.
    func testBurstIsRationed() {
        var s = SteamLines()
        for i in 0..<2000 { s.noteOn(UInt8(21 + i % 88), velocity: 0.9, at: Double(i) * 0.0005) }
        for _ in 0..<60 {
            s.step(dt: 1.0 / 60, roles: RoleValues())
            XCTAssertLessThanOrEqual(s.lastSpawns, SteamLines.maxSpawnsPerStep)
            XCTAssertLessThanOrEqual(s.wisps.count, SteamLines.cap)
        }
        XCTAssertEqual(s.wisps.count, SteamLines.cap)
        XCTAssertEqual(SteamLines.cap, 24)
        XCTAssertEqual(SteamLines.maxSpawnsPerStep, 8)
        XCTAssertEqual(s.lanternFlake?.time ?? -1, 1999 * 0.0005, accuracy: 1e-9, "one flake: the latest")

        // A full steam lets its dimmest wisp go first.
        var full = SteamLines()
        for i in 0..<24 { full.noteOn(UInt8(40 + i), velocity: 0.6, at: Double(i)) }
        run(&full, seconds: 0.5)
        full.noteOff(40)
        run(&full, seconds: 0.5)
        full.noteOn(90, velocity: 0.6, at: 30)
        run(&full, seconds: 0.1)
        XCTAssertEqual(full.wisps.count, SteamLines.cap)
        XCTAssertFalse(full.wisps.contains { $0.note == 40 }, "the released one made room")
        XCTAssertTrue(full.wisps.contains { $0.note == 90 })

        // The renderer's budget keeps the brightest, in order.
        var v = SteamLines()
        for i in 0..<24 { v.noteOn(UInt8(40 + i), velocity: 0.6, at: Double(i)) }
        run(&v, seconds: 0.5)
        for i in stride(from: 0, to: 24, by: 2) { v.noteOff(UInt8(40 + i)) }
        run(&v, seconds: 1)
        let shown = SteamLines.visible(v.wisps, limit: 12)
        XCTAssertEqual(shown.count, 12)
        XCTAssertTrue(shown.allSatisfy { $0.held }, "the held (brightest) wisps stay")
        XCTAssertEqual(shown.map(\.id), shown.map(\.id).sorted(), "in their original order")
        XCTAssertEqual(SteamLines.visible(v.wisps, limit: 100).count, v.wisps.count)
    }

    func testIdsWrap() {
        var s = SteamLines()
        s.nextID = Int.max - 2
        s.nextFlakeID = Int.max - 1
        for i in 0..<6 {
            s.noteOn(UInt8(60 + i), velocity: 0.9, at: Double(i) * 0.1)
            s.step(dt: 0.1, roles: RoleValues())
        }
        XCTAssertEqual(s.wisps.count, 6)
        XCTAssertEqual(Set(s.wisps.map(\.id)).count, 6)
        XCTAssertEqual(s.lanternFlake?.id, Int.min + 3, "the flakes' ids wrap too")
    }

    /// A hard note (velocity ≥ 0.85) knocks a snowflake off the stone lantern's cap: the latest falls for 4 s.
    func testHardNotesKnockSnowOffTheLantern() throws {
        var s = SteamLines()
        s.noteOn(60, velocity: 0.8, at: 1)
        run(&s, seconds: 0.1)
        XCTAssertNil(s.lanternFlake, "not hard enough")
        s.noteOn(96, velocity: 0.9, at: 2)
        run(&s, seconds: 0.5)
        let flake = try XCTUnwrap(s.lanternFlake)
        XCTAssertEqual(flake.x, SteamLines.capX(for: 96), accuracy: 1e-6)
        XCTAssertEqual(flake.time, 2)
        XCTAssertEqual(flake.age, 0.5, accuracy: 0.02)
        XCTAssertEqual(flake.velocity, 0.9, accuracy: 1e-6)
        s.noteOn(40, velocity: 1, at: 3)
        run(&s, seconds: 0.1)
        let latest = try XCTUnwrap(s.lanternFlake)
        XCTAssertEqual(latest.time, 3, "the latest knock is the one that falls")
        XCTAssertEqual(latest.x, SteamLines.capX(for: 40), accuracy: 1e-6)
        XCTAssertNotEqual(latest.id, flake.id)
        XCTAssertLessThan(SteamLines.capX(for: 40), SteamLines.capX(for: 96), "low keys knock it off the cap's left")
        XCTAssertTrue((0.1...0.9).contains(SteamLines.capX(for: 21)) && (0.1...0.9).contains(SteamLines.capX(for: 108)))
        run(&s, seconds: 3.8)
        XCTAssertNotNil(s.lanternFlake, "still falling at 3.9 s")
        run(&s, seconds: 0.2)
        XCTAssertNil(s.lanternFlake, "fallen after 4 s")
        var edge = SteamLines()
        edge.noteOn(70, velocity: SteamLines.hardNote, at: 0)
        XCTAssertNotNil(edge.lanternFlake, "0.85 is hard enough")
    }

    func testOddInputsStayFinite() {
        var s = SteamLines()
        s.reactionScale = .nan
        s.lingerScale = .infinity
        s.noteOn(200, velocity: .infinity, at: .nan)
        s.noteOn(0, velocity: -3, at: 0)
        s.noteOn(60, velocity: .nan, at: 0.1)
        s.noteOn(64, velocity: 0.9, at: -5)
        s.step(dt: .infinity, roles: RoleValues())
        s.step(dt: -1, roles: RoleValues())
        s.step(dt: .nan, roles: RoleValues())
        run(&s, seconds: 0.5)
        XCTAssertFalse(s.wisps.isEmpty)
        for w in s.wisps {
            XCTAssertTrue((0.2...0.8).contains(w.x), "\(w)")
            XCTAssertTrue((0...1).contains(w.rise), "\(w)")
            XCTAssertTrue((0...1).contains(w.brightness), "\(w)")
            XCTAssertTrue((0.3...1).contains(w.height), "\(w)")
            XCTAssertTrue(w.age.isFinite, "\(w)")
        }
        XCTAssertTrue(s.ribbonPath.allSatisfy { $0.isFinite && abs($0) <= 1 })
        XCTAssertTrue((0...1).contains(s.glow))
        XCTAssertTrue((0...1).contains(s.puff.strength) && s.puff.age.isFinite)
        XCTAssertEqual(SteamLines.ribbonCount(steam: 0), 2)
        XCTAssertEqual(SteamLines.ribbonCount(steam: 0.6), 3)
        XCTAssertEqual(SteamLines.ribbonCount(steam: 1), 4)
        XCTAssertEqual(SteamLines.ribbonCount(steam: .nan), 3)
        XCTAssertEqual(SteamLines.ribbonCount(steam: -1), 2)
        XCTAssertEqual(SteamLines.ribbonCount(steam: 5), 4)
    }
}
