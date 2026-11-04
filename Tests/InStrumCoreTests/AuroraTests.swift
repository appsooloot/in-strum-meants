import XCTest
@testable import InStrumCore

final class AuroraTests: XCTestCase {
    func testEdgeMovesEquatorwardWithKp() {
        XCTAssertEqual(AuroraMachine.edgeLatitude(kp: 0), 67, accuracy: 1e-9)
        XCTAssertEqual(AuroraMachine.edgeLatitude(kp: 5), 51, accuracy: 1e-9)
        var previous = 91.0
        for kp in stride(from: 0.0, through: 9, by: 0.5) {
            let edge = AuroraMachine.edgeLatitude(kp: kp)
            XCTAssertLessThan(edge, previous)
            previous = edge
        }
        // A stronger storm reaches further equatorward: at 50° the band climbs with Kp, and at 30° it brightens.
        XCTAssertLessThan(AuroraMachine.bandAltitude(latitude: 50, kp: 3), AuroraMachine.bandAltitude(latitude: 50, kp: 5))
        XCTAssertLessThan(AuroraMachine.brightness(latitude: 30, kp: 3), AuroraMachine.brightness(latitude: 30, kp: 6))
        XCTAssertEqual(AuroraMachine.bandAltitude(latitude: -75, kp: 1), 90, "under the oval (or inside it) it's overhead")
        XCTAssertEqual(AuroraMachine.bandAltitude(latitude: 10, kp: 2), 0, "the tropics never see it")
    }

    func testTromsoSeesItOverheadMelbourneLowOrNot() {
        let tromso = 69.6, melbourne = -37.8
        XCTAssertGreaterThanOrEqual(AuroraMachine.brightness(latitude: tromso, kp: 2), 0.5)
        XCTAssertGreaterThan(AuroraMachine.bandAltitude(latitude: tromso, kp: 2), 40)
        XCTAssertEqual(AuroraMachine.brightness(latitude: melbourne, kp: 2), 0)
        XCTAssertGreaterThan(AuroraMachine.brightness(latitude: melbourne, kp: 7), 0.3)
        let low = AuroraMachine.bandAltitude(latitude: melbourne, kp: 7)
        XCTAssertGreaterThanOrEqual(low, 5)
        XCTAssertLessThanOrEqual(low, 30)
    }

    func testAlwaysAndNever() {
        for latitude in [-89.0, -37.8, 0, 35, 69.6] {
            var m = AuroraMachine(seed: 3)
            for _ in 0..<120 {
                let a = m.step(dt: 1, mode: .always, latitude: latitude)
                XCTAssertEqual(a.kp, 6)
                XCTAssertEqual(a.visible, 1)
                XCTAssertGreaterThanOrEqual(a.altitude, 25, "at \(latitude)°")
                XCTAssertLessThanOrEqual(a.altitude, 60, "at \(latitude)°")
            }
            for _ in 0..<120 {
                let n = m.step(dt: 1, mode: .never, latitude: latitude)
                XCTAssertEqual(n.kp, 0); XCTAssertEqual(n.storm, 0); XCTAssertEqual(n.altitude, 0); XCTAssertEqual(n.visible, 0)
            }
        }
        XCTAssertEqual(AuroraMode.allCases.map(\.rawValue), ["Follow the sky", "Always", "Never"])
        let spec = AuroraMode.spec(default: .always)
        XCTAssertEqual(spec.id, "aurora.mode")
        XCTAssertEqual(spec.name, "Aurora")
        XCTAssertEqual(spec.group, "Sky")
        XCTAssertEqual(spec.defaultValue, .choice("Always"))
        XCTAssertFalse(spec.help.isEmpty)
    }

    /// Review focus 3: 48 simulated hours of 1-s steps keep Kp in 0…9 (and it wanders).
    func testKpStaysInRangeFor48Hours() {
        var m = AuroraMachine(seed: 11)
        var lo = 9.0, hi = 0.0, storms = 0, wasStorm = false, outOfRange = 0
        let t0 = Date()
        for _ in 0..<172_800 {
            let a = m.step(dt: 1, mode: .follow, latitude: 60)
            if !(0...9).contains(a.kp) || !(0...1).contains(a.storm) || !(0...1).contains(a.visible) || !(0...90).contains(a.altitude) {
                outOfRange += 1
            }
            lo = min(lo, a.kp); hi = max(hi, a.kp)
            if a.storm > 0.5 && !wasStorm { storms += 1 }
            wasStorm = a.storm > 0.5
        }
        XCTAssertEqual(outOfRange, 0)
        XCTAssertGreaterThan(hi - lo, 0.5, "Kp wanders (\(lo)…\(hi))")
        XCTAssertLessThan(Date().timeIntervalSince(t0), 1)
        _ = storms
        // Deterministic for a seed.
        var a = AuroraMachine(seed: 5), b = AuroraMachine(seed: 5)
        for _ in 0..<600 { XCTAssertEqual(a.step(dt: 1, mode: .follow, latitude: 50).kp, b.step(dt: 1, mode: .follow, latitude: 50).kp) }
    }

    func testSubstormsComeAndGo() {
        var m = AuroraMachine(seed: 2)
        var crossings = 0, above = false, peak: Float = 0
        for _ in 0..<(40 * 60) {
            let s = m.step(dt: 1, mode: .always, latitude: -37.8).storm
            if s > 0.5 && !above { crossings += 1 }
            above = s > 0.5
            peak = max(peak, s)
        }
        XCTAssertGreaterThanOrEqual(crossings, 3, "a substorm every 8–12 min in Always")
        XCTAssertGreaterThan(peak, 0.95)
        // The envelope: a 1-minute onset to half, the expansion to full, a slow recovery to nothing.
        XCTAssertEqual(AuroraMachine.envelope(age: 60, expansion: 240, length: 600), 0.5, accuracy: 1e-9)
        XCTAssertEqual(AuroraMachine.envelope(age: 300, expansion: 240, length: 600), 1, accuracy: 1e-9)
        XCTAssertEqual(AuroraMachine.envelope(age: 599.9, expansion: 240, length: 600), 0, accuracy: 1e-4)
        XCTAssertEqual(AuroraMachine.envelope(age: -1, expansion: 240, length: 600), 0)
    }
}
