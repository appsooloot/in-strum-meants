import XCTest
import simd
@testable import InStrumCore

final class MarineSnowTests: XCTestCase {
    private func inside(_ p: SIMD3<Float>) -> Bool {
        p.x >= 0 && p.x <= 1 && p.y >= 0 && p.y <= 1 && p.z >= 0 && p.z <= 1
    }

    /// 150 / 300 / 400 flecks by quality, always inside the volume over five simulated minutes (current or none, an
    /// upwelling, huge and odd inputs), each recycled as it leaves; deterministic from its seed, stepping in place.
    func testMarineSnowBounded() {
        XCTAssertEqual(MarineSnow.count(.lite), 150)
        XCTAssertEqual(MarineSnow.count(.high), 300)
        XCTAssertEqual(MarineSnow.count(.ultra), 400)
        XCTAssertEqual(MarineSnow.capacity, 400)
        for q in QualityLevel.allCases {
            var snow = MarineSnow(quality: q)
            XCTAssertEqual(snow.count, MarineSnow.count(q), "\(q)")
            XCTAssertEqual(snow.live.count, MarineSnow.count(q), "\(q)")
            XCTAssertEqual(snow.flecks.count, MarineSnow.capacity)
            let start = snow.live.map(\.position)
            let buffer = snow.flecks.withUnsafeBufferPointer { $0.baseAddress }
            // Five minutes in quarter-second steps: the default current carries every fleck out of a side within two
            // minutes, and the slowest sinks out of the bottom within four.
            for _ in 0..<1200 { snow.step(dt: 0.25) }
            XCTAssertEqual(snow.count, MarineSnow.count(q))
            XCTAssertTrue(snow.live.allSatisfy { inside($0.position) }, "\(q)")
            XCTAssertTrue(snow.live.allSatisfy { $0.brightness >= 0 && $0.brightness <= 1 && $0.size >= 0.5 && $0.size <= 1.6 })
            XCTAssertGreaterThanOrEqual(snow.recycled, 2 * snow.count, "flecks recycle as they leave (\(q))")
            XCTAssertTrue(zip(start, snow.live.map(\.position)).allSatisfy { $0 != $1 }, "every fleck moved")
            XCTAssertEqual(snow.flecks.withUnsafeBufferPointer { $0.baseAddress }, buffer, "stepped in place (\(q))")
        }

        // With no current they only sink: still each one leaves through the bottom and comes back in at the top.
        var still = MarineSnow(quality: .lite)
        still.current = .zero
        var lowest: Float = 1
        for _ in 0..<1200 {
            still.step(dt: 0.25)
            lowest = min(lowest, still.live.map(\.position.y).min() ?? 1)
        }
        XCTAssertGreaterThanOrEqual(still.recycled, still.count)
        XCTAssertTrue(still.live.allSatisfy { inside($0.position) })
        XCTAssertLessThan(lowest, 0.02, "they reach the bottom")

        // An upwelling carries them out of the top: back in at the bottom.
        var up = MarineSnow(quality: .lite)
        up.current = SIMD3(0, 0.05, 0)
        for _ in 0..<400 { up.step(dt: 0.25) }
        XCTAssertGreaterThanOrEqual(up.recycled, up.count)
        XCTAssertTrue(up.live.allSatisfy { inside($0.position) })

        // The count follows the quality, up and back down; the flecks that wait keep their places.
        var snow = MarineSnow(quality: .lite)
        let waiting = snow.flecks[200].position
        snow.setQuality(.ultra)
        XCTAssertEqual(snow.live.count, 400)
        XCTAssertEqual(snow.live[200].position, waiting, "brought in where it was seeded")
        snow.setQuality(.high)
        XCTAssertEqual(snow.live.count, 300)

        // Deterministic from the seed.
        var a = MarineSnow(quality: .high, seed: 7), b = MarineSnow(quality: .high, seed: 7), c = MarineSnow(quality: .high, seed: 8)
        for _ in 0..<300 { a.step(dt: 1.0 / 30); b.step(dt: 1.0 / 30); c.step(dt: 1.0 / 30) }
        XCTAssertEqual(a.flecks, b.flecks)
        XCTAssertNotEqual(a.flecks, c.flecks)

        // Huge and odd inputs stay finite and inside.
        var odd = MarineSnow(quality: .ultra)
        odd.current = SIMD3(.infinity, -.nan, 50)
        odd.sinkRate = .nan
        for dt in [Double.nan, -1, 1e9, .infinity, 0, 0.25] { odd.step(dt: dt) }
        XCTAssertTrue(odd.live.allSatisfy { inside($0.position) && $0.brightness.isFinite })
    }

    /// Flecks fade in and out near the volume's faces (nothing pops where they're recycled), and glint as they tumble.
    func testMarineSnowFadesAtTheFaces() {
        var snow = MarineSnow(quality: .ultra)
        var nearFace: [Float] = [], middle: [Float] = []
        for _ in 0..<240 {
            snow.step(dt: 0.25)
            for f in snow.live {
                let p = f.position
                let edge = min(min(min(p.x, 1 - p.x), min(p.y, 1 - p.y)), min(p.z, 1 - p.z))
                if edge < 0.005 { nearFace.append(f.brightness) } else if edge > 0.2 { middle.append(f.brightness) }
            }
        }
        XCTAssertFalse(nearFace.isEmpty)
        XCTAssertLessThan(nearFace.max() ?? 1, 0.1, "dim at the faces")
        XCTAssertGreaterThan(middle.reduce(0, +) / Float(max(1, middle.count)), 0.4, "pale in the middle")
        XCTAssertGreaterThan((middle.max() ?? 0) - (middle.min() ?? 0), 0.3, "each its own glint")
    }
}
