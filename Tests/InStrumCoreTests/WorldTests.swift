import XCTest
import simd
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

    func testSmoothBudgetKeepsTheStrongestRings() {
        // 40 rings: 32 fresh strong ones, then 8 faint old ones added last.
        var rings: [Ripple] = (0..<32).map { Ripple(x: Float($0) / 32, depth: 0.5, age: 0.2, strength: 1, lifetime: 3) }
        rings += (0..<8).map { Ripple(x: Float($0) / 8, depth: 0.2, age: 2.8, strength: 0.3, lifetime: 3) }
        let kept = LakeRipples.visible(rings, limit: 32)
        XCTAssertEqual(kept.count, 32)
        XCTAssertTrue(kept.allSatisfy { $0.strength == 1 }, "the faint, nearly spent rings are the ones left out")
        XCTAssertEqual(LakeRipples.visible(rings, limit: 64).count, 40)
        // The pick is stable: the same set every frame while nothing changes.
        XCTAssertEqual(LakeRipples.visible(rings, limit: 32), kept)
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

    // MARK: - Golden Hour Beach

    private func beachFrames(hour: Double = 13, seconds: Double = 30, notes: [UInt8] = [60, 64, 67], weather: WeatherKind = .clear,
                             state: ThemeState = ThemeState()) -> [BeachFrame] {
        let d = SceneDirector(themeID: GoldenHourBeachModel.id, state: state, reaction: ReactionPresets.expressivePianist)
        var s = SkySettings(); s.timeMode = .frozen; s.frozenHour = hour; s.cityID = "melbourne"; s.weatherMode = .pick; s.weather = weather
        d.sky.reset(settings: s)
        var frames: [BeachFrame] = []
        for i in 0..<Int(seconds * 30) {
            if i == 30 { d.handle(notes.map { .noteOn(note: $0, velocity: 0.8) }, at: Double(i) / 30) }
            if let f = d.step(dt: 1.0 / 30, t: Double(i) / 30, quality: .high) as? BeachFrame { frames.append(f) }
        }
        return frames
    }

    func testBeachIsRegistered() {
        XCTAssertEqual(ThemeRegistry.resolve(GoldenHourBeachModel.id), GoldenHourBeachModel.id)
        XCTAssertTrue(ThemeRegistry.all.contains { $0.id == GoldenHourBeachModel.id && $0.name == "Golden Hour Beach" })
        XCTAssertTrue(ThemeRegistry.isWorld(GoldenHourBeachModel.id))
        assertValidParameters(GoldenHourBeachModel.parameters)
        let params = ThemeRegistry.parameterSet(for: GoldenHourBeachModel.id, state: ThemeState())
        XCTAssertEqual(params.choice("light.hold"), "Golden hour")
        XCTAssertEqual(params.choice("visual"), "Tide Lines")
    }

    func testBeachFrame() throws {
        let frames = beachFrames()
        let last = try XCTUnwrap(frames.last)
        XCTAssertEqual(frames.count, 900)
        XCTAssertTrue(frames.contains { !$0.lines.isEmpty }, "notes write lines")
        XCTAssertTrue(frames.allSatisfy { (0...1).contains($0.washFront) })
        XCTAssertEqual(last.sky.sun.altitude, 5, accuracy: 1e-6, "held at golden hour although it's 1 pm")
        XCTAssertEqual(last.keys.count, 88)
        // A wave is heard on exactly the frames where one broke.
        var broke = 0
        for (a, b) in zip(frames, frames.dropFirst()) where b.recent.last?.breakTime != a.recent.last?.breakTime { broke += 1 }
        XCTAssertEqual(frames.filter { $0.ambience.wave != nil }.count, broke)
        XCTAssertGreaterThan(broke, 1)
        XCTAssertEqual(last.ambience.level(.gulls), 0, "gulls are off until they pass the ear test")
        XCTAssertEqual(last.ambience.level(.surf), 0.9, accuracy: 1e-9)
        XCTAssertEqual(last.ambience.surfDistance, 0.15, accuracy: 1e-9)
    }

    func testBeachWarpOptionStreaksInstead() throws {
        var state = ThemeState(); state.values["visual"] = .choice("Galaxy Warp")
        let frames = beachFrames(seconds: 3, state: state)
        let last = try XCTUnwrap(frames.last)
        XCTAssertNotNil(last.warp)
        XCTAssertTrue(frames.allSatisfy { $0.lines.isEmpty })
    }

    func testStormySeaIsBigger() throws {
        let calm = try XCTUnwrap(beachFrames(seconds: 2, notes: []).last), storm = try XCTUnwrap(beachFrames(seconds: 2, notes: [], weather: .storm).last)
        XCTAssertGreaterThan(storm.swellScale, calm.swellScale)
    }

    // MARK: - Coast Road

    /// The demo performance on the coast road at 60 fps (frames every step).
    private func roadFrames(seconds: Double = 12, hour: Double = 13, state: ThemeState = ThemeState()) -> [RoadFrame] {
        let d = SceneDirector(themeID: CoastRoadModel.id, state: state, reaction: ReactionPresets.expressivePianist)
        var s = SkySettings(); s.timeMode = .frozen; s.frozenHour = hour; s.cityID = "melbourne"; s.weatherMode = .pick; s.weather = .clear
        d.sky.reset(settings: s)
        var perf = PerformanceState()
        let script = ScriptedPerformance.demo
        var next = 0
        var frames: [RoadFrame] = []
        for i in 1...Int(seconds * 60) {
            let t = Double(i) / 60
            var events: [PerformanceEvent] = []
            while next < script.count, script[next].time <= t { events += perf.apply(script[next].message, at: script[next].time); next += 1 }
            d.handle(events, at: t)
            if let f = d.step(dt: 1.0 / 60, t: t, quality: .high) as? RoadFrame { frames.append(f) }
        }
        return frames
    }

    func testRoadIsRegistered() {
        XCTAssertEqual(ThemeRegistry.resolve(CoastRoadModel.id), CoastRoadModel.id)
        XCTAssertTrue(ThemeRegistry.all.contains { $0.id == CoastRoadModel.id && $0.name == "Coast Road" })
        XCTAssertTrue(ThemeRegistry.isWorld(CoastRoadModel.id))
        assertValidParameters(CoastRoadModel.parameters)
        let params = ThemeRegistry.parameterSet(for: CoastRoadModel.id, state: ThemeState())
        XCTAssertEqual(params.choice("light.hold"), "Blue hour")
        XCTAssertEqual(params.choice("visual"), "Coast Lights")
    }

    func testRoadFrame() throws {
        let frames = roadFrames()
        let last = try XCTUnwrap(frames.last)
        XCTAssertEqual(frames.count, 720)
        XCTAssertTrue(frames.contains { !$0.lights.isEmpty }, "notes light passing lights")
        XCTAssertTrue(frames.contains { $0.speed > CoastLights.cruise + 0.02 }, "playing speeds the car up")
        XCTAssertTrue(frames.allSatisfy { $0.speed <= 1 })
        for f in frames {
            XCTAssertEqual(f.ambience.speed, Double(f.speed), accuracy: 1e-6)
            XCTAssertLessThanOrEqual(abs(f.roll), 1.5 * 0.5 + 1e-9)
            XCTAssertLessThanOrEqual(abs(f.yaw), 2 * 0.5 + 1e-9)
        }
        XCTAssertEqual(last.sky.sun.altitude, -6, accuracy: 1e-6, "held at blue hour although it's 1 pm")
        XCTAssertEqual(last.keys.count, 88)
        XCTAssertGreaterThan(last.distance, 100, "the car travels")
        XCTAssertEqual(last.ambience.level(.road), 0.8, accuracy: 1e-9)
        XCTAssertEqual(last.ambience.surfDistance, 0.9, accuracy: 1e-9)
        XCTAssertGreaterThan(last.ambience.level(.engine), 0)
        // Full sway stays within ±1.5° roll and ±2° yaw, with slow periods.
        let swaying = roadFrames(seconds: 20, state: ThemeState(values: ["sway": .number(1)]))
        XCTAssertLessThanOrEqual(swaying.map { abs($0.roll) }.max() ?? 9, 1.5 + 1e-9)
        XCTAssertLessThanOrEqual(swaying.map { abs($0.yaw) }.max() ?? 9, 2 + 1e-9)
        XCTAssertGreaterThan(swaying.map { abs($0.roll) }.max() ?? 0, 1.2)
        XCTAssertLessThan(zip(swaying, swaying.dropFirst()).map { abs($1.roll - $0.roll) }.max() ?? 9, 0.02, "never jerky")
    }

    func testRoadWarpOptionStreaksInstead() throws {
        let frames = roadFrames(seconds: 3, state: ThemeState(values: ["visual": .choice("Galaxy Warp")]))
        XCTAssertNotNil(frames.last?.warp)
        XCTAssertTrue(frames.allSatisfy { $0.lights.isEmpty })
    }

    // MARK: - Galaxy Warp

    private func roles(energy: Double) -> RoleValues { var r = RoleValues(); r[.energy] = energy; return r }

    func testNotesLaunchStreaks() {
        var warp = GalaxyWarp()
        warp.noteOn(60, velocity: 120, at: 0)
        let f = warp.step(dt: 1.0 / 60, roles: RoleValues(), inputs: InputFrame())
        XCTAssertGreaterThanOrEqual(f.streaks.count, 3)
        XCTAssertGreaterThan(f.streaks[0].brightness, 0.8)
        var low = GalaxyWarp(), high = GalaxyWarp()
        low.noteOn(21, velocity: 100, at: 0)
        high.noteOn(108, velocity: 100, at: 0)
        let a = low.step(dt: 0.001, roles: RoleValues(), inputs: InputFrame()).streaks[0].direction
        let b = high.step(dt: 0.001, roles: RoleValues(), inputs: InputFrame()).streaks[0].direction
        XCTAssertGreaterThan(acos(min(1, max(-1, simd_dot(a, b)))), 1.5, "lowest and highest notes fly different ways")
        var soft = GalaxyWarp()
        soft.noteOn(60, velocity: 30, at: 0)
        let s = soft.step(dt: 0.001, roles: RoleValues(), inputs: InputFrame())
        XCTAssertLessThan(s.streaks[0].brightness, f.streaks[0].brightness, "velocity sets brightness")
    }

    func testIntensitySetsWarpSpeed() {
        var warp = GalaxyWarp()
        var f = warp.step(dt: 0, roles: RoleValues(), inputs: InputFrame())
        for _ in 0..<60 { f = warp.step(dt: 1.0 / 60, roles: roles(energy: 1), inputs: InputFrame()) }
        XCTAssertGreaterThan(f.warpSpeed, 0.8)
        for _ in 0..<(6 * 60) { f = warp.step(dt: 1.0 / 60, roles: roles(energy: 0), inputs: InputFrame()) }
        XCTAssertLessThan(f.warpSpeed, 0.15)
    }

    private func nebula(after notes: [UInt8]) -> WarpFrame {
        var warp = GalaxyWarp()
        for n in notes { warp.noteOn(n, velocity: 90, at: 0) }
        var f = warp.step(dt: 0, roles: RoleValues(), inputs: InputFrame())
        for _ in 0..<60 { f = warp.step(dt: 1.0 / 60, roles: RoleValues(), inputs: InputFrame()) }
        return f
    }

    func testChordBloomsNebula() {
        let major = nebula(after: [60, 64, 67])
        XCTAssertGreaterThan(major.nebula, 0.5)
        XCTAssertTrue((0.72...0.84).contains(major.nebulaHue), "major is warm violet: \(major.nebulaHue)")
        let minor = nebula(after: [57, 60, 64])
        XCTAssertTrue((0.58...0.68).contains(minor.nebulaHue), "minor is deep blue: \(minor.nebulaHue)")
        let tense = nebula(after: [60, 66, 71])
        XCTAssertTrue((0.85...0.95).contains(tense.nebulaHue), "tense is magenta: \(tense.nebulaHue)")
        XCTAssertLessThan(nebula(after: [60]).nebula, 0.05, "one note is not a chord")
    }

    func testSilenceSettles() {
        var warp = GalaxyWarp()
        for i in 0..<20 { warp.noteOn(UInt8(40 + i), velocity: 110, at: Double(i) * 0.05) }
        var f = warp.step(dt: 1.0 / 60, roles: roles(energy: 1), inputs: InputFrame())
        for i in 0..<20 { warp.noteOff(UInt8(40 + i)) }
        for _ in 0..<(8 * 60) { f = warp.step(dt: 1.0 / 60, roles: roles(energy: 0), inputs: InputFrame()) }
        XCTAssertEqual(f.streaks.count, 0)
        XCTAssertLessThan(f.warpSpeed, 0.15)
        XCTAssertLessThan(f.nebula, 0.1)
    }

    func testStreakSpawnsAreRationedPerStep() {
        var warp = GalaxyWarp()
        for i in 0..<400 { warp.noteOn(UInt8(21 + i % 88), velocity: 127, at: Double(i) * 0.0005) }   // a MIDI burst
        let first = warp.step(dt: 1.0 / 60, roles: RoleValues(), inputs: InputFrame())
        XCTAssertLessThanOrEqual(first.streaks.count, GalaxyWarp.maxSpawnsPerStep, "a burst can't fill the window in one frame")
        var f = first
        for _ in 0..<20 { f = warp.step(dt: 1.0 / 60, roles: RoleValues(), inputs: InputFrame()) }
        XCTAssertGreaterThan(f.streaks.count, GalaxyWarp.maxSpawnsPerStep, "the rest follow over the next frames")
        XCTAssertLessThanOrEqual(f.streaks.count, GalaxyWarp.cap)
    }

    func testWarpCapAndBudget() {
        var warp = GalaxyWarp()
        for i in 0..<2000 { warp.noteOn(UInt8(21 + i % 88), velocity: 127, at: Double(i) * 0.001) }
        let t0 = CFAbsoluteTimeGetCurrent()
        let f = warp.step(dt: 1.0 / 60, roles: roles(energy: 1), inputs: InputFrame())
        XCTAssertLessThan(CFAbsoluteTimeGetCurrent() - t0, 0.008)
        XCTAssertLessThanOrEqual(f.streaks.count, GalaxyWarp.cap)
    }

    // MARK: - Spaceship Lounge

    private func loungeFrame(_ s: SkySettings, at now: Date = Date(timeIntervalSince1970: 1_793_000_000)) -> LoungeFrame? {
        let d = SceneDirector(themeID: SpaceshipLoungeModel.id, state: ThemeState(), reaction: ReactionPresets.expressivePianist)
        d.sky.reset(settings: s)
        d.clock = { now }
        d.mood = .dreamy
        var frame: LoungeFrame?
        for i in 0..<30 { frame = d.step(dt: 1.0 / 30, t: Double(i) / 30, quality: .high) as? LoungeFrame }
        return frame
    }

    func testLoungeIsRegistered() {
        XCTAssertEqual(ThemeRegistry.resolve(SpaceshipLoungeModel.id), SpaceshipLoungeModel.id)
        XCTAssertTrue(ThemeRegistry.all.contains { $0.id == SpaceshipLoungeModel.id && $0.name == "Spaceship Lounge" })
        assertValidParameters(SpaceshipLoungeModel.parameters)
    }

    func testEarthFollowsRealSun() throws {
        var s = SkySettings(); s.timeMode = .realTime; s.cityID = "london"; s.weatherMode = .pick; s.weather = .clear
        let noon = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-28T12:00:00Z"))
        let f = try XCTUnwrap(loungeFrame(s, at: noon))
        XCTAssertEqual(f.sky.subsolar.longitude, -4, accuracy: 1.5)
        // London at noon: the lounge floats over the day side.
        let below = Double(f.earthRotation) * 180 / .pi
        var gap = abs(below - f.sky.subsolar.longitude).truncatingRemainder(dividingBy: 360)
        if gap > 180 { gap = 360 - gap }
        XCTAssertLessThan(gap, 20)
    }

    func testLoungeHasNoWeather() throws {
        var s = SkySettings(); s.timeMode = .frozen; s.frozenHour = 22; s.cityID = "melbourne"; s.weatherMode = .pick; s.weather = .rain
        let f = try XCTUnwrap(loungeFrame(s))
        XCTAssertEqual(f.ambience.level(.rainOnGlass), 0)
        XCTAssertEqual(f.ambience.level(.rainOnWater), 0)
        XCTAssertNil(f.ambience.thunder)
        XCTAssertEqual(f.sky.rain, 0)
        XCTAssertEqual(f.sky.cloudCover, 0)
        XCTAssertEqual(f.sky.starVisibility, 1)
        XCTAssertEqual(f.ambience.level(.shipHum), 0.8, accuracy: 1e-9)
        XCTAssertEqual(f.ambience.level(.airFlow), 0.5, accuracy: 1e-9)
        XCTAssertEqual(f.ambience.level(.chime), 0.25, accuracy: 1e-9)
        XCTAssertEqual(f.ambience.level(.hullTicks), 0.25, accuracy: 1e-9)
        XCTAssertEqual(f.mood, .dreamy)
    }

    func testGalaxyWarpCanRunOnLake() throws {
        XCTAssertTrue(MoonlitLakeModel.visuals.contains("Galaxy Warp"))
        let d = SceneDirector(themeID: MoonlitLakeModel.id, state: ThemeState(values: ["visual": .choice("Galaxy Warp")]),
                              reaction: ReactionPresets.expressivePianist)
        var s = SkySettings(); s.timeMode = .frozen; s.frozenHour = 22; s.cityID = "melbourne"; s.weatherMode = .pick; s.weather = .clear
        d.sky.reset(settings: s)
        d.handle([.noteOn(note: 60, velocity: 0.9), .noteOn(note: 72, velocity: 0.9)], at: 0)
        let f = try XCTUnwrap(d.step(dt: 1.0 / 30, t: 0, quality: .high) as? LakeFrame)
        let warp = try XCTUnwrap(f.warp)
        XCTAssertGreaterThan(warp.streaks.count, 0)
        XCTAssertTrue(f.ripples.isEmpty, "Galaxy Warp replaces the ripples")
        // Lake Ripples (the default) has no warp.
        let r = SceneDirector(themeID: MoonlitLakeModel.id, state: ThemeState(), reaction: ReactionPresets.expressivePianist)
        r.handle([.noteOn(note: 60, velocity: 0.9)], at: 0)
        let rf = try XCTUnwrap(r.step(dt: 1.0 / 30, t: 0, quality: .high) as? LakeFrame)
        XCTAssertNil(rf.warp)
        XCTAssertEqual(rf.ripples.count, 1)
    }

    // MARK: - After the rain and blizzards in every outdoor world

    private func scenes(_ sky: SkyState) -> [(String, AmbienceScene)] {
        var lake = MoonlitLakeModel(), beach = GoldenHourBeachModel(), road = CoastRoadModel()
        lake.setSky(sky); beach.setSky(sky); road.setSky(sky)
        let lp = ParameterSet(specs: MoonlitLakeModel.parameters, macroTargets: MoonlitLakeModel.macroTargets)
        let bp = ParameterSet(specs: GoldenHourBeachModel.parameters, macroTargets: GoldenHourBeachModel.macroTargets)
        let rp = ParameterSet(specs: CoastRoadModel.parameters, macroTargets: CoastRoadModel.macroTargets)
        return [("lake", lake.step(dt: 1.0 / 30, params: lp, roles: RoleValues(), inputs: InputFrame(), quality: .high).ambience),
                ("beach", beach.step(dt: 1.0 / 30, params: bp, roles: RoleValues(), inputs: InputFrame(), quality: .high).ambience),
                ("road", road.step(dt: 1.0 / 30, params: rp, roles: RoleValues(), inputs: InputFrame(), quality: .high).ambience)]
    }

    private func daySky() -> SkyState {
        var s = SkyState(); s.sun = SkyDirection(azimuth: 0, altitude: 30); s.hourOfDay = 13
        return s
    }

    func testDripsAfterRainInEveryOutdoorWorld() {
        var afterRain = daySky(); afterRain.wetness = 0.8
        for (name, scene) in scenes(afterRain) {
            XCTAssertEqual(scene.level(.drips), 0.8, accuracy: 1e-6, name)
            XCTAssertEqual(scene.wetness, 0.8, accuracy: 1e-6, name)
        }
        var raining = afterRain; raining.rain = 0.5
        for (name, scene) in scenes(raining) { XCTAssertEqual(scene.level(.drips), 0, name) }
    }

    func testBirdsSingUnderARainbowEverywhereOutdoors() {
        var shower = daySky(); shower.rain = 0.3; shower.rainbow = 1
        for (name, scene) in scenes(shower) { XCTAssertGreaterThanOrEqual(scene.level(.dawnChorus), 0.4 - 1e-9, name) }
        var none = daySky(); none.rain = 0.3
        for (name, scene) in scenes(none) { XCTAssertEqual(scene.level(.dawnChorus), 0, accuracy: 0.0001, "\(name): no bow, no daytime birdsong") }
        var storm = shower; storm.rain = 0.9
        for (name, scene) in scenes(storm) { XCTAssertEqual(scene.level(.dawnChorus), 0, accuracy: 0.0001, "\(name): not in heavy rain") }
    }

    func testBlizzardHowlsEverywhere() {
        var blizzard = daySky(); blizzard.snow = 1; blizzard.gust = 1; blizzard.wind = 1
        for (name, scene) in scenes(blizzard) { XCTAssertGreaterThanOrEqual(scene.level(.wind), 0.95, name) }
    }

    func testRoadSendsWetness() {
        var wet = daySky(); wet.wetness = 0.6
        XCTAssertEqual(scenes(wet).first { $0.0 == "road" }?.1.wetness ?? -1, 0.6, accuracy: 1e-6)
    }

    func testWeatherAmbienceHelper() {
        var levels: [AmbienceSource: Double] = [.wind: 0.2]
        var s = SkyState(); s.wetness = 0.4; s.snow = 1; s.gust = 0.5
        WeatherAmbience.levels(s, base: &levels)
        XCTAssertEqual(levels[.drips] ?? -1, 0.4, accuracy: 1e-6)
        XCTAssertEqual(levels[.wind] ?? -1, 0.65, accuracy: 1e-6)
    }

    /// Rime frost hushes the outdoors (spec §5): in rime (the world rimed past 0.3, or rime-frost weather more than 0.3
    /// of the sky) the wind drops to 0.15 at most, and `indoorsLift` (0.15 × min(1, rime / 0.6)) is there for worlds to
    /// muffle their outdoor sources with; a blizzard still howls through, and without rime nothing changes.
    func testRimeMufflesOutdoors() {
        var fog = daySky(); fog.weather = .rime; fog.nextWeather = .rime   // the fog has come; nothing is rimed yet
        var rimed = daySky(); rimed.rime = 0.8                              // the fog has gone; the world stays white
        for (name, sky) in [("fog", fog), ("rimed", rimed)] {
            var levels: [AmbienceSource: Double] = [.wind: 0.6, .breeze: 0.4, .water: 0.8]
            WeatherAmbience.levels(sky, base: &levels)
            XCTAssertEqual(levels[.wind] ?? -1, 0.15, accuracy: 1e-9, name)
            XCTAssertEqual(levels[.breeze] ?? -1, 0.4, accuracy: 1e-9, "\(name): only the wind drops")
            XCTAssertEqual(levels[.water] ?? -1, 0.8, accuracy: 1e-9, name)
            XCTAssertTrue(WeatherAmbience.inRime(sky), name)
        }
        var calm: [AmbienceSource: Double] = [.wind: 0.1, .water: 0.8]
        WeatherAmbience.levels(rimed, base: &calm)
        XCTAssertEqual(calm[.wind] ?? -1, 0.1, accuracy: 1e-9, "a softer wind is left as it is")
        var hush: [AmbienceSource: Double] = [.water: 0.8]
        WeatherAmbience.levels(rimed, base: &hush)
        XCTAssertNil(hush[.wind], "and no wind is added")
        // Not in rime: a light rime, the fog only arriving (its glide still under 0.3), or none at all.
        var light = daySky(); light.rime = 0.25
        var arriving = daySky(); arriving.weather = .clear; arriving.nextWeather = .rime; arriving.weatherBlend = 0.3
        for (name, sky) in [("light", light), ("arriving", arriving), ("clear", daySky())] {
            var levels: [AmbienceSource: Double] = [.wind: 0.6]
            WeatherAmbience.levels(sky, base: &levels)
            XCTAssertEqual(levels[.wind] ?? -1, 0.6, accuracy: 1e-9, name)
        }
        arriving.weatherBlend = 0.6
        XCTAssertTrue(WeatherAmbience.inRime(arriving), "past the glide's 0.3")
        // A blizzard's howl still comes through a rimed world.
        var blizzard = rimed; blizzard.snow = 1; blizzard.gust = 1
        var howl: [AmbienceSource: Double] = [.wind: 0.6]
        WeatherAmbience.levels(blizzard, base: &howl)
        XCTAssertGreaterThanOrEqual(howl[.wind] ?? 0, 0.95)
        // The hush for a world to add to its indoors: 0.15 × min(1, rime / 0.6).
        XCTAssertEqual(WeatherAmbience.indoorsLift(rimed), 0.15, accuracy: 1e-9)
        var half = daySky(); half.rime = 0.3
        XCTAssertEqual(WeatherAmbience.indoorsLift(half), 0.075, accuracy: 1e-6)
        XCTAssertEqual(WeatherAmbience.indoorsLift(fog), 0, "the fog alone has rimed nothing yet")
        XCTAssertEqual(WeatherAmbience.indoorsLift(daySky()), 0)
        var odd = daySky(); odd.rime = .nan
        XCTAssertEqual(WeatherAmbience.indoorsLift(odd), 0)
        // In the worlds: a gale over a rimed lake, beach and road is held down; without the rime it blows.
        var gale = daySky(); gale.wind = 0.9
        for (name, scene) in scenes(gale) { XCTAssertEqual(scene.level(.wind), 0.6, accuracy: 1e-5, name) }
        gale.rime = 1
        for (name, scene) in scenes(gale) { XCTAssertEqual(scene.level(.wind), 0.15, accuracy: 1e-9, "\(name) in rime") }
        // The cabin's wind round the walls drops too (the cold rule keeps the rime).
        var cabin = SnowboundCabinModel()
        cabin.setSky(rimed)
        XCTAssertEqual(cabinStep(&cabin, seconds: 1.0 / 30).ambience.level(.wind), 0.15, accuracy: 1e-9)
    }
}

