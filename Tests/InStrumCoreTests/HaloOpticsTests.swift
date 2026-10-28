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
}
