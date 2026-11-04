import XCTest
import InStrumDSP

/// Polar Choir: a vowel pad with breath, bowed glass and a swell (docs/superpowers/briefs/polar-choir.md).
final class PolarChoirTests: XCTestCase {
    typealias R = SynthRender
    let choir = ISD_ENGINE_POLAR_CHOIR
    /// Dry: no reverb, no shimmer.
    let dry: [Int: Float] = [Int(ISD_P_SPACE): 0, Int(ISD_P_SHIMMER): 0]
    /// The voices alone (test hook): one saw through the formants; no breath, glass, chorus, drift or swell rise.
    var voicesOnly: [Int: Float] { var p = dry; p[Int(ISD_P_DEBUG_VOICES_ONLY)] = 1; return p }
    let chord = [56, 60, 63, 67, 72].map { SynthRender.noteOn(0, UInt8($0), 90) }

    private func midiHz(_ m: Double) -> Double { 440 * pow(2, (m - 69) / 12) }
    private func band(_ x: [Float], _ lo: Double, _ hi: Double) -> Double { DSPTestKit.bandEnergy(x, sampleRate: R.sr, from: lo, to: hi) }
    private func db(_ x: Double) -> Double { 10 * log10(max(x, 1e-30)) }

    /// The frequency of the strongest spectral line between two frequencies.
    private func strongest(_ x: [Float], from lo: Double, to hi: Double) -> Double {
        let n = 1 << 16, p = DSPTestKit.powerSpectrum(x, size: n), bin = R.sr / Double(n)
        var best = Int(lo / bin)
        for k in Int(lo / bin)...Int(hi / bin) where p[k] > p[best] { best = k }
        return Double(best) * bin
    }

