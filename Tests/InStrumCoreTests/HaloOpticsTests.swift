import XCTest
@testable import InStrumCore

/// Ice-crystal optics for the sky dome (the shader mirrors these).
final class HaloOpticsTests: XCTestCase {
    func testRingPeaksAt22WithRedInside() {
        var best = 0.0, bestTotal: Float = -1
        for i in 0...1500 {
            let angle = 15 + Double(i) * 0.01
            let w = HaloOptics.ring(angle: angle, radius: HaloOptics.haloRadius)
            let total = w.x + w.y + w.z
            if total > bestTotal { bestTotal = total; best = angle }
        }
        XCTAssertEqual(best, 22, accuracy: 0.4)
        let inside = HaloOptics.ring(angle: 21.7, radius: 22), outside = HaloOptics.ring(angle: 22.6, radius: 22)
        XCTAssertGreaterThan(inside.x, inside.z, "red on the inner edge")
        XCTAssertGreaterThan(outside.z, outside.x, "bluish white outside")
        let far = HaloOptics.ring(angle: 15, radius: 22)
        XCTAssertLessThan(far.x + far.y + far.z, 0.01, "dark inside the ring")
    }

    func testSundogsMoveOutAndFade() {
        XCTAssertEqual(HaloOptics.sundogOffset(sunAltitude: 0), 22, accuracy: 1e-9)
        XCTAssertEqual(HaloOptics.sundogOffset(sunAltitude: 30), 25.4, accuracy: 0.1)
        XCTAssertEqual(HaloOptics.sundogStrength(sunAltitude: 20), 1)
        XCTAssertLessThan(HaloOptics.sundogStrength(sunAltitude: 44), 0.05)
        XCTAssertEqual(HaloOptics.sundogStrength(sunAltitude: -2), 0)
    }

    func testBeltOfVenusAtTwilightOnly() {
        XCTAssertEqual(HaloOptics.beltOfVenus(sunAltitude: -2), 1)
        XCTAssertEqual(HaloOptics.beltOfVenus(sunAltitude: 2), 0)
        XCTAssertEqual(HaloOptics.beltOfVenus(sunAltitude: -7), 0)
    }

    func testRainbowBowsAreRedOutsideAndReversedInTheSecondary() {
        let primaryInner = RainbowOptics.bow(angle: 40.9), primaryOuter = RainbowOptics.bow(angle: 42.1)
        XCTAssertGreaterThan(primaryOuter.x, primaryOuter.z, "red outside the primary")
        XCTAssertGreaterThan(primaryInner.z, primaryInner.x, "violet inside the primary")
        let secInner = RainbowOptics.bow(angle: 50.9), secOuter = RainbowOptics.bow(angle: 53.1)
        XCTAssertGreaterThan(secInner.x, secInner.z, "red inside the secondary (reversed)")
        XCTAssertGreaterThan(secOuter.z, secOuter.x, "violet outside the secondary")
        let mid = RainbowOptics.bow(angle: 41.5)
        XCTAssertGreaterThan(mid.x + mid.y + mid.z, 3 * secInner.x, "the primary is brighter than the secondary")
        for a in [30.0, 40.0, 46.0, 48.5, 54.0, 70.0] {
            XCTAssertEqual(RainbowOptics.bow(angle: a), SIMD3<Float>(0, 0, 0), "nothing at \(a)° (Alexander's dark band between the bows)")
        }
    }
}
