import XCTest
import simd
@testable import InStrumCore

final class DeepLightsTests: XCTestCase {
    private func run(_ d: inout DeepLights, seconds: Double, dt: Double = 1.0 / 60, roles: RoleValues = RoleValues()) {
        for _ in 0..<max(1, Int((seconds / dt).rounded())) { d.step(dt: dt, roles: roles) }
    }

    /// A note arriving for the next step, stamped with that step's time (as a world stamps it), and that step.
    private func strike(_ d: inout DeepLights, _ note: UInt8, velocity: Float = 0.8, dt: Double = 1.0 / 60) {
        d.noteOn(note, velocity: velocity, at: d.time + dt)
        d.step(dt: dt, roles: RoleValues())
    }

    /// The glow of a note's latest creature (0 while it has none).
    private func glow(_ d: DeepLights, _ note: UInt8) -> Float { d.creatures.last { $0.note == note }?.glow ?? 0 }

    /// When a glow peaks: each sample above the one before it and at least the one after.
    private func peaks(_ s: [(t: Double, g: Float)]) -> [Double] {
        guard s.count >= 3 else { return [] }
        return (1..<(s.count - 1)).filter { s[$0].g > s[$0 - 1].g && s[$0].g >= s[$0 + 1].g }.map { s[$0].t }
    }

    /// Each note releases a creature as high as its pitch (low notes deep at the bottom, high ones near the top), as big
    /// and bright as its velocity; it drifts sideways with the current (0.01–0.04 of the view a second) at its depth,
    /// stays lit while held or pedalled, and fades with τ 4 s once let go.
    func testCreaturesFollowPitch() throws {
        XCTAssertEqual(DeepLights.height(for: 21), 0.1, accuracy: 1e-6)
        XCTAssertEqual(DeepLights.height(for: 108), 0.9, accuracy: 1e-6)
        XCTAssertEqual(DeepLights.height(for: 60), 0.1 + 0.8 * 39 / 87, accuracy: 1e-6)
        XCTAssertEqual(DeepLights.height(for: 0), 0.1, accuracy: 1e-6, "below the keyboard: the bottom")
        XCTAssertEqual(DeepLights.height(for: 127), 0.9, accuracy: 1e-6, "above it: the top")
        var d = DeepLights()
        let notes: [UInt8] = [21, 40, 60, 84, 108]
        for n in notes { strike(&d, n) }
        XCTAssertEqual(d.creatures.map(\.note), notes, "one creature a note")
        let heights = d.creatures.map(\.position.y)
        XCTAssertEqual(heights, heights.sorted(), "higher notes, higher in the water")
        for c in d.creatures {
            XCTAssertEqual(c.position.y, DeepLights.height(for: c.note), accuracy: 1e-6)
            XCTAssertTrue((0.1...0.61).contains(c.position.x), "\(c.position.x)")
            XCTAssertTrue(c.held)
        }
        XCTAssertLessThan(heights[0], 0.15, "the lowest note deep at the bottom")
        XCTAssertGreaterThan(heights[4], 0.85, "the highest near the top")

        // Harder notes, bigger and brighter creatures; each lights at its peak as it arrives (its stroke's brightest).
        var v = DeepLights()
        strike(&v, 60, velocity: 1)
        strike(&v, 64, velocity: 0)
        let hard = try XCTUnwrap(v.creatures.first { $0.note == 60 }), soft = try XCTUnwrap(v.creatures.first { $0.note == 64 })
        XCTAssertEqual(hard.size, 1, accuracy: 1e-6)
        XCTAssertEqual(hard.peak, 1, accuracy: 1e-6)
        XCTAssertGreaterThan(hard.glow, 0.99)
        XCTAssertEqual(soft.size, 0.35, accuracy: 1e-6)
        XCTAssertEqual(soft.peak, 0.35, accuracy: 1e-6)
        XCTAssertEqual(soft.glow, 0.35, accuracy: 1e-6)

        // They drift sideways with the current, holding their depth.
        var drifting = DeepLights()
        for n: UInt8 in [36, 60, 96] { strike(&drifting, n) }
        let start = drifting.creatures.map(\.position)
        run(&drifting, seconds: 10)
        XCTAssertEqual(drifting.creatures.count, 3)
        for (a, c) in zip(start, drifting.creatures) {
            let speed = (c.position.x - a.x) / 10
            XCTAssertTrue((0.0099...0.0401).contains(speed), "\(c.kind): \(speed) a second")
            XCTAssertEqual(c.position.y, a.y, "at its depth")
        }

        // Held (here under the pedal) they stay lit; let go they fade with τ 4 s, and are gone once faded.
        var fade = DeepLights()
        fade.setPedal(true)
        strike(&fade, 60)
        fade.noteOff(60)
        run(&fade, seconds: 5)
        let sustained = try XCTUnwrap(fade.creatures.first)
        XCTAssertTrue(sustained.held, "sounding under the pedal")
        XCTAssertEqual(sustained.level, 1)
        fade.setPedal(false)
        run(&fade, seconds: 4)
        let fading = try XCTUnwrap(fade.creatures.first)
        XCTAssertFalse(fading.held)
        XCTAssertEqual(fading.level, Float(exp(-1.0)), accuracy: 0.01)
        XCTAssertLessThanOrEqual(fading.glow, fading.peak * fading.level + 1e-6)
        run(&fade, seconds: 20)
        XCTAssertTrue(fade.creatures.isEmpty, "gone once faded")

        // A note struck again releases a new creature; only the newest stays lit while it sounds.
        var again = DeepLights()
        strike(&again, 60)
        strike(&again, 60)
        run(&again, seconds: 0.1)
        XCTAssertEqual(again.creatures.count, 2)
        XCTAssertEqual(again.creatures.map(\.held), [false, true])
    }

