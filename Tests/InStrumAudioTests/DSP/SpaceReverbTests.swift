import XCTest
import InStrumDSP

final class SpaceReverbTests: XCTestCase {
    let sr = DSPTestKit.sampleRate

    /// Runs `input` (mono, fed to both sides) through a fresh reverb for `seconds`.
    private func render(seconds: Double, size: Float = 0.5, damping: Float = 0.5, predelay: Float = 10, shimmer: Float = 0,
                        input: (Int) -> Float) -> (l: [Float], r: [Float]) {
        let block = 512
        let rv = isd_reverb_create(sr, Int32(block))!
        defer { isd_reverb_destroy(rv) }
        isd_reverb_configure(rv, size, damping, predelay, shimmer)
        let total = Int(seconds * sr)
        var outL = [Float](repeating: 0, count: total), outR = [Float](repeating: 0, count: total)
        var inBuf = [Float](repeating: 0, count: block), l = [Float](repeating: 0, count: block), r = [Float](repeating: 0, count: block)
        var i = 0
        while i < total {
            let n = min(block, total - i)
            for k in 0..<n { inBuf[k] = input(i + k) }
            isd_reverb_process(rv, inBuf, inBuf, &l, &r, Int32(n))
            for k in 0..<n { outL[i + k] = l[k]; outR[i + k] = r[k] }
            i += n
        }
        return (outL, outR)
    }

    private func slice(_ x: [Float], _ a: Double, _ b: Double) -> ArraySlice<Float> { x[DSPTestKit.at(a)..<DSPTestKit.at(b)] }

    func testImpulseTailDecaysAndIsFinite() {
        let out = render(seconds: 5, size: 0.3) { $0 == 0 ? 1 : 0 }
        XCTAssertTrue(out.l.allSatisfy { $0.isFinite } && out.r.allSatisfy { $0.isFinite })
        let early = DSPTestKit.dBFS(slice(out.l, 0, 0.5)), first = DSPTestKit.dBFS(slice(out.l, 0, 1))
        let second = DSPTestKit.dBFS(slice(out.l, 1, 2)), late = DSPTestKit.dBFS(slice(out.l, 3, 4))
        XCTAssertGreaterThan(early, -80, "the reverb produced no tail")
        XCTAssertLessThan(second, first)
        XCTAssertLessThan(late - early, -50)
    }

    func testTailIsWideStereo() {
        let out = render(seconds: 2) { $0 == 0 ? 1 : 0 }
        XCTAssertLessThan(abs(DSPTestKit.correlation(slice(out.l, 0.5, 1.5), slice(out.r, 0.5, 1.5))), 0.5)
    }

    func testSilenceGivesExactZeros() {
        let quiet = render(seconds: 1) { _ in 0 }
        XCTAssertTrue(quiet.l.allSatisfy { $0 == 0 } && quiet.r.allSatisfy { $0 == 0 })
        let tail = render(seconds: 21) { $0 == 0 ? 1 : 0 }
        XCTAssertTrue(slice(tail.l, 20, 21).allSatisfy { $0 == 0 } && slice(tail.r, 20, 21).allSatisfy { $0 == 0 })
    }

    func testShimmerAddsOctaveUp() {
        let burst: (Int) -> Float = { i in i < DSPTestKit.at(0.3) ? Float(sin(2 * .pi * 440 * Double(i) / self.sr)) * 0.5 : 0 }
        let plain = render(seconds: 8, shimmer: 0, input: burst)
        let shimmer = render(seconds: 8, shimmer: 1, input: burst)
        let window = Array(slice(shimmer.l, 1, 2)), plainWindow = Array(slice(plain.l, 1, 2))
        let octave = DSPTestKit.bandEnergy(window, sampleRate: sr, from: 860, to: 900)
        let plainOctave = DSPTestKit.bandEnergy(plainWindow, sampleRate: sr, from: 860, to: 900)
        XCTAssertGreaterThan(octave, 4 * plainOctave + 1e-9)
        // Shimmer never runs away.
        XCTAssertLessThan(DSPTestKit.dBFS(slice(shimmer.l, 6, 7)), DSPTestKit.dBFS(slice(shimmer.l, 1, 2)))
        XCTAssertTrue(shimmer.l.allSatisfy { $0.isFinite })
    }
}
