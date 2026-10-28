import XCTest
import InStrumDSP

/// Haze Bells: tuning-fork bells over an airy organ, through a lo-fi haze (docs/superpowers/briefs/haze-bells.md).
final class HazeBellsTests: XCTestCase {
    typealias R = SynthRender
    let bells = ISD_ENGINE_HAZE_BELLS
    /// The brief's echo: a dotted eighth at 132 BPM.
    static let echoSeconds = 0.75 * 60.0 / 132.0
    /// Clean bells: no space, echo, crush or drift, no organ.
    let dry: [Int: Float] = [Int(ISD_P_SPACE): 0, Int(ISD_P_ECHO): 0, Int(ISD_P_CRUSH): 0, Int(ISD_P_DRIFT): 0, Int(ISD_P_ORGAN): 0]

    private func midiHz(_ m: Double) -> Double { 440 * pow(2, (m - 69) / 12) }

    private func band(_ x: [Float], _ lo: Double, _ hi: Double) -> Double {
        DSPTestKit.bandEnergy(x, sampleRate: R.sr, from: lo, to: hi)
    }

    /// RMS in dB of consecutive 50 ms frames.
    private func frames(_ x: [Float]) -> [Double] {
        let n = Int(0.05 * R.sr)
        return stride(from: 0, to: x.count - n, by: n).map { DSPTestKit.dBFS(x[$0..<($0 + n)]) }
    }

    func testTuningWithin2Cents() {
        for m: UInt8 in [48, 60, 72, 84] {
            let out = R.render(bells, seconds: 1.6, params: dry, events: [R.pedal(0, 127), R.noteOn(0.01, m, 100)])
            let ref = midiHz(Double(m))
            let f = DSPTestKit.fundamental(R.slice(out.l, 0.3, 1.5), sampleRate: R.sr, near: ref)
            XCTAssertEqual(DSPTestKit.cents(f, ref), 0, accuracy: 2, "MIDI \(m)")
        }
    }

    func testFineTuneAndTransposeExact() {
        var p = dry; p[Int(ISD_P_FINE_TUNE)] = 37; p[Int(ISD_P_TRANSPOSE)] = 5
        let out = R.render(bells, seconds: 1.6, params: p, events: [R.pedal(0, 127), R.noteOn(0.01, 60, 100)])
        let ref = midiHz(65)
        let f = DSPTestKit.fundamental(R.slice(out.l, 0.3, 1.5), sampleRate: R.sr, near: ref * pow(2, 37.0 / 1200))
        XCTAssertEqual(DSPTestKit.cents(f, ref) - 37, 0, accuracy: 1)
    }

    /// The fork's clang (about 6.25 × f0) is gone long before the pure ring fades.
    func testClangDecaysFasterThanTheFundamental() {
        let out = R.render(bells, seconds: 0.5, params: dry, events: [R.pedal(0, 127), R.noteOn(0, 72, 110)])
        let f0 = midiHz(72)
        let early = R.slice(out.l, 0.02, 0.06), late = R.slice(out.l, 0.30, 0.40)
        let clangDrop = 10 * log10(band(late, 6.25 * f0 * 0.95, 6.25 * f0 * 1.05) / band(early, 6.25 * f0 * 0.95, 6.25 * f0 * 1.05))
        let toneDrop = 10 * log10(band(late, f0 * 0.97, f0 * 1.03) / band(early, f0 * 0.97, f0 * 1.03))
        XCTAssertLessThan(clangDrop, toneDrop - 20, "clang \(clangDrop) dB, tone \(toneDrop) dB")
    }

    func testHarderIsBrighter() {
        let soft = R.render(bells, seconds: 0.25, params: dry, events: [R.noteOn(0, 72, 40)])
        let hard = R.render(bells, seconds: 0.25, params: dry, events: [R.noteOn(0, 72, 120)])
        let cs = DSPTestKit.centroid(R.slice(soft.l, 0, 0.2), sampleRate: R.sr)
        let ch = DSPTestKit.centroid(R.slice(hard.l, 0, 0.2), sampleRate: R.sr)
        XCTAssertGreaterThan(ch, 1.2 * cs, "soft \(cs) Hz, hard \(ch) Hz")
    }