    /// Kind by register: a jelly below C3 (Blue Depth's own bass split), a comb jelly from C3, a speck from C5. Each swims
    /// at its own pace (jellies slowest, specks quickest, all within 0.3–1 Hz) and drifts likewise.
    func testCreatureKindByRegister() {
        let cases: [(UInt8, CreatureKind)] = [(21, .jelly), (36, .jelly), (47, .jelly), (48, .combJelly), (60, .combJelly),
                                              (71, .combJelly), (72, .speck), (96, .speck), (108, .speck)]
        for (note, kind) in cases { XCTAssertEqual(DeepLights.kind(for: note), kind, "note \(note)") }
        XCTAssertEqual(DeepLights.bassSplit, 48, "C3")
        XCTAssertEqual(DeepLights.trebleSplit, 72, "C5")
        var d = DeepLights()
        for _ in 0..<4 { for n: UInt8 in [36, 60, 90] { strike(&d, n) } }
        XCTAssertEqual(d.creatures.count, 12)
        XCTAssertEqual(d.creatures.prefix(3).map(\.kind), [.jelly, .combJelly, .speck])
        for c in d.creatures {
            XCTAssertEqual(c.kind, DeepLights.kind(for: c.note))
            let rates: ClosedRange<Float> = c.kind == .jelly ? 0.3...0.45 : (c.kind == .combJelly ? 0.45...0.7 : 0.7...1)
            XCTAssertTrue(rates.contains(c.swimRate), "\(c.kind) swims at \(c.swimRate) Hz")
            let drifts: ClosedRange<Float> = c.kind == .jelly ? 0.01...0.018 : (c.kind == .combJelly ? 0.015...0.03 : 0.025...0.04)
            XCTAssertTrue(drifts.contains(c.drift), "\(c.kind) drifts at \(c.drift) a second")
        }
    }

