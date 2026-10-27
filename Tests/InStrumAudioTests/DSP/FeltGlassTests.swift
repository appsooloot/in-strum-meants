import XCTest
import InStrumDSP

final class FeltGlassTests: XCTestCase {
    typealias R = SynthRender
    let dry: [Int: Float] = [Int(ISD_P_SPACE): 0]

    private func midiHz(_ m: Double) -> Double { 440 * pow(2, (m - 69) / 12) }

    func testTuningWithin2Cents() {
        for m: UInt8 in [33, 45, 57, 69, 81, 93, 105] {
            let out = R.render(seconds: 1.4, params: dry, events: [R.noteOn(0, m, 100)])
            let ref = midiHz(Double(m))
            let f = DSPTestKit.fundamental(R.slice(out.l, 0.3, 1.3), sampleRate: R.sr, near: ref)
            XCTAssertEqual(DSPTestKit.cents(f, ref), 0, accuracy: 2, "MIDI \(m) measured \(f) Hz")
        }
    }

    func testFineTuneAndTransposeExact() {
        var fine = dry; fine[Int(ISD_P_FINE_TUNE)] = 37
        let a = R.render(seconds: 1.4, params: fine, events: [R.noteOn(0, 69, 100)])
        let fa = DSPTestKit.fundamental(R.slice(a.l, 0.3, 1.3), sampleRate: R.sr, near: 440 * pow(2, 37.0 / 1200))
        XCTAssertEqual(DSPTestKit.cents(fa, 440), 37, accuracy: 1)
        var shifted = dry; shifted[Int(ISD_P_TRANSPOSE)] = -5
        let b = R.render(seconds: 1.4, params: shifted, events: [R.noteOn(0, 69, 100)])
        let ref = midiHz(64)
        XCTAssertEqual(DSPTestKit.cents(DSPTestKit.fundamental(R.slice(b.l, 0.3, 1.3), sampleRate: R.sr, near: ref), ref), 0, accuracy: 1)
    }

    func testSofterIsDarker() {
        let soft = R.render(seconds: 0.3, params: dry, events: [R.noteOn(0, 60, 30)])
        let hard = R.render(seconds: 0.3, params: dry, events: [R.noteOn(0, 60, 110)])
        let cs = DSPTestKit.centroid(soft.l, sampleRate: R.sr), ch = DSPTestKit.centroid(hard.l, sampleRate: R.sr)
        XCTAssertLessThan(cs, 0.7 * ch, "soft \(cs) Hz vs hard \(ch) Hz")
    }

    func testReleaseDampsQuickly() {
        let out = R.render(seconds: 3.6, params: dry, events: [R.noteOn(0, 60, 100), R.noteOff(1, 60)])
        XCTAssertLessThan(DSPTestKit.dBFS(R.slice(out.l, 3.5, 3.6)), -90)
    }

    /// With the pedal down a released note keeps ringing: 1 s after key-up it is still within 30 dB of its attack
    /// (a damped note is below −90 dBFS by then).
    func testPedalKeepsRinging() {
        let out = R.render(seconds: 2.2, params: dry, events: [R.pedal(0, 127), R.noteOn(0, 60, 100), R.noteOff(1, 60)])
        let attack = DSPTestKit.dBFS(R.slice(out.l, 0, 0.3)), ringing = DSPTestKit.dBFS(R.slice(out.l, 2.0, 2.1))
        XCTAssertGreaterThan(ringing, attack - 30, "attack \(attack) dBFS, ringing \(ringing) dBFS")
    }

    func testGlassDialAddsBloom() {
        var none = dry; none[Int(ISD_P_GLASS)] = 0
        var full = dry; full[Int(ISD_P_GLASS)] = 1
        let f0 = midiHz(60)
        let a = R.render(seconds: 1.5, params: none, events: [R.noteOn(0, 60, 100)])
        let b = R.render(seconds: 1.5, params: full, events: [R.noteOn(0, 60, 100)])
        let ea = DSPTestKit.bandEnergy(R.slice(a.l, 0.8, 1.5), sampleRate: R.sr, from: 2 * f0 * 0.97, to: 20_000)
        let eb = DSPTestKit.bandEnergy(R.slice(b.l, 0.8, 1.5), sampleRate: R.sr, from: 2 * f0 * 0.97, to: 20_000)
        XCTAssertGreaterThan(eb, 3 * ea)
    }

