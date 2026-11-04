import XCTest
import InStrumDSP

/// A biquad (transposed direct form II, in Double) for the spark detector's band.
private struct BandFilter {
    var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0, z1 = 0.0, z2 = 0.0

    init(highpass hz: Double, q: Double) {
        let w = 2 * Double.pi * hz / DSPTestKit.sampleRate, al = sin(w) / (2 * q), c = cos(w), a0 = 1 + al
        b0 = (1 + c) / 2 / a0; b1 = -(1 + c) / a0; b2 = (1 + c) / 2 / a0; a1 = -2 * c / a0; a2 = (1 - al) / a0
    }

    init(lowpass hz: Double, q: Double) {
        let w = 2 * Double.pi * hz / DSPTestKit.sampleRate, al = sin(w) / (2 * q), c = cos(w), a0 = 1 + al
        b0 = (1 - c) / 2 / a0; b1 = (1 - c) / a0; b2 = (1 - c) / 2 / a0; a1 = -2 * c / a0; a2 = (1 - al) / a0
    }

    mutating func run(_ x: Double) -> Double {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }
}

/// Plankton Keys: an electric piano with bark, sparks, tremolo and phase (docs/superpowers/briefs/plankton-keys.md).
final class PlanktonKeysTests: XCTestCase {
    typealias R = SynthRender
    let keys = ISD_ENGINE_PLANKTON_KEYS
    /// Dry: no reverb, no sparks, no tremolo, no phaser.
    let dry: [Int: Float] = [Int(ISD_P_SPACE): 0, Int(ISD_P_DEBUG_NO_SPARKLE): 1, Int(ISD_P_DEBUG_NO_TREMOLO): 1, Int(ISD_P_PHASE): 0]

    private func midiHz(_ m: Double) -> Double { 440 * pow(2, (m - 69) / 12) }
    private func band(_ x: [Float], _ lo: Double, _ hi: Double) -> Double { DSPTestKit.bandEnergy(x, sampleRate: R.sr, from: lo, to: hi) }
    private func db(_ x: Double) -> Double { 10 * log10(max(x, 1e-30)) }

    /// Renders like `SynthRender.render`, calling all-notes-off at `panicAt` and reading the voice count at `probe`.
    private func renderPanic(params: [Int: Float], events: [R.Event], seconds: Double, panicAt: Double?, probe: Double)
        -> (l: [Float], r: [Float], voices: Int32) {
        guard let s = isd_synth_create(keys, R.sr, 256) else { return ([], [], -1) }
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
        return (left, right, voices)
    }

    /// Onsets in the 3–12 kHz band between 15 and 120 ms (the sparks' window), from a note struck at 0 s: the mono sum
    /// through a 4th-order Butterworth high-pass at 3 kHz (twice) and a 12 kHz low-pass, 4 ms RMS windows every 2 ms; an
    /// onset is a window at least 6 dB above the quietest of the three that end before it starts, and no more than
    /// 40 dB under the note's level over 0–120 ms; onsets at least 8 ms apart.
    private func sparkOnsets(_ l: [Float], _ r: [Float]) -> Int {
        let x = zip(l, r).map { $0.0 + $0.1 }
        var filters = [BandFilter(highpass: 3000, q: 0.5412), BandFilter(highpass: 3000, q: 1.3066),
                       BandFilter(highpass: 3000, q: 0.5412), BandFilter(highpass: 3000, q: 1.3066),
                       BandFilter(lowpass: 12000, q: 0.7071)]
        var y = [Double](repeating: 0, count: x.count)
        for i in 0..<x.count {
            var v = Double(x[i])
            for k in 0..<filters.count { v = filters[k].run(v) }
            y[i] = v
        }
        let hop = 96, w = 192
        var e: [Double] = []
        var i = 0
        while i + w <= y.count {
            var s = 0.0
            for k in i..<(i + w) { s += y[k] * y[k] }
            e.append(10 * log10(s / Double(w) + 1e-30))
            i += hop
        }
        let whole = DSPTestKit.dBFS(R.slice(x, 0, 0.12))
        var count = 0, last = -100
        for j in 4..<e.count {
            let t = Double(j * hop + w) / R.sr
            guard t >= 0.015, t <= 0.12 else { continue }
            let quiet = min(e[j - 2], e[j - 3], e[j - 4])
            if e[j] >= quiet + 6, e[j] >= whole - 40, j - last >= 4 { count += 1; last = j }
        }
        return count
    }

