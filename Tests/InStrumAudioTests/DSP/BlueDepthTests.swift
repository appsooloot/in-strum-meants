import XCTest
import InStrumDSP

/// Blue Depth (after "Underwater"): a blinking arp on the analogue voice core, through a dotted-eighth echo, with
/// ghostly voices behind it and a big bass under the left hand (docs/superpowers/briefs/blue-depth.md).
final class BlueDepthTests: XCTestCase {
    typealias R = SynthRender
    let depth = ISD_ENGINE_BLUE_DEPTH
    /// Dry (test hook): no echo, ghosts, reverb, slop or current.
    let dry: [Int: Float] = [Int(ISD_P_DEBUG_DRY): 1]
    /// Dry plain voices: the arp off too (test hook), so each key is one struck voice.
    var plain: [Int: Float] { var p = dry; p[Int(ISD_P_DEBUG_NO_ARP)] = 1; return p }
    /// One arp step at the record's 118 BPM (a sixteenth), and the echo (a dotted eighth).
    static let step = 15.0 / 118.0
    static let echo = 45.0 / 118.0
    let triad: [UInt8] = [60, 64, 67]

    private func midiHz(_ m: Double) -> Double { 440 * pow(2, (m - 69) / 12) }
    private func db(_ x: Double) -> Double { 10 * log10(max(x, 1e-30)) }
    private func mono(_ out: (l: [Float], r: [Float])) -> [Float] { zip(out.l, out.r).map { $0.0 + $0.1 } }
    private func press(_ notes: [UInt8], at t: Double) -> [R.Event] { notes.map { R.noteOn(t, $0, 100) } }

    /// Onsets (re-attacks): the RMS (dB) of `window`-sample windows every `hop` samples; an onset is a window at
    /// least `rise` dB above the loudest of the windows that end 1–`lookMs` ms before it starts, and above −70 dBFS,
    /// at least `gap` s after the last onset. Its time is the window's start.
    private func onsets(_ x: [Float], window: Int = 48, hop: Int = 12, rise: Double = 6, lookMs: Double = 6,
                        gap: Double = 0.03) -> [Double] {
        var sum = [Double](repeating: 0, count: x.count + 1)
        for i in 0..<x.count { sum[i + 1] = sum[i] + Double(x[i]) * Double(x[i]) }
        var e: [Double] = []
        var i = 0
        while i + window <= x.count {
            e.append(10 * log10((sum[i + window] - sum[i]) / Double(window) + 1e-30))
            i += hop
        }
        let near = Int(((Double(window) + 0.001 * R.sr) / Double(hop)).rounded(.up))
        let far = Int(((Double(window) + lookMs * 0.001 * R.sr) / Double(hop)).rounded(.up))
        var found: [Double] = []
        guard e.count > far else { return found }
        var last = -1.0
        for j in far..<e.count {
            var ref = -300.0
            for k in (j - far)...(j - near) { ref = max(ref, e[k]) }
            let t = Double(j * hop) / R.sr
            if e[j] >= ref + rise, e[j] >= -70, last < 0 || t - last >= gap {
                found.append(t)
                last = t
            }
        }
        return found
    }

    /// The strongest spectral line between two frequencies (Blackman–Harris, 2^16 points).
    private func strongest(_ x: [Float], from lo: Double, to hi: Double) -> Double {
        let n = 1 << 16, p = DSPTestKit.powerSpectrum(x, size: n), bin = R.sr / Double(n)
        var best = Int(lo / bin)
        for k in Int(lo / bin)...Int(hi / bin) where p[k] > p[best] { best = k }
        return Double(best) * bin
    }

    /// Which of `candidates` each onset plays: the one nearest the strongest line between 240 and 420 Hz over the
    /// 5–100 ms after it (C4–G4's fundamentals; their subs and harmonics lie outside that range).
    private func notes(at times: [Double], in x: [Float], among candidates: [UInt8]) -> [UInt8] {
        times.map { (t: Double) -> UInt8 in
            let f = strongest(R.slice(x, t + 0.005, t + 0.1), from: 240, to: 420)
            return candidates.min { abs(DSPTestKit.cents(f, midiHz(Double($0)))) < abs(DSPTestKit.cents(f, midiHz(Double($1)))) } ?? 0
        }
    }

