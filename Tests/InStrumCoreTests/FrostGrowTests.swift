import XCTest
@testable import InStrumCore

final class FrostGrowTests: XCTestCase {
    private func run(_ g: inout FrostGrow, seconds: Double, base: Float = 0.2, dt: Double = 1.0 / 60) {
        for _ in 0..<Int((seconds / dt).rounded()) { g.step(dt: dt, baseFrost: base, roles: RoleValues()) }
    }

    func testPatchesByPitchAndVelocity() throws {
        var g = FrostGrow()
        g.noteOn(21, velocity: 1, at: 0)
        g.noteOn(108, velocity: 1, at: 0.5)
        g.step(dt: 1.0 / 60, baseFrost: 0.2, roles: RoleValues())
        let low = try XCTUnwrap(g.patches.first { $0.note == 21 }), high = try XCTUnwrap(g.patches.first { $0.note == 108 })
        XCTAssertEqual(low.x, 0.08, accuracy: 0.01)
        XCTAssertEqual(high.x, 0.92, accuracy: 0.01)
        XCTAssertEqual(low.y, 0.75, accuracy: 1e-5)
        XCTAssertEqual(low.radius, 0.075, accuracy: 1e-5)
        g.noteOn(60, velocity: 0, at: 1)
        g.step(dt: 1.0 / 60, baseFrost: 0.2, roles: RoleValues())
        let soft = try XCTUnwrap(g.patches.first { $0.note == 60 })
        XCTAssertEqual(soft.y, 0.3, accuracy: 1e-5)
        XCTAssertEqual(soft.radius, 0.025, accuracy: 1e-5)
    }

    func testHeldPatchesStayClear() {
        var g = FrostGrow()
        g.noteOn(64, velocity: 0.7, at: 0)
        for _ in 0..<600 {
            g.step(dt: 1.0 / 60, baseFrost: 0.2, roles: RoleValues())
            XCTAssertEqual(g.patches.first?.warmth, 1)
            XCTAssertEqual(g.patches.first?.held, true)
        }
    }

    func testReleasedPatchesRefreeze() throws {
        var g = FrostGrow()
        g.noteOn(64, velocity: 0.7, at: 0)
        run(&g, seconds: 1)
        g.noteOff(64)
        run(&g, seconds: 3.5)
        let p = try XCTUnwrap(g.patches.first)
        XCTAssertFalse(p.held)
        XCTAssertEqual(p.warmth, Float(exp(-1.0)), accuracy: 0.05)
        run(&g, seconds: 16.5)
        XCTAssertTrue(g.patches.isEmpty, "gone by 20 s")
    }

    func testLevelGrowsWhileHeldAndIsCapped() {
        var g = FrostGrow()
        g.frost = 1
        for n: UInt8 in [60, 64, 67, 71] { g.noteOn(n, velocity: 0.6, at: 0) }
        var highest: Float = 0
        for _ in 0..<(40 * 60) {
            g.step(dt: 1.0 / 60, baseFrost: 0.2, roles: RoleValues())
            highest = max(highest, g.level)
        }
        XCTAssertGreaterThanOrEqual(g.level, 0.75)
        XCTAssertLessThanOrEqual(g.level, 0.85)
        XCTAssertLessThanOrEqual(highest, FrostGrow.levelCap)
        g.allNotesOff()
        run(&g, seconds: 90)
        XCTAssertEqual(g.level, 0.2, accuracy: 0.03)
    }

    func testPedalCountsAsHolding() {
        var g = FrostGrow()
        g.frost = 1
        g.setPedal(true)
        for n: UInt8 in [60, 64, 67] { g.noteOn(n, velocity: 0.6, at: 0) }
        run(&g, seconds: 0.2)
        for n: UInt8 in [60, 64, 67] { g.noteOff(n) }
        run(&g, seconds: 20)
        XCTAssertGreaterThan(g.level, 0.6, "the pedal keeps the notes, so the frost keeps growing")
        XCTAssertTrue(g.patches.allSatisfy { $0.warmth == 1 }, "and their patches warm")
        g.setPedal(false)
        run(&g, seconds: 4)
        XCTAssertTrue(g.patches.allSatisfy { $0.warmth < 0.5 })
    }

