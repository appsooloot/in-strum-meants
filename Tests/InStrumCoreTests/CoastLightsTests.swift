import XCTest
@testable import InStrumCore

/// Coast Lights: notes light passing lights by pitch (road, guardrail, lamps); playing sets the car's speed;
/// chords bloom the sea's glitter path.
final class CoastLightsTests: XCTestCase {
    private func roles(energy: Double, density: Double = 0) -> RoleValues {
        var r = RoleValues(); r[.energy] = energy; r[.density] = density; return r
    }

    private func step(_ c: inout CoastLights, seconds: Double, roles r: RoleValues = RoleValues()) {
        for _ in 0..<Int(seconds * 60) { c.step(dt: 1.0 / 60, roles: r) }
    }

    func testLanesByPitch() {
        XCTAssertEqual(CoastLights.lane(for: 21), .road)
        XCTAssertEqual(CoastLights.lane(for: 47), .road)
        XCTAssertEqual(CoastLights.lane(for: 48), .rail)
        XCTAssertEqual(CoastLights.lane(for: 71), .rail)
        XCTAssertEqual(CoastLights.lane(for: 72), .lamp)
        XCTAssertEqual(CoastLights.lane(for: 108), .lamp)
        var c = CoastLights()
        c.noteOn(50, velocity: 100, at: 0); c.noteOn(70, velocity: 100, at: 0)
        step(&c, seconds: 1.0 / 60)
        let rail = c.lights.filter { $0.lane == .rail }
        XCTAssertEqual(rail.count, 2)
        XCTAssertLessThan(rail[0].height, rail[1].height, "higher notes sit higher in their lane")
        XCTAssertTrue(c.lights.allSatisfy { (0...1).contains($0.height) && $0.x < 0.1 }, "lights enter at the right")
    }

    func testSpeedRisesCapsAndSettles() {
        var c = CoastLights()
        c.speedResponse = 1
        XCTAssertEqual(c.speed, CoastLights.cruise, accuracy: 1e-6)
        var last = c.speed, maxStep: Float = 0
        for _ in 0..<(4 * 60) {
            c.step(dt: 1.0 / 60, roles: roles(energy: 1, density: 1))
            maxStep = max(maxStep, abs(c.speed - last)); last = c.speed
            XCTAssertLessThanOrEqual(c.speed, 1)
        }
        XCTAssertGreaterThan(c.speed, 0.9, "playing hard speeds the car up")
        for _ in 0..<(12 * 60) {
            c.step(dt: 1.0 / 60, roles: RoleValues())
            maxStep = max(maxStep, abs(c.speed - last)); last = c.speed
        }
        XCTAssertEqual(c.speed, CoastLights.cruise, accuracy: 0.02, "silence eases it back to cruise")
        XCTAssertLessThan(maxStep, 0.05, "the speed never jumps")
        XCTAssertGreaterThan(c.distance, 0, "the car travels")
    }

    func testDistanceFollowsSpeed() {
        var c = CoastLights()
        step(&c, seconds: 10)
        // Cruise 0.35 is about 55 km/h: 10 s covers about 150 m.
        XCTAssertEqual(c.distance, 10 * (30 + 70 * 0.35) / 3.6, accuracy: 1)
    }

    func testChordBloomColourByQuality() {
        func bloom(_ notes: [UInt8]) -> CoastLights {
            var c = CoastLights()
            c.bloomAmount = 1
            for n in notes { c.noteOn(n, velocity: 100, at: 0) }
            step(&c, seconds: 0.5)
            return c
        }
        // Tense is the shared classifier's tense (a tritone or semitone): B–D–F.
        let major = bloom([60, 64, 67]), minor = bloom([57, 60, 64]), tense = bloom([59, 62, 65])
        XCTAssertEqual(major.bloomHue, CoastLights.majorHue, accuracy: 1e-4)
        XCTAssertEqual(minor.bloomHue, CoastLights.minorHue, accuracy: 1e-4)
        XCTAssertEqual(tense.bloomHue, CoastLights.tenseHue, accuracy: 1e-4)
        XCTAssertEqual(CoastLights.majorHue, 0.11); XCTAssertEqual(CoastLights.minorHue, 0.58); XCTAssertEqual(CoastLights.tenseHue, 0.78)
        XCTAssertGreaterThan(major.bloom, 0.5, "the bloom rises within half a second")
        var single = CoastLights()
        single.bloomAmount = 1
        single.noteOn(60, velocity: 100, at: 0)
        step(&single, seconds: 0.5)
        XCTAssertEqual(single.bloom, 0, "a single note doesn't bloom")
        var fading = major
        for n: UInt8 in [60, 64, 67] { fading.noteOff(n) }
        step(&fading, seconds: 5)
        XCTAssertLessThan(fading.bloom, 0.2 * major.bloom, "it fades when the chord lets go")
    }

