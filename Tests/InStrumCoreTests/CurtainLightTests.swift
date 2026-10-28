import XCTest
import simd
@testable import InStrumCore

final class CurtainLightTests: XCTestCase {
    private func run(_ c: inout CurtainLight, seconds: Double, sun: Double = 10, dt: Double = 1.0 / 60) {
        for _ in 0..<Int((seconds / dt).rounded()) { c.step(dt: dt, sunAltitude: sun, roles: RoleValues()) }
    }

    func testGlowRisesWhileHeld() {
        var c = CurtainLight(moteCount: 200)
        for n: UInt8 in [60, 64, 67] { c.noteOn(n, velocity: 0.7, at: 0) }
        run(&c, seconds: 3)
        XCTAssertGreaterThan(c.glow, 0.6)
        XCTAssertLessThanOrEqual(c.glow, CurtainLight.glowCap)
        for n: UInt8 in [60, 64, 67] { c.noteOff(n) }
        run(&c, seconds: 6)
        XCTAssertLessThan(c.glow, 0.35)
    }

    func testPuffsByPitch() throws {
        var c = CurtainLight(moteCount: 200)
        c.noteOn(21, velocity: 0.8, at: 0)
        c.step(dt: 1.0 / 60, sunAltitude: 10, roles: RoleValues())
        XCTAssertEqual(try XCTUnwrap(c.puffs.last).x, 0, accuracy: 0.02)
        c.noteOn(108, velocity: 0.8, at: 1)
        c.step(dt: 1.0 / 60, sunAltitude: 10, roles: RoleValues())
        XCTAssertEqual(try XCTUnwrap(c.puffs.last).x, 1, accuracy: 0.02)
        XCTAssertGreaterThan(try XCTUnwrap(c.puffs.last).strength, 0.5, "harder notes puff harder")
    }

    func testHighNotesGlintMotes() {
        var c = CurtainLight(moteCount: 400)
        c.noteOn(96, velocity: 0.8, at: 0)
        c.step(dt: 1.0 / 60, sunAltitude: 10, roles: RoleValues())
        let glinting = c.motes.filter { $0.glint > 0.5 }
        XCTAssertTrue((3...6).contains(glinting.count), "\(glinting.count)")
        let height = glinting.map(\.position.y).reduce(0, +) / Float(max(1, glinting.count))
        XCTAssertTrue((0.55...0.8).contains(height), "\(height)")
        run(&c, seconds: 3)
        XCTAssertTrue(c.motes.allSatisfy { $0.glint < 0.05 }, "glints fade in about 0.8 s")
        var low = CurtainLight(moteCount: 400)
        low.noteOn(60, velocity: 0.8, at: 0)
        low.step(dt: 1.0 / 60, sunAltitude: 10, roles: RoleValues())
        XCTAssertTrue(low.motes.allSatisfy { $0.glint == 0 })
    }

    /// Smooth draws only the first motes (CurtainLight.moteBudget): high notes glint only motes that are drawn
    /// (final review: on Smooth about half the glints were invisible).
    func testGlintsStayWithinTheDrawnMotes() {
        XCTAssertEqual(CurtainLight.moteBudget(.lite), 200)
        XCTAssertEqual(CurtainLight.moteBudget(.high), 400)
        var c = CurtainLight(moteCount: 400)
        c.glintLimit = CurtainLight.moteBudget(.lite)
        for i in 0..<60 {
            c.noteOn(UInt8(72 + i % 36), velocity: 0.8, at: Double(i) * 0.1)
            c.step(dt: 0.1, sunAltitude: 10, roles: RoleValues())
            for (k, m) in c.motes.enumerated() where m.glint > 0 { XCTAssertLessThan(k, 200, "mote \(k) glints but isn't drawn") }
        }
    }

    private func distanceToSegment(_ p: SIMD3<Float>, _ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        let ab = b - a
        let t = min(max(simd_dot(p - a, ab) / simd_dot(ab, ab), 0), 1)
        return simd_length(p - (a + ab * t))
    }

    func testChordTintGlidesInRGB() {
        var c = CurtainLight(moteCount: 200)
        let minor: [UInt8] = [57, 60, 64], major: [UInt8] = [60, 64, 67]
        for n in minor { c.noteOn(n, velocity: 0.7, at: 0) }
        run(&c, seconds: 10)
        XCTAssertLessThan(simd_length(c.tint - CurtainLight.minorTint), 0.002)
        for n in minor { c.noteOff(n) }
        for (i, n) in major.enumerated() { c.noteOn(n, velocity: 0.7, at: 10 + Double(i) * 0.01) }
        for _ in 0..<240 {
            c.step(dt: 1.0 / 60, sunAltitude: 10, roles: RoleValues())
            XCTAssertLessThan(distanceToSegment(c.tint, CurtainLight.minorTint, CurtainLight.majorTint), 1e-3)
        }
        XCTAssertLessThan(simd_length(c.tint - CurtainLight.majorTint), 0.02)
        for n in major { c.noteOff(n) }
        run(&c, seconds: 8)
        XCTAssertLessThan(simd_length(c.tint - CurtainLight.neutralTint), 0.02, "back to neutral when the chord lets go")
    }

    func testFairyTwinklesAtNightOnly() {
        var night = CurtainLight(moteCount: 200)
        night.noteOn(64, velocity: 0.8, at: 0)
        night.step(dt: 1.0 / 60, sunAltitude: -10, roles: RoleValues())
        XCTAssertEqual(night.fairy.count, CurtainLight.fairyCount)
        XCTAssertTrue(night.fairy.contains { $0 > 0.5 })
        var day = CurtainLight(moteCount: 200)
        day.noteOn(64, velocity: 0.8, at: 0)
        day.step(dt: 1.0 / 60, sunAltitude: 5, roles: RoleValues())
        XCTAssertTrue(day.fairy.allSatisfy { $0 == 0 })
    }

    func testBurstIsRationed() {
        var c = CurtainLight(moteCount: 400)
        for i in 0..<2000 { c.noteOn(UInt8(21 + i % 88), velocity: 0.9, at: Double(i) * 0.0005) }
        for _ in 0..<30 {
            let puffsBefore = c.puffs.count
            c.step(dt: 1.0 / 60, sunAltitude: -10, roles: RoleValues())
            XCTAssertLessThanOrEqual(c.lastEvents, CurtainLight.maxEventsPerStep)
            XCTAssertLessThanOrEqual(c.puffs.count - puffsBefore, CurtainLight.maxEventsPerStep)
        }
    }

    func testIdsWrap() {
        var c = CurtainLight(moteCount: 200)
        c.nextID = Int.max - 2
        for i in 0..<6 { c.noteOn(UInt8(80 + i), velocity: 0.6, at: Double(i)) }
        run(&c, seconds: 0.2)
        XCTAssertFalse(c.puffs.isEmpty)
    }

    func testOddInputsStayFinite() {
        var c = CurtainLight(moteCount: 0)
        c.noteOn(250, velocity: .nan, at: .infinity)
        c.step(dt: .nan, sunAltitude: .nan, roles: RoleValues())
        c.step(dt: 100, sunAltitude: -20, roles: RoleValues())
        XCTAssertTrue(c.glow.isFinite)
        XCTAssertTrue(c.tint.x.isFinite)
        XCTAssertTrue(c.puffs.allSatisfy { $0.x.isFinite && $0.strength.isFinite })
    }
}