    /// The time (s) at which the 50 ms RMS first falls 40 dB under its loudest so far, or -1.
    private func timeToMinus40(_ x: [Float]) -> Double {
        let w = Int(0.05 * R.sr)
        var peak = -200.0, i = 0
        while i + w <= x.count {
            let d = DSPTestKit.dBFS(x[i..<(i + w)])
            peak = max(peak, d)
            if d < peak - 40 { return Double(i) / R.sr }
            i += w
        }
        return -1
    }

    // MARK: - Tuning

    func testTuningWithin2Cents() {
        for m: UInt8 in [45, 57, 69, 81, 93] {
            let out = R.render(keys, seconds: 2, params: dry, events: [R.pedal(0, 127), R.noteOn(0.01, m, 100)])
            let ref = midiHz(Double(m))
            let f = DSPTestKit.fundamental(R.slice(out.l, 0.3, 1.9), sampleRate: R.sr, near: ref)
            XCTAssertEqual(DSPTestKit.cents(f, ref), 0, accuracy: 2, "MIDI \(m)")
        }
    }

    func testFineTuneAndTransposeExact() {
        var p = dry; p[Int(ISD_P_FINE_TUNE)] = 37; p[Int(ISD_P_TRANSPOSE)] = 5
        let out = R.render(keys, seconds: 2, params: p, events: [R.pedal(0, 127), R.noteOn(0.01, 57, 100)])
        let ref = midiHz(62)
        let f = DSPTestKit.fundamental(R.slice(out.l, 0.3, 1.9), sampleRate: R.sr, near: ref * pow(2, 37.0 / 1200))
        XCTAssertEqual(DSPTestKit.cents(f, ref) - 37, 0, accuracy: 1)
    }

    // MARK: - The tines

    /// A3 at velocity 40 against 120: the 2–6 kHz share of the first 120 ms (the band over the whole spectrum).
    func testHarderBarks() {
        func share(_ velocity: UInt8) -> Double {
            let x = R.slice(R.render(keys, seconds: 0.2, params: dry, events: [R.noteOn(0, 57, velocity)]).l, 0, 0.12)
            return db(band(x, 2000, 6000) / band(x, 0, 24000))
        }
        let soft = share(40), hard = share(120)
        XCTAssertGreaterThan(hard, soft + 8, "velocity 40: \(soft) dB, 120: \(hard) dB")
    }

    func testTineBalance() {
        func centroid(_ tine: Float) -> Double {
            var p = dry; p[Int(ISD_P_TINE)] = tine
            let out = R.render(keys, seconds: 0.6, params: p, events: [R.noteOn(0, 69, 100)])
            return DSPTestKit.centroid(R.slice(out.l, 0.2, 0.5), sampleRate: R.sr)
        }
        let bar = centroid(0), tine = centroid(1)
        XCTAssertGreaterThan(tine, 1.2 * bar, "tine 0: \(bar) Hz, tine 1: \(tine) Hz")
    }

    func testSparksFollowNotes() {
        func onsets(_ sparkle: Float) -> Int {
            var p = dry; p[Int(ISD_P_DEBUG_NO_SPARKLE)] = 0; p[Int(ISD_P_SPARKLE)] = sparkle
            let out = R.render(keys, seconds: 0.3, params: p, events: [R.noteOn(0, 76, 90)])
            return sparkOnsets(out.l, out.r)
        }
        XCTAssertGreaterThanOrEqual(onsets(1), 2)
        XCTAssertEqual(onsets(0), 0)
    }