    /// With the instrument's pulse (Blue Depth at 118 BPM, Blink .6), a held creature's glow peaks on the arp's sixteenth
    /// grid, every 127.1 ms from the phrase's first note; a note joining the phrase blinks on the same grid. The grid runs
    /// on through a short pause (as the arp's clock does) and starts afresh after 2 s of quiet or a panic; the bass's
    /// jellies never blink, and a bass note alone starts no grid; Blink turned up over held notes starts it there and
    /// then; a new Tempo carries on from the step it is on. Without a pulse, each creature pulses at its own swim rate,
    /// 0.3–1 Hz.
    func testCreaturesBlinkWithTheInstrumentPulse() throws {
        let dt = 0.001
        let pulse = InstrumentPulse(bpm: 118, gate: 0.6)
        let sixteenth = 60.0 / 118 / 4
        XCTAssertEqual(DeepLights.stepLength(pulse), sixteenth, accuracy: 1e-12)
        XCTAssertEqual(sixteenth * 1000, 127.1, accuracy: 0.05)
        var d = DeepLights()
        d.pulse = pulse
        run(&d, seconds: 0.3, dt: dt)
        XCTAssertNil(d.gridStep, "nothing sounding: no grid yet")

        // The phrase's first note, C4, held for 1.5 s; E4 joins it 50 ms in.
        let first = d.time + dt
        strike(&d, 60, dt: dt)
        XCTAssertEqual(try XCTUnwrap(d.gridStep), first, accuracy: 1e-9, "the grid starts on the phrase's first note")
        var c4: [(t: Double, g: Float)] = [(d.time - dt, 0), (d.time, glow(d, 60))]
        var e4: [(t: Double, g: Float)] = []
        for i in 0..<1500 {
            if i == 49 { d.noteOn(64, velocity: 0.8, at: d.time + dt) }
            d.step(dt: dt, roles: RoleValues())
            c4.append((d.time, glow(d, 60)))
            if i >= 49 { e4.append((d.time, glow(d, 64))) }
        }
        let p = peaks(c4)
        XCTAssertGreaterThanOrEqual(p.count, 11)
        for (k, t) in p.enumerated() { XCTAssertEqual(t, first + Double(k) * sixteenth, accuracy: 0.002, "peak \(k)") }
        for (a, b) in zip(p, p.dropFirst()) { XCTAssertEqual((b - a) * 1000, 127.1, accuracy: 2) }
        let lit = c4.dropFirst(2).map(\.g)
        let top = try XCTUnwrap(lit.max()), low = try XCTUnwrap(lit.min())
        // Full on each step: sampled once a frame, the brightest sample has already faded by up to a frame's decay
        // (0.8690 against 0.87 on the macos-15 runner), so within 0.2%.
        XCTAssertEqual(top, 0.35 + 0.65 * 0.8, accuracy: 2e-3, "full on each step")
        XCTAssertLessThan(low, 0.45 * top, "and a real blink between")
        let joined = peaks(e4)
        XCTAssertGreaterThanOrEqual(joined.count, 10)
        for t in joined {
            let steps = (t - first) / sixteenth
            XCTAssertEqual(steps, steps.rounded(), accuracy: 0.002 / sixteenth, "E4 blinks on the phrase's grid (at \(t))")
            XCTAssertGreaterThanOrEqual(steps.rounded(), 1)
        }

        // Let go, they swim again as they fade; the grid runs on silently through a 1 s pause, and a note then blinks on it.
        d.noteOff(60)
        d.noteOff(64)
        run(&d, seconds: 0.5, dt: dt)
        XCTAssertTrue(d.creatures.allSatisfy { !$0.held && $0.blinking < 0.05 })
        run(&d, seconds: 0.5, dt: dt)
        XCTAssertNotNil(d.gridStep, "a 1 s pause keeps the grid")
        let resumed = d.time + dt
        strike(&d, 72, dt: dt)
        XCTAssertNotEqual(d.gridStep, resumed, "no fresh grid: the phrase carries on")
        var c5: [(t: Double, g: Float)] = [(d.time, glow(d, 72))]
        for _ in 0..<600 {
            d.step(dt: dt, roles: RoleValues())
            c5.append((d.time, glow(d, 72)))
        }
        let onTheOldGrid = peaks(c5)
        XCTAssertGreaterThanOrEqual(onTheOldGrid.count, 4)
        for t in onTheOldGrid {
            let steps = (t - first) / sixteenth
            XCTAssertEqual(steps, steps.rounded(), accuracy: 0.002 / sixteenth)
        }

        // 2 s of quiet resets the arp's clock: the next note starts a fresh grid on itself.
        d.noteOff(72)
        run(&d, seconds: 2.5, dt: dt)
        XCTAssertNil(d.gridStep, "reset after 2 s of quiet")
        let fresh = d.time + dt
        strike(&d, 67, dt: dt)
        XCTAssertEqual(try XCTUnwrap(d.gridStep), fresh, accuracy: 1e-9)
        var g7: [(t: Double, g: Float)] = [(d.time - dt, 0), (d.time, glow(d, 67))]
        for _ in 0..<800 {
            d.step(dt: dt, roles: RoleValues())
            g7.append((d.time, glow(d, 67)))
        }
        let freshPeaks = peaks(g7)
        XCTAssertGreaterThanOrEqual(freshPeaks.count, 6)
        for (k, t) in freshPeaks.enumerated() { XCTAssertEqual(t, fresh + Double(k) * sixteenth, accuracy: 0.002) }

        // A panic resets it at once: the next note starts a fresh grid, however soon.
        d.allNotesOff()
        XCTAssertNil(d.gridStep)
        let afterPanic = d.time + dt
        strike(&d, 62, dt: dt)
        XCTAssertEqual(try XCTUnwrap(d.gridStep), afterPanic, accuracy: 1e-9)

        // The bass's jellies never blink (the arp never plays below C3), and a bass note alone starts no grid.
        var bass = DeepLights()
        bass.pulse = pulse
        strike(&bass, 36, dt: dt)
        run(&bass, seconds: 0.5, dt: dt)
        XCTAssertNil(bass.gridStep)
        XCTAssertEqual(try XCTUnwrap(bass.creatures.first).blinking, 0)
        strike(&bass, 60, dt: dt)
        run(&bass, seconds: 0.5, dt: dt)
        XCTAssertNotNil(bass.gridStep)
        XCTAssertEqual(try XCTUnwrap(bass.creatures.first { $0.note == 36 }).blinking, 0, "even with the grid running")
        XCTAssertEqual(try XCTUnwrap(bass.creatures.first { $0.note == 60 }).blinking, 1)

        // Blink turned up over a held note starts the grid there and then; a new Tempo carries on from the step it is on.
        var up = DeepLights()
        strike(&up, 60, dt: dt)
        run(&up, seconds: 0.2, dt: dt)
        XCTAssertNil(up.gridStep, "no pulse, no grid")
        up.pulse = pulse
        up.step(dt: dt, roles: RoleValues())
        XCTAssertEqual(try XCTUnwrap(up.gridStep), up.time, accuracy: 1e-9)
        run(&up, seconds: 0.5, dt: dt)
        up.pulse = InstrumentPulse(bpm: 140, gate: 0.6)
        var g8: [(t: Double, g: Float)] = []
        for _ in 0..<1000 {
            up.step(dt: dt, roles: RoleValues())
            g8.append((up.time, glow(up, 60)))
        }
        let faster = peaks(g8)
        XCTAssertGreaterThanOrEqual(faster.count, 8)
        for (a, b) in zip(faster, faster.dropFirst()) { XCTAssertEqual(b - a, 60.0 / 140 / 4, accuracy: 0.002) }

        // Without a pulse each creature pulses at its own swim rate, 0.3–1 Hz.
        var swimming = DeepLights()
        let swimDT = 0.005
        let notes: [UInt8] = [36, 60, 96]
        for n in notes { strike(&swimming, n, dt: swimDT) }
        var traces = [[(t: Double, g: Float)]](repeating: [], count: notes.count)
        for _ in 0..<Int((20 / swimDT).rounded()) {
            swimming.step(dt: swimDT, roles: RoleValues())
            for (i, n) in notes.enumerated() { traces[i].append((swimming.time, glow(swimming, n))) }
        }
        for (i, n) in notes.enumerated() {
            let strokes = peaks(traces[i])
            XCTAssertGreaterThanOrEqual(strokes.count, 5, "note \(n)")
            guard let a = strokes.first, let b = strokes.last, b > a else { continue }
            let rate = Double(strokes.count - 1) / (b - a)
            XCTAssertTrue((0.3...1.0).contains(rate), "note \(n) swims at \(rate) Hz")
            let c = try XCTUnwrap(swimming.creatures.first { $0.note == n })
            XCTAssertEqual(rate, Double(c.swimRate), accuracy: 0.01)
            XCTAssertEqual(c.blinking, 0)
            XCTAssertGreaterThanOrEqual(traces[i].map(\.g).min() ?? 0, 0.6 * c.peak - 1e-5, "a gentle swim, never dark")
        }
        XCTAssertNil(swimming.gridStep)
    }