    /// The energy between two frequencies, Blackman–Harris windowed (2^16 points), so a strong low fundamental
    /// doesn't leak into a higher band.
    private func band(_ x: [Float], _ lo: Double, _ hi: Double) -> Double {
        let n = 1 << 16, p = DSPTestKit.powerSpectrum(x, size: n), bin = R.sr / Double(n)
        var e = 0.0
        for (i, v) in p.enumerated() where i > 0 && Double(i) * bin >= lo && Double(i) * bin <= hi { e += v }
        return e
    }

    /// Renders like `SynthRender.render`, calling all-notes-off (an instrument or world switching) at `at`.
    private func renderSwitching(params: [Int: Float], events: [R.Event], seconds: Double, at: Double) -> (l: [Float], r: [Float]) {
        guard let s = isd_synth_create(depth, R.sr, 256) else { return ([], []) }
        defer { isd_synth_destroy(s) }
        for (a, v) in params { isd_synth_set_param(s, Int32(a), v) }
        let total = Int(seconds * R.sr), sorted = events.sorted { $0.time < $1.time }
        var left = [Float](repeating: 0, count: total), right = left
        var e = 0, i = 0, switched = false
        while i < total {
            let n = min(256, total - i)
            if !switched, Int(at * R.sr) < i + n { isd_synth_all_notes_off(s); switched = true }
            while e < sorted.count, Int(sorted[e].time * R.sr) < i + n {
                let off = max(0, Int(sorted[e].time * R.sr) - i)
                sorted[e].bytes.withUnsafeBufferPointer { isd_synth_midi(s, $0.baseAddress, Int32($0.count), Int32(off)) }
                e += 1
            }
            left.withUnsafeMutableBufferPointer { lp in
                right.withUnsafeMutableBufferPointer { rp in isd_synth_render(s, lp.baseAddress! + i, rp.baseAddress! + i, Int32(n)) }
            }
            i += n
        }
        return (left, right)
    }

    // MARK: - Tuning

    /// The detuned pair's centre over 3.6 s (longer than the 2.6 s the pair takes to beat once on A2): within 2 cents
    /// dry, and within 6 with slop (every hook off but the arp's), each oscillator wandering up to ±3 cents. Fine tune
    /// and transpose are exact.
    func testBlueDepthTuning() {
        let slop: [Int: Float] = [Int(ISD_P_DEBUG_NO_ARP): 1, Int(ISD_P_SPACE): 0, Int(ISD_P_ECHO): 0, Int(ISD_P_GHOSTS): 0]
        for m: UInt8 in [45, 57, 69, 81] {
            let ref = midiHz(Double(m))
            for (params, bound) in [(plain, 2.0), (slop, 6.0)] {
                let out = R.render(depth, seconds: 4, params: params, events: [R.noteOn(0, m, 100)])
                let centre = DSPTestKit.clusterCentre(R.slice(out.l, 0.3, 3.9), sampleRate: R.sr, near: ref)
                XCTAssertEqual(DSPTestKit.cents(centre, ref), 0, accuracy: bound, "MIDI \(m), within \(bound) cents")
            }
        }
        var p = plain; p[Int(ISD_P_FINE_TUNE)] = 37; p[Int(ISD_P_TRANSPOSE)] = 5
        let out = R.render(depth, seconds: 4, params: p, events: [R.noteOn(0, 57, 100)])
        let ref = midiHz(62)
        let centre = DSPTestKit.clusterCentre(R.slice(out.l, 0.3, 3.9), sampleRate: R.sr, near: ref * pow(2, 37.0 / 1200))
        XCTAssertEqual(DSPTestKit.cents(centre, ref) - 37, 0, accuracy: 1)
    }

    // MARK: - The arp

    /// C4, E4 and G4 held from 0.1 s at Blink .6: a step every sixteenth at 118 BPM, each within 1 ms of the grid,
    /// cycling C, E, G.
    func testArpStepsOnTheSixteenthGrid() {
        var p = dry; p[Int(ISD_P_BLINK)] = 0.6; p[Int(ISD_P_TEMPO)] = 118
        let x = mono(R.render(depth, seconds: 2.2, params: p, events: press(triad, at: 0.1)))
        let found = onsets(x).filter { $0 > 0.05 && $0 < 0.1 + 15.5 * Self.step }
        XCTAssertEqual(found.count, 16, "onsets \(found)")
        for (k, t) in found.enumerated() {
            XCTAssertEqual(t, 0.1 + Double(k) * Self.step, accuracy: 0.001, "step \(k)")
        }
        XCTAssertEqual(notes(at: found, in: x, among: triad), (0..<found.count).map { triad[$0 % 3] })
    }