    func testStealingIsClickFree() {
        var events = [R.pedal(0, 127)]
        for i in 0..<40 { events.append(R.noteOn(Double(i) * 0.05, UInt8(36 + i), 90)) }
        let out = R.render(seconds: 3, params: dry, events: events)
        XCTAssertTrue(out.l.allSatisfy(\.isFinite) && out.r.allSatisfy(\.isFinite))
        XCTAssertLessThan(DSPTestKit.maxJump(out.l), 0.2)
        XCTAssertLessThan(DSPTestKit.maxJump(out.r), 0.2)
        XCTAssertLessThanOrEqual(out.l.map { abs($0) }.max() ?? 2, 1.0)
        XCTAssertLessThanOrEqual(out.r.map { abs($0) }.max() ?? 2, 1.0)
    }

    func testDialSweepIsSmooth() {
        var start = dry; start[Int(ISD_P_GLASS)] = 0; start[Int(ISD_P_WARMTH)] = 0
        let out = R.render(seconds: 0.7, params: start, events: [R.noteOn(0, 60, 100)],
                           changes: [.init(time: 0.5, address: Int(ISD_P_GLASS), value: 1),
                                     .init(time: 0.5, address: Int(ISD_P_WARMTH), value: 1)])
        let before = DSPTestKit.maxJump(R.slice(out.l, 0.3, 0.45)), after = DSPTestKit.maxJump(R.slice(out.l, 0.45, 0.6))
        XCTAssertLessThan(after, 2 * before)
    }

    func testSilenceIsExact() {
        let quiet = R.render(seconds: 2, params: dry, events: [])
        XCTAssertTrue(quiet.l.allSatisfy { $0 == 0 } && quiet.r.allSatisfy { $0 == 0 })
        let tail = R.render(seconds: 27, params: [Int(ISD_P_SPACE): 0.5], events: [R.noteOn(0, 60, 100), R.noteOff(1, 60)])
        XCTAssertTrue(R.slice(tail.l, 26, 27).allSatisfy { $0 == 0 } && R.slice(tail.r, 26, 27).allSatisfy { $0 == 0 })
    }

    func testMIDIEdgeCases() {
        // A velocity-0 note-on is a note-off.
        let off = R.render(seconds: 2, params: dry, events: [R.noteOn(0, 60, 100), R.noteOff(0.5, 60)])
        let zero = R.render(seconds: 2, params: dry, events: [R.noteOn(0, 60, 100), .init(time: 0.5, bytes: [0x90, 60, 0])])
        XCTAssertEqual(R.maxAbsDifference(off.l, zero.l), 0, accuracy: 1e-6)
        // All Notes Off silences within 50 ms.
        let allOff = R.render(seconds: 0.6, params: dry, events: [R.noteOn(0, 60, 100), .init(time: 0.5, bytes: [0xB0, 123, 0])])
        XCTAssertLessThan(DSPTestKit.dBFS(R.slice(allOff.l, 0.55, 0.6)), -80)
        // The sustain pedal switches at 64.
        let up = R.render(seconds: 2.2, params: dry, events: [R.pedal(0, 63), R.noteOn(0, 60, 100), R.noteOff(1, 60)])
        let down = R.render(seconds: 2.2, params: dry, events: [R.pedal(0, 64), R.noteOn(0, 60, 100), R.noteOff(1, 60)])
        XCTAssertLessThan(DSPTestKit.dBFS(R.slice(up.l, 2.0, 2.1)), -90)
        XCTAssertGreaterThan(DSPTestKit.dBFS(R.slice(down.l, 2.0, 2.1)), DSPTestKit.dBFS(R.slice(down.l, 0, 0.3)) - 30)
        // Pitch bend and clock are ignored.
        let plain = R.render(seconds: 1, params: dry, events: [R.noteOn(0, 60, 100)])
        let noisy = R.render(seconds: 1, params: dry, events: [R.noteOn(0, 60, 100), .init(time: 0.2, bytes: [0xE0, 0x00, 0x60]),
                                                               .init(time: 0.3, bytes: [0xF8])])
        XCTAssertEqual(R.maxAbsDifference(plain.l, noisy.l), 0, accuracy: 1e-6)
    }

    func testParameterTable() {
        let count = Int(isd_synth_param_count(ISD_ENGINE_FELT_GLASS))
        let ids = (0..<count).compactMap { isd_synth_param_info(ISD_ENGINE_FELT_GLASS, Int32($0)) }.map { String(cString: $0.pointee.identifier) }
        XCTAssertEqual(Set(ids), ["fineTune", "transpose", "space", "felt", "glass", "warmth", "ring", "width",
                                  "moodEnergy", "moodWarmth", "moodBrightness", "moodSpace", "moodMotion"])
    }
}
