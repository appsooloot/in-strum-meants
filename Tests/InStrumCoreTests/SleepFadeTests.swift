import XCTest
@testable import InStrumCore

/// The sleep fade's clock (spec §3, Small Wins Task 5; Review focus 4 and 6). Every bound was measured first on a Python
/// mirror of `SleepFade` that reads it the same way; the measured values are in the comments.
final class SleepFadeTests: XCTestCase {
    private typealias Reading = (t: Double, gain: Float, dim: Double)

    /// What the player does, and when.
    private enum Act { case wake, off, start(Int) }

    private func apply(_ act: Act, to f: inout SleepFade, at t: Double) {
        switch act {
        case .wake: f.wake(at: t)
        case .off: f.turnOff(at: t)
        case .start(let minutes): f.start(minutes: minutes, at: t)
        }
    }

    /// A 15-minute timer set at 0: it fades from 300 s to its end at 900 s.
    private func fifteen() -> SleepFade {
        var f = SleepFade()
        f.start(minutes: 15, at: 0)
        return f
    }

    /// Reads the fade every 0.01 s from `from` to `to`, doing each act at its own time first.
    private func readings(_ fade: SleepFade, from: Double, to: Double, _ acts: [(at: Double, act: Act)]) -> [Reading] {
        var f = fade, next = 0, out: [Reading] = []
        for i in 0...Int(((to - from) * 100).rounded()) {
            let t = from + Double(i) / 100
            while next < acts.count, acts[next].at <= t + 1e-9 {
                apply(acts[next].act, to: &f, at: acts[next].at)
                next += 1
            }
            out.append((t, f.gain(at: t), f.dim(at: t)))
        }
        return out
    }

    /// The most the gain and the dim move over any 0.1 s.
    private func largestMoves(_ r: [Reading]) -> (gain: Float, dim: Double) {
        var gain: Float = 0, dim = 0.0
        for i in 10..<r.count {
            gain = max(gain, abs(r[i].gain - r[i - 10].gain))
            dim = max(dim, abs(r[i].dim - r[i - 10].dim))
        }
        return (gain, dim)
    }

    /// The most the exposure the dim leaves, exp2(−dim), rises within any `FlashLimiter.window`.
    private func largestRise(_ r: [Reading]) -> Double {
        let span = Int((FlashLimiter.window * 100).rounded()), e = r.map { exp2(-$0.dim) }
        var rise = 0.0
        for i in span..<e.count { rise = max(rise, e[i] - e[(i - span)...i].min()!) }
        return rise
    }

    func testGainCurve() {
        let f = fifteen()
        XCTAssertTrue(stride(from: 0.0, to: 300, by: 0.5).allSatisfy { f.gain(at: $0) == 1 }, "full until the fade")
        // Measured: 1, 0.85369986, 0.50050002, 0.14730017 and 0.0010000000475 (−60.0000 dB).
        let points: [(p: Double, gain: Float)] = [(0, 1), (0.25, 0.853700), (0.5, 0.500500), (0.75, 0.147300), (1, 0.001)]
        for (p, gain) in points {
            XCTAssertEqual(SleepFade.curve(p), gain, accuracy: 1e-6, "p \(p)")
            XCTAssertEqual(f.gain(at: p < 1 ? 300 + 600 * p : 900 - 1e-6), gain, accuracy: 1e-6, "p \(p)")
        }
        XCTAssertEqual(SleepFade.curve(1), SleepFade.endGain)
        XCTAssertEqual(20 * log10(Double(SleepFade.endGain)), -60, accuracy: 0.01)
        var rises = 0, last: Float = 1
        for i in 0...4000 {
            let g = f.gain(at: Double(i) / 4)
            if g > last { rises += 1 }
            last = g
        }
        XCTAssertEqual(rises, 0, "never rising")
        for t in [900.0, 900.25, 901, 5000] { XCTAssertEqual(f.gain(at: t), 0, "silent from the end, at \(t) s") }
    }

    func testShortTimersFadeAllTheWay() {
        var f = SleepFade()
        f.start(minutes: 6, at: 0)
        XCTAssertTrue(f.isFading(at: 0))
        XCTAssertEqual(f.remaining(at: 0), 360)
        XCTAssertEqual(f.gain(at: 0), 1)
        XCTAssertEqual(f.gain(at: 180), 0.5005, accuracy: 1e-6)
        XCTAssertEqual(f.dim(at: 180), 0.5, accuracy: 1e-9)
        XCTAssertEqual(f.gain(at: 359.999), 0.001, accuracy: 1e-6)
        XCTAssertEqual(f.gain(at: 360), 0)
        // Every timer on the moon's menu fades over just its last 10 minutes.
        for minutes in SleepFade.choices {
            var c = SleepFade()
            c.start(minutes: minutes, at: 1000)
            let fadeStart = 1000 + Double(minutes * 60) - SleepFade.fadeSeconds
            XCTAssertFalse(c.isFading(at: fadeStart - 0.001), "\(minutes) min")
            XCTAssertTrue(c.isFading(at: fadeStart), "\(minutes) min")
            XCTAssertEqual(c.gain(at: fadeStart + 300), 0.5005, accuracy: 1e-6, "\(minutes) min")
        }
    }

