import XCTest
import InStrumDSP

/// Magma Bass (Sets 13 & 14, Task 2; spec 2026-11-05-fire-and-neon-design.md §4.2, brief magma-bass.md).
/// Mirrors Scripts/dsp-harness/magma_test.cpp, where every bound below was measured first.
final class MagmaBassTests: XCTestCase {
    typealias R = SynthRender
    typealias K = DSPTestKit
    let magma = ISD_ENGINE_MAGMA_BASS
    let sr = DSPTestKit.sampleRate

    private func p(_ pairs: [(Int, Float)]) -> [Int: Float] { Dictionary(uniqueKeysWithValues: pairs) }
    private func hz(_ note: Double) -> Double { 440 * pow(2, (note - 69) / 12) }
    private func db(_ ratio: Double) -> Double { 10 * log10(ratio) }
    private func debug(_ events: [R.Event], seconds: Double, params: [Int: Float] = [:]) -> Int32 {
        guard let s = isd_synth_create(magma, sr, 256) else { return -1 }
        defer { isd_synth_destroy(s) }
        for (a, v) in params { isd_synth_set_param(s, Int32(a), v) }
        var l = [Float](repeating: 0, count: 256), r = l
        let total = Int(seconds * sr)
        let sorted = events.sorted { $0.time < $1.time }
        var e = 0, i = 0
        while i < total {
            while e < sorted.count, Int(sorted[e].time * sr) < i + 256 {
                var b = sorted[e].bytes
                isd_synth_midi(s, &b, Int32(b.count), Int32(max(0, Int(sorted[e].time * sr) - i))); e += 1
            }
            isd_synth_render(s, &l, &r, 256); i += 256
        }
        return isd_synth_debug_count(s, ISD_DEBUG_ERUPTIONS)
    }

    func testMagmaTuning() {
        let dry = p([(Int(ISD_P_DEBUG_MB_DRY), 1), (Int(ISD_P_RUMBLE), 0), (Int(ISD_P_HEAT), 1)])
        for note in [28, 45, 57, 60] {
            let out = R.render(magma, seconds: 3, params: dry, events: [R.noteOn(0, UInt8(note), 100)])
            let f = K.fundamental(R.slice(out.l, 0.3, 2.9), sampleRate: sr, near: hz(Double(note)))
            XCTAssertLessThan(abs(K.cents(f, hz(Double(note)))), 3, "note \(note) at \(f) Hz")
        }
    }

    func testVelocityRipsTheFilterOpen() {
        func share(_ growl: Float, _ velocity: UInt8) -> Double {
            let o = R.render(magma, seconds: 0.5, params: p([(Int(ISD_P_GROWL), growl)]), events: [R.noteOn(0, 33, velocity)])
            let x = R.slice(o.l, 0.05, 0.4)
            return db(K.bandEnergy(x, sampleRate: sr, from: 500, to: 4000) / K.bandEnergy(x, sampleRate: sr, from: 20, to: 20000))
        }
        XCTAssertGreaterThanOrEqual(share(0.55, 127) - share(0.55, 25), 4)
        XCTAssertGreaterThanOrEqual(share(0, 127) - share(0, 25), 9)
    }

    func testRumbleAddsSubTwo() {
        let f4 = hz(57) / 4
        func e(_ rumble: Float) -> Double {
            let o = R.render(magma, seconds: 1.5, params: p([(Int(ISD_P_RUMBLE), rumble)]), events: [R.noteOn(0, 57, 100)])
            return K.bandEnergy(R.slice(o.l, 0.2, 1.4), sampleRate: sr, from: f4 * 0.9, to: f4 * 1.1)
        }
        XCTAssertGreaterThanOrEqual(db(e(1) / e(0)), 10)
    }