    /// Tremolo 0.5 on a held note: the left/right balance ((L − R)/(L + R) of 5 ms RMS) repeats every 1/4.6 s.
    func testTremoloRate() {
        var p = dry; p[Int(ISD_P_DEBUG_NO_TREMOLO)] = 0; p[Int(ISD_P_TREMOLO)] = 0.5
        let out = R.render(keys, seconds: 3.2, params: p, events: [R.noteOn(0, 57, 100)])
        let w = 240
        var d: [Double] = []
        var i = Int(0.2 * R.sr)
        while i + w <= out.l.count {
            var a = 0.0, b = 0.0
            for k in i..<(i + w) { a += Double(out.l[k]) * Double(out.l[k]); b += Double(out.r[k]) * Double(out.r[k]) }
            a = a.squareRoot(); b = b.squareRoot()
            d.append((a - b) / (a + b + 1e-12))
            i += w
        }
        let mean = d.reduce(0, +) / Double(d.count)
        d = d.map { $0 - mean }
        let e0 = d.reduce(0) { $0 + $1 * $1 }
        var best = -2.0, bestLag = 0
        for lag in Int(0.1 * R.sr / Double(w))...Int(0.4 * R.sr / Double(w)) {
            var s = 0.0
            for j in 0..<(d.count - lag) { s += d[j] * d[j + lag] }
            if s / e0 > best { best = s / e0; bestLag = lag }
        }
        let period = Double(bestLag * w) / R.sr
        XCTAssertEqual(period, 1 / 4.6, accuracy: 0.1 / 4.6, "autocorrelation peak at \(period) s (r \(best))")
        XCTAssertGreaterThan(best, 0.5)
    }

    /// A3 with the pedal down falls 40 dB in 4–9 s; a note two octaves up dies sooner.
    func testDecayTime() {
        let a3 = timeToMinus40(R.render(keys, seconds: 9.5, params: dry, events: [R.pedal(0, 127), R.noteOn(0.01, 57, 100)]).l)
        XCTAssertGreaterThanOrEqual(a3, 4, "A3 reached −40 dB at \(a3) s")
        XCTAssertLessThanOrEqual(a3, 9, "A3 reached −40 dB at \(a3) s")
        let a5 = timeToMinus40(R.render(keys, seconds: 4, params: dry, events: [R.pedal(0, 127), R.noteOn(0.01, 81, 100)]).l)
        XCTAssertGreaterThan(a5, 0)
        XCTAssertLessThan(a5, a3, "A5 \(a5) s, A3 \(a3) s")
    }

    /// The dampers stop a released note: 40 dB down within 100–150 ms.
    func testReleaseDecays() {
        let out = R.render(keys, seconds: 1.3, params: dry, events: [R.noteOn(0, 57, 100), R.noteOff(1.0, 57)]).l
        let held = DSPTestKit.dBFS(R.slice(out, 0.9, 1.0)), after = DSPTestKit.dBFS(R.slice(out, 1.10, 1.15))
        XCTAssertLessThan(after, held - 40, "held \(held) dB, 100 ms after release \(after) dB")
    }

    // MARK: - Endings

    /// A 16-note burst with Sparkle 1 (sparks still waiting to land), then all-notes-off, or CC 120: silence by
    /// +50 ms and no voices.
    func testPanicStopsSparks() {
        let p: [Int: Float] = [Int(ISD_P_SPACE): 0, Int(ISD_P_SPARKLE): 1]
        let burst = (0..<16).map { R.noteOn(Double($0) * 0.01, UInt8(60 + $0 * 2), 110) }
        let api = renderPanic(params: p, events: burst, seconds: 0.45, panicAt: 0.2, probe: 0.3)
        XCTAssertLessThan(DSPTestKit.dBFS(R.slice(api.l, 0.25, 0.4)), -70)
        XCTAssertLessThan(DSPTestKit.dBFS(R.slice(api.r, 0.25, 0.4)), -70)
        XCTAssertEqual(api.voices, 0)
        let cc = renderPanic(params: p, events: burst + [R.Event(time: 0.2, bytes: [0xB0, 120, 0])], seconds: 0.45, panicAt: nil, probe: 0.3)
        XCTAssertLessThan(DSPTestKit.dBFS(R.slice(cc.l, 0.25, 0.4)), -70)
        XCTAssertLessThan(DSPTestKit.dBFS(R.slice(cc.r, 0.25, 0.4)), -70)
        XCTAssertEqual(cc.voices, 0)
    }

    // MARK: - Hygiene

