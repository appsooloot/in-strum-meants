import XCTest
import InStrumDSP

/// Ambience generators through the C API.
final class AmbienceTests: XCTestCase {
    static let sr = DSPTestKit.sampleRate
    typealias Action = (time: Double, apply: (OpaquePointer) -> Void)

    /// Renders `seconds` of ambience; `actions` run at the start of the block containing their time.
    static func render(seconds: Double, seed: UInt64 = 1, block: Int = 256, actions: [Action]) -> (l: [Float], r: [Float]) {
        guard let a = isd_ambience_create(sr, Int32(block), seed) else { return ([], []) }
        defer { isd_ambience_destroy(a) }
        let total = Int(seconds * sr)
        var left = [Float](repeating: 0, count: total), right = [Float](repeating: 0, count: total)
        let pending = actions.sorted { $0.time < $1.time }
        var next = 0, i = 0
        while i < total {
            let n = min(block, total - i)
            while next < pending.count, Int(pending[next].time * sr) < i + n { pending[next].apply(a); next += 1 }
            left.withUnsafeMutableBufferPointer { lp in
                right.withUnsafeMutableBufferPointer { rp in isd_ambience_render(a, lp.baseAddress! + i, rp.baseAddress! + i, Int32(n)) }
            }
            i += n
        }
        return (left, right)
    }

    static func level(_ s: ISDAmbienceSource, _ v: Float, at t: Double = 0) -> Action { (t, { isd_ambience_set_level($0, s, v) }) }

    /// RMS of each 0.5 s window, in dBFS.
    static func windows(_ x: [Float], seconds: Double = 0.5) -> [Double] {
        let n = Int(seconds * sr)
        return stride(from: 0, to: x.count - n + 1, by: n).map { DSPTestKit.dBFS(x[$0..<($0 + n)]) }
    }

    func testEachSourceInItsBand() {
        let bands: [(ISDAmbienceSource, String, ClosedRange<Double>, ClosedRange<Double>)] = [
            (ISD_AMB_WATER, "water", 150...1500, -30 ... -18),
            (ISD_AMB_CRICKETS, "crickets", 3500...6500, -36 ... -18),
            (ISD_AMB_BREEZE, "breeze", 200...2000, -30 ... -18),
            (ISD_AMB_RAIN_WATER, "rain on water", 800...4000, -30 ... -18),
            (ISD_AMB_RAIN_GLASS, "rain on glass", 1500...12000, -30 ... -18),
            (ISD_AMB_DAWN_CHORUS, "dawn chorus", 2000...6500, -36 ... -18),
            (ISD_AMB_SHIP_HUM, "ship hum", 20...250, -30 ... -18),
            (ISD_AMB_AIR_FLOW, "air flow", 300...3000, -30 ... -18),
            (ISD_AMB_WIND, "wind", 100...1500, -30 ... -18),
        ]
        for (source, name, band, loudness) in bands {
            let out = Self.render(seconds: 20, actions: [Self.level(source, 1)])
            let steady = SynthRender.slice(out.l, 3, 20)
            let centroid = DSPTestKit.averageCentroid(steady, sampleRate: Self.sr), db = DSPTestKit.dBFS(steady)
            XCTAssertTrue(band.contains(centroid), "\(name): centroid \(Int(centroid)) Hz")
            XCTAssertTrue(loudness.contains(db), "\(name): \(String(format: "%.1f", db)) dBFS")
            XCTAssertTrue(out.l.allSatisfy(\.isFinite) && out.r.allSatisfy(\.isFinite), name)
        }
    }

    /// Owl, chime and hull ticks are rare: at least one event in 300 s, silent most of the time.
    func testRareEventsHappen() {
        for (source, name) in [(ISD_AMB_OWL, "owl"), (ISD_AMB_CHIME, "chime"), (ISD_AMB_HULL_TICKS, "hull ticks")] {
            let out = Self.render(seconds: 300, actions: [Self.level(source, 1)])
            let w = Self.windows(out.l)
            let loud = w.filter { $0 > -60 }.count
            XCTAssertGreaterThanOrEqual(loud, 1, "\(name): no event in 300 s")
            XCTAssertLessThan(Double(loud) / Double(w.count), 0.25, "\(name) is not rare")
            XCTAssertLessThanOrEqual(max(out.l.map(abs).max() ?? 0, out.r.map(abs).max() ?? 0), 1, name)
        }
    }