    /// Steps follow the order the keys went down; keys pressed within 30 ms of each other go low to high.
    func testArpOrderIsAsPressed() {
        func steps(_ presses: [(Double, UInt8)]) -> [UInt8] {
            let x = mono(R.render(depth, seconds: 0.95, params: dry, events: presses.map { R.noteOn($0.0, $0.1, 100) }))
            let found = Array(onsets(x).filter { $0 > 0.05 }.prefix(6))
            return notes(at: found, in: x, among: triad)
        }
        let (c, e, g): (UInt8, UInt8, UInt8) = (60, 64, 67)
        XCTAssertEqual(steps([(0.1, g), (0.15, c), (0.2, e)]), [g, c, e, g, c, e])
        // As pressed, not sorted: E, then C, then G cycles E, C, G.
        XCTAssertEqual(steps([(0.1, e), (0.15, c), (0.2, g)]), [e, c, g, e, c, g])
        // Within 30 ms the three go low to high: E sounds at once, alone, and the order runs on from it.
        XCTAssertEqual(steps([(0.1, e), (0.11, c), (0.12, g)]), [e, g, c, e, g, c])
    }

    // MARK: - The echo, Murk, the ghosts and the bass

    /// One 50 ms note with the arp off: the echo's first repeat starts a dotted eighth (381.4 ms) after the note.
    func testEchoIsADottedEighth() {
        let p: [Int: Float] = [Int(ISD_P_DEBUG_NO_ARP): 1, Int(ISD_P_ECHO): 0.6, Int(ISD_P_SPACE): 0, Int(ISD_P_GHOSTS): 0]
        let x = mono(R.render(depth, seconds: 0.75, params: p, events: [R.noteOn(0.1, 60, 100), R.noteOff(0.15, 60)]))
        let found = onsets(x)
        XCTAssertGreaterThanOrEqual(found.count, 2, "onsets \(found)")
        guard found.count >= 2 else { return }
        XCTAssertEqual(found[1] - found[0], Self.echo, accuracy: 0.001)
    }

    /// On a held chord, Murk 1 against 0 at least halves the spectral centroid (the ceiling falls 7 kHz → 650 Hz).
    func testMurkDarkens() {
        func centroid(_ murk: Float) -> Double {
            var p = plain; p[Int(ISD_P_MURK)] = murk
            let out = R.render(depth, seconds: 1.1, params: p, events: press(triad, at: 0.1))
            return DSPTestKit.centroid(R.slice(out.l, 0.2, 1.0), sampleRate: R.sr)
        }
        let bright = centroid(0), murky = centroid(1)
        XCTAssertLessThanOrEqual(murky, 0.5 * bright, "Murk 0: \(bright) Hz, Murk 1: \(murky) Hz")
    }

    /// A held C-minor triad, blinking: Ghosts 1 against 0 raises the 250–900 Hz energy over 1–2 s by at least 6 dB
    /// (the ghosts sing an octave up, between "oo" and "oh", behind the steps).
    func testGhostsRiseBehindHeldNotes() {
        func energy(_ ghosts: Float) -> Double {
            let out = R.render(depth, seconds: 2, params: [Int(ISD_P_GHOSTS): ghosts], events: press([60, 63, 67], at: 0))
            return band(R.slice(mono(out), 1, 2), 250, 900)
        }
        let without = energy(0), with = energy(1)
        XCTAssertGreaterThanOrEqual(db(with / without), 6, "Ghosts 0: \(db(without)) dB, Ghosts 1: \(db(with)) dB")
    }

