import XCTest
@testable import InStrumCore

final class CurtainLightsTests: XCTestCase {
    private func run(_ c: inout CurtainLights, seconds: Double, dt: Double = 1.0 / 60, roles: RoleValues = RoleValues(),
                     each: (CurtainLights) -> Void = { _ in }) {
        for _ in 0..<Int((seconds / dt).rounded()) { c.step(dt: dt, roles: roles); each(c) }
    }

    func testRipplesStartAtTheKey() throws {
        var c = CurtainLights()
        c.noteOn(21, velocity: 0.8, at: 0)
        c.step(dt: 1.0 / 60, roles: RoleValues())
        XCTAssertEqual(try XCTUnwrap(c.ripples.last).position, 0.08, accuracy: 0.01)
        c.noteOn(108, velocity: 0.8, at: 1)
        c.step(dt: 1.0 / 60, roles: RoleValues())
        let high = try XCTUnwrap(c.ripples.last)
        XCTAssertEqual(high.position, 0.92, accuracy: 0.01)
        XCTAssertEqual(high.note, 108)
        XCTAssertEqual(high.width, 0.04 + 0.08 * 0.8, accuracy: 1e-5)
        XCTAssertEqual(high.peak, 0.3 + 0.7 * 0.8, accuracy: 1e-5)
        XCTAssertLessThan(CurtainLights.position(for: 60), CurtainLights.position(for: 72), "higher notes further along")
    }

    func testRipplesTravelBothWays() throws {
        var c = CurtainLights()
        c.noteOn(60, velocity: 0.7, at: 0)
        c.step(dt: 0, roles: RoleValues())
        let start = try XCTUnwrap(c.ripples.first)
        XCTAssertEqual(start.age, 0)
        XCTAssertEqual(start.offset, 0)
        run(&c, seconds: 1)
        let later = try XCTUnwrap(c.ripples.first)
        XCTAssertEqual(later.age, 1, accuracy: 0.01, "age grows at 1/s")
        XCTAssertEqual(later.position, start.position, "it stays centred on its key; the fronts spread both ways")
        XCTAssertEqual(later.offset, CurtainLights.speed * later.age, accuracy: 1e-6)
        XCTAssertEqual(CurtainRipple.offset(at: 2), 0.24, accuracy: 1e-6)
        XCTAssertLessThan(later.strength, start.strength, "it fades as it goes")
        run(&c, seconds: 3)
        XCTAssertTrue(c.ripples.isEmpty, "gone after its 3.5 s life")
    }

    func testHeldNotesSwellTheGlow() {
        var c = CurtainLights()
        for n: UInt8 in [60, 64, 67] { c.noteOn(n, velocity: 0.7, at: 0) }
        run(&c, seconds: 3)
        XCTAssertGreaterThan(c.glow, 0.6)
        XCTAssertLessThanOrEqual(c.glow, CurtainLights.glowCap)
        for n: UInt8 in [60, 64, 67] { c.noteOff(n) }
        run(&c, seconds: 6)
        XCTAssertLessThan(c.glow, 0.35)
        // The pedal keeps released notes sounding.
        var p = CurtainLights()
        p.setPedal(true)
        p.noteOn(60, velocity: 0.7, at: 0)
        run(&p, seconds: 0.5)
        p.noteOff(60)
        run(&p, seconds: 3)
        XCTAssertGreaterThan(p.glow, 0.45, "the pedal holds the glow up")
        p.setPedal(false)
        run(&p, seconds: 8)
        XCTAssertLessThan(p.glow, 0.25)
    }