    /// Renders like `SynthRender.render`, calling all-notes-off at `panicAt` and reading the voice count at `probe`.
    private func renderPanic(params: [Int: Float], events: [R.Event], seconds: Double, panicAt: Double?, probe: Double)
        -> (l: [Float], voices: Int32) {
        guard let s = isd_synth_create(choir, R.sr, 256) else { return ([], -1) }
        defer { isd_synth_destroy(s) }
        for (a, v) in params { isd_synth_set_param(s, Int32(a), v) }
        let total = Int(seconds * R.sr), sorted = events.sorted { $0.time < $1.time }
        var left = [Float](repeating: 0, count: total), right = left
        var e = 0, i = 0, panicked = false, voices: Int32 = -1
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
            if voices < 0, Double(i) / R.sr >= probe { voices = isd_synth_active_voices(s) }
        }
        return (left, voices)
    }

    // MARK: - Tuning

    func testTuningWithin2Cents() {
        for m: UInt8 in [45, 57, 69, 81] {
            let out = R.render(choir, seconds: 4, params: voicesOnly, events: [R.noteOn(0, m, 100)])
            let ref = midiHz(Double(m))
            let f = DSPTestKit.fundamental(R.slice(out.l, 1.0, 3.9), sampleRate: R.sr, near: ref)
            XCTAssertEqual(DSPTestKit.cents(f, ref), 0, accuracy: 2, "MIDI \(m)")
        }
    }

    func testFineTuneAndTransposeExact() {
        var p = voicesOnly; p[Int(ISD_P_FINE_TUNE)] = 37; p[Int(ISD_P_TRANSPOSE)] = 5
        let out = R.render(choir, seconds: 4, params: p, events: [R.noteOn(0, 57, 100)])
        let ref = midiHz(62)
        let f = DSPTestKit.fundamental(R.slice(out.l, 1.0, 3.9), sampleRate: R.sr, near: ref * pow(2, 37.0 / 1200))
        XCTAssertEqual(DSPTestKit.cents(f, ref) - 37, 0, accuracy: 1)
    }

    // MARK: - The voice

    /// On A3 (harmonics every 220 Hz) the strongest line follows F1 down from /a/ to /u/, and F2 up to /i/.
    func testVowelMorphMovesFormants() {
        func held(_ vowel: Float) -> [Float] {
            var p = voicesOnly; p[Int(ISD_P_VOWEL)] = vowel
            return R.slice(R.render(choir, seconds: 3, params: p, events: [R.noteOn(0, 57, 100)]).l, 1.0, 2.9)
        }
        let u = strongest(held(0), from: 300, to: 1000), a = strongest(held(0.5), from: 300, to: 1000)
        XCTAssertLessThan(u, 0.75 * a, "F1 at /u/ \(u) Hz, at /a/ \(a) Hz")
        let i = strongest(held(1), from: 1500, to: 3200)
        XCTAssertGreaterThan(i, 2000, "F2 at /i/ \(i) Hz")
    }

    func testBreathAddsAir() {
        func air(_ breath: Float) -> Double {
            var p = dry; p[Int(ISD_P_BREATH)] = breath
            return db(band(R.slice(R.render(choir, seconds: 3, params: p, events: chord).l, 1.0, 3.0), 2000, 6000))
        }
        let still = air(0), breathy = air(1)
        XCTAssertGreaterThan(breathy, still + 6, "breath 0: \(still) dB, breath 1: \(breathy) dB")
    }

    /// Swell 1 (the brief's measure: a 3 s attack, then the press); and Swell 0, whose 0.3 s attack is long over by
    /// 0.5 s, so its rise is the press alone.
    func testSwellRisesWhileHeld() {
        for swell: Float in [1, 0] {
            var p = dry; p[Int(ISD_P_SWELL)] = swell
            let out = R.render(choir, seconds: 4.5, params: p, events: [R.noteOn(0, 57, 100)]).l
            let early = DSPTestKit.dBFS(R.slice(out, 0.5, 1.0)), late = DSPTestKit.dBFS(R.slice(out, 4.0, 4.5))
            XCTAssertGreaterThan(late, early + 3, "swell \(swell): \(early) → \(late) dB")
        }
    }

    func testGlassAddsAPartial() {
        let f0 = midiHz(57), target = 4.2 * f0
        func held(_ glass: Float) -> [Float] {
            var p = dry; p[Int(ISD_P_GLASS)] = glass; p[Int(ISD_P_BREATH)] = 0
            return R.slice(R.render(choir, seconds: 3.5, params: p, events: [R.noteOn(0, 57, 100)]).l, 1.5, 3.5)
        }
        let with = held(1), without = held(0)
        let c = DSPTestKit.clusterCentre(with, sampleRate: R.sr, near: target, cents: 40)
        XCTAssertEqual(c / target, 1, accuracy: 0.02)
        let on = db(band(with, target * 0.98, target * 1.02)), off = db(band(without, target * 0.98, target * 1.02))
        XCTAssertGreaterThan(on, off + 12, "glass 0: \(off) dB, glass 1: \(on) dB")
    }

    // MARK: - Endings

    func testReleaseDecays() {
        let out = R.render(choir, seconds: 7.2, params: dry, events: [R.noteOn(0, 57, 100), R.noteOff(1, 57)]).l
        let held = DSPTestKit.dBFS(R.slice(out, 0.5, 1.0)), after = DSPTestKit.dBFS(R.slice(out, 7.0, 7.2))
        XCTAssertLessThan(after, held - 40, "held \(held) dB, 6 s after release \(after) dB")
    }

    /// Mid-swell (Swell 1, 1 s into a 3 s attack): all-notes-off, and CC 120 (all sound off), each end it.
    func testPanicStopsTheVoices() {
        var p = dry; p[Int(ISD_P_SWELL)] = 1
        let api = renderPanic(params: p, events: chord, seconds: 1.25, panicAt: 1.0, probe: 1.1)
        XCTAssertLessThan(DSPTestKit.dBFS(R.slice(api.l, 1.05, 1.2)), -70)
        XCTAssertEqual(api.voices, 0)
        let cc = renderPanic(params: p, events: chord + [R.Event(time: 1.0, bytes: [0xB0, 120, 0])], seconds: 1.25, panicAt: nil, probe: 1.1)
        XCTAssertLessThan(DSPTestKit.dBFS(R.slice(cc.l, 1.05, 1.2)), -70)
        XCTAssertEqual(cc.voices, 0)
    }

    // MARK: - Hygiene

    func testStealingIsClickFree() {
        let events = (0..<24).map { R.noteOn(Double($0) * 0.125, UInt8(40 + $0 * 2), 100) }
        let out = R.render(choir, seconds: 4, params: dry, events: events)
        XCTAssertTrue(out.l.allSatisfy(\.isFinite) && out.r.allSatisfy(\.isFinite))
        XCTAssertLessThan(DSPTestKit.maxJump(out.l), 0.2)
        XCTAssertLessThan(DSPTestKit.maxJump(out.r), 0.2)
        XCTAssertLessThanOrEqual(out.l.map { abs($0) }.max() ?? 2, 1.0)
    }

    func testDialSweepIsSmooth() {
        let dials = [ISD_P_VOWEL, ISD_P_BREATH, ISD_P_GLASS, ISD_P_SWELL, ISD_P_WIDTH].map { Int($0) }
        var start = dry
        for d in dials { start[d] = 0 }
        let changes = (dials + [Int(ISD_P_SPACE), Int(ISD_P_SHIMMER)]).map { SynthRender.ParamChange(time: 3.0, address: $0, value: 1) }
        let out = R.render(choir, seconds: 3.25, params: start, events: [R.noteOn(0, 57, 100), R.noteOn(0, 64, 100)], changes: changes)
        // Breath and glass legitimately add detail, so the change is compared with the sound it settles into.
        let before = DSPTestKit.maxJump(R.slice(out.l, 2.8, 2.95)), after = DSPTestKit.maxJump(R.slice(out.l, 2.95, 3.1))
        let settled = DSPTestKit.maxJump(R.slice(out.l, 3.1, 3.25))
        XCTAssertLessThan(after, 2 * max(before, settled) + 1e-4, "before \(before), after \(after), settled \(settled)")
    }

    func testParameterTable() {
        let count = Int(isd_synth_param_count(choir))
        let infos = (0..<count).compactMap { isd_synth_param_info(choir, Int32($0)) }.map { $0.pointee }
        XCTAssertEqual(infos.map { String(cString: $0.identifier) },
                       ["fineTune", "transpose", "vowel", "breath", "glass", "swell", "shimmer", "space", "width",
                        "moodEnergy", "moodWarmth", "moodBrightness", "moodSpace", "moodMotion", "debugVoicesOnly"])
        let defaults = Dictionary(uniqueKeysWithValues: infos.map { (String(cString: $0.identifier), $0.defaultValue) })
        XCTAssertEqual(defaults["vowel"], 0.55); XCTAssertEqual(defaults["breath"], 0.35); XCTAssertEqual(defaults["glass"], 0.30)
        XCTAssertEqual(defaults["swell"], 0.55); XCTAssertEqual(defaults["shimmer"], 0.25); XCTAssertEqual(defaults["space"], 0.60)
        XCTAssertEqual(defaults["width"], 0.60)
        XCTAssertEqual(infos.filter { $0.unit == 3 }.map(\.address), [Int32(ISD_P_DEBUG_VOICES_ONLY)], "the test hook is internal")
    }

    func testExtremesStayFinite() {
        for v: Float in [0, 1] {
            var p: [Int: Float] = [:]
            for a in [ISD_P_VOWEL, ISD_P_BREATH, ISD_P_GLASS, ISD_P_SWELL, ISD_P_SHIMMER, ISD_P_SPACE, ISD_P_WIDTH] { p[Int(a)] = v }
            var events: [R.Event] = [R.pedal(0.5, 127)]
            for i in 0..<12 { events.append(R.noteOn(0.01 + Double(i) * 0.05, UInt8(24 + i * 8), 127)) }
            let out = R.render(choir, seconds: 5, params: p, events: events)
            XCTAssertTrue(out.l.allSatisfy { $0.isFinite && abs($0) <= 1 } && out.r.allSatisfy { $0.isFinite && abs($0) <= 1 }, "dials at \(v)")
        }
    }
}