// MARK: - Snowbound Cabin

extension WorldTests {
    private func cabinStep(_ model: inout SnowboundCabinModel, seconds: Double, state: ThemeState = ThemeState()) -> CabinFrame {
        let p = ThemeRegistry.parameterSet(for: SnowboundCabinModel.id, state: state)
        var frame: CabinFrame?
        for _ in 0..<max(1, Int(seconds * 30)) {
            frame = model.step(dt: 1.0 / 30, params: p, roles: RoleValues(), inputs: InputFrame(), quality: .high)
        }
        return frame!
    }

    private func sky(sun altitude: Double, hour: Double) -> SkyState {
        var s = SkyState(); s.sun = SkyDirection(azimuth: 0, altitude: altitude); s.hourOfDay = hour
        return s
    }

    func testCabinTurnsRainToSnow() {
        var rain = sky(sun: 20, hour: 13); rain.rain = 0.75; rain.weather = .rain; rain.lightning = 0.5; rain.wetness = 0.7
        let cold = SnowboundCabinModel.coldSky(rain)
        XCTAssertEqual(cold.snow, 0.75, accuracy: 1e-6)
        XCTAssertEqual(cold.rain, 0)
        XCTAssertEqual(cold.lightning, 0)
        XCTAssertEqual(cold.wetness, 0)
        var storm = sky(sun: 20, hour: 13); storm.rain = 1; storm.wind = 0.9; storm.gust = 0.6; storm.weather = .storm
        let blizzard = SnowboundCabinModel.coldSky(storm)
        XCTAssertEqual(blizzard.snow, 1)
        XCTAssertEqual(blizzard.wind, 1)
        XCTAssertEqual(blizzard.gust, 1, accuracy: 1e-3, "a storm's gusts become a blizzard's")
        XCTAssertEqual(blizzard.rain, 0)
        XCTAssertEqual(blizzard.weather, .blizzard)
        var drizzle = sky(sun: 20, hour: 13); drizzle.rain = 0.3; drizzle.weather = .drizzle
        XCTAssertEqual(SnowboundCabinModel.coldSky(drizzle).snow, 0.3, accuracy: 1e-6, "drizzle is light snow")
        XCTAssertEqual(SnowboundCabinModel.coldSky(drizzle).weather, .snow)
        var shower = sky(sun: 20, hour: 13); shower.rain = 0.3; shower.rainbow = 1; shower.weather = .sunShower
        XCTAssertEqual(SnowboundCabinModel.coldSky(shower).rainbow, 0, "snow makes no rainbow")
        XCTAssertEqual(SnowboundCabinModel.coldSky(shower).weather, .snow)
    }

