import XCTest
import InStrumDSP

/// Cabin Felt: an upright felt piano with a top-voice flugelhorn (docs/superpowers/briefs/cabin-felt.md).
final class CabinFeltTests: XCTestCase {
    typealias R = SynthRender
    let cabin = ISD_ENGINE_CABIN_FELT
    /// Clean piano: no reverb, no mechanics, no horn.
    let dry: [Int: Float] = [Int(ISD_P_SPACE): 0, Int(ISD_P_DEBUG_NO_MECHANICS): 1, Int(ISD_P_HORN): 0]
    /// The horn on its own.
    let hornOnly: [Int: Float] = [Int(ISD_P_SPACE): 0, Int(ISD_P_HORN): 1, Int(ISD_P_DEBUG_HORN_ONLY): 1]

    private func midiHz(_ m: Double) -> Double { 440 * pow(2, (m - 69) / 12) }
    private func band(_ x: [Float], _ lo: Double, _ hi: Double) -> Double { DSPTestKit.bandEnergy(x, sampleRate: R.sr, from: lo, to: hi) }
    private func db(_ x: Double) -> Double { 10 * log10(max(x, 1e-30)) }

    /// Renders like `SynthRender.render`, reading a debug count at each probe time (at the block that contains it),
    /// and optionally calling all-notes-off at a time.
    private func renderProbing(seconds: Double, params: [Int: Float], events: [R.Event], probes: [Double],
                               which: ISDDebugCount = ISD_DEBUG_HORN_NOTE, panicAt: Double? = nil)
        -> (out: [Float], values: [Int32]) {
        guard let s = isd_synth_create(cabin, R.sr, 256) else { return ([], []) }
        defer { isd_synth_destroy(s) }
        for (a, v) in params { isd_synth_set_param(s, Int32(a), v) }
        let total = Int(seconds * R.sr), sorted = events.sorted { $0.time < $1.time }
        var left = [Float](repeating: 0, count: total), right = left
        var values: [Int32] = [], pending = probes.sorted(), e = 0, i = 0, panicked = false
        while i < total {
            let n = min(256, total - i)
            if let p = panicAt, !panicked, Int(p * R.sr) < i + n { isd_synth_all_notes_off(s); panicked = true }
            while e < sorted.count, Int(sorted[e].time * R.sr) < i + n {
                let off = max(0, Int(sorted[e].time * R.sr) - i)
                sorted[e].bytes.withUnsafeBufferPointer { isd_synth_midi(s, $0.baseAddress, Int32($0.count), Int32(off)) }
                e += 1
            }
            left.withUnsafeMutableBufferPointer { lp in
                right.withUnsafeMutableBufferPointer { rp in isd_synth_render(s, lp.baseAddress! + i, rp.baseAddress! + i, Int32(n)) }
            }
            i += n
            while let p = pending.first, Double(i) / R.sr >= p { values.append(isd_synth_debug_count(s, which)); pending.removeFirst() }
        }
        return (left, values)
    }

    // MARK: - Piano

    func testTuningWithin2Cents() {
        for m: UInt8 in [36, 48, 60, 72, 84] {
            let out = R.render(cabin, seconds: 1.6, params: dry, events: [R.pedal(0, 127), R.noteOn(0.01, m, 100)])
            let ref = midiHz(Double(m))
            let f = DSPTestKit.fundamental(R.slice(out.l, 0.3, 1.5), sampleRate: R.sr, near: ref)
            XCTAssertEqual(DSPTestKit.cents(f, ref), 0, accuracy: 2, "MIDI \(m)")
        }
    }

    func testFineTuneAndTransposeExact() {
        var p = dry; p[Int(ISD_P_FINE_TUNE)] = 37; p[Int(ISD_P_TRANSPOSE)] = 5
        let out = R.render(cabin, seconds: 1.6, params: p, events: [R.pedal(0, 127), R.noteOn(0.01, 60, 100)])
        let ref = midiHz(65)
        let f = DSPTestKit.fundamental(R.slice(out.l, 0.3, 1.5), sampleRate: R.sr, near: ref * pow(2, 37.0 / 1200))
        XCTAssertEqual(DSPTestKit.cents(f, ref) - 37, 0, accuracy: 1)
    }

