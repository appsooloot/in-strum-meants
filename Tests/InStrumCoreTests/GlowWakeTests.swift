import XCTest
import simd
@testable import InStrumCore

final class GlowWakeTests: XCTestCase {
    private func run(_ g: inout GlowWake, seconds: Double, dt: Double = 1.0 / 60, roles: RoleValues = RoleValues()) {
        for _ in 0..<Int((seconds / dt).rounded()) { g.step(dt: dt, roles: roles) }
    }

    func testPatchesByPitchAndVelocity() throws {
        var g = GlowWake()
        g.noteOn(21, velocity: 1, at: 0)
        g.noteOn(108, velocity: 1, at: 0.5)
        g.step(dt: 1.0 / 60, roles: RoleValues())
        let low = try XCTUnwrap(g.patches.first { $0.note == 21 }), high = try XCTUnwrap(g.patches.first { $0.note == 108 })
        XCTAssertEqual(low.x, 0.06, accuracy: 0.01)
        XCTAssertEqual(high.x, 0.94, accuracy: 0.01)
        XCTAssertEqual(low.depth, 0.15, accuracy: 1e-5, "hard notes land close")
        XCTAssertEqual(low.radius, 0.07, accuracy: 1e-5)
        XCTAssertEqual(low.brightness, 1, accuracy: 1e-5)
        XCTAssertTrue(low.held)
        g.noteOn(60, velocity: 0, at: 1)
        g.step(dt: 1.0 / 60, roles: RoleValues())
        let soft = try XCTUnwrap(g.patches.first { $0.note == 60 })
        XCTAssertEqual(soft.depth, 0.65, accuracy: 1e-5)
        XCTAssertEqual(soft.radius, 0.02, accuracy: 1e-5)
        XCTAssertEqual(soft.brightness, 0.4, accuracy: 1e-5)
        XCTAssertEqual(soft.x, GlowWake.x(for: 60), accuracy: 1e-4)
    }

    func testHeldPatchesStayLit() throws {
        var g = GlowWake()
        g.noteOn(64, velocity: 0.7, at: 0)
        let x0 = GlowWake.x(for: 64)
        for _ in 0..<600 {
            g.step(dt: 1.0 / 60, roles: RoleValues())
            XCTAssertEqual(g.patches.first?.brightness ?? 0, 0.4 + 0.6 * 0.7, accuracy: 1e-5)
            XCTAssertEqual(g.patches.first?.held, true)
        }
        // It drifts with the current, +0.004 per second.
        XCTAssertEqual(try XCTUnwrap(g.patches.first).x, x0 + 0.04, accuracy: 1e-3)

        // The pedal keeps a released note lit until it comes up.
        var p = GlowWake()
        p.setPedal(true)
        p.noteOn(60, velocity: 0.5, at: 0)
        run(&p, seconds: 0.2)
        p.noteOff(60)
        run(&p, seconds: 5)
        XCTAssertEqual(p.patches.first?.brightness ?? 0, 0.7, accuracy: 1e-5, "sounding under the pedal")
        p.setPedal(false)
        run(&p, seconds: 2.5)
        XCTAssertLessThan(p.patches.first?.brightness ?? 0, 0.7 * 0.5)
    }

    func testReleasedPatchesFade() throws {
        var g = GlowWake()
        g.noteOn(64, velocity: 1, at: 0)
        run(&g, seconds: 1)
        g.noteOff(64)
        run(&g, seconds: 2.5)
        let p = try XCTUnwrap(g.patches.first)
        XCTAssertFalse(p.held)
        // τ 2.5 s ± 10%: e^(−2.5/2.75) … e^(−2.5/2.25).
        XCTAssertGreaterThan(p.brightness, Float(exp(-2.5 / 2.25)))
        XCTAssertLessThan(p.brightness, Float(exp(-2.5 / 2.75)))
        run(&g, seconds: 15)
        XCTAssertTrue(g.patches.isEmpty, "gone once it has faded")

        // Linger doubles the time constant.
        var l = GlowWake()
        var linger = RoleValues(); linger[.linger] = 1
        l.noteOn(64, velocity: 1, at: 0)
        run(&l, seconds: 0.5, roles: linger)
        l.noteOff(64)
        run(&l, seconds: 5, roles: linger)
        XCTAssertEqual(try XCTUnwrap(l.patches.first).brightness, Float(exp(-1.0)), accuracy: 0.03)
    }