    /// The cold-sky rule lives in Core as `WorldWeather.cold`, shared by the cabin (and the fjord).
    func testColdSkySharedByCabin() {
        var storm = sky(sun: 20, hour: 13); storm.rain = 1; storm.wind = 0.9; storm.gust = 0.6; storm.weather = .storm
        storm.fireflies = 0.8; storm.aurora = 0.6; storm.pillar = 0.5
        XCTAssertEqual(SnowboundCabinModel.coldSky(storm), WorldWeather.cold(storm))
        let cold = WorldWeather.cold(storm)
        XCTAssertEqual(cold.weather, .blizzard)
        XCTAssertEqual(cold.fireflies, 0, "no fireflies in the cold")
        XCTAssertEqual(cold.aurora, 0.6, "the aurora and pillars stay")
        XCTAssertEqual(cold.pillar, 0.5)
        var humid = sky(sun: -20, hour: 23); humid.weather = .humid; humid.nextWeather = .humid; humid.fireflies = 1
        XCTAssertEqual(WorldWeather.cold(humid).weather, .clear)
        var dust = sky(sun: -20, hour: 23); dust.weather = .diamondDust; dust.nextWeather = .diamondDust
        XCTAssertEqual(WorldWeather.cold(dust).weather, .diamondDust, "diamond dust is at home in the cold")
        var cabin = SnowboundCabinModel(); cabin.setSky(storm)
        let frame = cabin.step(dt: 1.0 / 60, params: ThemeRegistry.parameterSet(for: SnowboundCabinModel.id, state: ThemeState()),
                               roles: RoleValues(), inputs: InputFrame(), quality: .high)
        XCTAssertEqual(frame.sky, cold)
    }

    /// Snow that was rain still frosts the glass, and a storm turned blizzard frosts it hard and whites out with each
    /// gust (final review: the frost vanished whenever the cabin's snow came from rain).
    func testColdSkyKeepsTheFrost() {
        var rain = sky(sun: 20, hour: 13); rain.rain = 0.75; rain.weather = .rain; rain.frost = 0
        XCTAssertGreaterThanOrEqual(SnowboundCabinModel.coldSky(rain).frost, 0.45)
        var storm = sky(sun: 20, hour: 13); storm.rain = 1; storm.wind = 0.9; storm.gust = 0.6; storm.mist = 0.2; storm.weather = .storm; storm.frost = 0
        let blizzard = SnowboundCabinModel.coldSky(storm)
        XCTAssertGreaterThanOrEqual(blizzard.frost, 0.85)
        XCTAssertGreaterThan(blizzard.mist, 0.2 + 0.2, "a gust whites it out")
        var snow = sky(sun: 20, hour: 13); snow.snow = 0.8; snow.weather = .snow; snow.frost = 0.6
        XCTAssertEqual(SnowboundCabinModel.coldSky(snow).frost, 0.6, accuracy: 1e-6, "real snow is left as it is")
    }