    /// A run (notes within 0.2 s of each other) sends a lanternfish shoal flashing past: a string of lights along its
    /// contour, one per note, its head crossing the porthole in 1.5 s, left to right for a rising run and right to left
    /// for a falling one; at most 4 at once, 12 lights each. Slower notes, notes struck together, or two notes send none.
    func testRunsSendALanternfishShoal() throws {
        func play(_ notes: [UInt8], every gap: Double, into d: inout DeepLights) {
            let dt = 1.0 / 120
            for n in notes {
                strike(&d, n, dt: dt)
                d.noteOff(n)
                run(&d, seconds: gap - dt, dt: dt)
            }
        }
        var d = DeepLights()
        let rising: [UInt8] = [60, 62, 64, 65, 67, 69]
        play(rising, every: 0.12, into: &d)
        XCTAssertEqual(d.shoals.count, 1, "one shoal for the run")
        let s = try XCTUnwrap(d.shoals.first)
        XCTAssertEqual(s.contour, rising.map { DeepLights.height(for: $0) }, "a light a note along the run's contour")
        XCTAssertEqual(s.direction, 1, "a rising run swims left to right")
        XCTAssertEqual(s.strength, 0.9, accuracy: 1e-5)
        XCTAssertEqual(s.progress, s.age / 1.5, accuracy: 1e-6, "the head crosses in 1.5 s")
        XCTAssertEqual(s.light(0).x, s.progress, accuracy: 1e-6)
        XCTAssertEqual(s.light(5).x, s.progress - 5 * DeepLights.shoalSpacing, accuracy: 1e-5)
        XCTAssertEqual(s.light(5).y, DeepLights.height(for: 69), accuracy: 1e-6)
        XCTAssertGreaterThan(s.brightness, 0.5)
        XCTAssertLessThanOrEqual(s.brightness, 1)
        run(&d, seconds: 2.5)
        XCTAssertTrue(d.shoals.isEmpty, "gone once its tail has crossed")

        var f = DeepLights()
        play([72, 71, 69, 67], every: 0.1, into: &f)
        let falling = try XCTUnwrap(f.shoals.first)
        XCTAssertEqual(falling.direction, -1, "a falling run swims right to left")
        XCTAssertEqual(falling.light(0).x, 1 - falling.progress, accuracy: 1e-6)
        XCTAssertGreaterThan(falling.light(1).x, falling.light(0).x, "its tail trailing to the right")

        var slow = DeepLights()
        play([60, 62, 64, 65], every: 0.5, into: &slow)
        XCTAssertTrue(slow.shoals.isEmpty, "0.5 s apart is no run")
        var chord = DeepLights()
        for n: UInt8 in [60, 64, 67] { chord.noteOn(n, velocity: 0.8, at: chord.time + 1.0 / 60) }
        run(&chord, seconds: 0.2)
        XCTAssertTrue(chord.shoals.isEmpty, "struck together: a chord, not a run")
        var two = DeepLights()
        play([60, 62], every: 0.1, into: &two)
        XCTAssertTrue(two.shoals.isEmpty, "two notes are not yet a shoal")

        // A long fast run sends shoal after shoal, never more than 4 at once.
        var long = DeepLights()
        var most = 0, longest = 0
        for i in 0..<80 {
            let n = UInt8(48 + (i * 7) % 36)
            strike(&long, n, dt: 1.0 / 120)
            long.noteOff(n)
            for _ in 0..<7 {
                long.step(dt: 1.0 / 120, roles: RoleValues())
                most = max(most, long.shoals.count)
                longest = max(longest, long.shoals.map(\.contour.count).max() ?? 0)
            }
        }
        XCTAssertGreaterThan(most, 1)
        XCTAssertLessThanOrEqual(most, DeepLights.shoalCap)
        XCTAssertLessThanOrEqual(longest, DeepLights.shoalLights)
    }