    func testRunsDrawWakes() throws {
        var g = GlowWake()
        g.noteOn(60, velocity: 0.8, at: 0)
        g.step(dt: 0.2, roles: RoleValues())
        g.noteOn(62, velocity: 0.8, at: 0.2)
        g.step(dt: 1.0 / 60, roles: RoleValues())
        XCTAssertEqual(g.wakes.count, 1)
        let w = try XCTUnwrap(g.wakes.first)
        XCTAssertEqual(w.from.x, GlowWake.x(for: 60), accuracy: 0.01)
        XCTAssertEqual(w.to.x, GlowWake.x(for: 62), accuracy: 0.01)
        XCTAssertGreaterThan(w.brightness, 0.5)
        run(&g, seconds: 1.6)
        XCTAssertTrue(g.wakes.isEmpty, "a wake fades in 1.5 s")

        var slow = GlowWake()
        slow.noteOn(60, velocity: 0.8, at: 0)
        slow.step(dt: 0.5, roles: RoleValues())
        slow.noteOn(62, velocity: 0.8, at: 0.5)
        slow.step(dt: 1.0 / 60, roles: RoleValues())
        XCTAssertTrue(slow.wakes.isEmpty, "0.5 s apart is not a run")
    }

    func testFastRunsSendDarts() {
        var g = GlowWake()
        // Two notes in a second: wakes but no fish.
        g.noteOn(60, velocity: 0.8, at: 0); g.step(dt: 0.15, roles: RoleValues())
        g.noteOn(62, velocity: 0.8, at: 0.15); g.step(dt: 1.0 / 60, roles: RoleValues())
        XCTAssertTrue(g.darts.isEmpty)
        XCTAssertFalse(g.wakes.isEmpty)

        // A fast run: eight notes, 0.1 s apart.
        var r = GlowWake()
        var sent = 0
        for i in 0..<8 {
            r.noteOn(UInt8(60 + 2 * i), velocity: 0.8, at: Double(i) * 0.1)
            r.step(dt: 0.1, roles: RoleValues())
            sent = max(sent, r.darts.count)
            XCTAssertLessThanOrEqual(r.darts.count, GlowWake.dartCap)
        }
        XCTAssertGreaterThan(sent, 0, "a fast run sends fish darting off the wake")
        XCTAssertTrue(r.darts.allSatisfy { abs(simd_length($0.direction) - 1) < 1e-3 && $0.brightness > 0 })
        run(&r, seconds: 0.7)
        XCTAssertTrue(r.darts.isEmpty, "darts fade in 0.6 s")

        // Seeded: the same run sends the same fish.
        func darts() -> [Dart] {
            var d = GlowWake()
            for i in 0..<6 { d.noteOn(UInt8(60 + i), velocity: 0.8, at: Double(i) * 0.1); d.step(dt: 0.1, roles: RoleValues()) }
            return d.darts
        }
        XCTAssertEqual(darts(), darts())
    }

