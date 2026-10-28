import XCTest
@testable import InStrumCore

final class WorldTests: XCTestCase {
    // MARK: - Lake Ripples

    func testRippleAtKeyPosition() {
        var lake = LakeRipples()
        lake.noteOn(60, velocity: 100, pedal: false, at: 0)
        let key = KeyboardLayout.key(for: 60)!
        let centre = key.x + key.width / 2
        XCTAssertEqual(lake.ripples.first?.x ?? -1, LakeRipples.lakeX(keyCentre: centre), accuracy: 0.01)
        XCTAssertEqual(LakeRipples.lakeX(keyCentre: centre), centre, accuracy: 0.01)
        lake.noteOn(30, velocity: 100, pedal: false, at: 1)
        lake.noteOn(100, velocity: 100, pedal: false, at: 2)
        XCTAssertLessThan(lake.ripples[1].depth, lake.ripples[2].depth, "low notes nearer")
    }

    func testHarderMakesBiggerRipples() {
        var lake = LakeRipples()
        lake.noteOn(60, velocity: 127, pedal: false, at: 0)
        lake.noteOn(62, velocity: 40, pedal: false, at: 1)
        XCTAssertGreaterThan(lake.ripples[0].strength, 1.5 * lake.ripples[1].strength)
    }

    func testPedalLingers() {
        var lake = LakeRipples()
        lake.noteOn(60, velocity: 100, pedal: false, at: 0)
        lake.noteOn(62, velocity: 100, pedal: true, at: 1)
        XCTAssertGreaterThanOrEqual(lake.ripples[1].lifetime, 1.5 * lake.ripples[0].lifetime)
    }

    func testHeldNotesRaiseGlitter() {
        var lake = LakeRipples()
        for (i, n) in [60, 64, 67, 72].enumerated() { lake.noteOn(UInt8(n), velocity: 90, pedal: false, at: Double(i) * 0.2) }
        for _ in 0..<60 { lake.step(dt: 1.0 / 60, roles: RoleValues()) }
        XCTAssertGreaterThan(lake.glitter, 0.8)
        for n in [60, 64, 67, 72] { lake.noteOff(UInt8(n)) }
        for _ in 0..<180 { lake.step(dt: 1.0 / 60, roles: RoleValues()) }
        XCTAssertLessThan(lake.glitter, 0.2)
    }

    func testChordReleasesFireflies() {
        var chord = LakeRipples()
        chord.noteOn(60, velocity: 90, pedal: false, at: 0)
        chord.noteOn(64, velocity: 90, pedal: false, at: 0.015)
        chord.noteOn(67, velocity: 90, pedal: false, at: 0.03)
        chord.step(dt: 1.0 / 60, roles: RoleValues())
        XCTAssertGreaterThanOrEqual(chord.fireflies.count, 2)
        XCTAssertLessThanOrEqual(chord.fireflies.count, 5)
        var single = LakeRipples()
        for i in 0..<6 { single.noteOn(UInt8(60 + i), velocity: 90, pedal: false, at: Double(i) * 0.2); single.step(dt: 0.2, roles: RoleValues()) }
        XCTAssertEqual(single.fireflies.count, 0)
        // They rise, drift and fade within 4–6 s.
        let start = chord.fireflies.map(\.position.y)
        for _ in 0..<120 { chord.step(dt: 1.0 / 60, roles: RoleValues()) }
        XCTAssertGreaterThan(chord.fireflies.map(\.position.y).reduce(0, +), start.reduce(0, +))
        for _ in 0..<(6 * 60) { chord.step(dt: 1.0 / 60, roles: RoleValues()) }
        XCTAssertEqual(chord.fireflies.count, 0)
    }