    /// Loud two-hand chords four a second under the pedal fill the voices with ringing notes, then softer ones steal
    /// them: the quietest go first, so they must still be ringing for a missing fade to be heard, and soft chords have
    /// little bark of their own above 10 kHz. Each soft chord steals eight at once from a full pool; with six spare
    /// voices the steals past the sixth were cut dead, up to 7 dB over the same chords played without stealing. Every
    /// steal now fades (the g++ mirror: 0.0 dB at worst; with the 20 ms fade removed, +13).
    func testStealingIsClickFree() {
        let steal = R.stealClicks(keys, params: dry, velocities: [100, 100, 100, 30, 30, 30, 30], gap: 0.25, from: 3)
        XCTAssertTrue(steal.out.l.allSatisfy(\.isFinite) && steal.out.r.allSatisfy(\.isFinite))
        XCTAssertLessThanOrEqual(max(steal.out.l.map { abs($0) }.max() ?? 2, steal.out.r.map { abs($0) }.max() ?? 2), 1.0)
        XCTAssertLessThan(steal.clicks.max() ?? 99, 3, "dB over the chords without stealing: \(steal.clicks)")
    }

    /// Each dial jumps from 0 to 1 on a held pair of notes under the pedal: no millisecond above 10 kHz louder than
    /// the same notes with the dial held at either end (the g++ mirror: −8.8 dB at worst; without the 20 ms
    /// smoothing, Tine +18, Bark +17).
    func testDialSweepIsSmooth() {
        let notes = [R.pedal(0, 127), R.noteOn(0, 57, 100), R.noteOn(0, 64, 100)]
        let dials: [(name: String, address: Int)] = [("tine", Int(ISD_P_TINE)), ("bark", Int(ISD_P_BARK)), ("sparkle", Int(ISD_P_SPARKLE)),
                                                     ("tremolo", Int(ISD_P_TREMOLO)), ("phase", Int(ISD_P_PHASE)), ("width", Int(ISD_P_WIDTH)),
                                                     ("space", Int(ISD_P_SPACE))]
        for dial in dials {
            let click = R.jumpClick(keys, params: [Int(ISD_P_SPACE): 0], dial: dial.address, at: 1.5, events: notes)
            XCTAssertLessThan(click, 6, "\(dial.name): \(click) dB over the dial held still")
        }
    }

    func testParameterTable() {
        let count = Int(isd_synth_param_count(keys))
        let infos = (0..<count).compactMap { isd_synth_param_info(keys, Int32($0)) }.map { $0.pointee }
        XCTAssertEqual(infos.map { String(cString: $0.identifier) },
                       ["fineTune", "transpose", "tine", "bark", "sparkle", "tremolo", "phase", "space", "width",
                        "moodEnergy", "moodWarmth", "moodBrightness", "moodSpace", "moodMotion", "debugNoSparkle", "debugNoTremolo"])
        let defaults = Dictionary(uniqueKeysWithValues: infos.map { (String(cString: $0.identifier), $0.defaultValue) })
        XCTAssertEqual(defaults["tine"], 0.55); XCTAssertEqual(defaults["bark"], 0.40); XCTAssertEqual(defaults["sparkle"], 0.50)
        XCTAssertEqual(defaults["tremolo"], 0.35); XCTAssertEqual(defaults["phase"], 0.20); XCTAssertEqual(defaults["space"], 0.50)
        XCTAssertEqual(defaults["width"], 0.55)
        XCTAssertEqual(infos.filter { $0.unit == 3 }.map(\.address), [Int32(ISD_P_DEBUG_NO_SPARKLE), Int32(ISD_P_DEBUG_NO_TREMOLO)],
                       "the test hooks are internal")
    }

    func testExtremesStayFinite() {
        for v: Float in [0, 1] {
            var p: [Int: Float] = [:]
            for a in [ISD_P_TINE, ISD_P_BARK, ISD_P_SPARKLE, ISD_P_TREMOLO, ISD_P_PHASE, ISD_P_SPACE, ISD_P_WIDTH,
                      ISD_P_MOOD_ENERGY, ISD_P_MOOD_WARMTH, ISD_P_MOOD_BRIGHTNESS, ISD_P_MOOD_SPACE, ISD_P_MOOD_MOTION] { p[Int(a)] = v }
            var events: [R.Event] = [R.pedal(0.5, 127)]
            for i in 0..<12 { events.append(R.noteOn(0.01 + Double(i) * 0.05, UInt8(24 + i * 8), 127)) }
            let out = R.render(keys, seconds: 5, params: p, events: events)
            XCTAssertTrue(out.l.allSatisfy { $0.isFinite && abs($0) <= 1 } && out.r.allSatisfy { $0.isFinite && abs($0) <= 1 }, "dials at \(v)")
        }
    }
}
