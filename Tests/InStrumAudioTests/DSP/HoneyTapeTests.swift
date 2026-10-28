import XCTest
import InStrumDSP

/// Honey Tape: flute and strings voices through a shared tape (docs/superpowers/briefs/honey-tape.md).
final class HoneyTapeTests: XCTestCase {
    typealias R = SynthRender
    let tape = ISD_ENGINE_HONEY_TAPE
    let dry: [Int: Float] = [Int(ISD_P_SPACE): 0]
    /// A plain flute: no strings, no wow, no vibrato (for pitch measurements).
    var flute: [Int: Float] {
        [Int(ISD_P_SPACE): 0, Int(ISD_P_STRINGS): 0, Int(ISD_P_WOW): 0, Int(ISD_P_DEBUG_NO_VIBRATO): 1]
    }

    private func midiHz(_ m: Double) -> Double { 440 * pow(2, (m - 69) / 12) }

    private func rms(_ x: [Float]) -> Double {
        (x.reduce(0) { $0 + Double($1) * Double($1) } / Double(max(1, x.count))).squareRoot()
    }

    /// Frequency over spans of `cycles` periods, from rising zero crossings (linear interpolation).
    private func instantaneousCents(_ x: [Float], ref: Double, cycles: Int = 8) -> [Double] {
        var crossings: [Double] = []
        for i in 1..<x.count where x[i - 1] < 0 && x[i] >= 0 {
            crossings.append(Double(i - 1) + Double(-x[i - 1] / (x[i] - x[i - 1])))
        }
        guard crossings.count > cycles else { return [] }
        return (cycles..<crossings.count).map { i in
            let hz = Double(cycles) * R.sr / (crossings[i] - crossings[i - cycles])
            return DSPTestKit.cents(hz, ref)
        }
    }

    /// Share of the energy lying between the harmonics (outside ±3% of k·f0, k = 1…24).
    private func interHarmonicShare(_ x: [Float], f0: Double) -> Double {
        let n = 1 << 16, binHz = R.sr / Double(n)
        let spectrum = DSPTestKit.powerSpectrum(Array(x.prefix(n)), size: n)
        var total = 0.0, between = 0.0
        for (i, p) in spectrum.enumerated() where i > 0 {
            let f = Double(i) * binHz
            total += p
            let k = (f / f0).rounded()
            if k < 1 || k > 24 || abs(f - k * f0) > 0.03 * k * f0 { between += p }
        }
        return between / max(total, 1e-30)
    }

    /// Energy of harmonics `ks` (±2% each).
    private func harmonicEnergy(_ x: [Float], f0: Double, _ ks: ClosedRange<Int>) -> Double {
        ks.reduce(0) { sum, k in
            sum + DSPTestKit.bandEnergy(x, sampleRate: R.sr, from: Double(k) * f0 * 0.98, to: Double(k) * f0 * 1.02)
        }
    }

    func testTuningWithin2Cents() {
        for m: UInt8 in [48, 60, 72, 84] {
            let out = R.render(tape, seconds: 3, params: flute, events: [R.noteOn(0, m, 100)])
            let ref = midiHz(Double(m))
            let f = DSPTestKit.fundamental(R.slice(out.l, 0.5, 2.5), sampleRate: R.sr, near: ref)
            XCTAssertEqual(DSPTestKit.cents(f, ref), 0, accuracy: 2, "flute MIDI \(m)")
        }
        var strings = flute; strings[Int(ISD_P_STRINGS)] = 1
        for m: UInt8 in [48, 60, 72] {
            let out = R.render(tape, seconds: 5, params: strings, events: [R.noteOn(0, m, 100)])
            let ref = midiHz(Double(m))
            let centre = DSPTestKit.clusterCentre(R.slice(out.l, 1.0, 4.5), sampleRate: R.sr, near: ref)
            XCTAssertEqual(DSPTestKit.cents(centre, ref), 0, accuracy: 2, "strings MIDI \(m)")
        }
    }

    func testFineTuneAndTransposeExact() {
        var p = flute; p[Int(ISD_P_FINE_TUNE)] = 37; p[Int(ISD_P_TRANSPOSE)] = 5
        let out = R.render(tape, seconds: 3, params: p, events: [R.noteOn(0, 60, 100)])
        let ref = midiHz(65)
        let f = DSPTestKit.fundamental(R.slice(out.l, 0.5, 2.5), sampleRate: R.sr, near: ref * pow(2, 37.0 / 1200))
        XCTAssertEqual(DSPTestKit.cents(f, ref) - 37, 0, accuracy: 1)
    }