    /// With the pedal down a middle fork rings at least 3 s to −40 dB; a high one fades sooner.
    func testRingLength() {
        func ring(_ m: UInt8) -> Double {
            let out = R.render(bells, seconds: 9, params: dry, events: [R.pedal(0, 127), R.noteOn(0.01, m, 100)])
            let f = frames(out.l), ref = f[2]
            let below = f.indices.first { $0 > 2 && f[$0] < ref - 40 } ?? f.count
            return Double(below) * 0.05
        }
        let middle = ring(60), high = ring(84)
        XCTAssertGreaterThanOrEqual(middle, 3, "MIDI 60 rang \(middle) s")
        XCTAssertLessThan(high, middle, "MIDI 84 rang \(high) s")
    }

    func testOrganAddsSustainedHarmonics() {
        var p = dry; p[Int(ISD_P_BELLS)] = 0; p[Int(ISD_P_ORGAN)] = 1
        let out = R.render(bells, seconds: 2.6, params: p, events: [R.noteOn(0, 57, 100)])
        let f0 = 220.0
        let a = R.slice(out.l, 0.5, 1.0), b = R.slice(out.l, 2.0, 2.5)
        for k in [2.0, 3.0] {
            let early = band(a, k * f0 * 0.98, k * f0 * 1.02), late = band(b, k * f0 * 0.98, k * f0 * 1.02)
            XCTAssertEqual(10 * log10(late / early), 0, accuracy: 3, "harmonic \(k) holds")
            XCTAssertGreaterThan(10 * log10(late / band(b, f0 * 0.98, f0 * 1.02)), -30, "harmonic \(k) is present")
        }
    }

    func testEchoLandsOnTheDottedEighth() {
        var p = dry; p[Int(ISD_P_ECHO)] = 1
        let out = R.render(bells, seconds: 0.8, params: p, events: [R.noteOn(0, 72, 110), R.noteOff(0.05, 72)])
        let x = zip(out.l, out.r).map { abs($0) + abs($1) }
        // The repeat's peak follows the strike's own peak by exactly the echo time.
        let strike = (0..<Int(0.1 * R.sr)).max { x[$0] < x[$1] } ?? 0
        let lo = Int(0.6 * Self.echoSeconds * R.sr), hi = Int(1.4 * Self.echoSeconds * R.sr)
        let peak = (lo..<hi).max { x[$0] < x[$1] } ?? 0
        XCTAssertEqual(Double(peak - strike) / R.sr, Self.echoSeconds, accuracy: 0.002)
    }

    func testCrushOnlyWhenTurnedUp() {
        let clean = R.render(bells, seconds: 1, params: dry, events: [R.pedal(0, 127), R.noteOn(0, 72, 100)])
        var p = dry; p[Int(ISD_P_CRUSH)] = 1
        let crushed = R.render(bells, seconds: 1, params: p, events: [R.pedal(0, 127), R.noteOn(0, 72, 100)])
        let a = band(R.slice(clean.l, 0.3, 0.9), 8000, 20000), b = band(R.slice(crushed.l, 0.3, 0.9), 8000, 20000)
        XCTAssertGreaterThan(10 * log10(b / max(a, 1e-30)), 10)
    }

    func testStealingIsClickFree() {
        let events = [R.pedal(0, 127)] + (0..<30).map { R.noteOn(0.01 + Double($0) * 0.1, UInt8(48 + $0), 100) }
        let out = R.render(bells, seconds: 4, params: dry, events: events)
        XCTAssertTrue(out.l.allSatisfy(\.isFinite) && out.r.allSatisfy(\.isFinite))
        XCTAssertLessThan(DSPTestKit.maxJump(out.l), 0.2)
        XCTAssertLessThan(DSPTestKit.maxJump(out.r), 0.2)
        XCTAssertLessThanOrEqual(out.l.map { abs($0) }.max() ?? 2, 1.0)
    }