    func testLevelsCrossFade() {
        let out = Self.render(seconds: 12, actions: [Self.level(ISD_AMB_WATER, 1)])
        let early = DSPTestKit.dBFS(SynthRender.slice(out.l, 0.4, 0.5)), steady = DSPTestKit.dBFS(SynthRender.slice(out.l, 4, 12))
        XCTAssertLessThan(early, steady - 6, "early \(early) steady \(steady)")
        XCTAssertGreaterThan(steady, -40)
        // A level that stepped instead of gliding would click in the fade's first second. (Steady water at
        // −24 dBFS has natural sample steps up to about 0.06, so the whole render is checked for clicks only.)
        XCTAssertLessThan(DSPTestKit.maxJump(SynthRender.slice(out.l, 0, 1)), 0.05)
        XCTAssertLessThan(DSPTestKit.maxJump(SynthRender.slice(out.r, 0, 1)), 0.05)
        XCTAssertLessThan(DSPTestKit.maxJump(out.l), 0.15)
    }

    func testDucking() {
        let out = Self.render(seconds: 12, actions: [Self.level(ISD_AMB_AIR_FLOW, 1),
                                                     (5, { isd_ambience_set_activity($0, 1) }),
                                                     (8, { isd_ambience_set_activity($0, 0) })])
        let before = DSPTestKit.dBFS(SynthRender.slice(out.l, 4, 5))
        let ducked = DSPTestKit.dBFS(SynthRender.slice(out.l, 5.5, 6))
        let back = DSPTestKit.dBFS(SynthRender.slice(out.l, 11, 12))
        XCTAssertGreaterThan(before - ducked, 3, "ducked \(before - ducked) dB")
        XCTAssertLessThan(before - ducked, 5, "ducked \(before - ducked) dB")
        XCTAssertEqual(back, before, accuracy: 1)
    }

    func testThunderFollowsLightning() {
        let bed: [Action] = [Self.level(ISD_AMB_RAIN_WATER, 0.5)]
        let quiet = Self.render(seconds: 12, actions: bed)
        let storm = Self.render(seconds: 12, actions: bed + [(3, { isd_ambience_trigger_thunder($0, 0.5) })])
        let low = { (x: [Float]) in DSPTestKit.bandEnergy(SynthRender.slice(x, 4, 11), sampleRate: Self.sr, from: 20, to: 200) }
        XCTAssertGreaterThan(10 * log10(low(storm.l) / max(low(quiet.l), 1e-12)), 6)
        let beforeStrike = DSPTestKit.dBFS(SynthRender.slice(storm.l, 3, 3.4)) - DSPTestKit.dBFS(SynthRender.slice(quiet.l, 3, 3.4))
        XCTAssertEqual(beforeStrike, 0, accuracy: 1, "thunder waits for the distance delay")
    }

    func testClosenessChangesTheRoom() {
        let near = Self.render(seconds: 10, actions: [Self.level(ISD_AMB_WATER, 1), (0, { isd_ambience_set_closeness($0, 1) })])
        let far = Self.render(seconds: 10, actions: [Self.level(ISD_AMB_WATER, 1), (0, { isd_ambience_set_closeness($0, 0) })])
        let c = { (x: [Float]) in DSPTestKit.averageCentroid(SynthRender.slice(x, 3, 10), sampleRate: Self.sr) }
        XCTAssertGreaterThan(c(near.l), c(far.l), "distant ambience loses its top")
        XCTAssertTrue(far.l.allSatisfy(\.isFinite))
    }

    func testSilentByDefault() {
        let out = Self.render(seconds: 1, actions: [])
        XCTAssertLessThan(DSPTestKit.dBFS(out.l), -150)
    }
}