    func testHarderIsBrighter() {
        let soft = R.render(cabin, seconds: 0.2, params: dry, events: [R.noteOn(0, 66, 40)])
        let hard = R.render(cabin, seconds: 0.2, params: dry, events: [R.noteOn(0, 66, 120)])
        let cs = DSPTestKit.centroid(R.slice(soft.l, 0, 0.08), sampleRate: R.sr)
        let ch = DSPTestKit.centroid(R.slice(hard.l, 0, 0.08), sampleRate: R.sr)
        XCTAssertGreaterThan(ch, 1.3 * cs, "soft \(cs) Hz, hard \(ch) Hz")
    }

    func testFeltSoftensTheStrike() {
        var bare = dry; bare[Int(ISD_P_FELT)] = 0
        var felt = dry; felt[Int(ISD_P_FELT)] = 1
        let a = R.slice(R.render(cabin, seconds: 0.2, params: bare, events: [R.noteOn(0, 66, 100)]).l, 0, 0.08)
        let b = R.slice(R.render(cabin, seconds: 0.2, params: felt, events: [R.noteOn(0, 66, 100)]).l, 0, 0.08)
        let ca = DSPTestKit.centroid(a, sampleRate: R.sr), cb = DSPTestKit.centroid(b, sampleRate: R.sr)
        XCTAssertLessThan(cb, 0.8 * ca, "felt 0: \(ca) Hz, felt 1: \(cb) Hz")
        XCTAssertLessThan(DSPTestKit.dBFS(b), DSPTestKit.dBFS(a) - 3)
    }

    /// The key thump at the strike and the damper's felt chuff at the release, close and quiet.
    func testMechanicsAreThere() {
        var on = dry; on[Int(ISD_P_DEBUG_NO_MECHANICS)] = 0
        let events = [R.noteOn(0, 60, 100), R.noteOff(1.0, 60)]
        let with = R.render(cabin, seconds: 1.2, params: on, events: events).l
        let without = R.render(cabin, seconds: 1.2, params: dry, events: events).l
        XCTAssertGreaterThan(db(band(R.slice(with, 0, 0.02), 40, 150)), db(band(R.slice(without, 0, 0.02), 40, 150)) + 3, "key thump")
    }

    /// The damper's chuff is there, but well under the note it stops (final review: it was louder than the note).
    func testDamperChuffIsQuiet() {
        var on = dry; on[Int(ISD_P_DEBUG_NO_MECHANICS)] = 0
        let events = [R.noteOn(0, 60, 110), R.noteOff(3.0, 60)]
        let with = R.render(cabin, seconds: 3.3, params: on, events: events).l
        let without = R.render(cabin, seconds: 3.3, params: dry, events: events).l
        let a = R.slice(with, 3.0, 3.025), b = R.slice(without, 3.0, 3.025)
        let chuff = DSPTestKit.dBFS(zip(a, b).map { $0 - $1 }), note = DSPTestKit.dBFS(R.slice(without, 2.95, 3.0))
        XCTAssertLessThan(chuff, note - 10, "chuff \(chuff) dB, note \(note) dB")
        XCTAssertGreaterThan(chuff, note - 40, "the chuff is still there")
    }