    func testSofterIsDarker() {
        let soft = R.render(tape, seconds: 1.6, params: dry, events: [R.noteOn(0, 67, 40)])
        let hard = R.render(tape, seconds: 1.6, params: dry, events: [R.noteOn(0, 67, 120)])
        let cs = DSPTestKit.averageCentroid(R.slice(soft.l, 0.3, 1.5), sampleRate: R.sr)
        let ch = DSPTestKit.averageCentroid(R.slice(hard.l, 0.3, 1.5), sampleRate: R.sr)
        XCTAssertLessThan(cs, 0.85 * ch, "soft \(cs) Hz, hard \(ch) Hz")
    }

    func testBreathAddsAir() {
        var p = flute; p[Int(ISD_P_AGE)] = 0
        p[Int(ISD_P_BREATH)] = 0
        let still = R.render(tape, seconds: 2.5, params: p, events: [R.noteOn(0, 69, 100)])
        p[Int(ISD_P_BREATH)] = 1
        let airy = R.render(tape, seconds: 2.5, params: p, events: [R.noteOn(0, 69, 100)])
        let a = interHarmonicShare(R.slice(still.l, 0.8, 2.4), f0: 440), b = interHarmonicShare(R.slice(airy.l, 0.8, 2.4), f0: 440)
        XCTAssertGreaterThan(10 * log10(b / max(a, 1e-30)), 6, "breath 0 share \(a), breath 1 share \(b)")
    }

    func testStringsBlend() {
        var p = flute; p[Int(ISD_P_BREATH)] = 0
        let flutey = R.render(tape, seconds: 3, params: p, events: [R.noteOn(0, 57, 100)])
        p[Int(ISD_P_STRINGS)] = 1
        let stringy = R.render(tape, seconds: 3, params: p, events: [R.noteOn(0, 57, 100)])
        func tilt(_ x: [Float]) -> Double {
            10 * log10(harmonicEnergy(x, f0: 220, 5...10) / max(harmonicEnergy(x, f0: 220, 1...2), 1e-30))
        }
        let a = tilt(R.slice(flutey.l, 1.5, 2.9)), b = tilt(R.slice(stringy.l, 1.5, 2.9))
        XCTAssertGreaterThan(b - a, 10, "flute \(a) dB, strings \(b) dB")
    }

    /// Wow ±12 cents and flutter ±3 at the top of the dial: half the dial peaks near 7.5 cents.
    func testWowDepthFollowsTheDial() {
        var p = flute; p[Int(ISD_P_BREATH)] = 0; p[Int(ISD_P_AGE)] = 0
        let still = R.render(tape, seconds: 5, params: p, events: [R.noteOn(0, 69, 100)])
        let stillPeak = instantaneousCents(R.slice(still.l, 1, 5), ref: 440).map { abs($0) }.max() ?? 99
        XCTAssertLessThan(stillPeak, 1, "wow 0")
        p[Int(ISD_P_WOW)] = 0.5
        let wobbly = R.render(tape, seconds: 5, params: p, events: [R.noteOn(0, 69, 100)])
        let peak = instantaneousCents(R.slice(wobbly.l, 1, 5), ref: 440).map { abs($0) }.max() ?? 0
        XCTAssertEqual(peak, 7.5, accuracy: 1.5, "wow 0.5")
    }

    func testReelRunsOut() {
        var p = dry; p[Int(ISD_P_REEL)] = 1
        let out = R.render(tape, seconds: 9.2, params: p, events: [R.noteOn(0, 60, 100)])
        let held = rms(R.slice(out.l, 1, 2)), after = rms(R.slice(out.l, 8.5, 9.0))
        XCTAssertLessThan(20 * log10(max(after, 1e-12) / held), -60, "reel 1")
        p[Int(ISD_P_REEL)] = 0
        let endless = R.render(tape, seconds: 9.2, params: p, events: [R.noteOn(0, 60, 100)])
        let drop = 20 * log10(max(rms(R.slice(endless.l, 8.5, 9.0)), 1e-12) / rms(R.slice(endless.l, 1, 2)))
        XCTAssertGreaterThan(drop, -30, "reel 0")
    }

