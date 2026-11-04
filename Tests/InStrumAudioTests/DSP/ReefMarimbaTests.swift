import XCTest
import InStrumDSP

/// A biquad high-pass (transposed direct form II, in Double) for the roll detector.
private struct HighPass {
    var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0, z1 = 0.0, z2 = 0.0

    init(_ hz: Double, q: Double) {
        let w = 2 * Double.pi * hz / DSPTestKit.sampleRate, al = sin(w) / (2 * q), c = cos(w), a0 = 1 + al
        b0 = (1 + c) / 2 / a0; b1 = -(1 + c) / a0; b2 = (1 + c) / 2 / a0; a1 = -2 * c / a0; a2 = (1 - al) / a0
    }

    mutating func run(_ x: Double) -> Double {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }
}

/// Reef Marimba: rosewood bars over tuned tubes on the modal mallet core, rolling under held notes
/// (docs/superpowers/briefs/reef-marimba.md). Every bound was measured first with the C++ mirror (g++ and clang).
final class ReefMarimbaTests: XCTestCase {
    typealias R = SynthRender
    let marimba = ISD_ENGINE_REEF_MARIMBA
    /// No reverb, no rolls.
    let dry: [Int: Float] = [Int(ISD_P_SPACE): 0, Int(ISD_P_DEBUG_NO_ROLL): 1]
    /// The bars alone (no tube, steel, untuned modes or reverb), no rolls.
    let bar: [Int: Float] = [Int(ISD_P_DEBUG_BAR_ONLY): 1, Int(ISD_P_DEBUG_NO_ROLL): 1]

    private func midiHz(_ m: Double) -> Double { 440 * pow(2, (m - 69) / 12) }
    private func db(_ x: Double) -> Double { 10 * log10(max(x, 1e-30)) }

    /// Band power from the kit's Blackman–Harris spectrum (a plain FFT leaks the fundamental, and the tube's bloom,
    /// into a quiet band).
    private func quietBand(_ x: [Float], _ lo: Double, _ hi: Double, size: Int) -> Double {
        let p = DSPTestKit.powerSpectrum(x, size: size), bin = R.sr / Double(2 * p.count)
        var sum = 0.0
        for (k, e) in p.enumerated() {
            let f = Double(k) * bin
            if f >= lo && f <= hi { sum += e }
        }
        return sum
    }

    /// The strongest peak between `lo` and `hi` Hz (Blackman–Harris, zero-padded to 2^18, parabolic interpolation).
    private func peak(_ x: [Float], _ lo: Double, _ hi: Double) -> Double {
        let p = DSPTestKit.powerSpectrum(x, size: 1 << 18), bin = R.sr / Double(2 * p.count)
        let a = max(1, Int(lo / bin)), b = min(p.count - 2, Int(hi / bin) + 1)
        guard a < b else { return 0 }
        var best = a
        for i in a...b where p[i] > p[best] { best = i }
        let l = log(p[best - 1] + 1e-30), c = log(p[best] + 1e-30), r = log(p[best + 1] + 1e-30)
        let d = l - 2 * c + r
        return (Double(best) + (d != 0 ? 0.5 * (l - r) / d : 0)) * bin
    }

    /// The T60 of the partial near `hz` (± 6%): 2048-sample Blackman–Harris frames every 10 ms from `a` to `b`
    /// seconds, the band's power in dB, a least-squares line.
    private func t60(_ x: [Float], _ hz: Double, from a: Double, to b: Double) -> Double {
        let n = 2048, span = Double(n) / R.sr
        var times: [Double] = [], levels: [Double] = []
        var t0 = a
        while t0 + span <= b + 1e-9 {
            times.append(t0)
            levels.append(db(quietBand(R.slice(x, t0, t0 + span), hz * 0.94, hz * 1.06, size: n)))
            t0 += 0.01
        }
        let mt = times.reduce(0, +) / Double(times.count), ml = levels.reduce(0, +) / Double(levels.count)
        var sxy = 0.0, sxx = 0.0
        for (t, l) in zip(times, levels) { sxy += (t - mt) * (l - ml); sxx += (t - mt) * (t - mt) }
        return -60 / (sxy / sxx)
    }