    func testChordsBloomAPool() {
        var major = GlowWake()
        major.noteOn(60, velocity: 0.8, at: 0); major.noteOn(64, velocity: 0.8, at: 0.02); major.noteOn(67, velocity: 0.8, at: 0.05)
        run(&major, seconds: 0.3)
        XCTAssertGreaterThan(major.pool.strength, 0.5)
        XCTAssertEqual(major.pool.warm, 1)
        XCTAssertEqual(major.pool.radius, 0.25, accuracy: 1e-6)
        let mean = (GlowWake.x(for: 60) + GlowWake.x(for: 64) + GlowWake.x(for: 67)) / 3
        XCTAssertEqual(major.pool.x, mean, accuracy: 1e-4)
        XCTAssertTrue(major.wakes.isEmpty, "a chord blooms; it does not streak")
        run(&major, seconds: 8)
        XCTAssertLessThan(major.pool.strength, 0.05, "it dies back down")

        var minor = GlowWake()
        minor.noteOn(57, velocity: 0.8, at: 0); minor.noteOn(60, velocity: 0.8, at: 0.02); minor.noteOn(64, velocity: 0.8, at: 0.05)
        run(&minor, seconds: 0.3)
        XCTAssertGreaterThan(minor.pool.strength, 0.5)
        XCTAssertEqual(minor.pool.warm, 0, "a deeper teal")

        var single = GlowWake()
        single.noteOn(60, velocity: 1, at: 0)
        run(&single, seconds: 0.3)
        XCTAssertEqual(single.pool.strength, 0)

        // By day the plankton is dark: everything it hands out is scaled to nothing.
        var day = GlowWake()
        day.nightScale = 0
        day.noteOn(60, velocity: 0.8, at: 0); day.noteOn(64, velocity: 0.8, at: 0.02); day.noteOn(67, velocity: 0.8, at: 0.05)
        run(&day, seconds: 0.3)
        XCTAssertEqual(day.pool.strength, 0)
        XCTAssertEqual(day.patches.count, 3)
        XCTAssertTrue(day.patches.allSatisfy { $0.brightness == 0 })
    }

    func testBurstIsRationed() {
        var g = GlowWake()
        for i in 0..<2000 { g.noteOn(UInt8(21 + i % 88), velocity: 0.9, at: Double(i) * 0.0005) }
        var before = 0
        for _ in 0..<60 {
            g.step(dt: 1.0 / 60, roles: RoleValues())
            XCTAssertLessThanOrEqual(g.patches.count - before, GlowWake.maxSpawnsPerStep)
            XCTAssertLessThanOrEqual(g.patches.count, GlowWake.cap)
            XCTAssertLessThanOrEqual(g.wakes.count, GlowWake.wakeCap)
            XCTAssertLessThanOrEqual(g.darts.count, GlowWake.dartCap)
            before = g.patches.count
        }
        XCTAssertEqual(g.patches.count, GlowWake.cap)

        // The renderer's budget keeps the brightest, in order.
        var v = GlowWake()
        for i in 0..<24 { v.noteOn(UInt8(40 + i), velocity: 0.6, at: Double(i)) }
        run(&v, seconds: 0.5)
        for i in stride(from: 0, to: 24, by: 2) { v.noteOff(UInt8(40 + i)) }
        run(&v, seconds: 1)
        let shown = GlowWake.visible(v.patches, limit: 12)
        XCTAssertEqual(shown.count, 12)
        XCTAssertTrue(shown.allSatisfy { $0.held }, "the held (brightest) patches stay")
        XCTAssertEqual(shown.map(\.id), shown.map(\.id).sorted(), "in their original order")
        XCTAssertEqual(GlowWake.visible(v.patches, limit: 100).count, v.patches.count)
    }

    func testIdsWrap() {
        var g = GlowWake()
        g.nextID = Int.max - 2
        g.nextWakeID = Int.max - 2
        g.nextDartID = Int.max - 1
        for i in 0..<6 {
            g.noteOn(UInt8(60 + i), velocity: 0.5, at: Double(i) * 0.1)
            g.step(dt: 0.1, roles: RoleValues())
        }
        XCTAssertEqual(g.patches.count, 6)
        XCTAssertEqual(Set(g.patches.map(\.id)).count, 6)
        XCTAssertEqual(Set(g.wakes.map(\.id)).count, g.wakes.count)
        XCTAssertEqual(Set(g.darts.map(\.id)).count, g.darts.count)
    }
}