    func testChordsShiftTheHue() {
        var c = CurtainLights()
        for (i, n) in ([60, 64, 67] as [UInt8]).enumerated() { c.noteOn(n, velocity: 0.7, at: Double(i) * 0.01) }
        var previous = c.hueShift
        run(&c, seconds: 4) { s in
            XCTAssertGreaterThanOrEqual(s.hueShift, previous - 1e-6, "the glide is monotonic")
            previous = s.hueShift
        }
        XCTAssertEqual(c.hueShift, 1, accuracy: 0.05, "major → warm")

        var m = CurtainLights()
        for (i, n) in ([57, 60, 64] as [UInt8]).enumerated() { m.noteOn(n, velocity: 0.7, at: Double(i) * 0.01) }
        previous = m.hueShift
        run(&m, seconds: 4) { s in
            XCTAssertLessThanOrEqual(s.hueShift, previous + 1e-6, "the glide is monotonic")
            previous = s.hueShift
        }
        XCTAssertEqual(m.hueShift, -1, accuracy: 0.05, "minor → cool")

        var t = CurtainLights()
        for (i, n) in ([60, 61, 66] as [UInt8]).enumerated() { t.noteOn(n, velocity: 0.7, at: Double(i) * 0.01) }
        var peak: Float = 0
        run(&t, seconds: 0.5) { s in peak = max(peak, s.tensePulse) }
        XCTAssertGreaterThan(peak, 0.4, "a tense chord pulses the purple fringe")
        XCTAssertEqual(t.hueShift, 0, accuracy: 1e-6, "tense leaves the hue neutral")
        run(&t, seconds: 6)
        XCTAssertLessThan(t.tensePulse, 0.01, "and the pulse dies away")

        // Notes spread out are not a chord.
        var spread = CurtainLights()
        for (i, n) in ([60, 64, 67] as [UInt8]).enumerated() { spread.noteOn(n, velocity: 0.7, at: Double(i) * 0.2) }
        run(&spread, seconds: 2)
        XCTAssertEqual(spread.hueShift, 0, accuracy: 1e-6)

        // Letting the chord go glides the hue back to neutral.
        for n: UInt8 in [60, 64, 67] { c.noteOff(n) }
        run(&c, seconds: 6)
        XCTAssertEqual(c.hueShift, 0, accuracy: 0.05)
    }

    func testShimmerFollowsEnergy() {
        var c = CurtainLights()
        c.step(dt: 1.0 / 60, roles: RoleValues())
        XCTAssertEqual(c.shimmerSpeed, 1, accuracy: 1e-6)
        var r = RoleValues(); r[.energy] = 1
        c.step(dt: 1.0 / 60, roles: r)
        XCTAssertEqual(c.shimmerSpeed, 2, accuracy: 1e-6)
    }

    func testBurstIsRationed() {
        var c = CurtainLights()
        for i in 0..<2000 { c.noteOn(UInt8(21 + i % 88), velocity: 0.9, at: Double(i) * 0.0005) }
        for _ in 0..<60 {
            c.step(dt: 1.0 / 60, roles: RoleValues())
            XCTAssertLessThanOrEqual(c.lastSpawns, CurtainLights.maxSpawnsPerStep)
            XCTAssertLessThanOrEqual(c.ripples.count, CurtainLights.keep)
            let visible = CurtainLights.visible(c.ripples, limit: CurtainLights.cap)
            XCTAssertLessThanOrEqual(visible.count, CurtainLights.cap)
            // The visible ones are the strongest, in their original order.
            if c.ripples.count > CurtainLights.cap {
                let weakestShown = visible.map(\.strength).min() ?? 0
                let hidden = c.ripples.filter { r in !visible.contains { $0.id == r.id } }
                XCTAssertTrue(hidden.allSatisfy { $0.strength <= weakestShown + 1e-6 })
                let order = visible.compactMap { v in c.ripples.firstIndex { $0.id == v.id } }
                XCTAssertEqual(order, order.sorted())
            }
        }
        c.allNotesOff()
        run(&c, seconds: 5)
        XCTAssertTrue(c.ripples.isEmpty, "a panic sends nothing more; the rest fade")
    }

    func testIdsWrap() {
        var c = CurtainLights()
        c.nextID = Int.max - 2
        for i in 0..<6 { c.noteOn(UInt8(60 + i), velocity: 0.5, at: Double(i)) }
        run(&c, seconds: 0.1)
        XCTAssertEqual(c.ripples.count, 6)
        XCTAssertEqual(Set(c.ripples.map(\.id)).count, 6)
    }

    func testOddInputsStayFinite() {
        var c = CurtainLights()
        c.reactionScale = .nan
        c.lingerScale = .infinity
        c.noteOn(200, velocity: .infinity, at: .nan)
        c.noteOn(0, velocity: -3, at: 0)
        c.step(dt: .infinity, roles: RoleValues())
        c.step(dt: .nan, roles: RoleValues())
        c.step(dt: -1, roles: RoleValues())
        XCTAssertEqual(c.ripples.count, 2)
        for r in c.ripples {
            XCTAssertTrue(r.position.isFinite && r.strength.isFinite && r.width.isFinite && r.age.isFinite)
            XCTAssertTrue((0.07...0.93).contains(r.position))
        }
        XCTAssertTrue(c.glow.isFinite && c.hueShift.isFinite && c.tensePulse.isFinite)
    }
}