    /// A roll's strokes: the mono sum through an 8th-order Butterworth high-pass at 2.5 × f0 (two 4th-order stages: the
    /// fundamental falls 64 dB, while the bar's upper modes, which every stroke strikes afresh, come through); 5 ms RMS
    /// windows every 2.5 ms; an onset is a window at least 6 dB above the quietest of the four that end before it
    /// starts, within 50 dB of the loudest window and at least 40 ms after the last onset. Returns the windows' start
    /// times from `from` seconds.
    private func onsets(_ l: [Float], _ r: [Float], f0: Double, from: Double) -> [Double] {
        var stages = [HighPass(2.5 * f0, q: 0.5412), HighPass(2.5 * f0, q: 1.3066),
                      HighPass(2.5 * f0, q: 0.5412), HighPass(2.5 * f0, q: 1.3066)]
        var y = [Double](repeating: 0, count: min(l.count, r.count))
        for i in 0..<y.count {
            var v = Double(l[i]) + Double(r[i])
            for k in 0..<stages.count { v = stages[k].run(v) }
            y[i] = v
        }
        let hop = 120, w = 240
        var e: [Double] = []
        var i = 0
        while i + w <= y.count {
            var s = 0.0
            for k in i..<(i + w) { s += y[k] * y[k] }
            e.append(10 * log10(s / Double(w) + 1e-30))
            i += hop
        }
        guard e.count > 5 else { return [] }
        let loud = e.max() ?? -300
        var times: [Double] = [], last = -1000
        for j in 5..<e.count {
            let start = Double(j * hop) / R.sr
            guard start >= from else { continue }
            let quiet = min(e[j - 2], e[j - 3], e[j - 4], e[j - 5])
            if e[j] >= quiet + 6, e[j] >= loud - 50, j - last >= 16 { times.append(start); last = j }
        }
        return times
    }

    private func rate(_ t: [Double]) -> Double { t.count < 2 ? 0 : Double(t.count - 1) / (t[t.count - 1] - t[0]) }

    /// Renders in 256-sample blocks like `SynthRender.render` (all-notes-off at `panicAt`), reading the bars sounding
    /// after every block. A steal point is a note-on that lands while 32 bars are sounding.
    private func renderCounting(params: [Int: Float], events: [R.Event], seconds: Double, panicAt: Double? = nil)
        -> (l: [Float], r: [Float], counts: [Int32], steals: [Double]) {
        guard let s = isd_synth_create(marimba, R.sr, 256) else { return ([], [], [], []) }
        defer { isd_synth_destroy(s) }
        for (a, v) in params { isd_synth_set_param(s, Int32(a), v) }
        let total = Int(seconds * R.sr), sorted = events.sorted { $0.time < $1.time }
        var left = [Float](repeating: 0, count: total), right = left
        var counts: [Int32] = [], steals: [Double] = []
        var e = 0, i = 0, sounding: Int32 = 0, panicked = false
        while i < total {
            let n = min(256, total - i)
            if let p = panicAt, !panicked, Int(p * R.sr) < i + n { isd_synth_all_notes_off(s); panicked = true }
            while e < sorted.count, Int(sorted[e].time * R.sr) < i + n {
                if sorted[e].bytes[0] == 0x90, sounding >= 32 { steals.append(sorted[e].time) }
                let off = max(0, Int(sorted[e].time * R.sr) - i)
                sorted[e].bytes.withUnsafeBufferPointer { isd_synth_midi(s, $0.baseAddress, Int32($0.count), Int32(off)) }
                e += 1
            }
            left.withUnsafeMutableBufferPointer { lp in
                right.withUnsafeMutableBufferPointer { rp in isd_synth_render(s, lp.baseAddress! + i, rp.baseAddress! + i, Int32(n)) }
            }
            i += n
            sounding = isd_synth_active_voices(s)
            counts.append(sounding)
        }
        return (left, right, counts, steals)
    }

