import XCTest
import InStrumDSP

final class OrbitPadTests: XCTestCase {
    typealias R = SynthRender
    let pad = ISD_ENGINE_ORBIT_PAD
    let dry: [Int: Float] = [Int(ISD_P_SPACE): 0]

    private func midiHz(_ m: Double) -> Double { 440 * pow(2, (m - 69) / 12) }

    /// Drift 0 still leaves the ±3-cent analogue unison; its centre (over 4 s, longer than the beats) is in tune.
    func testTuningWithin2Cents() {
        var p = dry; p[Int(ISD_P_DRIFT)] = 0; p[Int(ISD_P_MOTION)] = 0
        for m: UInt8 in [45, 57, 69, 81] {
            let out = R.render(pad, seconds: 5, params: p, events: [R.noteOn(0, m, 100)])
            let ref = midiHz(Double(m))
            let centre = DSPTestKit.clusterCentre(R.slice(out.l, 0.5, 4.5), sampleRate: R.sr, near: ref)
            XCTAssertEqual(DSPTestKit.cents(centre, ref), 0, accuracy: 2, "MIDI \(m)")
        }
    }

    func testAliasFree() {
        // One plain saw (debug hook: layer A only, no detune, drift, motion or chorus), filter wide open.
        let p: [Int: Float] = [Int(ISD_P_SPACE): 0, Int(ISD_P_DEBUG_LAYER_A_ONLY): 1, Int(ISD_P_BRIGHTNESS): 1, Int(ISD_P_BLOOM): 0]
        let out = R.render(pad, seconds: 3, params: p, events: [R.noteOn(0, 96, 120)])
        let x = R.slice(out.l, 1.5, 2.9)
        let f0 = midiHz(96), n = 1 << 16, binHz = R.sr / Double(n)
        var harmonic = 0.0, total = 0.0
        let spectrum = DSPTestKit.powerSpectrum(Array(x.prefix(n)), size: n)
        for (i, p) in spectrum.enumerated() where i > 0 {
            total += p
            let f = Double(i) * binHz, k = (f / f0).rounded()
            if k >= 1, abs(f - k * f0) <= 5 * binHz { harmonic += p }
        }
        XCTAssertLessThan(10 * log10((total - harmonic) / total), -50)
    }

    /// Measured on one plain saw (test hook): a five-saw unison's beating swings a half-second centroid by ±40%.
    func testBloomOpensOverTime() {
        var p = dry; p[Int(ISD_P_BLOOM)] = 0.5; p[Int(ISD_P_DEBUG_LAYER_A_ONLY)] = 1
        let out = R.render(pad, seconds: 3.6, params: p, events: [R.noteOn(0, 57, 100)])
        let early = DSPTestKit.centroid(R.slice(out.l, 0.3, 0.8), sampleRate: R.sr)
        let late = DSPTestKit.centroid(R.slice(out.l, 3.0, 3.5), sampleRate: R.sr)
        XCTAssertGreaterThan(late, 1.5 * early, "early \(early) Hz, late \(late) Hz")
    }

    /// Held 4 s then released: still within 40 dB of its held level 2 s later, gone (< −90 dBFS) 12 s later.
    func testLongRelease() {
        let out = R.render(pad, seconds: 17.2, params: dry, events: [R.noteOn(0, 57, 100), R.noteOff(4, 57)])
        let held = DSPTestKit.dBFS(R.slice(out.l, 3.5, 4.0))
        XCTAssertGreaterThan(DSPTestKit.dBFS(R.slice(out.l, 6.0, 6.1)), held - 40)
        XCTAssertLessThan(DSPTestKit.dBFS(R.slice(out.l, 16.0, 17.0)), -90)
    }

    func testStealingIsClickFree() {
        let events = (0..<24).map { R.noteOn(Double($0) * 0.125, UInt8(40 + $0 * 2), 100) }
        let out = R.render(pad, seconds: 4, params: dry, events: events)
        XCTAssertTrue(out.l.allSatisfy(\.isFinite) && out.r.allSatisfy(\.isFinite))
        XCTAssertLessThan(DSPTestKit.maxJump(out.l), 0.2)
        XCTAssertLessThan(DSPTestKit.maxJump(out.r), 0.2)
        XCTAssertLessThanOrEqual(out.l.map { abs($0) }.max() ?? 2, 1.0)
    }

    /// Two-hand chords a second apart under the pedal: from the third on, each steals eight voices at once from a full
    /// pool. With four spare voices the steals past the fourth were cut dead, and the pad's ladder filter leaves almost
    /// nothing above 10 kHz to hide the cut: 36 dB over the same chords played without stealing (Polar Choir's breath
    /// hid its own). Every steal now fades (the g++ mirror: −2.9 dB at worst; with the 20 ms fade removed, +34).
    func testFullPoolStealIsClickFree() {
        let steal = R.stealClicks(pad, params: dry, velocities: [UInt8](repeating: 90, count: 6), gap: 1, from: 2)
        XCTAssertTrue(steal.out.l.allSatisfy(\.isFinite) && steal.out.r.allSatisfy(\.isFinite))
        XCTAssertLessThan(steal.clicks.max() ?? 99, 3, "dB over the chords without stealing: \(steal.clicks)")
    }

    func testDialSweepIsSmooth() {
        var start = dry; start[Int(ISD_P_BLOOM)] = 0; start[Int(ISD_P_BRIGHTNESS)] = 0; start[Int(ISD_P_DRIFT)] = 0
        let out = R.render(pad, seconds: 3.25, params: start, events: [R.noteOn(0, 57, 100)],
                           changes: [.init(time: 3.0, address: Int(ISD_P_BLOOM), value: 1),
                                     .init(time: 3.0, address: Int(ISD_P_BRIGHTNESS), value: 1),
                                     .init(time: 3.0, address: Int(ISD_P_DRIFT), value: 1)])
        // Brightness legitimately steepens the waveform, so the change is compared with the sound it settles into.
        let before = DSPTestKit.maxJump(R.slice(out.l, 2.8, 2.95)), after = DSPTestKit.maxJump(R.slice(out.l, 2.95, 3.1))
        let settled = DSPTestKit.maxJump(R.slice(out.l, 3.1, 3.25))
        XCTAssertLessThan(after, 2 * max(before, settled) + 1e-4, "before \(before), after \(after), settled \(settled)")
    }

    func testParameterTable() {
        let count = Int(isd_synth_param_count(pad))
        let infos = (0..<count).compactMap { isd_synth_param_info(pad, Int32($0)) }.map { $0.pointee }
        let ids = infos.filter { $0.unit != 3 }.map { String(cString: $0.identifier) }
        XCTAssertEqual(Set(ids), ["fineTune", "transpose", "space", "bloom", "drift", "motion", "shimmer", "brightness",
                                  "moodEnergy", "moodWarmth", "moodBrightness", "moodSpace", "moodMotion"])
        XCTAssertEqual(infos.filter { $0.unit == 3 }.map(\.address), [200], "the test hook is internal")
    }
}