    /// A chord (three notes within 60 ms) sends a siphonophore drifting across behind: a chain of 12–20 bells coloured by
    /// the chord (major pale blue-green with gold flecks, minor deep blue-violet, tense a slow deep red), at most 2 at once.
    /// It swells in, stays lit while the chord sounds, fades after and goes.
    func testChordsSendASiphonophore() throws {
        func chord(_ notes: [UInt8], velocity: Float = 0.8) -> DeepLights {
            var d = DeepLights()
            for (i, n) in notes.enumerated() { d.noteOn(n, velocity: velocity, at: 0.01 + 0.01 * Double(i)) }
            run(&d, seconds: 1.5)
            return d
        }
        var major = chord([60, 64, 67])
        XCTAssertEqual(major.siphonophores.count, 1)
        let m = try XCTUnwrap(major.siphonophores.first)
        XCTAssertEqual(m.quality, .major)
        XCTAssertEqual(m.colour, DeepLights.colour(.major))
        XCTAssertGreaterThan(m.colour.y, m.colour.x, "pale blue-green")
        XCTAssertGreaterThan(m.colour.z, m.colour.x)
        XCTAssertEqual(m.flecks, 1, "with gold flecks")
        XCTAssertTrue((12...20).contains(m.bells), "\(m.bells) bells")
        XCTAssertEqual(m.position.y, DeepLights.height(for: 64), accuracy: 0.01, "at the chord's mean pitch")
        XCTAssertGreaterThan(m.brightness, 0.4, "swelled in while it sounds")
        XCTAssertLessThanOrEqual(m.brightness, 1)

        let minor = try XCTUnwrap(chord([57, 60, 64]).siphonophores.first)
        XCTAssertEqual(minor.quality, .minor)
        XCTAssertGreaterThan(minor.colour.z, 2 * minor.colour.y, "deep blue-violet")
        XCTAssertGreaterThan(minor.colour.x, minor.colour.y, "violet, not teal")
        XCTAssertEqual(minor.flecks, 0)
        let tense = try XCTUnwrap(chord([59, 62, 65]).siphonophores.first)
        XCTAssertEqual(tense.quality, .tense)
        XCTAssertGreaterThan(tense.colour.x, 4 * max(tense.colour.y, tense.colour.z), "tense: the deep sea's one red light")
        XCTAssertLessThan(tense.pulseRate, m.pulseRate, "a slow deep red")
        XCTAssertEqual(tense.flecks, 0)
        let big = try XCTUnwrap(chord([60, 64, 67, 71, 74, 79], velocity: 1).siphonophores.first)
        XCTAssertEqual(big.bells, 20, "a bigger, harder chord: a longer chain (its later notes join it)")
        XCTAssertGreaterThan(big.bells, m.bells)
        XCTAssertEqual(big.position.y, DeepLights.height(for: 69), accuracy: 0.01, "at the whole chord's mean pitch")
        // A chord whose seventh lands first reads tense on its first three notes; the rest of it, joining within 60 ms,
        // recolours it by the whole chord (C7: major).
        let seventh = try XCTUnwrap(chord([70, 60, 64, 67]).siphonophores.first)
        XCTAssertEqual(seventh.quality, .major)
        XCTAssertEqual(seventh.colour, DeepLights.colour(.major))
        XCTAssertEqual(chord([70, 60, 64, 67]).siphonophores.count, 1, "one chord, one siphonophore")

        // Single notes send none.
        var single = DeepLights()
        strike(&single, 60)
        run(&single, seconds: 0.5)
        XCTAssertTrue(single.siphonophores.isEmpty)
        // Let go, it fades, and goes.
        let lit = m.brightness
        for n: UInt8 in [60, 64, 67] { major.noteOff(n) }
        run(&major, seconds: 5)
        XCTAssertLessThan(try XCTUnwrap(major.siphonophores.first).brightness, 0.5 * lit)
        run(&major, seconds: 30)
        XCTAssertTrue(major.siphonophores.isEmpty)
        // At most 2 at once.
        var many = DeepLights()
        for k in 0..<5 {
            let t = many.time + 0.01
            for (i, n) in [60, 64, 67].enumerated() { many.noteOn(UInt8(n + k), velocity: 0.8, at: t + 0.02 * Double(i)) }
            run(&many, seconds: 0.5)
            XCTAssertLessThanOrEqual(many.siphonophores.count, DeepLights.siphonophoreCap)
        }
        XCTAssertEqual(many.siphonophores.count, DeepLights.siphonophoreCap)
    }