    // MARK: - The bars

    func testReefMarimbaTuning() {
        for m: UInt8 in [36, 48, 60, 72, 84, 96] {
            let out = R.render(marimba, seconds: 1.2, params: dry, events: [R.noteOn(0.01, m, 100)])
            let ref = midiHz(Double(m))
            let f = DSPTestKit.fundamental(R.slice(out.l, 0.02, 1.2), sampleRate: R.sr, near: ref)
            XCTAssertEqual(DSPTestKit.cents(f, ref), 0, accuracy: 2, "MIDI \(m)")
        }
    }

    func testFineTuneAndTransposeExact() {
        var p = dry; p[Int(ISD_P_FINE_TUNE)] = 37; p[Int(ISD_P_TRANSPOSE)] = 5
        let out = R.render(marimba, seconds: 1.2, params: p, events: [R.noteOn(0.01, 57, 100)])
        let ref = midiHz(62)
        let f = DSPTestKit.fundamental(R.slice(out.l, 0.02, 1.2), sampleRate: R.sr, near: ref * pow(2, 37.0 / 1200))
        XCTAssertEqual(DSPTestKit.cents(f, ref) - 37, 0, accuracy: 1)
    }

    /// A3 struck hard, a little off centre, bars alone: the 1 : 4 : 10 tuning (the third partial is 10.0 up to C4,
    /// 9.2 from C5; the brief's 9.2–10 is held to the same ±0.02 as the second).
    func testBarPartialsAreOneFourTen() {
        var p = bar; p[Int(ISD_P_MALLET)] = 1; p[Int(ISD_P_STRIKE)] = 0.5
        let out = R.render(marimba, seconds: 0.5, params: p, events: [R.noteOn(0, 57, 110)])
        let x = R.slice(out.l, 0.005, 0.3), f0 = midiHz(57)
        XCTAssertEqual(peak(x, 0.95 * f0, 1.05 * f0) / f0, 1, accuracy: 0.002)
        XCTAssertEqual(peak(x, 3.8 * f0, 4.2 * f0) / f0, 3.99, accuracy: 0.02)
        let third = peak(x, 8.8 * f0, 10.4 * f0) / f0
        XCTAssertTrue((9.18...10.02).contains(third), "third partial at \(third) × f0")
    }

    /// Bork: the 4× partial decays 4 times faster than the fundamental and the third partial 10 times (the mirror
    /// reads 0.2505 and 0.1000).
    func testUpperPartialsDieFaster() {
        var p = bar; p[Int(ISD_P_MALLET)] = 1; p[Int(ISD_P_STRIKE)] = 0.5
        let x = R.render(marimba, seconds: 1.4, params: p, events: [R.noteOn(0, 57, 110)]).l
        let f0 = midiHz(57)
        let t1 = t60(x, f0, from: 0.1, to: 1.3), t2 = t60(x, 3.99 * f0, from: 0.03, to: 0.4), t3 = t60(x, 10 * f0, from: 0.02, to: 0.16)
        XCTAssertEqual(t2 / t1, 0.25, accuracy: 0.05, "T60s: fundamental \(t1) s, 4× \(t2) s")
        XCTAssertEqual(t3 / t1, 0.1, accuracy: 0.025, "T60s: fundamental \(t1) s, third \(t3) s")
    }

    /// A3: the 2–6 kHz power over the first 50 ms, hard rubber against soft yarn (the mirror: 36 dB).
    func testHardMalletIsBrighter() {
        func band(_ mallet: Float) -> Double {
            var p = dry; p[Int(ISD_P_MALLET)] = mallet
            let x = R.slice(R.render(marimba, seconds: 0.1, params: p, events: [R.noteOn(0, 57, 100)]).l, 0, 0.05)
            return db(quietBand(x, 2000, 6000, size: 4096))
        }
        let soft = band(0), hard = band(1)
        XCTAssertGreaterThan(hard, soft + 12, "2–6 kHz: Mallet 0 \(soft) dB, Mallet 1 \(hard) dB")
    }