    /// A storm turned blizzard comes and goes with the weather's glide, never in one frame (final review: it vanished
    /// in a frame when the storm ended).
    func testCabinStormBlizzardGlides() throws {
        var settings = SkySettings(); settings.timeMode = .frozen; settings.frozenHour = 13; settings.cityID = "melbourne"
        settings.weatherMode = .pick; settings.weather = .storm
        let living = LivingSky(settings: settings, seed: 1, homeZone: try XCTUnwrap(TimeZone(identifier: "Australia/Melbourne")))
        let start = Date(timeIntervalSince1970: 1_793_000_000)
        var now = start
        _ = living.step(now: now, dt: 0)
        for _ in 0..<60 { now += 1; _ = living.step(now: now, dt: 1) }
        settings.weather = .clear; living.settings = settings
        var previous = SnowboundCabinModel.coldSky(living.step(now: now, dt: 0))
        var worstSnow: Float = 0, worstWind: Float = 0
        for _ in 0..<(75 * 60) {
            now += 1.0 / 60
            let cold = SnowboundCabinModel.coldSky(living.step(now: now, dt: 1.0 / 60))
            worstSnow = max(worstSnow, abs(cold.snow - previous.snow)); worstWind = max(worstWind, abs(cold.wind - previous.wind))
            previous = cold
        }
        XCTAssertLessThan(worstSnow, 0.05)
        XCTAssertLessThan(worstWind, 0.05)
        XCTAssertLessThan(previous.snow, 0.05, "and the blizzard is over")
    }

    /// A panic (or unplugging the keyboard) with the pedal down lets the pedal go too, so later notes don't stay
    /// "sounding" for ever (final review).
    func testPanicLetsThePedalGo() {
        var cabin = SnowboundCabinModel()
        cabin.setSky(sky(sun: -20, hour: 22))
        cabin.handle(.pedal(down: true, amount: 1))
        cabin.handle(.allNotesOff)
        _ = cabinStep(&cabin, seconds: 0.1)
        cabin.handle(.noteOn(note: 60, velocity: 0.8))
        _ = cabinStep(&cabin, seconds: 0.5)
        cabin.handle(.noteOff(note: 60))
        XCTAssertTrue(cabinStep(&cabin, seconds: 30).patches.isEmpty, "the patch freezes over again")
        var bedroom = BedroomDawnModel()
        bedroom.setSky(bedroomSky(sun: 2, hour: 6.8))
        bedroom.handle(.pedal(down: true, amount: 1))
        bedroom.handle(.allNotesOff)
        _ = bedroomStep(&bedroom, seconds: 0.1)
        bedroom.handle(.noteOn(note: 64, velocity: 0.8))
        _ = bedroomStep(&bedroom, seconds: 1)
        bedroom.handle(.noteOff(note: 64))
        XCTAssertLessThan(bedroomStep(&bedroom, seconds: 30).glow, 0.02, "the morning glow settles")
    }

    func testCabinAmbience() {
        var model = SnowboundCabinModel()
        var s = sky(sun: -20, hour: 22); s.snow = 0.8; s.gust = 0.3
        model.setSky(s)
        let a = cabinStep(&model, seconds: 0.1).ambience
        XCTAssertEqual(a.level(.fire), 0.7 * 0.7, accuracy: 1e-9)
        XCTAssertEqual(a.level(.wind), 0.25 + 0.3, accuracy: 1e-6)
        XCTAssertEqual(a.level(.rainOnGlass), 0.4 * 0.8, accuracy: 1e-6)
        XCTAssertEqual(a.snowOnGlass, 0.8, accuracy: 1e-6)
        XCTAssertEqual(a.indoors, 1)
        XCTAssertEqual(a.level(.clock), 0)
        XCTAssertEqual(a.level(.surf), 0)
        XCTAssertEqual(a.level(.road), 0)
        XCTAssertEqual(a.wetness, 0)
    }

    func testCabinDefaults() {
        XCTAssertEqual(ThemeRegistry.resolve(SnowboundCabinModel.id), SnowboundCabinModel.id)
        XCTAssertTrue(ThemeRegistry.all.contains { $0.id == SnowboundCabinModel.id && $0.name == "Snowbound Cabin Window" })
        XCTAssertTrue(ThemeRegistry.isWorld(SnowboundCabinModel.id))
        assertValidParameters(SnowboundCabinModel.parameters)
        let params = ThemeRegistry.parameterSet(for: SnowboundCabinModel.id, state: ThemeState())
        XCTAssertEqual(params.choice("light.hold"), "Follow the sky")
        XCTAssertEqual(params.choice("visual"), "Frost Grow")
        XCTAssertEqual(SnowboundCabinModel.visuals, ["Frost Grow", "Galaxy Warp"])
        XCTAssertEqual(params.number("frost"), 0.6, accuracy: 1e-9)
        XCTAssertEqual(params.number("fire"), 0.7, accuracy: 1e-9)
        XCTAssertEqual(params.number("condensation"), 0.4, accuracy: 1e-9)
        XCTAssertEqual(params.number("farCabin"), 0.7, accuracy: 1e-9)
        XCTAssertEqual(Mood.hushedWarm, Mood(energy: 0.2, warmth: 0.85, brightness: 0.3, space: 0.35, motion: 0.2))
    }

    func testCabinFrameCarriesFrost() {
        var model = SnowboundCabinModel()
        var s = sky(sun: -20, hour: 22); s.frost = 0.3
        model.setSky(s)
        for n: UInt8 in [60, 64, 67] { model.handle(.noteOn(note: n, velocity: 0.7)) }
        let f = cabinStep(&model, seconds: 20)
        XCTAssertGreaterThan(f.frostLevel, 0.3 * 0.6 + 0.05, "above the base while notes are held")
        XCTAssertEqual(f.patches.count, 3)
        XCTAssertNil(f.warp)
        XCTAssertEqual(f.keys.count, 88)
        XCTAssertTrue((0...1).contains(f.fireFlicker))
    }

    func testCabinWarpOptionStreaksInstead() {
        var model = SnowboundCabinModel()
        model.setSky(sky(sun: -20, hour: 22))
        model.handle(.noteOn(note: 60, velocity: 0.9))
        let f = cabinStep(&model, seconds: 0.5, state: ThemeState(values: ["visual": .choice("Galaxy Warp")]))
        XCTAssertNotNil(f.warp)
        XCTAssertTrue(f.patches.isEmpty, "Galaxy Warp replaces the patches")
    }

    func testFarCabinLightsAtNight() {
        func lit(_ altitude: Double, _ hour: Double) -> Bool {
            var model = SnowboundCabinModel()
            model.setSky(sky(sun: altitude, hour: hour))
            return cabinStep(&model, seconds: 0.1).farCabinLit
        }
        XCTAssertTrue(lit(-20, 22))
        XCTAssertFalse(lit(30, 13))
        XCTAssertFalse(lit(-30, 3), "everyone's asleep")
    }

    func testFireFlickersDeterministically() {
        var a = SnowboundCabinModel(), b = SnowboundCabinModel()
        a.setSky(sky(sun: -20, hour: 22)); b.setSky(sky(sun: -20, hour: 22))
        var values: [Float] = []
        for i in 0..<60 {
            let fa = cabinStep(&a, seconds: 1.0 / 30), fb = cabinStep(&b, seconds: 1.0 / 30)
            XCTAssertEqual(fa.fireFlicker, fb.fireFlicker, "step \(i)")
            values.append(fa.fireFlicker)
        }
        XCTAssertGreaterThan((values.max() ?? 0) - (values.min() ?? 0), 0.05, "it flickers")
    }
}

// MARK: - Bedroom at Dawn

extension WorldTests {
    private func bedroomStep(_ model: inout BedroomDawnModel, seconds: Double, state: ThemeState = ThemeState(),
                             each: ((BedroomFrame) -> Void)? = nil) -> BedroomFrame {
        let p = ThemeRegistry.parameterSet(for: BedroomDawnModel.id, state: state)
        var frame: BedroomFrame?
        for _ in 0..<max(1, Int((seconds * 30).rounded())) {
            frame = model.step(dt: 1.0 / 30, params: p, roles: RoleValues(), inputs: InputFrame(), quality: .high)
            if let frame { each?(frame) }
        }
        return frame!
    }

    private func bedroomSky(sun altitude: Double, hour: Double) -> SkyState {
        var s = SkyState(); s.sun = SkyDirection(azimuth: 90, altitude: altitude); s.hourOfDay = hour
        return s
    }

    func testBedroomDefaults() {
        XCTAssertEqual(ThemeRegistry.resolve(BedroomDawnModel.id), BedroomDawnModel.id)
        XCTAssertTrue(ThemeRegistry.all.contains { $0.id == BedroomDawnModel.id && $0.name == "Bedroom Window at Dawn" })
        XCTAssertTrue(ThemeRegistry.isWorld(BedroomDawnModel.id))
        assertValidParameters(BedroomDawnModel.parameters)
        let params = ThemeRegistry.parameterSet(for: BedroomDawnModel.id, state: ThemeState())
        XCTAssertEqual(params.choice("light.hold"), "Pastel dawn")
        XCTAssertEqual(params.choice("visual"), "Curtain Light")
        XCTAssertEqual(BedroomDawnModel.visuals, ["Curtain Light", "Frost Grow", "Galaxy Warp"])
        XCTAssertEqual(params.number("light"), 0.6, accuracy: 1e-9)
        XCTAssertEqual(params.number("sway"), 0.5, accuracy: 1e-9)
        XCTAssertEqual(params.number("motes"), 0.6, accuracy: 1e-9)
        XCTAssertEqual(params.number("fairy"), 0.5, accuracy: 1e-9)
        XCTAssertEqual(params.number("frost"), 0.5, accuracy: 1e-9)
        XCTAssertEqual(params.number("window.open"), 0, "the window starts closed")
        XCTAssertEqual(Mood.softWaking, Mood(energy: 0.25, warmth: 0.6, brightness: 0.65, space: 0.55, motion: 0.3))
    }

    func testStreetLampHysteresis() {
        var model = BedroomDawnModel()
        model.setSky(bedroomSky(sun: -5, hour: 5))
        var f = bedroomStep(&model, seconds: 5)
        XCTAssertGreaterThan(f.streetLamp, 0.9, "on in the dark")
        model.setSky(bedroomSky(sun: -2.5, hour: 6))
        f = bedroomStep(&model, seconds: 1)
        XCTAssertGreaterThan(f.streetLamp, 0.9, "still on between −3° and −2°")
        model.setSky(bedroomSky(sun: 1, hour: 6.5))
        f = bedroomStep(&model, seconds: 0.2)
        XCTAssertEqual(f.streetLamp, 0, "off once the sun is above −2°")
        model.setSky(bedroomSky(sun: -2.5, hour: 19))
        f = bedroomStep(&model, seconds: 1)
        XCTAssertEqual(f.streetLamp, 0, "and stays off until below −3°")
        model.setSky(bedroomSky(sun: -4, hour: 19.5))
        var levels: [Float] = []
        _ = bedroomStep(&model, seconds: 4) { levels.append($0.streetLamp) }
        XCTAssertLessThan(levels[15], 0.8, "warming up at 0.5 s")
        XCTAssertGreaterThan(levels.last ?? 0, 0.95, "fully on after about 3 s")
    }