    /// Lifting the pedal off a big chord lands every damper at once: it never gets louder.
    func testPedalUpNeverGetsLouder() {
        var events = [R.pedal(0, 127)]
        for n: UInt8 in [48, 52, 55, 60, 64, 67, 71, 72] { events += [R.noteOn(0.01, n, 100), R.noteOff(0.5, n)] }
        events.append(R.pedal(2.0, 0))
        let out = R.render(cabin, seconds: 2.4, params: [Int(ISD_P_SPACE): 0, Int(ISD_P_HORN): 0], events: events).l
        let before = DSPTestKit.dBFS(R.slice(out, 1.98, 2.0)), after = DSPTestKit.dBFS(R.slice(out, 2.0, 2.02))
        XCTAssertLessThanOrEqual(after, before + 0.5)
        let peakBefore = R.slice(out, 1.9, 2.0).map(abs).max() ?? 0, peakAfter = R.slice(out, 2.0, 2.05).map(abs).max() ?? 0
        XCTAssertLessThanOrEqual(peakAfter, peakBefore * 1.05)
    }

    // MARK: - Horn

    func testHornTakesTheHighestWhenPressed() {
        let events = [R.noteOn(0, 60, 100), R.noteOn(0, 64, 100), R.noteOn(0, 67, 100), R.noteOn(0.5, 55, 100), R.noteOff(1.0, 67)]
        let r = renderProbing(seconds: 1.7, params: hornOnly, events: events, probes: [0.1, 0.7, 1.2])
        XCTAssertEqual(r.values, [67, 67, -1])
        XCTAssertLessThan(DSPTestKit.dBFS(R.slice(r.out, 1.4, 1.6)), -60, "the horn never drops to a lower held note")
    }

    /// A chord's notes arrive bottom-first (in one sample, or rolled a few ms apart): the horn lands on the top note at
    /// once instead of sliding up through the chord (final review).
    func testHornLandsOnTheTopOfAChord() {
        for gap in [0.0, 0.008] {
            let out = R.render(cabin, seconds: 0.3, params: hornOnly,
                               events: [R.noteOn(0, 60, 100), R.noteOn(gap, 64, 100), R.noteOn(2 * gap, 67, 100)]).l
            let w = R.slice(out, 0.03, 0.07)
            XCTAssertGreaterThan(band(w, 370, 420), 4 * band(w, 250, 345), "rolled \(gap) s apart")
        }
    }

    /// A detached melody re-attacks while the last note is still dying away: no click (final review).
    func testHornReattacksWithoutAClick() {
        var worst: Float = 0
        for gap in [0.0, 0.0005, 0.002, 0.005, 0.01, 0.02] {
            let out = R.render(cabin, seconds: 0.6, params: hornOnly,
                               events: [R.noteOn(0, 67, 100), R.noteOff(0.3, 67), R.noteOn(0.3 + gap, 69, 100)]).l
            let steady = DSPTestKit.maxJump(R.slice(out, 0.15, 0.28))
            worst = max(worst, DSPTestKit.maxJump(R.slice(out, 0.3 + gap - 0.0005, 0.3 + gap + 0.003)) / steady)
        }
        XCTAssertLessThan(worst, 1.2, "the re-attack's step against the steady note's")
    }

    /// A slur from a soft note to a hard one swells over a few ms rather than jumping in one sample.
    func testHornSlurSwellsSmoothly() {
        let out = R.render(cabin, seconds: 1.0, params: hornOnly, events: [R.noteOn(0, 67, 40), R.noteOn(0.5, 69, 127)]).l
        let before = DSPTestKit.dBFS(R.slice(out, 0.498, 0.5)), after = DSPTestKit.dBFS(R.slice(out, 0.5, 0.502))
        XCTAssertLessThan(after - before, 3)
    }

    /// A rising line past the horn's top (C6 → D6) folds D6 down an octave: the horn starts it afresh instead of
    /// gliding down through the octave (final review).
    func testHornNeverGlidesTheWrongWay() {
        let out = R.render(cabin, seconds: 0.9, params: hornOnly, events: [R.noteOn(0, 84, 100), R.noteOn(0.5, 86, 100)]).l
        let w = R.slice(out, 0.52, 0.57)
        XCTAssertLessThan(band(w, 640, 1000), 0.25 * band(w, 560, 615))
    }