    /// Struck at the centre, the second bending mode sits on its node: the 4× partial is gone.
    func testCentreStrikeSilencesTheDoubleOctave() {
        func twoOctaves(_ strike: Float) -> Double {
            var p = bar; p[Int(ISD_P_STRIKE)] = strike
            let x = R.slice(R.render(marimba, seconds: 0.35, params: p, events: [R.noteOn(0, 57, 100)]).l, 0.01, 0.3)
            let f = 3.99 * midiHz(57)
            return db(quietBand(x, f * 0.98, f * 1.02, size: 16384))
        }
        let centre = twoOctaves(0), standard = twoOctaves(0.5)
        XCTAssertLessThan(centre, standard - 20, "4× partial: Strike 0 \(centre) dB, Strike 0.5 \(standard) dB")
    }

    /// The resonator's bloom on A3's fundamental over the first second (the mirror: +9.0 dB at Tube 1).
    func testTubeBlooms() {
        func fundamental(_ tube: Float) -> Double {
            var p = dry; p[Int(ISD_P_TUBE)] = tube
            let x = R.slice(R.render(marimba, seconds: 1, params: p, events: [R.noteOn(0, 57, 100)]).l, 0, 1)
            return db(DSPTestKit.bandEnergy(x, sampleRate: R.sr, from: 220 * 0.97, to: 220 * 1.03))
        }
        let pop = fundamental(0), bloom = fundamental(1)
        XCTAssertGreaterThan(bloom, pop + 6, "fundamental: Tube 0 \(pop) dB, Tube 1 \(bloom) dB")
    }

    // MARK: - The roll and the steel

    /// A3 held, bars alone: it rolls after 0.3 s at 9–13 Hz (the mirror: 11.2 Hz at Roll .5); Roll 0 never rolls;
    /// full pressure speeds the roll (the mirror: 16.2 Hz).
    func testHeldNotesRoll() {
        func strokes(_ roll: Float, pressure: Bool = false) -> [Double] {
            var events = [R.noteOn(0, 57, 100)]
            if pressure { events.append(R.Event(time: 0.1, bytes: [0xD0, 127])) }
            let out = R.render(marimba, seconds: 1.6, params: [Int(ISD_P_DEBUG_BAR_ONLY): 1, Int(ISD_P_ROLL): roll], events: events)
            return onsets(out.l, out.r, f0: midiHz(57), from: 0.05)
        }
        let rolled = strokes(0.5)
        XCTAssertGreaterThanOrEqual(rolled.count, 12, "strokes at \(rolled)")
        XCTAssertGreaterThanOrEqual(rolled.first ?? 0, 0.29, "nothing rolls before 0.3 s: \(rolled)")
        XCTAssertTrue((9...13).contains(rate(rolled)), "Roll .5 rolls at \(rate(rolled)) Hz")
        XCTAssertEqual(strokes(0).count, 0, "Roll 0: the bar just rings")
        let pressed = strokes(0.5, pressure: true)
        XCTAssertGreaterThanOrEqual(rate(pressed), rate(rolled) + 2, "pressure: \(rate(pressed)) Hz against \(rate(rolled)) Hz")
    }

