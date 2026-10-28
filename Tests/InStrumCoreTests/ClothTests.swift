import XCTest
import simd
@testable import InStrumCore

final class ClothTests: XCTestCase {
    private func panel(width: Float = 0.5, seed: UInt64 = 7) -> Cloth {
        Cloth(width: width, height: 1.4, origin: SIMD3(0, 1.2, 0), seed: seed)
    }

    private func run(_ c: inout Cloth, seconds: Double, wind: Float, puffs: (Double) -> [Cloth.Puff] = { _ in [] }) {
        let frames = Int((seconds * 60).rounded())
        for i in 0..<frames { c.step(dt: 1.0 / 60, wind: wind, puffs: puffs(Double(i + 1) / 60)) }
    }

    func testDeterministic() {
        var a = panel(), b = panel(), c = panel(seed: 8)
        let puffs: (Double) -> [Cloth.Puff] = { t in [Cloth.Puff(x: 0.2, strength: 0.8, age: Float(t.truncatingRemainder(dividingBy: 1)))] }
        run(&a, seconds: 3, wind: 0.6, puffs: puffs)
        run(&b, seconds: 3, wind: 0.6, puffs: puffs)
        run(&c, seconds: 3, wind: 0.6, puffs: puffs)
        XCTAssertEqual(a.positions, b.positions)
        XCTAssertNotEqual(a.positions, c.positions, "another seed has another breeze")
        XCTAssertEqual(a.positions.count, 24 * 32)
    }

    func testPinnedRowStays() {
        var c = panel()
        let top = Array(c.positions.prefix(24))
        run(&c, seconds: 10, wind: 1)
        XCTAssertEqual(Array(c.positions.prefix(24)), top)
    }

    func testHangsUnderGravity() {
        var c = panel()
        run(&c, seconds: 5, wind: 0)
        let top = c.positions[0].y, bottom = c.positions[31 * 24].y
        XCTAssertGreaterThanOrEqual(top - bottom, 0.95 * 1.4)
    }

    /// A puff at 0.3 spreads both ways at 1.5 m/s: on its right side the fastest-moving column moves outward.
    func testPuffTravelsSideways() {
        var c = panel(width: 1)
        var fastest: [Double: Int] = [:]
        for i in 1...24 {
            let t = Double(i) / 60
            let before = c.positions
            c.step(dt: 1.0 / 60, wind: 0, puffs: [Cloth.Puff(x: 0.3, strength: 1, age: Float(t))])
            guard i == 6 || i == 24 else { continue }
            var best = -1, speed: Float = -1
            for col in 0..<24 where c.restPositions[col].x > 0.3 {
                var v: Float = 0
                for row in 1..<32 { v = max(v, abs(c.positions[row * 24 + col].z - before[row * 24 + col].z)) }
                if v > speed { speed = v; best = col }
            }
            fastest[t] = best
        }
        let early = fastest[0.1] ?? -1, late = fastest[0.4] ?? -1
        XCTAssertGreaterThan(early, -1)
        XCTAssertLessThan(early, late, "the gust ripples outward")
    }

    /// Review Focus 3: ten minutes of full wind with a puff every 0.1 s stays finite and bounded.
    func testClothStaysCalmUnderLongWind() {
        var c = panel(seed: 9)
        var puffs: [Cloth.Puff] = []
        for i in 0..<(10 * 60 * 60) {
            if i % 6 == 0 { puffs.append(Cloth.Puff(x: Float((i / 6) % 10) / 10, strength: 1, age: 0)) }
            for k in puffs.indices { puffs[k].age += 1.0 / 60 }
            puffs.removeAll { $0.age > 1.2 }
            c.step(dt: 1.0 / 60, wind: 1, puffs: puffs)
        }
        for (p, r) in zip(c.positions, c.restPositions) {
            XCTAssertTrue(p.x.isFinite && p.y.isFinite && p.z.isFinite)
            XCTAssertLessThanOrEqual(simd_length(p - r), Cloth.maxDisplacement + 1e-4)
        }
    }

    func testHugeDtIsClamped() {
        var c = panel()
        c.step(dt: 5, wind: 1, puffs: [Cloth.Puff(x: 0.25, strength: 1, age: 0)])
        XCTAssertLessThanOrEqual(c.lastSubsteps, Cloth.maxSubsteps)
        XCTAssertTrue(c.positions.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite })
        c.step(dt: .infinity, wind: .nan, puffs: [Cloth.Puff(x: .nan, strength: .infinity, age: -1)])
        c.step(dt: -1, wind: 1, puffs: [])
        XCTAssertTrue(c.positions.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite })
        var d = panel()
        d.step(dt: 1.0 / 60, wind: 0, puffs: [])
        XCTAssertEqual(d.lastSubsteps, 2, "two 120 Hz substeps per 60 Hz frame")
    }

    func testStepIsCheap() {
        var c = panel()
        let puffs = [Cloth.Puff(x: 0.2, strength: 0.7, age: 0.2)]
        run(&c, seconds: 1, wind: 0.8, puffs: { _ in puffs })
        let start = Date()
        run(&c, seconds: 5, wind: 0.8, puffs: { _ in puffs })
        let perFrame = Date().timeIntervalSince(start) / 300
        #if DEBUG
        XCTAssertLessThan(perFrame, 0.003)
        #else
        XCTAssertLessThan(perFrame, 0.0003)
        #endif
    }
}