    func testWindowsLightUpAsMorningComes() {
        var model = BedroomDawnModel()
        let follow = ThemeState(values: ["light.hold": .choice(SkyHold.follow.rawValue)])
        model.setSky(bedroomSky(sun: -20, hour: 4))
        XCTAssertEqual(bedroomStep(&model, seconds: 0.1, state: follow).litWindows, 0)
        model.setSky(bedroomSky(sun: 5, hour: 7.75))
        XCTAssertGreaterThanOrEqual(bedroomStep(&model, seconds: 0.1, state: follow).litWindows, 6)
        model.setSky(bedroomSky(sun: -30, hour: 23.5))
        XCTAssertLessThan(bedroomStep(&model, seconds: 0.1, state: follow).litWindows, 8, "going dark late at night")
    }

    /// Pastel dawn (the set's default hold) keeps it morning whatever the clock says: the dawn chorus sings, the street
    /// is only just waking and the houses are lighting up (final review: an evening session heard no birds, mid-morning
    /// traffic and houses going dark under a frozen dawn).
    func testHeldDawnSoundsLikeMorning() {
        var model = BedroomDawnModel()
        model.setSky(bedroomSky(sun: 1.5, hour: 20))
        let evening = bedroomStep(&model, seconds: 0.1)
        XCTAssertGreaterThanOrEqual(evening.ambience.level(.dawnChorus), 0.5)
        XCTAssertLessThan(evening.ambience.level(.street), 0.35)
        model.setSky(bedroomSky(sun: 1.5, hour: 23.5))
        XCTAssertEqual(bedroomStep(&model, seconds: 0.1).litWindows, BedroomDawnModel.litWindows(hour: 6.5))
    }

    func testBedroomAmbience() {
        var model = BedroomDawnModel()
        var s = bedroomSky(sun: 5, hour: 6.5); s.wetness = 0.5
        model.setSky(s)
        var a = bedroomStep(&model, seconds: 0.1).ambience
        XCTAssertEqual(a.level(.kettle), 0.5, accuracy: 1e-9)
        XCTAssertEqual(a.level(.clock), 0.15, accuracy: 1e-9)
        XCTAssertEqual(a.indoors, 0.7, accuracy: 1e-9, "an old sash window lets the birds through, softly")
        XCTAssertEqual(a.level(.drips), 0.5, accuracy: 1e-6)
        XCTAssertGreaterThan(a.level(.dawnChorus), 0.3)
        a = bedroomStep(&model, seconds: 0.1, state: ThemeState(values: ["window.open": .bool(true)])).ambience
        XCTAssertEqual(a.indoors, 0.35, accuracy: 1e-9)
        var early = BedroomDawnModel(), late = BedroomDawnModel()
        early.setSky(bedroomSky(sun: -12, hour: 5)); late.setSky(bedroomSky(sun: 28, hour: 9))
        XCTAssertGreaterThan(bedroomStep(&late, seconds: 0.1).ambience.level(.street), bedroomStep(&early, seconds: 0.1).ambience.level(.street))
        var raining = BedroomDawnModel()
        var r = bedroomSky(sun: 10, hour: 8); r.rain = 0.6; r.wetness = 0.4
        raining.setSky(r)
        let ra = bedroomStep(&raining, seconds: 0.1).ambience
        XCTAssertEqual(ra.level(.rainOnGlass), 0.6, accuracy: 1e-6)
        XCTAssertEqual(ra.level(.drips), 0)
    }

    func testCurtainsMoveMoreWithTheWindowOpen() {
        func motion(open: Bool) -> Double {
            var model = BedroomDawnModel()
            var s = bedroomSky(sun: 10, hour: 8); s.wind = 0.4
            model.setSky(s)
            let state = ThemeState(values: ["window.open": .bool(open)])
            _ = bedroomStep(&model, seconds: 2, state: state)
            var total = 0.0
            var previous: [SIMD3<Float>]?
            _ = bedroomStep(&model, seconds: 10, state: state) { f in
                let now = f.curtains.left + f.curtains.right
                if let prev = previous { for (a, b) in zip(now, prev) { total += Double(simd_length(a - b)) } }
                previous = now
            }
            return total
        }
        XCTAssertGreaterThanOrEqual(motion(open: true), 1.5 * motion(open: false))
    }

    func testBedroomFrameCarriesTheCurtains() {
        var model = BedroomDawnModel()
        model.setSky(bedroomSky(sun: 2, hour: 6.8))
        for n: UInt8 in [60, 64, 67, 84] { model.handle(.noteOn(note: n, velocity: 0.8)) }
        let f = bedroomStep(&model, seconds: 2)
        XCTAssertEqual(f.curtains.left.count, 24 * 32)
        XCTAssertEqual(f.curtains.right.count, 24 * 32)
        XCTAssertTrue((f.curtains.left + f.curtains.right).allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite })
        XCTAssertGreaterThan(f.glow, 0.3, "held notes raise the morning glow")
        XCTAssertEqual(f.keys.count, 88)
        XCTAssertNil(f.warp)
        XCTAssertEqual(f.fairy.count, CurtainLight.fairyCount)
    }

    func testBedroomFrostGrowOption() {
        var model = BedroomDawnModel()
        var s = bedroomSky(sun: 2, hour: 6.8); s.frost = 0.6
        model.setSky(s)
        model.handle(.noteOn(note: 64, velocity: 0.8))
        let f = bedroomStep(&model, seconds: 3, state: ThemeState(values: ["visual": .choice("Frost Grow")]))
        XCTAssertEqual(f.patches.count, 1)
        XCTAssertGreaterThan(f.frostLevel, 0.6 * 0.5 * 0.5, "the sky's frost and the setting set the base")
        XCTAssertEqual(f.glow, 0, accuracy: 1e-6, "Curtain Light rests while Frost Grow plays")
    }
}

// MARK: - Bioluminescent Bay

extension WorldTests {
    private func bayStep(_ model: inout BioluminescentBayModel, seconds: Double, dt: Double = 1.0 / 30,
                         state: ThemeState = ThemeState()) -> BayFrame {
        let p = ThemeRegistry.parameterSet(for: BioluminescentBayModel.id, state: state)
        var frame: BayFrame?
        for _ in 0..<max(1, Int((seconds / dt).rounded())) {
            frame = model.step(dt: dt, params: p, roles: RoleValues(), inputs: InputFrame(), quality: .high)
        }
        return frame!
    }

    /// The bay through the director at a frozen hour in Melbourne, following the sky (not held at deep night).
    private func bayFrame(hour: Double, weather: WeatherKind = .clear, hold: SkyHold = .follow) -> BayFrame? {
        var state = ThemeState(); state.values["light.hold"] = .choice(hold.rawValue)
        let d = SceneDirector(themeID: BioluminescentBayModel.id, state: state, reaction: ReactionPresets.expressivePianist)
        var s = SkySettings(); s.timeMode = .frozen; s.frozenHour = hour; s.cityID = "melbourne"; s.weatherMode = .pick; s.weather = weather
        d.sky.reset(settings: s)
        var frame: BayFrame?
        for i in 0..<90 {
            if i == 80 { d.handle([.noteOn(note: 60, velocity: 0.8)], at: Double(i) / 30) }
            frame = d.step(dt: 1.0 / 30, t: Double(i) / 30, quality: .high) as? BayFrame
        }
        return frame
    }

    func testBayGlowsOnlyAtNight() throws {
        let noon = try XCTUnwrap(bayFrame(hour: 12))
        XCTAssertGreaterThan(noon.sky.sun.altitude, 20)
        XCTAssertEqual(noon.glowScale, 0, "the plankton needs the dark")
        XCTAssertEqual(noon.patches.count, 1, "the note still lands")
        XCTAssertTrue(noon.patches.allSatisfy { $0.brightness == 0 })
        XCTAssertFalse(noon.lanternLit)
        let night = try XCTUnwrap(bayFrame(hour: 23))
        XCTAssertLessThan(night.sky.sun.altitude, -8)
        XCTAssertEqual(night.glowScale, 1, accuracy: 0.02)
        XCTAssertGreaterThan(try XCTUnwrap(night.patches.first).brightness, 0.6)
        XCTAssertTrue(night.lanternLit)
        // Held at deep night (the default), noon glows too.
        XCTAssertEqual(try XCTUnwrap(bayFrame(hour: 12, hold: .deepNight)).glowScale, 1, accuracy: 0.02)

        // Rain dulls it: ×(1 − 0.6·rain).
        var model = BioluminescentBayModel()
        var s = SkyState(); s.sun = SkyDirection(azimuth: 0, altitude: -20); s.hourOfDay = 23; s.rain = 0.5
        model.setSky(s)
        XCTAssertEqual(bayStep(&model, seconds: 0.1).glowScale, 0.7, accuracy: 1e-5)
        XCTAssertEqual(BioluminescentBayModel.glowScale(s), 0.7, accuracy: 1e-5)
    }

    func testBayAmbience() {
        var night = BioluminescentBayModel()
        night.mood = .secretGlow
        night.setSky(sky(sun: -20, hour: 23))
        let a = bayStep(&night, seconds: 0.1).ambience
        XCTAssertEqual(a.level(.lapping), 0.7, accuracy: 1e-9)
        XCTAssertEqual(a.level(.water), 0.3, accuracy: 1e-9)
        XCTAssertEqual(a.level(.crickets), 0.5, accuracy: 1e-9)
        XCTAssertEqual(a.level(.boat), 0.4, accuracy: 1e-9)
        XCTAssertEqual(a.level(.breeze), 0.25, accuracy: 1e-9)
        XCTAssertEqual(a.level(.owl), 0.15, accuracy: 1e-9)
        XCTAssertEqual(a.level(.gulls), 0, accuracy: 1e-9)
        XCTAssertEqual(a.level(.surf), 0, "a sheltered cove: no surf")
        XCTAssertEqual(a.closeness, MoodLook.ambienceCloseness(base: 0.6, .secretGlow), accuracy: 1e-9)
        XCTAssertGreaterThan(a.nightCool, 0)
        XCTAssertNil(a.wave)

        var day = BioluminescentBayModel()
        var d = sky(sun: 40, hour: 13); d.wind = 0.3; d.rain = 0.4
        day.setSky(d)
        let b = bayStep(&day, seconds: 0.1).ambience
        XCTAssertEqual(b.level(.crickets), 0)
        XCTAssertEqual(b.level(.owl), 0)
        XCTAssertEqual(b.level(.gulls), 0.2, accuracy: 1e-9)
        XCTAssertEqual(b.level(.breeze), 0.55, accuracy: 1e-6)
        XCTAssertEqual(b.level(.rainOnWater), 0.4, accuracy: 1e-6)

        // Thunder as the lake: once per strike.
        var storm = BioluminescentBayModel()
        var st = sky(sun: -20, hour: 23); st.lightning = 1
        storm.setSky(st)
        let p = ThemeRegistry.parameterSet(for: BioluminescentBayModel.id, state: ThemeState())
        let first = storm.step(dt: 1.0 / 30, params: p, roles: RoleValues(), inputs: InputFrame(), quality: .high)
        let second = storm.step(dt: 1.0 / 30, params: p, roles: RoleValues(), inputs: InputFrame(), quality: .high)
        XCTAssertNotNil(first.ambience.thunder)
        XCTAssertNil(second.ambience.thunder)
    }