    /// A3: at Steel 1 the octave sounds at −20 dB or more against the fundamental (the mirror: −14.8 dB); at Steel 0
    /// there is none (the bar has no 2× mode).
    func testSteelAddsTheOctave() {
        func octave(_ steel: Float) -> Double {
            var p = dry; p[Int(ISD_P_STEEL)] = steel
            let x = R.slice(R.render(marimba, seconds: 0.6, params: p, events: [R.noteOn(0, 57, 100)]).l, 0, 0.5)
            return db(quietBand(x, 440 * 0.98, 440 * 1.02, size: 32768)) - db(quietBand(x, 220 * 0.98, 220 * 1.02, size: 32768))
        }
        let steel = octave(1), wood = octave(0)
        XCTAssertGreaterThanOrEqual(steel, -20, "Steel 1: the octave at \(steel) dB")
        XCTAssertLessThan(wood, -40, "Steel 0: the octave at \(wood) dB")
    }

    func testNotesOutsideTheRangeFold() {
        for (outside, inside) in [(UInt8(24), UInt8(36)), (UInt8(108), UInt8(96))] {
            let a = R.render(marimba, seconds: 1, params: dry, events: [R.noteOn(0.01, outside, 100)])
            let b = R.render(marimba, seconds: 1, params: dry, events: [R.noteOn(0.01, inside, 100)])
            XCTAssertLessThan(R.maxAbsDifference(a.l, b.l), 1e-6, "MIDI \(outside) sounds MIDI \(inside)")
            let ref = midiHz(Double(inside))
            let f = DSPTestKit.fundamental(R.slice(a.l, 0.02, 1), sampleRate: R.sr, near: ref)
            XCTAssertEqual(DSPTestKit.cents(f, ref), 0, accuracy: 2, "MIDI \(outside)")
        }
    }

    // MARK: - Hygiene

    /// Review focus 6: four rolling notes under a 64-note run at 20 notes a second, at the default dials. The run fills
    /// the pool, so bars are stolen (quietest first, held bars last, with 20 ms fades): never more than 32 sound, and no
    /// sample-to-sample jump over 0.25 where one was stolen (the mirror: 32 steals, the largest jump 0.063).
    func testRollsAndRunsStealCleanly() {
        var events = [48, 55, 60, 64].map { R.noteOn(0, UInt8($0), 100) }
        for i in 0..<64 {
            let t = 0.5 + 0.05 * Double(i), n = UInt8(36 + i)
            events += [R.noteOn(t, n, 100), R.noteOff(t + 0.04, n)]
        }
        let out = renderCounting(params: [:], events: events, seconds: 4.5)
        XCTAssertTrue(out.l.allSatisfy(\.isFinite) && out.r.allSatisfy(\.isFinite))
        let most = out.counts.max() ?? 0
        XCTAssertLessThanOrEqual(most, 32, "never more than 32 bars sounding")
        XCTAssertEqual(most, 32, "the run fills the pool")
        XCTAssertFalse(out.steals.isEmpty, "bars were stolen")
        for t in out.steals {
            let jump = max(DSPTestKit.maxJump(R.slice(out.l, t - 0.005, t + 0.03)), DSPTestKit.maxJump(R.slice(out.r, t - 0.005, t + 0.03)))
            XCTAssertLessThan(jump, 0.25, "a click where a bar was stolen at \(t) s")
        }
    }

    /// A rolling chord, then all-notes-off (or CC 120, with the reverb up): silent by +50 ms with no bars left, and the
    /// keys still down never roll again.
    func testPanicStopsRolls() {
        let chord = [48, 55, 60, 64].map { R.noteOn(0, UInt8($0), 110) }
        let api = renderCounting(params: [Int(ISD_P_SPACE): 0], events: chord, seconds: 1.3, panicAt: 1.0)
        XCTAssertLessThan(DSPTestKit.dBFS(R.slice(api.l, 1.05, 1.3)), -70)
        XCTAssertLessThan(DSPTestKit.dBFS(R.slice(api.r, 1.05, 1.3)), -70)
        XCTAssertEqual(api.counts[Int(1.1 * R.sr) / 256], 0)
        let cc = renderCounting(params: [:], events: chord + [R.Event(time: 1.0, bytes: [0xB0, 120, 0])], seconds: 1.3)
        XCTAssertLessThan(DSPTestKit.dBFS(R.slice(cc.l, 1.05, 1.3)), -70, "the reverb empties too")
        XCTAssertLessThan(DSPTestKit.dBFS(R.slice(cc.r, 1.05, 1.3)), -70, "the reverb empties too")
        XCTAssertEqual(cc.counts[Int(1.1 * R.sr) / 256], 0)
    }