    func testDimFollowsTheFade() {
        let f = fifteen()
        for t in [0.0, 150, 299.9, 300] { XCTAssertEqual(f.dim(at: t), 0, "before the fade, at \(t) s") }
        XCTAssertEqual(f.dim(at: 600), 0.5, accuracy: 1e-12)
        for t in [900.0, 900.1, 5000] { XCTAssertEqual(f.dim(at: t), 1, "from the end, at \(t) s") }
        // The light falls with the sound: the dim is 1 − (gain − 0.001)/0.999 throughout (measured within 2.9e-8).
        for t in stride(from: 300.0, to: 900, by: 7.5) {
            XCTAssertEqual(f.dim(at: t), 1 - (Double(f.gain(at: t)) - 0.001) / 0.999, accuracy: 1e-6, "\(t) s")
        }
    }

    func testANoteRestoresOverThreeSeconds() {
        var f = fifteen()
        XCTAssertTrue(f.wake(at: 600))   // p 0.5
        for s in [0, 1.5, 3] {
            // Measured within 2.3e-8 and 1.1e-16.
            XCTAssertEqual(f.gain(at: 600 + s), Float(0.5005 + 0.4995 * s / 3), accuracy: 1e-4, "\(s) s in")
            XCTAssertEqual(f.dim(at: 600 + s), 0.5 * (1 - s / 3), accuracy: 1e-4, "\(s) s in")
        }
        XCTAssertNil(f.remaining(at: 600), "waking turns the timer Off")
        XCTAssertFalse(f.isFading(at: 600))
        XCTAssertFalse(f.isOff(at: 602.9), "still gliding")
        for t in [603.0, 603.1, 900, 3600] {
            XCTAssertTrue(f.isOff(at: t), "\(t) s")
            XCTAssertEqual(f.gain(at: t), 1, "\(t) s")
            XCTAssertEqual(f.dim(at: t), 0, "\(t) s")
        }
    }

    func testTheTimerEndsOff() {
        var f = fifteen()
        XCTAssertEqual(f.remaining(at: 899.5), 0.5)
        for t in [900.0, 900.5, 3600] {
            XCTAssertNil(f.remaining(at: t), "\(t) s")
            XCTAssertEqual(f.gain(at: t), 0, "\(t) s")
            XCTAssertEqual(f.dim(at: t), 1, "\(t) s")
            XCTAssertTrue(f.isFading(at: t), "it rests dim and silent until woken")
            XCTAssertFalse(f.isOff(at: t), "\(t) s")
        }
        XCTAssertTrue(f.wake(at: 3600), "a wake restores")
        XCTAssertEqual(f.gain(at: 3601.5), 0.5, accuracy: 1e-4)
        XCTAssertEqual(f.dim(at: 3601.5), 0.5, accuracy: 1e-4)
        XCTAssertEqual(f.gain(at: 3603), 1)
        XCTAssertEqual(f.dim(at: 3603), 0)
        XCTAssertTrue(f.isOff(at: 3603))
    }

    func testInputBeforeTheFadeIsIgnored() {
        var f = fifteen()
        XCTAssertFalse(f.wake(at: 100))
        XCTAssertFalse(f.wake(at: 299.9))
        XCTAssertEqual(f.remaining(at: 100), 800)
        // Playing from before the fade, passed again on a tick inside it, still never cancels it.
        XCTAssertFalse(f.wake(at: 250))
        XCTAssertTrue(f.isFading(at: 610))
        XCTAssertEqual(f.gain(at: 600), 0.5005, accuracy: 1e-6, "the fade still comes")
        var off = SleepFade()
        XCTAssertFalse(off.wake(at: 100), "with no timer there is nothing to wake")
        XCTAssertTrue(off.isOff(at: 100))
    }