    func testBayDefaults() {
        XCTAssertEqual(ThemeRegistry.resolve(BioluminescentBayModel.id), BioluminescentBayModel.id)
        XCTAssertTrue(ThemeRegistry.all.contains { $0.id == BioluminescentBayModel.id && $0.name == "Bioluminescent Bay" })
        XCTAssertTrue(ThemeRegistry.isWorld(BioluminescentBayModel.id))
        assertValidParameters(BioluminescentBayModel.parameters)
        let params = ThemeRegistry.parameterSet(for: BioluminescentBayModel.id, state: ThemeState())
        XCTAssertEqual(BioluminescentBayModel.visuals, ["Glow Wake", "Galaxy Warp"])
        XCTAssertEqual(params.choice("visual"), "Glow Wake")
        XCTAssertEqual(params.choice("light.hold"), "Deep night")
        XCTAssertEqual(params.choice("aurora.mode"), "Follow the sky")
        XCTAssertEqual(params.number("glow"), 0.7, accuracy: 1e-9)
        XCTAssertEqual(params.number("lantern"), 0.6, accuracy: 1e-9)
        XCTAssertEqual(params.number("lighthouse"), 0.5, accuracy: 1e-9)
        XCTAssertEqual(params.number("keys.show"), 1, accuracy: 1e-9)
        XCTAssertEqual(params.number("keys.height"), 0.12, accuracy: 1e-9)
        XCTAssertTrue(BioluminescentBayModel.parameters.first { $0.id == "glow" }?.hero ?? false)
        XCTAssertEqual(Mood.secretGlow, Mood(energy: 0.3, warmth: 0.55, brightness: 0.35, space: 0.7, motion: 0.4))

        // The frame carries the glow, the keys and, with Galaxy Warp, streaks instead.
        var model = BioluminescentBayModel()
        model.setSky(sky(sun: -20, hour: 23))
        model.handle(.noteOn(note: 60, velocity: 0.8))
        let f = bayStep(&model, seconds: 0.5)
        XCTAssertEqual(f.patches.count, 1)
        XCTAssertEqual(f.keys.count, 88)
        XCTAssertTrue(f.keys.contains { $0.key.note == 60 && $0.pressed })
        XCTAssertNil(f.warp)
        XCTAssertTrue(f.swellScale > 0 && f.swellScale < 0.2, "a still bay in calm weather")
        let w = bayStep(&model, seconds: 0.5, state: ThemeState(values: ["visual": .choice("Galaxy Warp")]))
        XCTAssertNotNil(w.warp)
        XCTAssertTrue(w.patches.isEmpty, "Galaxy Warp replaces the glow")

        // Storms whip the bay up.
        var stormy = BioluminescentBayModel()
        var s = sky(sun: -20, hour: 23); s.weather = .storm; s.nextWeather = .storm
        stormy.setSky(s)
        XCTAssertGreaterThan(bayStep(&stormy, seconds: 0.1).swellScale, 2 * f.swellScale)
    }

    func testLighthouseBlinksEverySixSeconds() {
        var model = BioluminescentBayModel()
        model.setSky(sky(sun: -20, hour: 23))
        let p = ThemeRegistry.parameterSet(for: BioluminescentBayModel.id, state: ThemeState())
        let dt = 1.0 / 60
        var onsets: [Double] = []
        var litFrames = 0
        var previous: Float = 0
        for i in 1...(19 * 60) {
            let f = model.step(dt: dt, params: p, roles: RoleValues(), inputs: InputFrame(), quality: .high)
            XCTAssertTrue((0...1).contains(f.lighthouseFlash))
            if f.lighthouseFlash > 0 { litFrames += 1 }
            if f.lighthouseFlash > 0, previous == 0 { onsets.append(Double(i) * dt) }
            previous = f.lighthouseFlash
        }
        XCTAssertEqual(onsets.count, 4, "at 0, 6, 12 and 18 s")
        for (a, b) in zip(onsets, onsets.dropFirst()) { XCTAssertEqual(b - a, 6, accuracy: 0.05) }
        XCTAssertEqual(Double(litFrames) * dt / Double(onsets.count), 0.4, accuracy: 0.05, "each flash lasts 0.4 s")

        // Dark by day, and when the lighthouse is turned off.
        var day = BioluminescentBayModel()
        day.setSky(sky(sun: 30, hour: 13))
        var dayMax: Float = 0
        for _ in 0..<(7 * 60) { dayMax = max(dayMax, day.step(dt: dt, params: p, roles: RoleValues(), inputs: InputFrame(), quality: .high).lighthouseFlash) }
        XCTAssertEqual(dayMax, 0)
        var off = BioluminescentBayModel()
        off.setSky(sky(sun: -20, hour: 23))
        let po = ThemeRegistry.parameterSet(for: BioluminescentBayModel.id, state: ThemeState(values: ["lighthouse": .number(0)]))
        var offMax: Float = 0
        for _ in 0..<(7 * 60) { offMax = max(offMax, off.step(dt: dt, params: po, roles: RoleValues(), inputs: InputFrame(), quality: .high).lighthouseFlash) }
        XCTAssertEqual(offMax, 0)
    }
}


// MARK: - Aurora Fjord

extension WorldTests {
    private func fjordStep(_ model: inout AuroraFjordModel, seconds: Double, state: ThemeState = ThemeState()) -> FjordFrame {
        let p = ThemeRegistry.parameterSet(for: AuroraFjordModel.id, state: state)
        var frame: FjordFrame?
        for _ in 0..<max(1, Int((seconds * 30).rounded())) {
            frame = model.step(dt: 1.0 / 30, params: p, roles: RoleValues(), inputs: InputFrame(), quality: .high)
        }
        return frame!
    }

    private func fjordSkyState(sun altitude: Double, hour: Double) -> SkyState {
        var s = SkyState(); s.sun = SkyDirection(azimuth: 0, altitude: altitude); s.hourOfDay = hour
        return s
    }

    func testFjordTurnsRainToSleetAndStormsToBlizzards() {
        var rain = fjordSkyState(sun: -20, hour: 22); rain.rain = 0.6; rain.weather = .rain; rain.nextWeather = .rain
        rain.lightning = 0.5; rain.wetness = 0.4; rain.fireflies = 0.3
        let sleet = AuroraFjordModel.fjordSky(rain)
        XCTAssertEqual(sleet.rain, 0.3, accuracy: 1e-6, "half the rain stays rain")
        XCTAssertEqual(sleet.snow, 0.3, accuracy: 1e-6, "and half falls as snow")
        XCTAssertEqual(sleet.weather, .sleet)
        XCTAssertEqual(sleet.lightning, 0)
        XCTAssertEqual(sleet.fireflies, 0, "no fireflies in the cold")
        XCTAssertEqual(sleet.wetness, 0.2, accuracy: 1e-6)
        var drizzle = fjordSkyState(sun: 10, hour: 13); drizzle.rain = 0.3; drizzle.weather = .drizzle
        XCTAssertEqual(AuroraFjordModel.fjordSky(drizzle).weather, .sleet)
        XCTAssertEqual(AuroraFjordModel.fjordSky(drizzle).snow, 0.15, accuracy: 1e-6)

        var storm = fjordSkyState(sun: 10, hour: 13); storm.rain = 1; storm.wind = 0.9; storm.gust = 0.6; storm.weather = .storm
        storm.lightning = 1
        let blizzard = AuroraFjordModel.fjordSky(storm)
        XCTAssertEqual(blizzard.weather, .blizzard)
        XCTAssertEqual(blizzard.snow, 1)
        XCTAssertEqual(blizzard.rain, 0, "a blizzard, not sleet")
        XCTAssertEqual(blizzard.wind, 1)
        XCTAssertEqual(blizzard.lightning, 0)
        XCTAssertEqual(blizzard.wetness, 0)
        // Half-way out of a storm into rain: part blizzard, part sleet, and every value in range.
        var gliding = storm; gliding.nextWeather = .rain; gliding.weatherBlend = 0.5
        let mid = AuroraFjordModel.fjordSky(gliding)
        XCTAssertEqual(mid.rain, 0.25, accuracy: 1e-6)
        XCTAssertGreaterThanOrEqual(mid.snow, 0.5)
        XCTAssertEqual(mid.nextWeather, .sleet)
        for v in [mid.rain, mid.snow, mid.wind, mid.gust, mid.mist, mid.frost, mid.wetness] { XCTAssertTrue((0...1).contains(v)) }
        // Snow and diamond dust are left as they are.
        var dust = fjordSkyState(sun: -20, hour: 23); dust.weather = .diamondDust; dust.nextWeather = .diamondDust; dust.pillar = 1
        XCTAssertEqual(AuroraFjordModel.fjordSky(dust).weather, .diamondDust)
        XCTAssertEqual(AuroraFjordModel.fjordSky(dust).pillar, 1)
        // The model shows the fjord's sky.
        var model = AuroraFjordModel(); model.setSky(rain)
        XCTAssertEqual(fjordStep(&model, seconds: 0.1).sky, sleet)
    }

    func testFjordAmbience() {
        var model = AuroraFjordModel()
        var s = fjordSkyState(sun: -20, hour: 22); s.wind = 0.5; s.wetness = 0.4
        model.setSky(s)
        let a = fjordStep(&model, seconds: 0.1).ambience
        XCTAssertEqual(a.level(.iceGroan), 0.8, accuracy: 1e-6, "the ice groans more at night")
        XCTAssertEqual(a.level(.waterfall), 0.35, accuracy: 1e-9)
        XCTAssertEqual(a.level(.water), 0.5, accuracy: 1e-9)
        XCTAssertEqual(a.level(.wind), 0.2 + 0.8 * 0.5, accuracy: 1e-6)
        XCTAssertEqual(a.level(.lapping), 0.3, accuracy: 1e-9)
        XCTAssertEqual(a.level(.breeze), 0.2, accuracy: 1e-9)
        XCTAssertEqual(a.level(.crickets), 0)
        XCTAssertEqual(a.level(.owl), 0)
        XCTAssertEqual(a.level(.drips), 0.2, accuracy: 1e-6, "drips after the sleet")
        XCTAssertEqual(a.wetness, 0.2, accuracy: 1e-6)
        XCTAssertEqual(a.closeness, MoodLook.ambienceCloseness(base: 0.45, .neutral), accuracy: 1e-9)
        XCTAssertEqual(a.indoors, 0)
        XCTAssertNil(a.thunder, "the cold sky has no lightning")
        var day = AuroraFjordModel()
        day.setSky(fjordSkyState(sun: 20, hour: 13))
        XCTAssertEqual(fjordStep(&day, seconds: 0.1).ambience.level(.iceGroan), 0.5, accuracy: 1e-6)
        var blizzard = AuroraFjordModel()
        var b = fjordSkyState(sun: 10, hour: 13); b.rain = 1; b.weather = .storm; b.gust = 0.6
        blizzard.setSky(b)
        XCTAssertGreaterThanOrEqual(fjordStep(&blizzard, seconds: 0.1).ambience.level(.wind), 0.9, "a blizzard howls")
    }

