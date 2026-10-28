import XCTest
@testable import InStrumCore

/// The ocean's swell: waves in sets, each breaking at a known moment, shared by the picture and the surf.
final class OceanSwellTests: XCTestCase {
    private func breaks(_ swell: inout OceanSwell, seconds: Double, scale: Float = 1) -> [Wave] {
        swell.scale = scale
        var out: [Wave] = []
        for _ in 0..<Int(seconds * 60) { out += swell.step(dt: 1.0 / 60) }
        return out
    }

    func testSameSeedSameWaves() {
        var a = OceanSwell(seed: 1), b = OceanSwell(seed: 1), c = OceanSwell(seed: 2)
        let wa = breaks(&a, seconds: 120), wb = breaks(&b, seconds: 120), wc = breaks(&c, seconds: 120)
        XCTAssertFalse(wa.isEmpty)
        XCTAssertEqual(wa, wb)
        XCTAssertNotEqual(wa.map(\.breakTime), wc.map(\.breakTime))
    }

    func testPeriodsAndSets() {
        var s = OceanSwell(seed: 3)
        let waves = breaks(&s, seconds: 600)
        for (a, b) in zip(waves, waves.dropFirst()) {
            let gap = b.breakTime - a.breakTime
            XCTAssertGreaterThanOrEqual(gap, 8 - 1.0 / 60); XCTAssertLessThanOrEqual(gap, 12 + 1.0 / 60)
        }
        // Runs of big waves are 3–5 long, lulls 2–4 (the first and last runs may be cut by the window).
        var runs: [(big: Bool, count: Int)] = []
        for w in waves {
            if let last = runs.last, last.big == w.big { runs[runs.count - 1].count += 1 } else { runs.append((w.big, 1)) }
        }
        for r in runs.dropFirst().dropLast() {
            if r.big { XCTAssertTrue((3...5).contains(r.count), "set of \(r.count)") } else { XCTAssertTrue((2...4).contains(r.count), "lull of \(r.count)") }
        }
        XCTAssertGreaterThan(runs.count, 6)
    }

    func testStormIsBigger() {
        var calm = OceanSwell(seed: 5), storm = OceanSwell(seed: 5)
        let a = breaks(&calm, seconds: 600), b = breaks(&storm, seconds: 600, scale: 1.8)
        let mean = { (w: [Wave]) in w.map { Double($0.strength) }.reduce(0, +) / Double(max(1, w.count)) }
        XCTAssertGreaterThan(mean(b), 1.5 * mean(a), "calm \(mean(a)), storm \(mean(b))")
        XCTAssertTrue(b.allSatisfy { $0.strength <= 1 })
    }

    func testWashRisesAfterEachBreakAndDrains() {
        var s = OceanSwell(seed: 7)
        let waves = breaks(&s, seconds: 90)
        // Look back over each break (recent keeps the last six).
        for w in waves.suffix(5) {
            let high = s.washFront(at: w.breakTime + 1.6), drained = s.washFront(at: w.breakTime + 6.5)
            XCTAssertGreaterThan(high, 0.3, "after the break at \(w.breakTime)")
            XCTAssertLessThan(drained, high)
            XCTAssertLessThanOrEqual(high, 1)
        }
        XCTAssertEqual(s.washFront(at: waves[waves.count - 1].breakTime - 0.5), 0, accuracy: 1e-6, "dry just before a break")
    }

    func testWeatherScale() {
        var sky = SkyState()
        for (kind, scale) in [(WeatherKind.clear, Float(1)), (.lightCloud, 1), (.rain, 1.2), (.drizzle, 1.2), (.storm, 1.8), (.mist, 0.8)] {
            sky.weather = kind; sky.nextWeather = kind; sky.weatherBlend = 0
            XCTAssertEqual(OceanSwell.weatherScale(sky), scale, accuracy: 1e-6, kind.rawValue)
        }
        sky.weather = .clear; sky.nextWeather = .storm; sky.weatherBlend = 0.5
        XCTAssertEqual(OceanSwell.weatherScale(sky), 1.4, accuracy: 1e-6)
    }

    func testPhasesWrap() {
        let s = OceanSwell(seed: 1)
        let p = s.phases(at: 36_000), q = s.phases(at: 36_000 + 1.0 / 60)
        for i in 0..<4 {
            XCTAssertGreaterThanOrEqual(p[i], 0); XCTAssertLessThan(p[i], 2 * .pi)
            var d = abs(q[i] - p[i]); if d > .pi { d = 2 * .pi - d }
            XCTAssertLessThan(d, 0.05)
        }
    }

    func testUpcomingIsAhead() {
        var s = OceanSwell(seed: 9)
        _ = breaks(&s, seconds: 30)
        let next = s.upcoming(3)
        XCTAssertEqual(next.count, 3)
        XCTAssertTrue(next.allSatisfy { $0.breakTime > s.time })
        XCTAssertEqual(next.map(\.breakTime), next.map(\.breakTime).sorted())
    }
}