    func testHornSlursLegato() {
        let out = R.render(cabin, seconds: 1.4, params: hornOnly, events: [R.noteOn(0, 67, 100), R.noteOn(1.0, 72, 100)]).l
        let f = DSPTestKit.fundamental(R.slice(out, 1.09, 1.20), sampleRate: R.sr, near: midiHz(72))
        XCTAssertEqual(DSPTestKit.cents(f, midiHz(72)), 0, accuracy: 10)
        let before = DSPTestKit.dBFS(R.slice(out, 0.9, 1.0))
        for k in 0..<12 {
            let t = 0.98 + Double(k) * 0.01
            XCTAssertGreaterThan(DSPTestKit.dBFS(R.slice(out, t, t + 0.01)), before - 6, "no re-attack gap at \(t) s")
        }
    }

    func testHornScoopsIntoFreshNotes() {
        let out = R.render(cabin, seconds: 0.4, params: hornOnly, events: [R.noteOn(0, 69, 100)]).l
        let early = DSPTestKit.cents(DSPTestKit.fundamental(R.slice(out, 0.005, 0.025), sampleRate: R.sr, near: 440), 440)
        let settled = DSPTestKit.cents(DSPTestKit.fundamental(R.slice(out, 0.12, 0.22), sampleRate: R.sr, near: 440), 440)
        XCTAssertTrue((-60 ... -20).contains(early), "starts \(early) cents")
        XCTAssertEqual(settled, 0, accuracy: 5)
    }

    func testHornBrightensWithVelocity() {
        let soft = R.render(cabin, seconds: 0.7, params: hornOnly, events: [R.noteOn(0, 66, 40)]).l
        let hard = R.render(cabin, seconds: 0.7, params: hornOnly, events: [R.noteOn(0, 66, 120)]).l
        let cs = DSPTestKit.centroid(R.slice(soft, 0.3, 0.6), sampleRate: R.sr)
        let ch = DSPTestKit.centroid(R.slice(hard, 0.3, 0.6), sampleRate: R.sr)
        XCTAssertGreaterThan(ch, 1.25 * cs, "soft \(cs) Hz, hard \(ch) Hz")
    }

    func testHornFoldsIntoItsRange() {
        for (key, sounds) in [(UInt8(96), 84.0), (UInt8(40), 52.0)] {
            let r = renderProbing(seconds: 0.5, params: hornOnly, events: [R.noteOn(0, key, 100)], probes: [0.3])
            let f = DSPTestKit.fundamental(R.slice(r.out, 0.2, 0.45), sampleRate: R.sr, near: midiHz(sounds))
            XCTAssertEqual(DSPTestKit.cents(f, midiHz(sounds)), 0, accuracy: 5, "MIDI \(key)")
            XCTAssertEqual(r.values, [Int32(sounds)])
        }
    }

    func testHornOffAtZero() {
        var p = hornOnly; p[Int(ISD_P_HORN)] = 0
        let out = R.render(cabin, seconds: 0.6, params: p, events: [R.noteOn(0, 67, 110)]).l
        XCTAssertLessThan(DSPTestKit.dBFS(out), -90)
    }

    func testPanicStopsTheHorn() {
        let r = renderProbing(seconds: 1.3, params: hornOnly, events: [R.noteOn(0, 67, 100)], probes: [1.06], panicAt: 1.0)
        XCTAssertEqual(r.values, [-1])
        XCTAssertLessThan(DSPTestKit.dBFS(R.slice(r.out, 1.05, 1.2)), -70)
        let cc = R.render(cabin, seconds: 1.3, params: hornOnly, events: [R.noteOn(0, 67, 100), R.Event(time: 1.0, bytes: [0xB0, 120, 0])]).l
        XCTAssertLessThan(DSPTestKit.dBFS(R.slice(cc, 1.05, 1.2)), -70)
    }

    // MARK: - Hygiene

    func testReleaseDecays() {
        let out = R.render(cabin, seconds: 3.2, params: [Int(ISD_P_SPACE): 0], events: [R.noteOn(0, 60, 100), R.noteOff(1, 60)]).l
        XCTAssertLessThan(DSPTestKit.dBFS(R.slice(out, 3.0, 3.2)), -90)
    }

