import XCTest
@testable import InStrumCore

final class ButterflyGardenModelTests: XCTestCase {
    typealias M = ButterflyGardenModel
    let params = ParameterSet(specs: M.parameters, macroTargets: M.macroTargets)

    private func step(_ m: inout M, _ seconds: Double, roles: RoleValues = RoleValues(), quality: QualityLevel = .high) -> GardenFrame {
        var f: GardenFrame!
        let frames = max(1, Int(seconds * 60))
        for _ in 0..<frames { f = m.step(dt: seconds / Double(frames), params: params, roles: roles, inputs: InputFrame(), quality: quality) }
        return f
    }
    private func keyX(_ n: UInt8) -> Float { let k = KeyboardLayout.key(for: n)!; return k.x + k.width / 2 }

    func testIdentity() { XCTAssertEqual(M.id, "butterfly-garden"); XCTAssertEqual(M.displayName, "Butterfly Garden") }
    func testParameterIdsUniqueAndDefaultsValid() { assertValidParameters(M.parameters) }

    func testHarderNoteMakesBiggerButterfly() {
        var soft = M(); soft.handle(.noteOn(note: 60, velocity: 0.2))
        var hard = M(); hard.handle(.noteOn(note: 60, velocity: 1.0))
        XCTAssertGreaterThan(step(&hard, 1.0 / 60).butterflies[0].size, step(&soft, 1.0 / 60).butterflies[0].size * 1.5)
    }
    func testLowNoteBiggerThanHigh() {
        var m = M(); m.handle(.noteOn(note: 30, velocity: 0.7)); m.handle(.noteOn(note: 100, velocity: 0.7))
        let b = step(&m, 1.0 / 60).butterflies
        let low = b.first { $0.homeNote == 30 }!, high = b.first { $0.homeNote == 100 }!
        XCTAssertGreaterThan(low.size, high.size)
        XCTAssertLessThan(low.flapRate, high.flapRate)
    }
    func testHeldNoteHoversAboveItsKey() {
        var m = M(); m.handle(.noteOn(note: 60, velocity: 0.7))
        let b = step(&m, 2).butterflies.first { $0.homeNote == 60 }!
        XCTAssertEqual(b.position.x, keyX(60), accuracy: 0.02)
        XCTAssertTrue((0.15...0.3).contains(b.position.y), "y \(b.position.y)")
    }
    func testPedalSlowsWings() {
        var a = M(); a.handle(.noteOn(note: 60, velocity: 0.7))
        var b = M(); b.handle(.noteOn(note: 60, velocity: 0.7))
        var linger = RoleValues(); linger[.linger] = 1
        let normal = step(&a, 0.1).butterflies[0].flapRate
        let slow = step(&b, 0.1, roles: linger).butterflies[0].flapRate
        XCTAssertLessThanOrEqual(slow, normal * 0.45)
    }
    func testChordStartsSpiral() {
        var m = M(); m.handle(.chord(notes: [60, 64, 67]))
        XCTAssertGreaterThan(step(&m, 1.0 / 60).spiral, 0.5)
        XCTAssertLessThan(step(&m, 3).spiral, 0.1)
    }
    func testSilenceLandsButterflies() {
        var m = M()
        for n: UInt8 in [60, 64, 67, 72] { m.handle(.noteOn(note: n, velocity: 0.7)); m.handle(.noteOff(note: n)) }
        let f = step(&m, 5)
        XCTAssertFalse(f.butterflies.isEmpty)
        XCTAssertTrue(f.butterflies.allSatisfy { $0.landed })
    }
    func testPlayingAgainWakesThem() {
        var m = M(); m.handle(.noteOn(note: 60, velocity: 0.7)); m.handle(.noteOff(note: 60))
        _ = step(&m, 5)
        m.handle(.noteOn(note: 62, velocity: 0.7))
        XCTAssertTrue(step(&m, 0.1).butterflies.allSatisfy { !$0.landed })
    }
    func testBloomAppearsWhereMelodyLands() {
        var m = M(); m.handle(.noteOn(note: 72, velocity: 0.7))
        let f = step(&m, 1)
        XCTAssertTrue(f.blooms.contains { abs($0.x - keyX(72)) < 0.02 && $0.openness > 0 })
    }
    func testCountCapHolds() {
        var m = M()
        for i in 0..<2000 { m.handle(.noteOn(note: UInt8(21 + i % 88), velocity: 0.8)); m.handle(.noteOff(note: UInt8(21 + i % 88))) }
        XCTAssertLessThanOrEqual(step(&m, 1.0 / 60).butterflies.count, 300)   // butterflies.max default
    }
    func testQualityLiteCaps200() {
        var p = params; p.set("butterflies.max", .number(1200))
        var m = M()
        for i in 0..<2000 { m.handle(.noteOn(note: UInt8(21 + i % 88), velocity: 0.8)); m.handle(.noteOff(note: UInt8(21 + i % 88))) }
        XCTAssertLessThanOrEqual(m.step(dt: 1.0 / 60, params: p, roles: RoleValues(), inputs: InputFrame(), quality: .lite).butterflies.count, 200)
    }
    func testOutOfRangeNoteSpawnsNothing() {
        var m = M(); m.handle(.noteOn(note: 10, velocity: 1))
        XCTAssertTrue(step(&m, 1.0 / 60).butterflies.isEmpty)
    }
    func testMinimumVelocityGate() {
        var p = params; p.set("spawn.minVelocity", .number(0.3))
        var m = M(); m.handle(.noteOn(note: 60, velocity: 0.1))
        XCTAssertTrue(m.step(dt: 0.016, params: p, roles: RoleValues(), inputs: InputFrame(), quality: .high).butterflies.isEmpty)
    }
    func testAllNotesOffReleasesHovering() {
        var m = M(); m.handle(.noteOn(note: 60, velocity: 0.7)); _ = step(&m, 0.5)
        m.handle(.allNotesOff)
        let f = step(&m, 1.0 / 60)
        XCTAssertTrue(f.butterflies.allSatisfy { $0.homeNote == nil })
        XCTAssertTrue(f.keys.allSatisfy { !$0.pressed })
    }
    func testEnergyRaisesExposureAndRays() {
        var calm = M(), lit = M()
        var e = RoleValues(); e[.energy] = 1; e[.brightness] = 1
        XCTAssertGreaterThan(step(&lit, 0.1, roles: e).exposure, step(&calm, 0.1).exposure)
    }
    func testBurstStepsWithinBudget() {
        var m = M()
        let start = DispatchTime.now().uptimeNanoseconds
        for i in 0..<2000 { m.handle(.noteOn(note: UInt8(21 + i % 88), velocity: 0.8)) }
        _ = m.step(dt: 1.0 / 60, params: params, roles: RoleValues(), inputs: InputFrame(), quality: .high)
        XCTAssertLessThan(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6, 8)
    }
    func testDeterministic() {
        var a = M(), b = M()
        a.handle(.noteOn(note: 60, velocity: 0.7)); b.handle(.noteOn(note: 60, velocity: 0.7))
        XCTAssertEqual(step(&a, 1).butterflies, step(&b, 1).butterflies)
    }
}