    func testGrowlBrightensMonotonically() {
        var last = -Double.infinity
        for g: Float in [0, 0.33, 0.66, 1] {
            let o = R.render(magma, seconds: 1, params: p([(Int(ISD_P_GROWL), g), (Int(ISD_P_HEAT), 0.8), (Int(ISD_P_ERUPT), 0), (Int(ISD_P_RES), 0)]),
                             events: [R.noteOn(0, 45, 100)])
            let x = R.slice(o.l, 0.2, 0.9)
            let ratio = db(K.bandEnergy(x, sampleRate: sr, from: 800, to: 5000) / K.bandEnergy(x, sampleRate: sr, from: 20, to: 400))
            XCTAssertGreaterThan(ratio, last, "Growl \(g)")
            last = ratio
        }
    }

    func testMonoLegatoGlides() {
        let params = p([(Int(ISD_P_MONO), 1), (Int(ISD_P_FLOW), 0.5), (Int(ISD_P_DEBUG_MB_DRY), 1), (Int(ISD_P_RUMBLE), 0), (Int(ISD_P_HEAT), 1)])
        let o = R.render(magma, seconds: 1, params: params, events: [R.noteOn(0, 45, 100), R.noteOn(0.3, 52, 100)])
        let f = K.fundamental(R.slice(o.l, 0.45, 1.0), sampleRate: sr, near: hz(52))
        XCTAssertLessThan(abs(K.cents(f, hz(52))), 5)
        // No re-attack: the RMS of 25 ms windows never jumps by more than 3 dB across the change.
        var t = 0.22
        while t < 0.42 {
            let a = K.dBFS(R.slice(o.l, t, t + 0.025)), b = K.dBFS(R.slice(o.l, t + 0.025, t + 0.05))
            XCTAssertLessThan(b - a, 3, "at \(t) s")
            t += 0.005
        }
    }

    func testSparkOnlyAboveC4() {
        func high(_ s: Float, _ note: UInt8) -> Double {
            let o = R.render(magma, seconds: 1, params: p([(Int(ISD_P_SPARK), s)]), events: [R.noteOn(0, note, 100)])
            return K.bandEnergy(R.slice(o.l, 0.1, 0.9), sampleRate: sr, from: 2000, to: 6000)
        }
        XCTAssertGreaterThanOrEqual(db(high(1, 72) / high(0, 72)), 6)
        let c1 = R.render(magma, seconds: 1, params: p([(Int(ISD_P_SPARK), 1)]), events: [R.noteOn(0, 48, 100)])
        let c0 = R.render(magma, seconds: 1, params: p([(Int(ISD_P_SPARK), 0)]), events: [R.noteOn(0, 48, 100)])
        XCTAssertLessThan(abs(K.dBFS(c1.l) - K.dBFS(c0.l)), 0.5)
    }

    func testEruptChordSwells() {
        let chord = [R.noteOn(0, 28, 120), R.noteOn(0.01, 33, 120), R.noteOn(0.02, 40, 120), R.noteOn(0.03, 45, 120)]
        let spread = [R.noteOn(0, 28, 120), R.noteOn(0.05, 33, 120), R.noteOn(0.10, 40, 120), R.noteOn(0.15, 45, 120)]
        XCTAssertEqual(debug(chord, seconds: 1.5), 1)
        XCTAssertEqual(debug(spread, seconds: 1.5), 0)
        XCTAssertEqual(debug([R.noteOn(0, 60, 127), R.noteOn(0.01, 64, 127), R.noteOn(0.02, 67, 127)], seconds: 0.5), 0, "a high chord")
        XCTAssertEqual(debug([R.noteOn(0, 28, 80), R.noteOn(0.01, 33, 80), R.noteOn(0.02, 40, 80)], seconds: 0.5), 0, "a soft low chord")
        let a = R.render(magma, seconds: 1.5, events: chord), b = R.render(magma, seconds: 1.5, events: spread)
        let ea = K.bandEnergy(R.slice(a.l, 0.25, 0.7), sampleRate: sr, from: 20, to: 60)
        let eb = K.bandEnergy(R.slice(b.l, 0.25, 0.7), sampleRate: sr, from: 20, to: 60)
        XCTAssertGreaterThanOrEqual(db(ea / eb), 2.5)
    }

