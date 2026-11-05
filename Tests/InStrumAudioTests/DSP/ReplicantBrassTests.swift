import XCTest
import InStrumDSP

/// Replicant Brass with Chrome Bass (Sets 13 & 14, Task 3; spec 2026-11-05-fire-and-neon-design.md §4.3–§4.4, brief
/// replicant-brass.md). Mirrors Scripts/dsp-harness/brass_test.cpp, where every bound below was measured first.
final class ReplicantBrassTests: XCTestCase {
    typealias R = SynthRender
    typealias K = DSPTestKit
    let brass = ISD_ENGINE_REPLICANT_BRASS
    let sr = DSPTestKit.sampleRate
    lazy var dry: [Int: Float] = [Int(ISD_P_DEBUG_RB_DRY): 1, Int(ISD_P_SPLIT): 0]

    private func hz(_ note: Double) -> Double { 440 * pow(2, (note - 69) / 12) }
    private func db(_ ratio: Double) -> Double { 10 * log10(ratio) }
    private func with(_ base: [Int: Float], _ extra: [(Int, Float)]) -> [Int: Float] {
        var p = base
        for (k, v) in extra { p[k] = v }
        return p
    }
    /// Energy between lo and hi in consecutive frames of `ms`.
    private func frames(_ x: [Float], ms: Double, from lo: Double, to hi: Double) -> [Double] {
        let w = Int(ms * 0.001 * sr)
        return stride(from: 0, to: x.count - w + 1, by: w).map { K.bandEnergy(Array(x[$0..<($0 + w)]), sampleRate: sr, from: lo, to: hi) }
    }

    func testSwellFollowsTheDial() {
        func t90(_ s: Float) -> Double {
            let o = R.render(brass, seconds: 1.2, params: with(dry, [(Int(ISD_P_SWELL_RB), s)]), events: [R.noteOn(0, 60, 90)])
            let e = frames(o.l, ms: 5, from: 1000, to: 4000), m = e.max() ?? 0
            return Double(e.firstIndex { $0 >= 0.9 * m } ?? 999) * 5
        }
        XCTAssertEqual(t90(0), 40, accuracy: 15)
        XCTAssertGreaterThanOrEqual(t90(1), 450)
    }

    func testBlareAtFullVelocity() {
        func peak(_ v: UInt8) -> (share: Double, ms: Double) {
            let o = R.render(brass, seconds: 0.6, params: with(dry, [(Int(ISD_P_UNISON_WIDTH), 0)]), events: [R.noteOn(0, 60, v)])
            let e = frames(o.l, ms: 10, from: 20, to: 20000), h = frames(o.l, ms: 10, from: 1500, to: 20000)
            var best = 0.0, at = 0.0
            for i in 2..<min(40, e.count) where h[i] / e[i] > best { best = h[i] / e[i]; at = Double(i) * 10 }
            return (best, at)
        }
        let hard = peak(127), mid = peak(76)
        XCTAssertGreaterThanOrEqual(hard.share, 1.5 * mid.share)
        XCTAssertLessThanOrEqual(hard.ms, 100)
        XCTAssertGreaterThanOrEqual(mid.ms, 150)
    }

    func testWidthSpreadsTheStack() {
        func corr(_ w: Float) -> Double {
            let o = R.render(brass, seconds: 1, params: with(dry, [(Int(ISD_P_UNISON_WIDTH), w)]), events: [60, 64, 67].map { R.noteOn(0, UInt8($0), 90) })
            return K.correlation(R.slice(o.l, 0.3, 0.9)[...], R.slice(o.r, 0.3, 0.9)[...])
        }
        XCTAssertGreaterThanOrEqual(corr(0), 0.9)
        XCTAssertLessThanOrEqual(corr(1), 0.5)
    }

    func testSplitRoutesAndAMovedSplitStrandsNothing() {
        let p: [Int: Float] = [Int(ISD_P_DEBUG_RB_DRY): 1, Int(ISD_P_ARP_MODE): 0]
        let bassNote = R.slice(R.render(brass, seconds: 0.5, params: p, events: [R.noteOn(0, 36, 100)]).l, 0.05, 0.45)
        let brassNote = R.slice(R.render(brass, seconds: 0.5, params: p, events: [R.noteOn(0, 72, 100)]).l, 0.05, 0.45)
        XCTAssertGreaterThan(K.bandEnergy(bassNote, sampleRate: sr, from: 20, to: 200) / K.bandEnergy(bassNote, sampleRate: sr, from: 20, to: 20000), 0.5)
        XCTAssertLessThan(K.bandEnergy(brassNote, sampleRate: sr, from: 20, to: 200) / K.bandEnergy(brassNote, sampleRate: sr, from: 20, to: 20000), 0.05)
        // C4 held as brass; the split moves to C5 (C4 would now be bass); C4 lets go: its brass voice still releases.
        let out = R.render(brass, seconds: 2.5, params: p, events: [R.noteOn(0, 60, 100), R.noteOff(0.5, 60)],
                           changes: [R.ParamChange(time: 0.25, address: Int(ISD_P_SPLIT), value: 72)])
        XCTAssertLessThan(K.dBFS(R.slice(out.l, 2.0, 2.5)), -80)
    }