    func testFjordDefaults() {
        XCTAssertEqual(ThemeRegistry.resolve(AuroraFjordModel.id), AuroraFjordModel.id)
        XCTAssertEqual(AuroraFjordModel.id, "aurora-fjord")
        XCTAssertTrue(ThemeRegistry.all.contains { $0.id == AuroraFjordModel.id && $0.name == "Aurora Fjord" })
        XCTAssertTrue(ThemeRegistry.isWorld(AuroraFjordModel.id))
        assertValidParameters(AuroraFjordModel.parameters)
        let params = ThemeRegistry.parameterSet(for: AuroraFjordModel.id, state: ThemeState())
        XCTAssertEqual(params.choice("light.hold"), "Deep night")
        XCTAssertEqual(params.choice("aurora.mode"), "Always")
        XCTAssertEqual(params.choice("visual"), "Curtain Lights")
        XCTAssertEqual(AuroraFjordModel.visuals, ["Curtain Lights", "Galaxy Warp"])
        XCTAssertEqual(params.number("floes"), 0.6, accuracy: 1e-9)
        XCTAssertEqual(params.number("village"), 0.7, accuracy: 1e-9)
        XCTAssertEqual(params.number("swell"), 0.4, accuracy: 1e-9)
        XCTAssertEqual(params.number("keys.show"), 1)
        XCTAssertEqual(params.number("keys.height"), 0.12, accuracy: 1e-9)
        XCTAssertTrue(AuroraFjordModel.parameters.first { $0.id == "floes" }?.hero ?? false)
        XCTAssertEqual(Mood.electricAwe, Mood(energy: 0.45, warmth: 0.25, brightness: 0.45, space: 0.95, motion: 0.6))
    }

    func testFjordFrameCarriesRipplesAndFloes() {
        var model = AuroraFjordModel()
        model.setSky(fjordSkyState(sun: -30, hour: 23))
        for n: UInt8 in [60, 67] { model.handle(.noteOn(note: n, velocity: 0.8)) }
        let f = fjordStep(&model, seconds: 2)
        XCTAssertEqual(f.ripples.count, 2)
        XCTAssertTrue((AuroraFjordModel.minFloes...AuroraFjordModel.maxFloes).contains(f.floes.count), "\(f.floes.count)")
        XCTAssertGreaterThan(f.glow, 0.3, "held notes swell the curtain")
        XCTAssertTrue(f.villageLit)
        XCTAssertEqual(f.keys.count, 88)
        XCTAssertNil(f.warp)
        for r in f.ripples { XCTAssertTrue(r.position.isFinite && r.age.isFinite && r.strength.isFinite && r.width.isFinite) }
        for fl in f.floes {
            XCTAssertTrue(fl.x.isFinite && fl.depth.isFinite && fl.size.isFinite && fl.angle.isFinite && fl.drift.isFinite)
            XCTAssertTrue((0...1).contains(fl.x) && (0...1).contains(fl.depth))
        }
        XCTAssertTrue(f.glow.isFinite && f.hueShift.isFinite && f.tensePulse.isFinite)
        // The floes drift, deterministically from a fresh world.
        var again = AuroraFjordModel()
        again.setSky(fjordSkyState(sun: -30, hour: 23))
        XCTAssertEqual(fjordStep(&again, seconds: 2).floes, f.floes)
        XCTAssertNotEqual(fjordStep(&again, seconds: 3).floes, f.floes, "they keep drifting")
        // The setting sets how many: 6 at none, 14 at most.
        var few = AuroraFjordModel(), many = AuroraFjordModel()
        XCTAssertEqual(fjordStep(&few, seconds: 0.1, state: ThemeState(values: ["floes": .number(0)])).floes.count, 6)
        XCTAssertEqual(fjordStep(&many, seconds: 0.1, state: ThemeState(values: ["floes": .number(1)])).floes.count, 14)
        // By day the village is dark; Galaxy Warp streaks instead of rippling.
        var day = AuroraFjordModel()
        day.setSky(fjordSkyState(sun: 20, hour: 13))
        day.handle(.noteOn(note: 60, velocity: 0.9))
        let w = fjordStep(&day, seconds: 0.5, state: ThemeState(values: ["visual": .choice("Galaxy Warp")]))
        XCTAssertFalse(w.villageLit)
        XCTAssertNotNil(w.warp)
        XCTAssertTrue(w.ripples.isEmpty, "Galaxy Warp replaces the ripples")
    }
}

// MARK: Zen Rock Garden

extension WorldTests {
    private func gardenStep(_ model: inout ZenRockGardenModel, seconds: Double, dt: Double = 1.0 / 30,
                            state: ThemeState = ThemeState()) -> ZenGardenFrame {
        let p = ThemeRegistry.parameterSet(for: ZenRockGardenModel.id, state: state)
        var frame: ZenGardenFrame?
        for _ in 0..<max(1, Int((seconds / dt).rounded())) {
            frame = model.step(dt: dt, params: p, roles: RoleValues(), inputs: InputFrame(), quality: .high)
        }
        return frame!
    }

    /// A sky over the garden: the sun's altitude, the local hour, the day of the year, and the hemisphere (Kyoto's
    /// latitude in the north, Melbourne's in the south).
    private func gardenSky(sun altitude: Double, hour: Double, day: Int = 105, south: Bool = false) -> SkyState {
        var s = SkyState()
        s.sun = SkyDirection(azimuth: 100, altitude: altitude)
        s.hourOfDay = hour
        s.dayOfYear = day
        s.latitude = south ? -37.81 : 35.01
        s.hemisphere = south ? -1 : 1
        return s
    }

    func testGardenDefaults() throws {
        XCTAssertEqual(ZenRockGardenModel.id, "zen-rock-garden")
        XCTAssertEqual(ThemeRegistry.resolve(ZenRockGardenModel.id), ZenRockGardenModel.id)
        XCTAssertTrue(ThemeRegistry.all.contains { $0.id == ZenRockGardenModel.id && $0.name == "Zen Rock Garden" })
        XCTAssertTrue(ThemeRegistry.isWorld(ZenRockGardenModel.id))
        assertValidParameters(ZenRockGardenModel.parameters)
        let params = ThemeRegistry.parameterSet(for: ZenRockGardenModel.id, state: ThemeState())
        XCTAssertEqual(ZenRockGardenModel.visuals, ["Rake Lines", "Galaxy Warp"])
        XCTAssertEqual(params.choice("visual"), "Rake Lines")
        XCTAssertEqual(params.choice("light.hold"), "Follow the sky")
        XCTAssertEqual(params.choice("aurora.mode"), "Follow the sky")
        XCTAssertEqual(params.number("ridge"), 0.6, accuracy: 1e-9)
        XCTAssertEqual(params.number("moss"), 0.5, accuracy: 1e-9)
        XCTAssertEqual(params.choice("season"), "Follow the date")
        XCTAssertEqual(ZenRockGardenModel.seasons, ["Follow the date", "Spring", "Summer", "Autumn", "Winter"])
        XCTAssertEqual(params.number("keys.show"), 1)
        XCTAssertEqual(params.number("keys.height"), 0.12, accuracy: 1e-9)
        let ridge = try XCTUnwrap(ZenRockGardenModel.parameters.first { $0.id == "ridge" })
        XCTAssertTrue(ridge.hero)
        XCTAssertEqual(ridge.name, "Rake depth")
        XCTAssertEqual(ZenRockGardenModel.parameters.first { $0.id == "moss" }?.name, "Moss")
        XCTAssertEqual(Mood.orderedCalm, Mood(energy: 0.15, warmth: 0.45, brightness: 0.55, space: 0.5, motion: 0.15))

        // A still garden shows the morning's pattern and has nothing new to upload.
        var model = ZenRockGardenModel()
        model.setSky(gardenSky(sun: 20, hour: 9))
        let still = gardenStep(&model, seconds: 1)
        XCTAssertEqual(still.field.heights.count, RakeField.width * RakeField.height)
        XCTAssertEqual(still.field.heights, RakeLines.morning)
        XCTAssertEqual(still.field.version, 0)
        XCTAssertFalse(still.field.dirty)
        XCTAssertEqual(still.keys.count, 88)
        XCTAssertNil(still.wave)
        XCTAssertNil(still.warp)
        // A note rakes a ring round the tall stone, and the field moves on a version.
        model.handle(.noteOn(note: 60, velocity: 0.8))
        let raked = gardenStep(&model, seconds: 1.0 / 30)
        XCTAssertEqual(raked.rings.count, 1)
        XCTAssertEqual(raked.rings.first?.stone, 2)
        XCTAssertEqual(raked.field.version, 1)
        XCTAssertTrue(raked.field.dirty)
        XCTAssertTrue(raked.keys.contains { $0.key.note == 60 && $0.pressed })
        // Galaxy Warp streaks instead of raking.
        model.handle(.noteOn(note: 67, velocity: 0.8))
        let warped = gardenStep(&model, seconds: 0.5, state: ThemeState(values: ["visual": .choice("Galaxy Warp")]))
        XCTAssertNotNil(warped.warp)
        XCTAssertEqual(warped.rings.count, 1, "no new ring")

        // Rain darkens the gravel at once; snow fills the grooves over minutes and melts in the sun.
        var rainy = ZenRockGardenModel()
        var wet = gardenSky(sun: 20, hour: 11)
        wet.rain = 0.8
        wet.wetness = 0.1
        rainy.setSky(wet)
        XCTAssertEqual(gardenStep(&rainy, seconds: 0.1).wetness, 0.48, accuracy: 1e-6)
        var snowy = ZenRockGardenModel()
        var snow = gardenSky(sun: 5, hour: 9, day: 20)
        snow.snow = 1
        snowy.setSky(snow)
        let early = gardenStep(&snowy, seconds: 10, dt: 0.25).snowCover
        XCTAssertTrue(early > 0 && early < 0.1, "\(early)")
        let deep = gardenStep(&snowy, seconds: 600, dt: 0.25).snowCover
        XCTAssertTrue(deep > 0.9 && deep <= 1, "\(deep)")
        snow.snow = 0
        snow.sun = SkyDirection(azimuth: 180, altitude: 30)
        snowy.setSky(snow)
        XCTAssertLessThan(gardenStep(&snowy, seconds: 900, dt: 0.25).snowCover, 0.1, "it melts in the sun")
        // Humid nights bring fireflies over the moss: more moss, more fireflies.
        var humid = gardenSky(sun: -20, hour: 23, day: 200)
        humid.fireflies = 0.8
        var bare = ZenRockGardenModel(), lush = ZenRockGardenModel()
        bare.setSky(humid)
        lush.setSky(humid)
        XCTAssertEqual(gardenStep(&bare, seconds: 0.1, state: ThemeState(values: ["moss": .number(0)])).fireflies, 0.24, accuracy: 1e-6)
        XCTAssertEqual(gardenStep(&lush, seconds: 0.1, state: ThemeState(values: ["moss": .number(1)])).fireflies, 0.8, accuracy: 1e-6)

        // The water-knocker fills and clacks every 15–40 s at a neutral mood, its swing always within 0…1.
        var garden = ZenRockGardenModel()
        garden.setSky(gardenSky(sun: 20, hour: 9))
        let p = ThemeRegistry.parameterSet(for: ZenRockGardenModel.id, state: ThemeState())
        var clacks: [Double] = []
        var previous: Float = 0, lowest: Float = 1, highest: Float = 0
        for i in 1...(200 * 30) {
            let k = garden.step(dt: 1.0 / 30, params: p, roles: RoleValues(), inputs: InputFrame(), quality: .high).knocker
            lowest = min(lowest, k.fill, k.tip, k.clack, k.phase)
            highest = max(highest, k.fill, k.tip, k.clack, k.phase)
            if k.clack > 0, previous == 0 { clacks.append(Double(i) / 30) }
            previous = k.clack
        }
        XCTAssertGreaterThanOrEqual(lowest, 0)
        XCTAssertLessThanOrEqual(highest, 1)
        XCTAssertGreaterThanOrEqual(clacks.count, 4)
        for (a, b) in zip(clacks, clacks.dropFirst()) { XCTAssertTrue((15.8...40.9).contains(b - a), "\(b - a) s between clacks") }
    }