    /// A1 held 1 s at Blink .6: at Bass 1 it is one held bass voice (a single onset) with at least 6 dB more below
    /// 120 Hz than at Bass 0, where it joins the arp like any other note.
    func testBassNotesAreNotArpeggiated() {
        func held(_ bass: Float) -> [Float] {
            var p = dry; p[Int(ISD_P_BLINK)] = 0.6; p[Int(ISD_P_BASS)] = bass
            return mono(R.render(depth, seconds: 1.2, params: p, events: [R.noteOn(0.1, 33, 100), R.noteOff(1.1, 33)]))
        }
        // Onsets on a 10 ms scale: A1's sub takes 36 ms a cycle.
        func count(_ x: [Float]) -> Int { onsets(x, window: 480, hop: 120, lookMs: 40, gap: 0.05).filter { $0 < 1.1 }.count }
        let big = held(1), blinking = held(0)
        XCTAssertEqual(count(big), 1)
        XCTAssertGreaterThan(count(blinking), 4, "at Bass 0 the note joins the arp")
        let low = db(band(R.slice(big, 0.1, 1.1), 0, 120) / band(R.slice(blinking, 0.1, 1.1), 0, 120))
        XCTAssertGreaterThanOrEqual(low, 6)
    }

    // MARK: - The wheel and pressure

    /// The wheel full up: the pair's centre reads +200 cents from 60 ms after it.
    func testWheelBendsTwoSemitones() {
        let events = [R.noteOn(0, 57, 100), R.Event(time: 0.5, bytes: [0xE0, 0x7F, 0x7F])]
        let out = R.render(depth, seconds: 2.5, params: plain, events: events)
        let centre = DSPTestKit.clusterCentre(R.slice(out.l, 0.56, 2.4), sampleRate: R.sr, near: midiHz(59))
        XCTAssertEqual(DSPTestKit.cents(centre, midiHz(57)), 200, accuracy: 5)
    }

    /// Channel pressure 1 opens the filter (up to +0.8 octave): a held A3's 1–4 kHz energy rises by at least 4 dB.
    func testPressureOpensTheFilter() {
        func air(_ pressed: Bool) -> Double {
            var events = [R.noteOn(0, 57, 100)]
            if pressed { events.append(R.Event(time: 0.5, bytes: [0xD0, 127])) }
            return band(R.slice(R.render(depth, seconds: 1.5, params: plain, events: events).l, 0.6, 1.4), 1000, 4000)
        }
        XCTAssertGreaterThanOrEqual(db(air(true) / air(false)), 4)
    }

    // MARK: - Endings

    /// Review focus 1. Panic (CC 120, all sound off) mid-arp is silent within 50 ms, echo and reverb included. A switch
    /// (all notes off) stops the arp and empties the echo within 50 ms, the pedal held through it or not, and the next
    /// chord starts a fresh grid on its own note-on.
    func testArpStopsOnSwitchAndPanic() {
        let held = press(triad, at: 0.1)
        let panic = R.render(depth, seconds: 1.35, events: held + [R.Event(time: 1.0, bytes: [0xB0, 120, 0])])
        XCTAssertLessThan(DSPTestKit.dBFS(R.slice(panic.l, 1.05, 1.3)), -60)
        XCTAssertLessThan(DSPTestKit.dBFS(R.slice(panic.r, 1.05, 1.3)), -60)
        // The reverb's tail rings on through a switch by design, so it is off here: the arp and the echo must stop.
        let quiet: [Int: Float] = [Int(ISD_P_SPACE): 0, Int(ISD_P_GHOSTS): 0]
        let next = press([62, 65, 69], at: 1.337)
        for pedal in [false, true] {
            var events = held + next
            if pedal { events += [R.pedal(0.05, 127)] + triad.map { R.noteOff(0.5, $0) } }
            let out = renderSwitching(params: quiet, events: events, seconds: 1.6, at: 1.0)
            XCTAssertLessThan(DSPTestKit.dBFS(R.slice(out.l, 1.05, 1.3)), -60, "pedal \(pedal)")
            XCTAssertLessThan(DSPTestKit.dBFS(R.slice(out.r, 1.05, 1.3)), -60, "pedal \(pedal)")
            let first = onsets(mono(out)).first { $0 > 1.2 } ?? -1
            XCTAssertEqual(first, 1.337, accuracy: 0.001, "pedal \(pedal): a fresh grid")
        }
    }