    /// As Felt Glass's: 40 notes 50 ms apart, pedal down, so voices are stolen while ringing.
    func testStealingIsClickFree() {
        var events = [R.pedal(0, 127)]
        for i in 0..<40 { events.append(R.noteOn(Double(i) * 0.05, UInt8(36 + i), 90)) }
        let out = R.render(cabin, seconds: 3, params: [Int(ISD_P_SPACE): 0, Int(ISD_P_HORN): 0], events: events)
        XCTAssertTrue(out.l.allSatisfy(\.isFinite) && out.r.allSatisfy(\.isFinite))
        XCTAssertLessThan(DSPTestKit.maxJump(out.l), 0.2)
        XCTAssertLessThan(DSPTestKit.maxJump(out.r), 0.2)
    }

    func testDialSweepIsSmooth() {
        let dials = [ISD_P_FELT, ISD_P_HORN, ISD_P_FIRE, ISD_P_WOOD, ISD_P_SPACE, ISD_P_WIDTH].map { Int($0) }
        var start: [Int: Float] = [:]
        for d in dials { start[d] = 0 }
        start[Int(ISD_P_HORN)] = 0.2
        let changes = dials.map { SynthRender.ParamChange(time: 3.0, address: $0, value: 1) }
        let out = R.render(cabin, seconds: 3.25, params: start, events: [R.noteOn(0, 57, 100), R.noteOn(0, 64, 100)], changes: changes)
        let before = DSPTestKit.maxJump(R.slice(out.l, 2.8, 2.95)), after = DSPTestKit.maxJump(R.slice(out.l, 2.95, 3.1))
        let settled = DSPTestKit.maxJump(R.slice(out.l, 3.1, 3.25))
        XCTAssertLessThan(after, 2 * max(before, settled) + 1e-4, "before \(before), after \(after), settled \(settled)")
    }

    func testParameterTable() {
        let count = Int(isd_synth_param_count(cabin))
        let infos = (0..<count).compactMap { isd_synth_param_info(cabin, Int32($0)) }.map { $0.pointee }
        XCTAssertEqual(infos.map { String(cString: $0.identifier) },
                       ["fineTune", "transpose", "felt", "horn", "fire", "wood", "space", "width",
                        "moodEnergy", "moodWarmth", "moodBrightness", "moodSpace", "moodMotion", "debugNoMechanics", "debugHornOnly"])
        let defaults = Dictionary(uniqueKeysWithValues: infos.map { (String(cString: $0.identifier), $0.defaultValue) })
        XCTAssertEqual(defaults["felt"], 0.60); XCTAssertEqual(defaults["horn"], 0.30); XCTAssertEqual(defaults["fire"], 0.50)
        XCTAssertEqual(defaults["wood"], 0.50); XCTAssertEqual(defaults["space"], 0.35); XCTAssertEqual(defaults["width"], 0.50)
        XCTAssertEqual(infos.filter { $0.unit == 3 }.map { String(cString: $0.identifier) }, ["debugNoMechanics", "debugHornOnly"])
    }

    func testExtremesStayFinite() {
        for v: Float in [0, 1] {
            var p: [Int: Float] = [:]
            for a in [ISD_P_FELT, ISD_P_HORN, ISD_P_FIRE, ISD_P_WOOD, ISD_P_SPACE, ISD_P_WIDTH] { p[Int(a)] = v }
            var events: [R.Event] = [R.pedal(0.5, 127)]
            for i in 0..<10 { events.append(R.noteOn(Double(i) * 0.1, UInt8(30 + i * 7), 127)) }
            let out = R.render(cabin, seconds: 5, params: p, events: events)
            XCTAssertTrue(out.l.allSatisfy { $0.isFinite && abs($0) <= 1 } && out.r.allSatisfy { $0.isFinite && abs($0) <= 1 }, "dials at \(v)")
        }
    }
}