    func testRippleCapAndBudget() {
        var lake = LakeRipples()
        let start = CFAbsoluteTimeGetCurrent()
        for i in 0..<2000 { lake.noteOn(UInt8(21 + i % 88), velocity: 100, pedal: true, at: Double(i) * 0.001) }
        lake.step(dt: 1.0 / 60, roles: RoleValues())
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        XCTAssertLessThanOrEqual(lake.ripples.count, LakeRipples.cap)
        XCTAssertLessThan(elapsed, 0.1, "2000 notes and a step: no worse than 50 µs a note in a debug build on CI")
        let t0 = CFAbsoluteTimeGetCurrent()
        lake.step(dt: 1.0 / 60, roles: RoleValues())
        XCTAssertLessThan(CFAbsoluteTimeGetCurrent() - t0, 0.008)
    }

    func testRipplesFadeAway() {
        var lake = LakeRipples()
        lake.noteOn(60, velocity: 100, pedal: false, at: 0)
        for _ in 0..<(10 * 60) { lake.step(dt: 1.0 / 60, roles: RoleValues()) }
        XCTAssertTrue(lake.ripples.isEmpty)
    }

    // MARK: - Moonlit Lake

    private func lakeFrame(hour: Double, weather: WeatherKind = .clear, notes: [UInt8] = []) -> LakeFrame? {
        let d = SceneDirector(themeID: MoonlitLakeModel.id, state: ThemeState(), reaction: ReactionPresets.expressivePianist)
        var s = SkySettings(); s.timeMode = .frozen; s.frozenHour = hour; s.cityID = "melbourne"; s.weatherMode = .pick; s.weather = weather
        d.sky.reset(settings: s)
        d.mood = .serene
        var frame: LakeFrame?
        for i in 0..<90 {   // three seconds for the sky to settle; the notes land in the last third of a second
            if i == 80 { d.handle(notes.map { .noteOn(note: $0, velocity: 0.8) }, at: Double(i) / 30) }
            frame = d.step(dt: 1.0 / 30, t: Double(i) / 30, quality: .high) as? LakeFrame
        }
        return frame
    }

    func testLakeIsRegistered() {
        XCTAssertEqual(ThemeRegistry.resolve(MoonlitLakeModel.id), MoonlitLakeModel.id)
        XCTAssertTrue(ThemeRegistry.all.contains { $0.id == MoonlitLakeModel.id && $0.name == "Moonlit Lake" })
        assertValidParameters(MoonlitLakeModel.parameters)
    }

    func testLakeAmbienceFollowsSky() throws {
        let night = try XCTUnwrap(lakeFrame(hour: 23))
        let day = try XCTUnwrap(lakeFrame(hour: 13))
        XCTAssertGreaterThan(night.ambience.level(.crickets), 0.5)
        XCTAssertEqual(day.ambience.level(.crickets), 0)
        XCTAssertGreaterThan(night.ambience.level(.owl), 0)
        XCTAssertEqual(night.ambience.level(.water), 0.8, accuracy: 1e-9)
        let rain = try XCTUnwrap(lakeFrame(hour: 23, weather: .rain))
        XCTAssertGreaterThan(rain.ambience.level(.rainOnWater), 0.6)
        XCTAssertGreaterThan(night.ambience.nightCool, 0)
        XCTAssertEqual(night.ambience.closeness, MoodLook.ambienceCloseness(base: 0.5, .serene), accuracy: 1e-9)
        XCTAssertEqual(night.mood, .serene)
        let dawn = try XCTUnwrap(lakeFrame(hour: 7.1))
        XCTAssertGreaterThan(dawn.ambience.level(.dawnChorus), 0, "birds as the sun comes up")
    }

    func testLakeFrameCarriesRipplesAndKeys() throws {
        let f = try XCTUnwrap(lakeFrame(hour: 22, notes: [60, 64]))
        XCTAssertEqual(f.ripples.count, 2)
        XCTAssertEqual(f.keys.count, 88)
        XCTAssertTrue(f.keys.contains { $0.key.note == 60 && $0.pressed })
        XCTAssertLessThan(f.sky.sun.altitude, -6)
    }
}