    func testTurningOffWakesOrStops() {
        var f = fifteen()
        f.turnOff(at: 100)
        XCTAssertNil(f.remaining(at: 100))
        XCTAssertTrue(f.isOff(at: 100))
        XCTAssertEqual(f, SleepFade(), "before the fade, Off just stops it")
        XCTAssertEqual(f.gain(at: 600), 1)
        for t in [600.0, 950] {   // in the fade, and resting after it
            var g = fifteen()
            g.turnOff(at: t)
            XCTAssertNil(g.remaining(at: t), "\(t) s")
            XCTAssertFalse(g.isFading(at: t), "\(t) s")
            XCTAssertFalse(g.isOff(at: t), "Off wakes a dim world over 3 s, at \(t) s")
            XCTAssertEqual(g.gain(at: t + 3), 1, "\(t) s")
            XCTAssertEqual(g.dim(at: t + 3), 0, "\(t) s")
            XCTAssertTrue(g.isOff(at: t + 3), "\(t) s")
        }
        var h = fifteen()
        h.wake(at: 950)
        h.turnOff(at: 951)
        XCTAssertEqual(h.gain(at: 951.5), 0.5, accuracy: 1e-4, "Off lets a glide finish")
        var r = fifteen()
        r.start(minutes: 30, at: 100)
        XCTAssertEqual(r.remaining(at: 100), 1800, "a new time counts down afresh")
        XCTAssertFalse(r.isFading(at: 1299))
        XCTAssertTrue(r.isFading(at: 1300))
    }

    func testWakingAtTheEdges() {
        // Measured: 0.0333 at most for both (a glide back from silence, or from night); 0.0167 from mid-fade.
        let cases: [(String, [(at: Double, act: Act)])] = [
            ("a wake 0.5 s before the end", [(899.5, .wake)]),
            ("a wake 1 s after the end", [(901, .wake)]),
            ("twice in a glide", [(901, .wake), (902, .wake)]),
            ("twice in a glide mid-fade", [(600, .wake), (601.5, .wake)]),
            ("a new time while resting", [(950, .start(30))]),
            ("a new time mid-fade", [(600, .start(30))]),
            ("a new time 1 s into a wake from the end", [(900, .wake), (901, .start(30))]),
        ]
        for (name, acts) in cases {
            let r = readings(fifteen(), from: acts[0].at - 5, to: acts[acts.count - 1].at + 5, acts)
            let moves = largestMoves(r)
            XCTAssertLessThanOrEqual(moves.gain, 0.034, name)
            XCTAssertLessThanOrEqual(moves.dim, 0.034, name)
            XCTAssertEqual(r[r.count - 1].gain, 1, name)
            XCTAssertEqual(r[r.count - 1].dim, 0, name)
        }
        var twice = fifteen()
        XCTAssertTrue(twice.wake(at: 901))
        XCTAssertFalse(twice.wake(at: 902), "a second wake leaves the glide alone")
        XCTAssertEqual(twice.gain(at: 902.5), 0.5, accuracy: 1e-4)
        XCTAssertEqual(twice.gain(at: 904), 1)
        var renewed = fifteen()
        renewed.wake(at: 900)
        renewed.start(minutes: 30, at: 901)
        XCTAssertEqual(renewed.gain(at: 901.5), 0.5, accuracy: 0.01, "the glide carries on")
        XCTAssertEqual(renewed.dim(at: 901.5), 0.5, accuracy: 0.01)
        XCTAssertEqual(renewed.gain(at: 903), 1)
        XCTAssertEqual(renewed.dim(at: 903), 0)
        XCTAssertEqual(renewed.remaining(at: 903), 1798)
        XCTAssertEqual(renewed.gain(at: 2401), 0.5005, accuracy: 1e-6, "and the new timer fades in its turn (2101…2701 s)")
        var chosen = fifteen()
        chosen.start(minutes: 30, at: 950)
        XCTAssertEqual(chosen.gain(at: 951.5), 0.5, accuracy: 0.01, "a new time chosen while dim glides back too")
        XCTAssertEqual(chosen.dim(at: 951.5), 0.5, accuracy: 0.01)
        XCTAssertEqual(chosen.remaining(at: 950), 1800)
        XCTAssertFalse(chosen.isFading(at: 950))
    }

    func testWakingNeverFlashes() {
        var worst = 0.0
        for w in stride(from: 300.0, through: 905, by: 5) {   // a wake every 5 s through the fade and the rest after it
            worst = max(worst, largestRise(readings(fifteen(), from: w - 0.5, to: w + 3.5, [(w, .wake)])))
        }
        let edges: [[(at: Double, act: Act)]] = [
            [(899.5, .wake)], [(901, .wake), (902, .wake)], [(950, .start(30))], [(600, .start(30))], [(950, .off)],
            [(901, .wake), (902, .start(6))],
        ]
        for acts in edges {
            worst = max(worst, largestRise(readings(fifteen(), from: acts[0].at - 1, to: acts[acts.count - 1].at + 4, acts)))
        }
        // Measured: 0.02284, 1 − 2^(−0.1/3), as a glide back from night ends. A flash is a rise of 0.25.
        XCTAssertLessThan(worst, 0.025)
        XCTAssertGreaterThan(worst, 0.02, "the light did come back")
    }
}