    /// An accent (velocity 0.85 or more) sends a stream of bubbles rising past the glass from the hull, under its key, and
    /// asks for a burst of their sound on that step alone: the submarine's frame after the accent carries the
    /// `bubbleBurst` one-shot, and the next frame none. Softer notes raise none; at most 6 streams at once.
    func testAccentsRaiseBubbles() throws {
        var d = DeepLights()
        strike(&d, 60, velocity: 0.84)
        XCTAssertNil(d.burst)
        XCTAssertTrue(d.bubbleStreams.isEmpty, "not an accent")
        strike(&d, 40, velocity: 0.9)
        let burst = try XCTUnwrap(d.burst)
        XCTAssertEqual(burst, 0.6 + 0.4 * (0.9 - 0.85) / 0.15, accuracy: 1e-5)
        XCTAssertEqual(d.bubbleStreams.count, 1)
        let stream = try XCTUnwrap(d.bubbleStreams.first)
        XCTAssertEqual(stream.x, DeepLights.streamX(for: 40), accuracy: 1e-6, "under its key")
        XCTAssertLessThan(stream.x, DeepLights.streamX(for: 80))
        XCTAssertEqual(Double(stream.strength), burst, accuracy: 1e-6)
        d.step(dt: 1.0 / 60, roles: RoleValues())
        XCTAssertNil(d.burst, "a one-shot: the next step has none")
        XCTAssertEqual(d.bubbleStreams.count, 1, "while the stream rises on")
        run(&d, seconds: 3.6)
        XCTAssertTrue(d.bubbleStreams.isEmpty, "risen and gone")
        // Several accents on one step: one burst, the strongest.
        for (i, v) in [Float(0.86), 1, 0.9].enumerated() { d.noteOn(UInt8(60 + i), velocity: v, at: d.time + 1.0 / 60) }
        d.step(dt: 1.0 / 60, roles: RoleValues())
        XCTAssertEqual(try XCTUnwrap(d.burst), 1, accuracy: 1e-6)
        XCTAssertEqual(d.bubbleStreams.count, 3)
        for i in 0..<10 { strike(&d, UInt8(30 + 5 * i), velocity: 1) }
        XCTAssertEqual(d.bubbleStreams.count, DeepLights.streamCap, "at most 6")

        // Through the submarine: the frame after the accent carries the one-shot, the next frame none, over a bed of
        // bubbles that is always up (a burst only sounds while it is).
        var sub = SubmarineWindowModel()
        let p = ThemeRegistry.parameterSet(for: SubmarineWindowModel.id, state: ThemeState())
        func frame(_ params: ParameterSet) -> SubFrame {
            sub.step(dt: 1.0 / 60, params: params, roles: RoleValues(), inputs: InputFrame(), quality: .high)
        }
        XCTAssertNil(frame(p).ambience.bubbleBurst)
        sub.handle(.noteOn(note: 72, velocity: 0.95))
        let after = frame(p)
        XCTAssertEqual(after.ambience.bubbleBurst ?? 0, 0.6 + 0.4 * 0.1 / 0.15, accuracy: 1e-5)
        XCTAssertEqual(after.bubbleStreams.count, 1)
        XCTAssertGreaterThan(after.ambience.level(.bubbles), 0)
        let next = frame(p)
        XCTAssertNil(next.ambience.bubbleBurst, "and the next frame carries none")
        XCTAssertEqual(next.bubbleStreams.count, 1)
        XCTAssertGreaterThan(next.ambience.level(.bubbles), 0)
        sub.handle(.noteOn(note: 74, velocity: 0.6))
        XCTAssertNil(frame(p).ambience.bubbleBurst, "a softer note raises none")
        // Under Galaxy Warp accents streak stars instead: no bubbles, no burst.
        let warp = ThemeRegistry.parameterSet(for: SubmarineWindowModel.id, state: ThemeState(values: ["visual": .choice("Galaxy Warp")]))
        _ = frame(warp)
        sub.handle(.noteOn(note: 76, velocity: 1))
        let warped = frame(warp)
        XCTAssertNil(warped.ambience.bubbleBurst)
        XCTAssertTrue(warped.bubbleStreams.isEmpty)
        XCTAssertNotNil(warped.warp)
    }