    func testReelRunsOutEvenWithThePedal() {
        var p = dry; p[Int(ISD_P_REEL)] = 1
        let out = R.render(tape, seconds: 9.2, params: p, events: [R.pedal(0, 127), R.noteOn(0.01, 60, 100), R.noteOff(0.5, 60)])
        let held = rms(R.slice(out.l, 1, 2)), after = rms(R.slice(out.l, 8.5, 9.0))
        XCTAssertLessThan(20 * log10(max(after, 1e-12) / held), -60)
    }

    func testPanicDuringReelFadeLeavesNoVoices() {
        guard let s = isd_synth_create(tape, R.sr, 256) else { return XCTFail("no Honey Tape") }
        defer { isd_synth_destroy(s) }
        isd_synth_set_param(s, Int32(ISD_P_REEL), 1)
        var l = [Float](repeating: 0, count: 256), r = l
        func run(until seconds: Double, from start: inout Int) {
            while Double(start) / R.sr < seconds {
                l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
                    isd_synth_render(s, lp.baseAddress!, rp.baseAddress!, 256) } }
                start += 256
            }
        }
        for (i, n) in [48, 52, 55, 60, 64, 67, 72, 76].enumerated() {
            let bytes: [UInt8] = [0x90, UInt8(n), 100]
            bytes.withUnsafeBufferPointer { isd_synth_midi(s, $0.baseAddress, 3, Int32(i)) }
        }
        var at = 0
        run(until: 8.1, from: &at)
        XCTAssertGreaterThan(isd_synth_active_voices(s), 0, "still fading at 8.1 s")
        isd_synth_all_notes_off(s)
        run(until: 8.4, from: &at)
        XCTAssertEqual(isd_synth_active_voices(s), 0)
    }

    /// The tape saturates softly: a chord sounds like the sum of its notes. An mf four-note chord (the brief's
    /// play-along shape) stays within 5% distortion and 1 dB of the sum; a forte two-hand chord within 10%.
    func testChordsStayClean() {
        var p = flute; p[Int(ISD_P_BREATH)] = 0
        let cases: [([UInt8], UInt8, Double)] = [([37, 44, 49, 52], 90, 0.05), ([49, 56, 61, 64, 68, 73], 127, 0.10)]
        for (notes, velocity, limit) in cases {
            let chord = R.render(tape, seconds: 1.5, params: p, events: notes.map { R.noteOn(0, $0, velocity) })
            var sum = [Float](repeating: 0, count: chord.l.count)
            for n in notes {
                let one = R.render(tape, seconds: 1.5, params: p, events: [R.noteOn(0, n, velocity)])
                for i in sum.indices { sum[i] += one.l[i] }
            }
            let c = R.slice(chord.l, 0.6, 1.4), s = R.slice(sum, 0.6, 1.4)
            let residual = zip(c, s).map { $0 - $1 }
            let distortion = rms(residual) / rms(s)
            XCTAssertLessThan(distortion, limit, "\(notes.count) notes at velocity \(velocity): \(distortion)")
            XCTAssertEqual(20 * log10(rms(c) / rms(s)), 0, accuracy: 1, "\(notes.count) notes keep their level")
        }
    }

    /// Age lays a soft bed of hiss under the notes: audible at Age 1 (between −72 and −56 dBFS between the
    /// harmonics of a soft A4), absent at Age 0.
    func testAgeAddsAudibleHiss() {
        func betweenHarmonics(age: Float) -> Double {
            var p = flute; p[Int(ISD_P_BREATH)] = 0; p[Int(ISD_P_AGE)] = age
            let out = R.render(tape, seconds: 3, params: p, events: [R.noteOn(0, 69, 60)])
            let x = R.slice(out.l, 1, 2.5)
            let n = 1 << 16, binHz = R.sr / Double(n)
            let spectrum = DSPTestKit.powerSpectrum(Array(x.prefix(n)), size: n)
            var total = 0.0, hiss = 0.0
            for (i, p) in spectrum.enumerated() where i > 0 {
                let f = Double(i) * binHz
                total += p
                let k = (f / 440).rounded()
                if f >= 2000, f <= 5500, abs(f - k * 440) > 0.03 * k * 440 { hiss += p }
            }
            // The share of the note's power lying between the harmonics, as a level.
            return DSPTestKit.dBFS(Array(x.prefix(n))) + 10 * log10(max(hiss, 1e-30) / max(total, 1e-30))
        }
        let aged = betweenHarmonics(age: 1), clean = betweenHarmonics(age: 0)
        XCTAssertGreaterThan(aged, -72, "hiss at Age 1: \(aged) dBFS")
        XCTAssertLessThan(aged, -56, "hiss at Age 1 stays a soft bed: \(aged) dBFS")
        XCTAssertGreaterThan(aged - clean, 10, "Age 0 has none: \(clean) dBFS")
    }

    func testReleaseDecays() {
        let out = R.render(tape, seconds: 3.2, params: dry, events: [R.noteOn(0, 60, 100), R.noteOff(1, 60)])
        XCTAssertLessThan(DSPTestKit.dBFS(R.slice(out.l, 3.0, 3.2)), -90)
    }

    func testStealingIsClickFree() {
        let events = (0..<24).map { R.noteOn(Double($0) * 0.125, UInt8(40 + $0 * 2), 100) }
        let out = R.render(tape, seconds: 4, params: dry, events: events)
        XCTAssertTrue(out.l.allSatisfy(\.isFinite) && out.r.allSatisfy(\.isFinite))
        XCTAssertLessThan(DSPTestKit.maxJump(out.l), 0.2)
        XCTAssertLessThan(DSPTestKit.maxJump(out.r), 0.2)
        XCTAssertLessThanOrEqual(out.l.map { abs($0) }.max() ?? 2, 1.0)
    }

    func testDialSweepIsSmooth() {
        let dials = [ISD_P_BREATH, ISD_P_STRINGS, ISD_P_WOW, ISD_P_AGE, ISD_P_WIDTH].map { Int($0) }
        var start = dry
        for d in dials { start[d] = 0 }
        let changes = dials.map { SynthRender.ParamChange(time: 3.0, address: $0, value: 1) }
        let out = R.render(tape, seconds: 3.25, params: start, events: [R.noteOn(0, 57, 100)], changes: changes)
        let before = DSPTestKit.maxJump(R.slice(out.l, 2.8, 2.95)), after = DSPTestKit.maxJump(R.slice(out.l, 2.95, 3.1))
        let settled = DSPTestKit.maxJump(R.slice(out.l, 3.1, 3.25))
        XCTAssertLessThan(after, 2 * max(before, settled) + 1e-4, "before \(before), after \(after), settled \(settled)")
    }

    func testParameterTable() {
        let count = Int(isd_synth_param_count(tape))
        let infos = (0..<count).compactMap { isd_synth_param_info(tape, Int32($0)) }.map { $0.pointee }
        let shown = infos.filter { $0.unit != 3 }
        XCTAssertEqual(shown.map { String(cString: $0.identifier) },
                       ["fineTune", "transpose", "breath", "strings", "wow", "age", "reel", "space", "width",
                        "moodEnergy", "moodWarmth", "moodBrightness", "moodSpace", "moodMotion"])
        let defaults = Dictionary(uniqueKeysWithValues: shown.map { (String(cString: $0.identifier), $0.defaultValue) })
        XCTAssertEqual(defaults["breath"], 0.45); XCTAssertEqual(defaults["strings"], 0.30); XCTAssertEqual(defaults["wow"], 0.35)
        XCTAssertEqual(defaults["age"], 0.40); XCTAssertEqual(defaults["reel"], 0); XCTAssertEqual(defaults["space"], 0.50)
        XCTAssertEqual(defaults["width"], 0.50)
        XCTAssertEqual(infos.filter { $0.unit == 3 }.map(\.address), [201], "the test hook is internal")
    }

    func testExtremesStayFinite() {
        let dials = [ISD_P_BREATH, ISD_P_STRINGS, ISD_P_WOW, ISD_P_AGE, ISD_P_REEL, ISD_P_SPACE, ISD_P_WIDTH].map { Int($0) }
        for value: Float in [0, 1] {
            let p = Dictionary(uniqueKeysWithValues: dials.map { ($0, value) })
            let events = (0..<10).map { R.noteOn(Double($0) * 0.05, UInt8(36 + $0 * 6), 127) }
            let out = R.render(tape, seconds: 5, params: p, events: events)
            XCTAssertTrue(out.l.allSatisfy { $0.isFinite && abs($0) <= 1 } && out.r.allSatisfy { $0.isFinite && abs($0) <= 1 }, "dials at \(value)")
        }
    }
}