    func testChromeArpIsSampleAccurate() {
        let p: [Int: Float] = [Int(ISD_P_DEBUG_RB_DRY): 1, Int(ISD_P_ARP_MODE): 4, Int(ISD_P_ARP_RATE): 3, Int(ISD_P_TEMPO_RB): 120]
        let o = R.render(brass, seconds: 1.6, params: p, events: [R.noteOn(0.1, 36, 100), R.noteOn(0.1, 43, 100)])
        let e = frames(o.l, ms: 1, from: 1500, to: 8000)
        var onsets: [Int] = []
        for i in 3..<(e.count - 1) {
            let before = max(e[i - 1], e[i - 2], e[i - 3])
            if e[i] > 8 * before, e[i] > 1e-6, onsets.last.map({ i - $0 > 50 }) ?? true { onsets.append(i) }
        }
        XCTAssertGreaterThanOrEqual(onsets.count, 8)
        XCTAssertEqual(Double(onsets.first ?? -1), 100, accuracy: 1.5)
        for k in 1..<onsets.count { XCTAssertEqual(Double(onsets[k] - onsets[k - 1]), 125, accuracy: 1.5, "step \(k)") }
    }

    func testBendBladeAndFall() {
        let full = R.Event(time: 0, bytes: [0xE0, 0x7F, 0x7F])
        let bent = R.render(brass, seconds: 1, params: dry, events: [R.noteOn(0, 60, 90), full])
        XCTAssertLessThan(abs(K.cents(K.fundamental(R.slice(bent.l, 0.2, 1.0), sampleRate: sr, near: hz(67)), hz(67))), 10)
        let fell = R.render(brass, seconds: 1, params: dry, events: [R.noteOn(0, 60, 90), full, R.noteOff(0.5, 60)])
        XCTAssertLessThan(abs(K.cents(K.fundamental(R.slice(fell.l, 0.62, 0.8), sampleRate: sr, near: hz(60)), hz(60))), 25)
    }

    func testArpStopsOnPanicThenStartsAFreshGrid() {
        let o = R.render(brass, seconds: 1.2, params: [Int(ISD_P_ARP_MODE): 4],
                         events: [R.noteOn(0, 36, 100), R.noteOn(0, 43, 100), R.noteOn(0, 72, 100), R.Event(time: 0.5, bytes: [0xB0, 120, 0]), R.noteOn(0.8, 38, 100)])
        XCTAssertLessThan(K.dBFS(R.slice(o.l, 0.55, 0.79)), -60)
        let e = frames(o.l, ms: 1, from: 1500, to: 8000)
        let first = (790..<e.count).first { e[$0] > 1e-4 } ?? -1
        XCTAssertTrue((800...802).contains(first), "first onset after the panic at \(first) ms")
    }

    func testReplicantCeiling() {
        let o = R.render(brass, seconds: 3, params: [Int(ISD_P_HALL): 1, Int(ISD_P_BLAZE): 1],
                         events: [36, 43, 48, 55, 60, 64, 67, 71, 74, 79].map { R.noteOn(0, UInt8($0), 127) })
        XCTAssertTrue(o.l.allSatisfy(\.isFinite) && o.r.allSatisfy(\.isFinite))
        XCTAssertLessThanOrEqual(max(K.peak(o.l), K.peak(o.r)), 0.966)
    }

    func testStealingIsClickFree() {
        let steal = R.stealClicks(brass, params: [Int(ISD_P_SPLIT): 0], velocities: [UInt8](repeating: 100, count: 6), gap: 0.25, from: 1)
        XCTAssertTrue(steal.out.l.allSatisfy(\.isFinite))
        XCTAssertLessThan(steal.clicks.max() ?? 99, 3, "dB over the chords without stealing: \(steal.clicks)")
    }
}