    func testSeasonFollowsTheDateAndHemisphere() throws {
        // 15 January through the real sky: midsummer in Melbourne, midwinter in Kyoto.
        let at = try XCTUnwrap(ISO8601DateFormatter().date(from: "2027-01-15T03:00:00Z"))
        func frame(_ city: String, season: String = ZenRockGardenModel.followTheDate) -> ZenGardenFrame {
            var settings = SkySettings()
            settings.timeMode = .realTime
            settings.cityID = city
            var model = ZenRockGardenModel()
            model.setSky(LivingSky(settings: settings).step(now: at, dt: 0))
            return gardenStep(&model, seconds: 0.1, state: ThemeState(values: ["season": .choice(season)]))
        }
        let melbourne = frame("melbourne"), kyoto = frame("kyoto")
        XCTAssertEqual(melbourne.sky.dayOfYear, 15)
        XCTAssertEqual(kyoto.sky.dayOfYear, 15)
        XCTAssertEqual(melbourne.sky.hemisphere, -1)
        XCTAssertEqual(kyoto.sky.hemisphere, 1)
        XCTAssertEqual(melbourne.season, .summer)
        XCTAssertEqual(kyoto.season, .winter)
        XCTAssertGreaterThan(melbourne.maple.y, melbourne.maple.x, "a green maple in summer")
        XCTAssertLessThan(kyoto.mapleLeaves, 0.2, "bare in winter")
        // Chosen, the setting decides: autumn in Melbourne's January, and a red maple.
        let autumn = frame("melbourne", season: "Autumn")
        XCTAssertEqual(autumn.season, .autumn)
        XCTAssertGreaterThan(autumn.maple.x, 2 * autumn.maple.y, "red in autumn")
        XCTAssertEqual(frame("kyoto", season: "Summer").season, .summer)

        // The calendar's edges (non-leap day numbers): spring from 1 March, summer from 1 June, autumn from 1
        // September, winter from 1 December; the other way round in the south.
        let north: [(day: Int, season: GardenSeason)] = [(1, .winter), (59, .winter), (60, .spring), (151, .spring),
                                                         (152, .summer), (243, .summer), (244, .autumn), (334, .autumn),
                                                         (335, .winter), (366, .winter)]
        for (day, season) in north {
            XCTAssertEqual(ZenRockGardenModel.season(dayOfYear: day, southern: false), season, "day \(day) in the north")
        }
        let south: [(day: Int, season: GardenSeason)] = [(15, .summer), (60, .autumn), (152, .winter), (244, .spring),
                                                         (308, .spring), (335, .summer)]
        for (day, season) in south {
            XCTAssertEqual(ZenRockGardenModel.season(dayOfYear: day, southern: true), season, "day \(day) in the south")
        }
        XCTAssertEqual(ZenRockGardenModel.season(dayOfYear: 308, southern: false), .autumn, "early November in Kyoto")
        // Through autumn the maple turns from green to gold to red, carrying on from summer's green.
        let green = ZenRockGardenModel.maple(.autumn, progress: 0).colour
        let gold = ZenRockGardenModel.maple(.autumn, progress: 0.35).colour
        let red = ZenRockGardenModel.maple(.autumn, progress: 0.8).colour
        XCTAssertGreaterThan(green.y, green.x)
        XCTAssertGreaterThan(gold.x, green.x)
        XCTAssertGreaterThan(red.x, 2 * red.y)
        XCTAssertLessThan(simd_distance(ZenRockGardenModel.maple(.summer, progress: 1).colour, green), 0.05)
        XCTAssertEqual(ZenRockGardenModel.maple(.autumn, progress: 1).leaves, ZenRockGardenModel.maple(.winter, progress: 0).leaves,
                       accuracy: 1e-6, "the last leaves fall early in winter")
        XCTAssertLessThan(simd_distance(ZenRockGardenModel.maple(.autumn, progress: 1).colour, ZenRockGardenModel.maple(.winter, progress: 0).colour), 1e-6)
        XCTAssertLessThan(ZenRockGardenModel.maple(.winter, progress: 0.5).leaves, 0.2)
    }

    func testGardenAmbience() {
        func scene(_ sky: SkyState, season: String = ZenRockGardenModel.followTheDate, mood: Mood = .neutral) -> AmbienceScene {
            var model = ZenRockGardenModel()
            model.mood = mood
            model.setSky(sky)
            return gardenStep(&model, seconds: 0.1, state: ThemeState(values: ["season": .choice(season)])).ambience
        }
        // A spring morning in Kyoto (mid-April, 07:00, the sun 12° up): the warbler sings by the water-knocker.
        let springMorning = gardenSky(sun: 12, hour: 7, day: 105)
        let a = scene(springMorning, mood: .orderedCalm)
        XCTAssertEqual(a.level(.waterKnocker), 0.6, accuracy: 1e-9)
        XCTAssertEqual(a.level(.warbler), 0.5, accuracy: 1e-9)
        XCTAssertEqual(a.level(.breeze), 0.25, accuracy: 1e-9)
        XCTAssertEqual(a.level(.templeBell), 0.3, accuracy: 1e-9)
        XCTAssertEqual(a.level(.crickets), 0)
        XCTAssertEqual(a.level(.dawnChorus), 0, accuracy: 1e-9, "the sun is up past the dawn chorus")
        XCTAssertEqual(a.level(.rainOnWater), 0)
        XCTAssertEqual(a.closeness, MoodLook.ambienceCloseness(base: 0.55, .orderedCalm), accuracy: 1e-9)
        XCTAssertEqual(a.density, MoodLook.ambienceDensity(.orderedCalm), accuracy: 1e-9)
        XCTAssertEqual(a.indoors, 0)
        // Summer mornings too, in the north (July) and the south (January).
        XCTAssertEqual(scene(gardenSky(sun: 12, hour: 7, day: 198)).level(.warbler), 0.5, accuracy: 1e-9)
        XCTAssertEqual(scene(gardenSky(sun: 12, hour: 7, day: 15, south: true)).level(.warbler), 0.5, accuracy: 1e-9)
        // Only then: not in autumn or winter, not in the afternoon, not at night. The knocker, always.
        let quiet: [(name: String, sky: SkyState)] = [
            ("autumn", gardenSky(sun: 12, hour: 7, day: 300)),
            ("winter", gardenSky(sun: 12, hour: 7, day: 15)),
            ("a southern winter", gardenSky(sun: 12, hour: 7, day: 198, south: true)),
            ("a spring afternoon", gardenSky(sun: 40, hour: 15, day: 105)),
            ("a spring night", gardenSky(sun: -20, hour: 23, day: 105)),
        ]
        for (name, sky) in quiet {
            let s = scene(sky)
            XCTAssertEqual(s.level(.warbler), 0, name)
            XCTAssertEqual(s.level(.waterKnocker), 0.6, accuracy: 1e-9, "\(name): the knocker always")
            XCTAssertEqual(s.level(.templeBell), 0.3, accuracy: 1e-9, name)
        }
        // A chosen season decides over the date.
        XCTAssertEqual(scene(gardenSky(sun: 12, hour: 7, day: 300), season: "Spring").level(.warbler), 0.5, accuracy: 1e-9)
        XCTAssertEqual(scene(springMorning, season: "Winter").level(.warbler), 0)
        // Summer nights' crickets; the dawn chorus at first light; rain in the basin, drips after; rime's hush.
        XCTAssertEqual(scene(gardenSky(sun: -20, hour: 23, day: 198)).level(.crickets), 0.4, accuracy: 1e-9)
        XCTAssertEqual(scene(gardenSky(sun: -20, hour: 23, day: 105)).level(.crickets), 0, "crickets are summer's")
        XCTAssertEqual(scene(gardenSky(sun: -1, hour: 5.5, day: 105)).level(.dawnChorus), 0.3, accuracy: 1e-9)
        var rain = gardenSky(sun: 30, hour: 13)
        rain.rain = 0.6
        rain.wind = 0.3
        let r = scene(rain)
        XCTAssertEqual(r.level(.rainOnWater), 0.3, accuracy: 1e-6)
        XCTAssertEqual(r.level(.breeze), 0.55, accuracy: 1e-6)
        XCTAssertEqual(r.level(.drips), 0)
        var after = gardenSky(sun: 30, hour: 13)
        after.wetness = 0.5
        XCTAssertEqual(scene(after).level(.drips), 0.5, accuracy: 1e-6)
        XCTAssertEqual(scene(after).wetness, 0.5, accuracy: 1e-6)
        var rimed = gardenSky(sun: 5, hour: 8)
        rimed.rime = 0.9
        XCTAssertEqual(scene(rimed).indoors, 0.15, accuracy: 1e-9)
    }
}