    /// A MIDI flood: at most 10 creatures released a step and 48 in the window (the dimmest let go first), only the
    /// latest notes waiting their turn; the shoals, siphonophores and bubble streams stay within their caps, and every
    /// brightness within 0…1.
    func testBurstIsRationed() {
        var d = DeepLights()
        d.pulse = InstrumentPulse(bpm: 118, gate: 0.6)
        for i in 0..<2000 { d.noteOn(UInt8(21 + i % 88), velocity: 0.9, at: Double(i) * 0.0005) }
        var before = 0
        for _ in 0..<60 {
            d.step(dt: 1.0 / 60, roles: RoleValues())
            XCTAssertLessThanOrEqual(d.lastSpawns, DeepLights.maxSpawnsPerStep)
            XCTAssertLessThanOrEqual(d.creatures.count - before, DeepLights.maxSpawnsPerStep)
            XCTAssertLessThanOrEqual(d.creatures.count, DeepLights.cap)
            XCTAssertLessThanOrEqual(d.shoals.count, DeepLights.shoalCap)
            XCTAssertTrue(d.shoals.allSatisfy { $0.contour.count <= DeepLights.shoalLights })
            XCTAssertLessThanOrEqual(d.siphonophores.count, DeepLights.siphonophoreCap)
            XCTAssertLessThanOrEqual(d.bubbleStreams.count, DeepLights.streamCap)
            XCTAssertTrue(d.creatures.allSatisfy { $0.glow >= 0 && $0.glow <= 1 })
            XCTAssertTrue(d.shoals.allSatisfy { $0.brightness >= 0 && $0.brightness <= 1 })
            XCTAssertTrue(d.siphonophores.allSatisfy { $0.brightness >= 0 && $0.brightness <= 1 })
            before = d.creatures.count
        }
        XCTAssertEqual(d.creatures.count, DeepLights.cap)
        // A second flood: the window stays full, the dimmest let go first.
        for i in 0..<100 { d.noteOn(UInt8(21 + i % 88), velocity: 0.5, at: d.time + 0.0005 * Double(i)) }
        run(&d, seconds: 0.5)
        XCTAssertEqual(d.creatures.count, DeepLights.cap)

        // The renderer's budget keeps the held and brightest, in their original order.
        var v = DeepLights()
        for i in 0..<24 { strike(&v, UInt8(40 + i), velocity: 0.6) }
        for i in stride(from: 0, to: 24, by: 2) { v.noteOff(UInt8(40 + i)) }
        run(&v, seconds: 1)
        let shown = DeepLights.visible(v.creatures, limit: 12)
        XCTAssertEqual(shown.count, 12)
        XCTAssertTrue(shown.allSatisfy { $0.held }, "the held creatures stay")
        XCTAssertEqual(shown.map(\.id), shown.map(\.id).sorted(), "in their original order")
        XCTAssertEqual(DeepLights.visible(v.creatures, limit: 100).count, v.creatures.count)
    }