    /// With the pedal down and the keys let go the steps go on; with the pedal up they stop after the current step,
    /// as they do when the keys let go without it.
    func testPedalHeldNotesStayInTheArp() {
        let keys = press(triad, at: 0.1) + triad.map { R.noteOff(0.55, $0) }
        let pedalled = onsets(mono(R.render(depth, seconds: 2, params: dry, events: keys + [R.pedal(0.05, 127), R.pedal(1.0, 0)])))
        XCTAssertGreaterThanOrEqual(pedalled.filter { $0 > 0.6 && $0 < 1.0 }.count, 3, "the pedal holds the notes in the arp")
        XCTAssertEqual(pedalled.filter { $0 > 1.01 }.count, 0, "pedal up: the arp stops after the current step")
        let unpedalled = onsets(mono(R.render(depth, seconds: 2, params: dry, events: keys)))
        XCTAssertEqual(unpedalled.filter { $0 > 0.6 }.count, 0)
    }

    // MARK: - Hygiene

    /// Every dial and mood at each end (so the echo's and the reverb's feedback at their highest), Tempo at its ends,
    /// full pressure, the wheel at both ends, and fortissimo chords and bass for 4 s: only finite samples within ±1.
    func testBlueDepthRendersFinite() {
        let dials = [ISD_P_BLINK, ISD_P_MURK, ISD_P_GHOSTS, ISD_P_ECHO, ISD_P_BASS, ISD_P_SPACE, ISD_P_WIDTH, ISD_P_MOOD_ENERGY,
                     ISD_P_MOOD_WARMTH, ISD_P_MOOD_BRIGHTNESS, ISD_P_MOOD_SPACE, ISD_P_MOOD_MOTION].map { Int($0) }
        for v: Float in [0, 1] {
            var p = Dictionary(uniqueKeysWithValues: dials.map { ($0, v) })
            p[Int(ISD_P_TEMPO)] = v > 0 ? 160 : 70
            var events: [R.Event] = [R.pedal(0.5, 127), R.Event(time: 0.2, bytes: [0xD0, 127]),
                                     R.Event(time: 0.3, bytes: [0xE0, 0x7F, 0x7F]), R.Event(time: 2.0, bytes: [0xE0, 0, 0])]
            for i in 0..<12 { events.append(R.noteOn(0.01 + Double(i) * 0.05, UInt8(24 + i * 8), 127)) }
            for i in 0..<6 { events.append(R.noteOn(2.5 + Double(i) * 0.01, UInt8(28 + i * 12), 127)) }
            let out = R.render(depth, seconds: 4, params: p, events: events)
            XCTAssertTrue(out.l.allSatisfy { $0.isFinite && abs($0) <= 1 } && out.r.allSatisfy { $0.isFinite && abs($0) <= 1 }, "dials at \(v)")
        }
    }

    func testBlueDepthParameterTable() {
        let count = Int(isd_synth_param_count(depth))
        let infos = (0..<count).compactMap { isd_synth_param_info(depth, Int32($0)) }.map { $0.pointee }
        XCTAssertEqual(infos.map { String(cString: $0.identifier) },
                       ["fineTune", "transpose", "blink", "murk", "ghosts", "echo", "bass", "tempo", "space", "width",
                        "moodEnergy", "moodWarmth", "moodBrightness", "moodSpace", "moodMotion", "debugNoArp", "debugDry"])
        let defaults = Dictionary(uniqueKeysWithValues: infos.map { (String(cString: $0.identifier), $0.defaultValue) })
        XCTAssertEqual(defaults["blink"], 0.60); XCTAssertEqual(defaults["murk"], 0.55); XCTAssertEqual(defaults["ghosts"], 0.40)
        XCTAssertEqual(defaults["echo"], 0.50); XCTAssertEqual(defaults["bass"], 0.55); XCTAssertEqual(defaults["tempo"], 118)
        XCTAssertEqual(defaults["space"], 0.55); XCTAssertEqual(defaults["width"], 0.60)
        let tempo = infos.first { String(cString: $0.identifier) == "tempo" }
        XCTAssertEqual(tempo?.minValue, 70)
        XCTAssertEqual(tempo?.maxValue, 160)
        XCTAssertEqual(infos.filter { $0.unit == 3 }.map(\.address), [Int32(ISD_P_DEBUG_NO_ARP), Int32(ISD_P_DEBUG_DRY)],
                       "the test hooks are internal")
    }
}