    func testChordFlare() {
        var major = FrostGrow()
        major.noteOn(60, velocity: 0.8, at: 0); major.noteOn(64, velocity: 0.8, at: 0.02); major.noteOn(67, velocity: 0.8, at: 0.05)
        run(&major, seconds: 0.3)
        XCTAssertGreaterThan(major.flare, 0.5)
        XCTAssertEqual(major.flareWarm, 1)
        run(&major, seconds: 8)
        XCTAssertLessThan(major.flare, 0.05, "it dies back down")

        var minor = FrostGrow()
        minor.noteOn(57, velocity: 0.8, at: 0); minor.noteOn(60, velocity: 0.8, at: 0.02); minor.noteOn(64, velocity: 0.8, at: 0.05)
        run(&minor, seconds: 0.3)
        XCTAssertGreaterThan(minor.flare, 0.5)
        XCTAssertEqual(minor.flareWarm, 0)

        var single = FrostGrow()
        single.noteOn(60, velocity: 1, at: 0)
        run(&single, seconds: 0.3)
        XCTAssertEqual(single.flare, 0)
    }

    func testHighNotesGlintFlakes() {
        var g = FrostGrow()
        g.noteOn(80, velocity: 0.7, at: 0)
        g.step(dt: 1.0 / 60, baseFrost: 0.2, roles: RoleValues())
        XCTAssertEqual(g.flakeGlints.count, 1)
        XCTAssertEqual(g.flakeGlints.first ?? -1, FrostGrow.x(for: 80), accuracy: 1e-6)
        g.step(dt: 1.0 / 60, baseFrost: 0.2, roles: RoleValues())
        XCTAssertTrue(g.flakeGlints.isEmpty, "only on the step after the note")
        g.noteOn(60, velocity: 0.7, at: 1)
        g.step(dt: 1.0 / 60, baseFrost: 0.2, roles: RoleValues())
        XCTAssertTrue(g.flakeGlints.isEmpty)
    }

    func testBurstIsRationed() {
        var g = FrostGrow()
        for i in 0..<2000 { g.noteOn(UInt8(21 + i % 88), velocity: 0.9, at: Double(i) * 0.0005) }
        var before = 0
        for _ in 0..<60 {
            g.step(dt: 1.0 / 60, baseFrost: 0.2, roles: RoleValues())
            XCTAssertLessThanOrEqual(g.patches.count - before, FrostGrow.maxSpawnsPerStep)
            XCTAssertLessThanOrEqual(g.patches.count, FrostGrow.cap)
            XCTAssertLessThanOrEqual(g.flakeGlints.count, FrostGrow.maxSpawnsPerStep)
            before = g.patches.count
        }
        XCTAssertEqual(g.patches.count, FrostGrow.cap)
    }

    func testSmoothKeepsTheWarmest24() {
        var g = FrostGrow()
        for i in 0..<48 { g.noteOn(UInt8(30 + i), velocity: 0.5, at: Double(i) * 0.1) }
        run(&g, seconds: 0.2)
        // Release every other note, then let them cool a little.
        for i in stride(from: 0, to: 48, by: 2) { g.noteOff(UInt8(30 + i)) }
        run(&g, seconds: 1)
        let shown = FrostGrow.visible(g.patches, limit: 24)
        XCTAssertEqual(shown.count, 24)
        XCTAssertTrue(shown.allSatisfy { $0.held }, "the held (warmest) patches stay")
        XCTAssertEqual(shown.map(\.id), shown.map(\.id).sorted(), "in their original order")
        XCTAssertEqual(FrostGrow.visible(g.patches, limit: 100).count, g.patches.count)
    }

    func testIdsWrap() {
        var g = FrostGrow()
        g.nextID = Int.max - 2
        for i in 0..<6 { g.noteOn(UInt8(60 + i), velocity: 0.5, at: Double(i)) }
        run(&g, seconds: 0.1)
        XCTAssertEqual(g.patches.count, 6)
        XCTAssertEqual(Set(g.patches.map(\.id)).count, 6)
    }

    func testOddInputsStayFinite() {
        var g = FrostGrow()
        g.frost = .nan
        g.noteOn(200, velocity: .infinity, at: .nan)
        g.noteOn(60, velocity: -3, at: 0)
        g.step(dt: .infinity, baseFrost: .nan, roles: RoleValues())
        g.step(dt: -1, baseFrost: 2, roles: RoleValues())
        XCTAssertTrue(g.level.isFinite)
        XCTAssertLessThanOrEqual(g.level, FrostGrow.levelCap)
        XCTAssertTrue(g.patches.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.radius > 0 })
    }
}