    func testIdsWrap() throws {
        var d = DeepLights()
        d.nextID = Int.max - 2
        d.nextShoalID = Int.max
        d.nextSiphonophoreID = Int.max
        d.nextStreamID = Int.max - 1
        // A run of accents: creatures, a shoal and bubble streams, their ids wrapping past Int.max.
        for i in 0..<6 {
            strike(&d, UInt8(60 + 2 * i), velocity: 0.9)
            run(&d, seconds: 0.1)
        }
        XCTAssertEqual(d.creatures.count, 6)
        XCTAssertEqual(Set(d.creatures.map(\.id)).count, 6)
        XCTAssertTrue(d.creatures.contains { $0.id < 0 }, "wrapped")
        XCTAssertEqual(Set(d.bubbleStreams.map(\.id)).count, d.bubbleStreams.count)
        XCTAssertTrue(d.bubbleStreams.contains { $0.id < 0 })
        XCTAssertEqual(d.shoals.map(\.id), [Int.max])
        run(&d, seconds: 1)
        for i in 0..<4 {
            strike(&d, UInt8(70 - 2 * i))
            run(&d, seconds: 0.1)
        }
        XCTAssertEqual(d.shoals.last?.id, Int.min, "the next shoal's id wrapped")
        // Chords: siphonophores.
        for k in 0..<3 {
            let t = d.time + 0.01
            for (i, n) in [48, 52, 55].enumerated() { d.noteOn(UInt8(n + k), velocity: 0.7, at: t + 0.02 * Double(i)) }
            run(&d, seconds: 0.5)
        }
        XCTAssertEqual(d.siphonophores.count, 2)
        XCTAssertEqual(Set(d.siphonophores.map(\.id)).count, 2)
        XCTAssertTrue(d.siphonophores.allSatisfy { $0.id < 0 })
        // The sonar screen's blips too.
        var sub = SubmarineWindowModel()
        sub.nextBlipID = Int.max - 1
        for n: UInt8 in 60...63 { sub.handle(.noteOn(note: n, velocity: 0.7)) }
        let p = ThemeRegistry.parameterSet(for: SubmarineWindowModel.id, state: ThemeState())
        let f = sub.step(dt: 1.0 / 30, params: p, roles: RoleValues(), inputs: InputFrame(), quality: .high)
        XCTAssertEqual(f.sonarBlips.count, 4)
        XCTAssertEqual(Set(f.sonarBlips.map(\.id)).count, 4)
        XCTAssertTrue(f.sonarBlips.contains { $0.id < 0 })
    }
}
