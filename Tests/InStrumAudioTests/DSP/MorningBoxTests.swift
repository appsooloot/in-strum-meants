import XCTest
import InStrumDSP

/// Morning Box: a celesta (or music box) over a warm synth wall that builds as you play
/// (docs/superpowers/briefs/morning-box.md).
final class MorningBoxTests: XCTestCase {
    typealias R = SynthRender
    let morning = ISD_ENGINE_MORNING_BOX
    /// Dry: no reverb, no haze.
    let dry: [Int: Float] = [Int(ISD_P_SPACE): 0, Int(ISD_P_HAZE): 0]
    var boxOnly: [Int: Float] { var p = dry; p[Int(ISD_P_DEBUG_BOX_ONLY)] = 1; return p }
    var wallOnly: [Int: Float] { var p = dry; p[Int(ISD_P_DEBUG_WALL_ONLY)] = 1; return p }

    private func midiHz(_ m: Double) -> Double { 440 * pow(2, (m - 69) / 12) }
    private func band(_ x: [Float], _ lo: Double, _ hi: Double) -> Double { DSPTestKit.bandEnergy(x, sampleRate: R.sr, from: lo, to: hi) }
    private func db(_ x: Double) -> Double { 10 * log10(max(x, 1e-30)) }

    /// Renders and reads a debug count at each probe time (at the end of the block that reaches it).
    private func renderProbing(seconds: Double, params: [Int: Float], events: [R.Event], probes: [Double],
                               which: ISDDebugCount = ISD_DEBUG_BUILD_PERMILLE, panicAt: Double? = nil)
        -> (l: [Float], r: [Float], values: [Int32], voicesAfterPanic: Int32) {
        guard let s = isd_synth_create(morning, R.sr, 256) else { return ([], [], [], -1) }
        defer { isd_synth_destroy(s) }
        for (a, v) in params { isd_synth_set_param(s, Int32(a), v) }
        let total = Int(seconds * R.sr), sorted = events.sorted { $0.time < $1.time }
        var left = [Float](repeating: 0, count: total), right = left
        var values: [Int32] = [], pending = probes.sorted(), e = 0, i = 0, panicked = false, voices: Int32 = -1
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
            if let p = panicAt, voices < 0, Double(i) / R.sr >= p + 0.1 { voices = isd_synth_active_voices(s) }
            while let p = pending.first, Double(i) / R.sr >= p { values.append(isd_synth_debug_count(s, which)); pending.removeFirst() }
        }
        return (left, right, values, voices)
    }

    /// A 4-note C♯ chord re-struck every 2 s for `seconds`.
    private func chordEvery2s(_ seconds: Double) -> [R.Event] {
        var events: [R.Event] = []
        var t = 0.0
        while t < seconds {
            for n: UInt8 in [61, 65, 68, 73] {
                if t > 0 { events.append(R.noteOff(t - 0.01, n)) }
                events.append(R.noteOn(t, n, 90))
            }
            t += 2
        }
        return events
    }

    private func sideToMid(_ l: [Float], _ r: [Float]) -> Double {
        var m = 0.0, s = 0.0
        for i in 0..<min(l.count, r.count) {
            let mid = Double(l[i] + r[i]) / 2, side = Double(l[i] - r[i]) / 2
            m += mid * mid; s += side * side
        }
        return m > 0 ? (s / m).squareRoot() : 0
    }

    // MARK: - Tuning

    func testTuningWithin2Cents() {
        for m: UInt8 in [49, 61, 73, 85] {
            let ref = midiHz(Double(m))
            let box = R.render(morning, seconds: 1.6, params: boxOnly, events: [R.pedal(0, 127), R.noteOn(0.01, m, 100)])
            let f = DSPTestKit.fundamental(R.slice(box.l, 0.3, 1.5), sampleRate: R.sr, near: ref)
            XCTAssertEqual(DSPTestKit.cents(f, ref), 0, accuracy: 2, "box MIDI \(m)")
        }
        // The wall's detuned unison beats slowly: its centre is read over two seconds, above the bass (where ±30 cents
        // is narrower than the window's resolution).
        for m: UInt8 in [61, 73, 85] {
            let ref = midiHz(Double(m))
            let wall = R.render(morning, seconds: 3.6, params: wallOnly, events: [R.noteOn(0.01, m, 100)])
            let c = DSPTestKit.clusterCentre(R.slice(wall.l, 1.5, 3.5), sampleRate: R.sr, near: ref)
            XCTAssertEqual(DSPTestKit.cents(c, ref), 0, accuracy: 2, "wall MIDI \(m)")
        }
    }

    func testFineTuneAndTransposeExact() {
        var p = boxOnly; p[Int(ISD_P_FINE_TUNE)] = 37; p[Int(ISD_P_TRANSPOSE)] = 5
        let out = R.render(morning, seconds: 1.6, params: p, events: [R.pedal(0, 127), R.noteOn(0.01, 61, 100)])
        let ref = midiHz(66)
        let f = DSPTestKit.fundamental(R.slice(out.l, 0.3, 1.5), sampleRate: R.sr, near: ref * pow(2, 37.0 / 1200))
        XCTAssertEqual(DSPTestKit.cents(f, ref) - 37, 0, accuracy: 1)
    }

    // MARK: - The box

    func testBarPartials() {
        var p = boxOnly; p[Int(ISD_P_BOX)] = 0
        let out = R.render(morning, seconds: 0.5, params: p, events: [R.pedal(0, 127), R.noteOn(0, 61, 110)])
        let f0 = midiHz(61), x = R.slice(out.l, 0.01, 0.3)
        for ratio in [2.76, 5.40] {
            let c = DSPTestKit.clusterCentre(x, sampleRate: R.sr, near: ratio * f0, cents: 40)
            XCTAssertEqual(c / (ratio * f0), 1, accuracy: 0.02, "mode \(ratio)")
        }
    }

    func testCombPartials() {
        var p = boxOnly; p[Int(ISD_P_BOX)] = 1
        let out = R.render(morning, seconds: 0.6, params: p, events: [R.pedal(0, 127), R.noteOn(0, 61, 110)])
        let f0 = midiHz(61), x = R.slice(out.l, 0.01, 0.4)
        let c = DSPTestKit.clusterCentre(x, sampleRate: R.sr, near: 6.27 * f0, cents: 40)
        XCTAssertEqual(c / (6.27 * f0), 1, accuracy: 0.02)
        let fundamental = db(band(x, f0 * 0.97, f0 * 1.03)), bar = db(band(x, 2.76 * f0 * 0.98, 2.76 * f0 * 1.02))
        XCTAssertLessThan(bar, fundamental - 25, "no bar mode in the comb")
    }

    /// Band energy from the kit's Blackman–Harris spectrum (a plain FFT of a 5 ms slice leaks the fundamental
    /// into the tick's band).
    private func quietBand(_ x: [Float], _ lo: Double, _ hi: Double) -> Double {
        let n = 1024, p = DSPTestKit.powerSpectrum(x, size: n), bin = R.sr / Double(n)
        var sum = 0.0
        for (k, e) in p.enumerated() {
            let f = Double(k) * bin
            if f >= lo && f <= hi { sum += e }
        }
        return sum
    }

    /// The celesta's felt tick (box 0): bright, and gone within a few milliseconds.
    func testTickIsShort() {
        var p = boxOnly; p[Int(ISD_P_BOX)] = 0
        let out = R.render(morning, seconds: 0.1, params: p, events: [R.noteOn(0, 73, 110)]).l
        let start = db(quietBand(R.slice(out, 0, 0.005), 2000, 4000)), later = db(quietBand(R.slice(out, 0.015, 0.025), 2000, 4000))
        XCTAssertLessThan(later, start - 20)
    }

    func testDampersStopReleasedNotes() {
        let out = R.render(morning, seconds: 1.3, params: boxOnly, events: [R.noteOn(0, 73, 100), R.noteOff(1.0, 73)]).l
        XCTAssertLessThan(DSPTestKit.dBFS(R.slice(out, 1.10, 1.15)), DSPTestKit.dBFS(R.slice(out, 0.9, 1.0)) - 40)
    }

    // MARK: - The wall and Build

    func testBuildRises() {
        var p = wallOnly; p[Int(ISD_P_BUILD)] = 1
        let r = renderProbing(seconds: 60, params: p, events: chordEvery2s(60), probes: [2, 60])
        XCTAssertLessThan(r.values[0], 120); XCTAssertGreaterThan(r.values[1], 600)
        let u = renderProbing(seconds: 60, params: p, events: chordEvery2s(60), probes: [60], which: ISD_DEBUG_WALL_UNISON)
        XCTAssertGreaterThanOrEqual(u.values[0], 5)
        let early = R.slice(r.l, 1, 3), late = R.slice(r.l, 58, 60)
        let ce = DSPTestKit.averageCentroid(early, sampleRate: R.sr), cl = DSPTestKit.averageCentroid(late, sampleRate: R.sr)
        XCTAssertGreaterThan(cl, 1.4 * ce, "centroid \(ce) → \(cl) Hz")
        let we = sideToMid(R.slice(r.l, 1, 3), R.slice(r.r, 1, 3)), wl = sideToMid(R.slice(r.l, 58, 60), R.slice(r.r, 58, 60))
        XCTAssertGreaterThan(wl, 1.2 * we, "width \(we) → \(wl)")
    }

    func testBuildFallsInSilence() {
        var p = wallOnly; p[Int(ISD_P_BUILD)] = 1
        var events = chordEvery2s(60)
        for n: UInt8 in [61, 65, 68, 73] { events.append(R.noteOff(60, n)) }
        let r = renderProbing(seconds: 72.1, params: p, events: events, probes: [60, 72])
        let share = Double(r.values[1]) / Double(max(1, r.values[0]))
        XCTAssertTrue((0.30...0.45).contains(share), "\(r.values[0]) → \(r.values[1])")
    }

    func testBuildZeroDoesNotGrow() {
        var p = wallOnly; p[Int(ISD_P_BUILD)] = 0
        let r = renderProbing(seconds: 30, params: p, events: chordEvery2s(30), probes: [5, 15, 29])
        XCTAssertEqual(r.values, [0, 0, 0])
    }

    func testBuildStaysUnderItsCeiling() {
        var p = wallOnly; p[Int(ISD_P_BUILD)] = 0.5
        var events: [R.Event] = []
        for i in 0..<960 { let t = Double(i) / 8; events.append(R.noteOn(t, UInt8(60 + i % 12), 100)); events.append(R.noteOff(t + 0.1, UInt8(60 + i % 12))) }
        let probes = stride(from: 5.0, through: 120, by: 5).map { $0 }
        let r = renderProbing(seconds: 120, params: p, events: events, probes: probes)
        XCTAssertTrue(r.values.allSatisfy { $0 <= 500 }, "\(r.values)")
        XCTAssertGreaterThan(r.values.last ?? 0, 300, "it does build")
    }

    /// Haze sets a held tone moving (chorus and wow). Measured on one celesta note, whose own level falls smoothly
    /// (the wall's detuned unison already beats by itself): the spread of its 20 ms levels around their trend.
    func testHazeAddsMovement() {
        func wobble(_ haze: Float) -> Double {
            var p = boxOnly; p[Int(ISD_P_HAZE)] = haze; p[Int(ISD_P_BOX)] = 0
            let out = R.render(morning, seconds: 3, params: p, events: [R.pedal(0, 127), R.noteOn(0, 73, 90)]).l
            let times = stride(from: 0.5, to: 2.5, by: 0.02).map { $0 }
            let levels = times.map { DSPTestKit.dBFS(R.slice(out, $0, $0 + 0.02)) }
            let mt = times.reduce(0, +) / Double(times.count), ml = levels.reduce(0, +) / Double(levels.count)
            var sxy = 0.0, sxx = 0.0
            for (t, l) in zip(times, levels) { sxy += (t - mt) * (l - ml); sxx += (t - mt) * (t - mt) }
            let slope = sxy / sxx
            var residual = 0.0
            for (t, l) in zip(times, levels) {
                let e = l - (ml + slope * (t - mt))
                residual += e * e
            }
            residual /= Double(times.count)
            return residual.squareRoot()
        }
        let still = wobble(0), hazy = wobble(1)
        XCTAssertGreaterThan(hazy, 2 * still + 0.1, "haze 0: \(still) dB, haze 1: \(hazy) dB")
    }

    func testPanicSilencesTheWall() {
        var p = dry; p[Int(ISD_P_BUILD)] = 1
        let r = renderProbing(seconds: 30.3, params: p, events: chordEvery2s(30), probes: [], panicAt: 30)
        XCTAssertLessThan(DSPTestKit.dBFS(R.slice(r.l, 30.05, 30.2)), -70)
        XCTAssertEqual(r.voicesAfterPanic, 0)
    }

    // MARK: - Hygiene

    /// The box's struck attacks are sharp by design, so stealing is judged against the same 40 attacks played
    /// short (no pedal, at most a handful sounding, nothing stolen): stealing 16 voices must add no bigger jump.
    func testStealingIsClickFree() {
        var stealing = [R.pedal(0, 127)], short: [R.Event] = []
        for i in 0..<40 {
            let t = Double(i) * 0.05, n = UInt8(48 + i)
            stealing.append(R.noteOn(t, n, 90))
            short.append(R.noteOn(t, n, 90)); short.append(R.noteOff(t + 0.3, n))
        }
        let a = R.render(morning, seconds: 3, params: dry, events: stealing)
        let b = R.render(morning, seconds: 3, params: dry, events: short)
        XCTAssertTrue(a.l.allSatisfy(\.isFinite) && a.r.allSatisfy(\.isFinite))
        let stolen = max(DSPTestKit.maxJump(a.l), DSPTestKit.maxJump(a.r))
        let attacks = max(DSPTestKit.maxJump(b.l), DSPTestKit.maxJump(b.r))
        XCTAssertLessThan(stolen, 1.25 * attacks + 0.01, "stealing \(stolen) against the attacks alone \(attacks)")
        XCTAssertLessThan(stolen, 0.4, "an attack jump this big would be a click")
    }

    /// 24 notes already held by the pedal, then five new ones: the wall lets the oldest go, never the newest
    /// (final review: it kept stealing the note still swelling in).
    func testWallFollowsNewNotesUnderThePedal() {
        var held = [R.pedal(0, 127)]
        for i in 0..<24 { held += [R.noteOn(0.01 + 0.05 * Double(i), UInt8(60 + i), 100), R.noteOff(0.03 + 0.05 * Double(i), UInt8(60 + i))] }
        let fresh: [UInt8] = [38, 40, 41, 43, 45]   // below every held note and its sub, so their bands are their own
        var with = held
        for (i, n) in fresh.enumerated() { with += [R.noteOn(1.3 + 0.18 * Double(i), n, 100), R.noteOff(1.32 + 0.18 * Double(i), n)] }
        let a = R.slice(R.render(morning, seconds: 3.6, params: wallOnly, events: with).l, 3.0, 3.6)
        let b = R.slice(R.render(morning, seconds: 3.6, params: wallOnly, events: held).l, 3.0, 3.6)
        for n in fresh {
            let f = midiHz(Double(n))
            XCTAssertGreaterThan(db(band(a, f * 0.985, f * 1.015)) - db(band(b, f * 0.985, f * 1.015)), 20, "note \(n)")
        }
    }

    /// Striking one note again and again under the pedal swells its wall voice again instead of stacking voices.
    func testRestrikingUnderThePedalReusesTheWallVoice() {
        var events = [R.pedal(0, 127)]
        for i in 0..<16 { events += [R.noteOn(0.01 + 0.125 * Double(i), 60, 100), R.noteOff(0.06 + 0.125 * Double(i), 60)] }
        guard let s = isd_synth_create(morning, R.sr, 256) else { return XCTFail("no synth") }
        defer { isd_synth_destroy(s) }
        for (a, v) in wallOnly { isd_synth_set_param(s, Int32(a), v) }
        var l = [Float](repeating: 0, count: 256), r = l, e = 0
        let total = Int(2.2 * R.sr)
        for i in stride(from: 0, to: total, by: 256) {
            while e < events.count, Int(events[e].time * R.sr) < i + 256 {
                let off = max(0, Int(events[e].time * R.sr) - i)
                events[e].bytes.withUnsafeBufferPointer { isd_synth_midi(s, $0.baseAddress, Int32($0.count), Int32(off)) }
                e += 1
            }
            l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in isd_synth_render(s, lp.baseAddress!, rp.baseAddress!, 256) } }
        }
        XCTAssertLessThanOrEqual(isd_synth_active_voices(s), 2)
    }

    /// A full wall (24 notes under the pedal) and an 8-note chord in one sample: every chord note sounds, and the
    /// voices it displaces fade rather than being cut.
    func testFullPoolChordIsWholeAndClickFree() {
        var held = [R.pedal(0, 127)]
        for i in 0..<24 { held += [R.noteOn(0.01 + 0.05 * Double(i), UInt8(60 + i), 100), R.noteOff(0.03 + 0.05 * Double(i), UInt8(60 + i))] }
        let big: [UInt8] = [29, 31, 33, 34, 36, 38, 40, 41]
        let chord = big.map { R.noteOn(2.0, $0, 100) }
        let full = R.render(morning, seconds: 3.0, params: wallOnly, events: held + chord).l
        let alone = R.render(morning, seconds: 3.0, params: wallOnly, events: [R.pedal(0, 127)] + chord).l
        let heldOnly = R.render(morning, seconds: 3.0, params: wallOnly, events: held).l
        let a = R.slice(full, 2.6, 3.0), c = R.slice(alone, 2.6, 3.0)
        for n in big {
            let f = midiHz(Double(n))
            XCTAssertGreaterThan(db(band(a, f * 0.971, f * 1.029)) - db(band(c, f * 0.971, f * 1.029)), -3, "chord note \(n)")
        }
        let residual = (0..<full.count).map { full[$0] - heldOnly[$0] - alone[$0] }
        XCTAssertLessThan(DSPTestKit.maxJump(R.slice(residual, 1.999, 2.04)), 0.01)
    }

    func testDialSweepIsSmooth() {
        let dials = [ISD_P_BARS, ISD_P_BOX, ISD_P_BLOOM, ISD_P_BUILD, ISD_P_HAZE, ISD_P_SPACE, ISD_P_WIDTH].map { Int($0) }
        var start: [Int: Float] = [:]
        for d in dials { start[d] = 0 }
        let changes = dials.map { SynthRender.ParamChange(time: 3.0, address: $0, value: 1) }
        let out = R.render(morning, seconds: 3.25, params: start, events: [R.pedal(0, 127), R.noteOn(0, 61, 100), R.noteOn(0, 68, 100)], changes: changes)
        let before = DSPTestKit.maxJump(R.slice(out.l, 2.8, 2.95)), after = DSPTestKit.maxJump(R.slice(out.l, 2.95, 3.1))
        let settled = DSPTestKit.maxJump(R.slice(out.l, 3.1, 3.25))
        XCTAssertLessThan(after, 2 * max(before, settled) + 1e-4, "before \(before), after \(after), settled \(settled)")
    }

    func testParameterTable() {
        let count = Int(isd_synth_param_count(morning))
        let infos = (0..<count).compactMap { isd_synth_param_info(morning, Int32($0)) }.map { $0.pointee }
        XCTAssertEqual(infos.map { String(cString: $0.identifier) },
                       ["fineTune", "transpose", "bars", "box", "bloom", "build", "haze", "space", "width",
                        "moodEnergy", "moodWarmth", "moodBrightness", "moodSpace", "moodMotion", "debugBoxOnly", "debugWallOnly"])
        let defaults = Dictionary(uniqueKeysWithValues: infos.map { (String(cString: $0.identifier), $0.defaultValue) })
        XCTAssertEqual(defaults["bars"], 0.60); XCTAssertEqual(defaults["box"], 0.20); XCTAssertEqual(defaults["bloom"], 0.40)
        XCTAssertEqual(defaults["build"], 0.50); XCTAssertEqual(defaults["haze"], 0.35); XCTAssertEqual(defaults["space"], 0.50)
        XCTAssertEqual(defaults["width"], 0.55)
        XCTAssertEqual(infos.filter { $0.unit == 3 }.map { String(cString: $0.identifier) }, ["debugBoxOnly", "debugWallOnly"])
    }

    func testExtremesStayFinite() {
        for v: Float in [0, 1] {
            var p: [Int: Float] = [:]
            for a in [ISD_P_BARS, ISD_P_BOX, ISD_P_BLOOM, ISD_P_BUILD, ISD_P_HAZE, ISD_P_SPACE, ISD_P_WIDTH] { p[Int(a)] = v }
            var events: [R.Event] = [R.pedal(0.5, 127)]
            for i in 0..<10 { events.append(R.noteOn(Double(i) * 0.1, UInt8(30 + i * 7), 127)) }
            let out = R.render(morning, seconds: 5, params: p, events: events)
            XCTAssertTrue(out.l.allSatisfy { $0.isFinite && abs($0) <= 1 } && out.r.allSatisfy { $0.isFinite && abs($0) <= 1 }, "dials at \(v)")
        }
    }
}