    func testBloomHueChangesWithTheChordNotThroughOtherColours() {
        var c = CoastLights()
        c.bloomAmount = 1
        for n: UInt8 in [57, 60, 64] { c.noteOn(n, velocity: 100, at: 0) }
        step(&c, seconds: 0.5)
        for n: UInt8 in [57, 60, 64] { c.noteOff(n) }
        for n: UInt8 in [60, 64, 67] { c.noteOn(n, velocity: 100, at: 0.5) }
        c.step(dt: 1.0 / 60, roles: RoleValues())
        XCTAssertEqual(c.bloomHue, CoastLights.majorHue, accuracy: 1e-6, "no hue sweep through green on the way")
    }

    func testLampLightsKnowWhereTheyJoinedTheRoad() {
        var c = CoastLights()
        step(&c, seconds: 2)
        c.noteOn(84, velocity: 100, at: 2)
        step(&c, seconds: 1.0 / 60)
        let lamp = try? XCTUnwrap(c.lights.first)
        XCTAssertEqual(lamp?.lane, .lamp)
        XCTAssertEqual(lamp?.spawnDistance ?? -1, c.distance, accuracy: 1)
        // Lamp lights pass with the lamps: gone once the car has gone CoastLights.lampTravel metres on.
        let joined = c.distance
        while c.distance - joined < CoastLights.lampTravel - 1 { c.step(dt: 1.0 / 60, roles: RoleValues()) }
        XCTAssertEqual(c.lights.count, 1, "still passing")
        while c.distance - joined < CoastLights.lampTravel + 1 { c.step(dt: 1.0 / 60, roles: RoleValues()) }
        XCTAssertTrue(c.lights.isEmpty, "gone past")
    }

    func testLightsStreamPastAndFade() {
        var c = CoastLights()
        c.noteOn(60, velocity: 127, at: 0)
        step(&c, seconds: 0.1)
        let x0 = c.lights[0].x, b0 = c.lights[0].brightness
        c.noteOff(60)
        step(&c, seconds: 0.5)
        XCTAssertGreaterThan(c.lights.first?.x ?? 2, x0, "lights travel right to left")
        XCTAssertLessThan(c.lights.first?.brightness ?? 0, b0, "and fade once released")
        step(&c, seconds: 8)
        XCTAssertTrue(c.lights.isEmpty, "gone past")
    }

    func testHarderMeansBrighterLongerTrails() {
        var c = CoastLights()
        c.noteOn(60, velocity: 127, at: 0); c.noteOn(62, velocity: 30, at: 0)
        step(&c, seconds: 1.0 / 60)
        XCTAssertGreaterThan(c.lights[0].brightness, c.lights[1].brightness)
        XCTAssertGreaterThan(c.lights[0].trail, c.lights[1].trail)
    }

    func testBurstIsRationed() {
        var c = CoastLights()
        for i in 0..<2000 { c.noteOn(UInt8(21 + i % 88), velocity: 100, at: Double(i) * 0.0001) }
        var last = 0
        for _ in 0..<20 {
            c.step(dt: 1.0 / 60, roles: RoleValues())
            XCTAssertLessThanOrEqual(c.lights.count - last, CoastLights.maxSpawnsPerStep)
            XCTAssertLessThanOrEqual(c.lights.count, CoastLights.cap)
            last = c.lights.count
        }
        XCTAssertGreaterThan(c.lights.count, CoastLights.maxSpawnsPerStep, "the burst streams out over frames")
    }

    func testSmoothKeepsTheStrongest64() {
        var c = CoastLights()
        for i in 0..<100 { c.noteOn(UInt8(21 + i % 88), velocity: UInt8(20 + (i * 37) % 107), at: Double(i) * 0.01) }
        step(&c, seconds: 0.2)
        let lights = c.lights
        XCTAssertGreaterThan(lights.count, 64)
        let kept = CoastLights.visible(lights, limit: 64)
        XCTAssertEqual(kept.count, 64)
        let weakestKept = kept.map(\.brightness).min() ?? 0
        let keptIDs = Set(kept.map(\.id))
        XCTAssertTrue(lights.filter { !keptIDs.contains($0.id) }.allSatisfy { $0.brightness <= weakestKept })
        XCTAssertEqual(kept.map(\.id), lights.map(\.id).filter { keptIDs.contains($0) }, "original order")
    }
}