    /// Bars don't bend: the wheel changes nothing.
    func testBarsIgnoreTheWheel() {
        let notes = [R.noteOn(0.05, 60, 90), R.noteOn(0.06, 64, 80), R.noteOn(0.07, 67, 70),
                     R.noteOff(1.0, 60), R.noteOff(1.0, 64), R.noteOff(1.0, 67)]
        let wheel = [R.Event(time: 0.2, bytes: [0xE0, 0x7F, 0x7F]), R.Event(time: 0.5, bytes: [0xE0, 0x00, 0x00]),
                     R.Event(time: 0.7, bytes: [0xE0, 0x00, 0x40])]
        let plain = R.render(marimba, seconds: 1.5, events: notes)
        let bent = R.render(marimba, seconds: 1.5, events: notes + wheel)
        XCTAssertLessThan(R.maxAbsDifference(plain.l, bent.l), 1e-6)
        XCTAssertLessThan(R.maxAbsDifference(plain.r, bent.r), 1e-6)
    }

    func testReefMarimbaRendersFinite() {
        let dials = [ISD_P_MALLET, ISD_P_STRIKE, ISD_P_TUBE, ISD_P_ROLL, ISD_P_STEEL, ISD_P_SPACE, ISD_P_WIDTH,
                     ISD_P_MOOD_ENERGY, ISD_P_MOOD_WARMTH, ISD_P_MOOD_BRIGHTNESS, ISD_P_MOOD_SPACE, ISD_P_MOOD_MOTION].map { Int($0) }
        for v: Float in [0, 1] {
            let p = Dictionary(uniqueKeysWithValues: dials.map { ($0, v) })
            // Twelve fortissimo notes across (and past) the range, held so they roll, then full pressure.
            var events = [R.Event(time: 0.5, bytes: [0xD0, 127])]
            for i in 0..<12 { events.append(R.noteOn(0.01 + Double(i) * 0.05, UInt8(24 + i * 8), 127)) }
            let out = R.render(marimba, seconds: 4, params: p, events: events)
            XCTAssertTrue(out.l.allSatisfy { $0.isFinite && abs($0) <= 1 } && out.r.allSatisfy { $0.isFinite && abs($0) <= 1 }, "dials at \(v)")
        }
    }

    func testParameterTable() {
        let count = Int(isd_synth_param_count(marimba))
        let infos = (0..<count).compactMap { isd_synth_param_info(marimba, Int32($0)) }.map { $0.pointee }
        XCTAssertEqual(infos.map { String(cString: $0.identifier) },
                       ["fineTune", "transpose", "mallet", "strike", "tube", "roll", "steel", "space", "width",
                        "moodEnergy", "moodWarmth", "moodBrightness", "moodSpace", "moodMotion", "debugNoRoll", "debugBarOnly"])
        let defaults = Dictionary(uniqueKeysWithValues: infos.map { (String(cString: $0.identifier), $0.defaultValue) })
        XCTAssertEqual(defaults["mallet"], 0.45); XCTAssertEqual(defaults["strike"], 0.40); XCTAssertEqual(defaults["tube"], 0.70)
        XCTAssertEqual(defaults["roll"], 0.35); XCTAssertEqual(defaults["steel"], 0.20); XCTAssertEqual(defaults["space"], 0.35)
        XCTAssertEqual(defaults["width"], 0.55)
        XCTAssertEqual(infos.filter { $0.unit == 3 }.map(\.address), [Int32(ISD_P_DEBUG_NO_ROLL), Int32(ISD_P_DEBUG_BAR_ONLY)],
                       "the test hooks are internal")
    }
}