    func testMagmaCeiling() {
        let params = p([(Int(ISD_P_GROWL), 1), (Int(ISD_P_RES), 0.9), (Int(ISD_P_RUMBLE), 1), (Int(ISD_P_SPACE), 1)])
        let o = R.render(magma, seconds: 3, params: params, events: [28, 35, 40, 47, 52, 59].map { R.noteOn(0, UInt8($0), 127) })
        XCTAssertTrue(o.l.allSatisfy(\.isFinite) && o.r.allSatisfy(\.isFinite))
        XCTAssertLessThanOrEqual(max(K.peak(o.l), K.peak(o.r)), 0.966)
    }

    func testPressureWheelAndPanic() {
        let warm = p([(Int(ISD_P_HEAT), 0.3)])
        let pressed = R.render(magma, seconds: 1, params: warm, events: [R.noteOn(0, 45, 90), R.Event(time: 0.1, bytes: [0xD0, 127])])
        let plain = R.render(magma, seconds: 1, params: warm, events: [R.noteOn(0, 45, 90)])
        XCTAssertGreaterThanOrEqual(db(K.bandEnergy(R.slice(pressed.l, 0.3, 0.9), sampleRate: sr, from: 500, to: 3000)
                                       / K.bandEnergy(R.slice(plain.l, 0.3, 0.9), sampleRate: sr, from: 500, to: 3000)), 4)
        let dry = p([(Int(ISD_P_DEBUG_MB_DRY), 1), (Int(ISD_P_RUMBLE), 0), (Int(ISD_P_HEAT), 1)])
        let bent = R.render(magma, seconds: 1, params: dry, events: [R.noteOn(0, 45, 100), R.Event(time: 0, bytes: [0xE0, 0x7F, 0x7F])])
        XCTAssertLessThan(abs(K.cents(K.fundamental(R.slice(bent.l, 0.2, 1.0), sampleRate: sr, near: hz(47)), hz(47))), 5)
        let wobble = R.render(magma, seconds: 2, params: p([(Int(ISD_P_HEAT), 0.4)]), events: [R.noteOn(0, 45, 90), R.Event(time: 0.05, bytes: [0xB0, 1, 127])])
        var lo = Double.infinity, hi = 0.0, t = 0.5
        while t < 1.8 { let e = K.bandEnergy(R.slice(wobble.l, t, t + 0.02), sampleRate: sr, from: 500, to: 3000); lo = min(lo, e); hi = max(hi, e); t += 0.02 }
        XCTAssertGreaterThan(db(hi / lo), 6, "the mod wheel's wobble")
        let panic = R.render(magma, seconds: 1, events: [R.noteOn(0, 45, 127), R.noteOn(0, 52, 127), R.Event(time: 0.5, bytes: [0xB0, 120, 0])])
        XCTAssertLessThan(K.dBFS(R.slice(panic.l, 0.55, 1.0)), -60)
    }

    func testStealingStaysInThePool() {
        guard let s = isd_synth_create(magma, sr, 256) else { return XCTFail() }
        defer { isd_synth_destroy(s) }
        var l = [Float](repeating: 0, count: 256), r = l
        for i in 0..<40 {
            var on: [UInt8] = [0x90, UInt8(28 + (i * 5) % 30), 110]
            isd_synth_midi(s, &on, 3, 0)
            for _ in 0..<4 { isd_synth_render(s, &l, &r, 256) }
            XCTAssertTrue(l.allSatisfy(\.isFinite))
        }
        XCTAssertLessThanOrEqual(isd_synth_active_voices(s), 12)
    }

    func testStealingDoesNotClick() {
        let velocities = [UInt8](repeating: 105, count: 6)
        let (clicks, out) = R.stealClicks(magma, params: [:], velocities: velocities, gap: 0.25, from: 1)
        XCTAssertTrue(out.l.allSatisfy(\.isFinite))
        XCTAssertLessThan(clicks.max() ?? 99, 3, "dB over the chords without stealing: \(clicks)")
    }
}