    func testDialSweepIsSmooth() {
        let dials = [ISD_P_BELLS, ISD_P_ORGAN, ISD_P_ECHO, ISD_P_CRUSH, ISD_P_DRIFT].map { Int($0) }
        var start = dry
        for d in dials { start[d] = 0.2 }
        let changes = dials.map { SynthRender.ParamChange(time: 3.0, address: $0, value: 1) }
        let out = R.render(bells, seconds: 3.25, params: start, events: [R.pedal(0, 127), R.noteOn(0.01, 57, 100)], changes: changes)
        let before = DSPTestKit.maxJump(R.slice(out.l, 2.8, 2.95)), after = DSPTestKit.maxJump(R.slice(out.l, 2.95, 3.1))
        let settled = DSPTestKit.maxJump(R.slice(out.l, 3.1, 3.25))
        XCTAssertLessThan(after, 2 * max(before, settled) + 1e-4, "before \(before), after \(after), settled \(settled)")
    }

    func testParameterTable() {
        let count = Int(isd_synth_param_count(bells))
        let infos = (0..<count).compactMap { isd_synth_param_info(bells, Int32($0)) }.map { $0.pointee }
        XCTAssertEqual(infos.map { String(cString: $0.identifier) },
                       ["fineTune", "transpose", "bells", "organ", "echo", "crush", "drift", "space",
                        "moodEnergy", "moodWarmth", "moodBrightness", "moodSpace", "moodMotion"])
        let defaults = Dictionary(uniqueKeysWithValues: infos.map { (String(cString: $0.identifier), $0.defaultValue) })
        XCTAssertEqual(defaults["bells"], 0.80); XCTAssertEqual(defaults["organ"], 0.25); XCTAssertEqual(defaults["echo"], 0.35)
        XCTAssertEqual(defaults["crush"], 0.15); XCTAssertEqual(defaults["drift"], 0.30); XCTAssertEqual(defaults["space"], 0.50)
    }

    /// Switching between the built-ins shouldn't jump the volume: a mezzo-forte chord on each sits within 3 dB of Felt Glass's.
    func testBuiltInsShareOneLoudness() {
        let chord = [59, 62, 66, 71].map { R.noteOn(0, UInt8($0), 90) }
        func level(_ engine: ISDEngine) -> Double { DSPTestKit.dBFS(R.slice(R.render(engine, seconds: 1.5, events: chord).l, 0.05, 1.5)) }
        let felt = level(ISD_ENGINE_FELT_GLASS)
        for (name, engine) in [("Orbit Pad", ISD_ENGINE_ORBIT_PAD), ("Honey Tape", ISD_ENGINE_HONEY_TAPE), ("Haze Bells", ISD_ENGINE_HAZE_BELLS)] {
            XCTAssertEqual(level(engine), felt, accuracy: 3, name)
        }
    }

    func testExtremesStayFinite() {
        let dials = [ISD_P_BELLS, ISD_P_ORGAN, ISD_P_ECHO, ISD_P_CRUSH, ISD_P_DRIFT, ISD_P_SPACE].map { Int($0) }
        for value: Float in [0, 1] {
            let p = Dictionary(uniqueKeysWithValues: dials.map { ($0, value) })
            let events = [R.pedal(0, 127)] + (0..<12).map { R.noteOn(0.01 + Double($0) * 0.05, UInt8(36 + $0 * 5), 127) }
            let out = R.render(bells, seconds: 5, params: p, events: events)
            XCTAssertTrue(out.l.allSatisfy { $0.isFinite && abs($0) <= 1 } && out.r.allSatisfy { $0.isFinite && abs($0) <= 1 }, "dials at \(value)")
        }
    }
}
