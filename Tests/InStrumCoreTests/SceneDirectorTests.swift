import XCTest
@testable import InStrumCore

final class SceneDirectorTests: XCTestCase {
    func director(_ id: String = ButterflyGardenModel.id) -> SceneDirector {
        SceneDirector(themeID: id, state: ThemeState(), reaction: ReactionPresets.expressivePianist)
    }

    func testRegistryListsBothThemes() {
        XCTAssertEqual(Array(ThemeRegistry.all.map(\.id).prefix(2)), [MidnightSteinwayModel.id, ButterflyGardenModel.id])
        XCTAssertTrue(ThemeRegistry.all.contains { $0.id == MoonlitLakeModel.id })
    }
    func testUnknownThemeFallsBack() {
        XCTAssertEqual(ThemeRegistry.resolve("galaxy-of-the-future"), MidnightSteinwayModel.id)
        XCTAssertEqual(director("nope").themeID, MidnightSteinwayModel.id)
    }
    func testDirectorRoutesEventsToTheme() {
        let d = director()
        d.handle([.noteOn(note: 60, velocity: 0.8)], at: 0)
        let f = d.step(dt: 1.0 / 60, t: 1.0 / 60, quality: .high) as? GardenFrame
        XCTAssertEqual(f?.butterflies.count, 1)
    }
    func testVelocityReachesEnergyRole() {
        let d = director()
        d.handle([.noteOn(note: 60, velocity: 1)], at: 0)
        _ = d.step(dt: 1.0 / 60, t: 0, quality: .high)
        XCTAssertGreaterThan(d.lastRoles[.energy], 0.9)
    }
    func testSwitchingThemeWhileHoldingIsClean() {
        let d = director(MidnightSteinwayModel.id)
        d.handle([.pedal(down: true, amount: 1), .noteOn(note: 60, velocity: 0.9), .noteOn(note: 64, velocity: 0.9), .noteOn(note: 67, velocity: 0.9)], at: 0)
        _ = d.step(dt: 0.1, t: 0.1, quality: .high)
        d.switchTheme(to: ButterflyGardenModel.id, state: ThemeState())
        let g = d.step(dt: 1.0 / 60, t: 0.12, quality: .high) as? GardenFrame
        XCTAssertEqual(g?.butterflies.count, 0)
        XCTAssertTrue(g?.keys.allSatisfy { !$0.pressed } ?? false)
        d.switchTheme(to: MidnightSteinwayModel.id, state: ThemeState())
        let s = d.step(dt: 1.0 / 60, t: 0.14, quality: .high) as? SteinwayFrame
        XCTAssertTrue(s?.scene.keys.allSatisfy { !$0.pressed && $0.glow == 0 } ?? false)
    }
    func testThemeStateAppliedOnSwitch() {
        let d = director(MidnightSteinwayModel.id)
        d.switchTheme(to: ButterflyGardenModel.id, state: ThemeState(values: ["time": .choice("Moonlight")], macros: [.speed: 0.5]))
        XCTAssertEqual(d.parameters.choice("time"), "Moonlight")
        XCTAssertEqual(d.parameters.macros[.speed], 0.5)
        XCTAssertEqual(d.themeID, ButterflyGardenModel.id)
    }
    func testMidnightSteinwayParametersValid() { assertValidParameters(MidnightSteinwayModel.parameters) }
    func testSteinwayGlowFollowsVelocity() {
        let d = director(MidnightSteinwayModel.id)
        d.handle([.noteOn(note: 60, velocity: 1)], at: 0)
        let s = d.step(dt: 0, t: 0, quality: .high) as? SteinwayFrame
        XCTAssertEqual(s?.scene.keys.first { $0.key.note == 60 }?.glow ?? 0, 1, accuracy: 0.01)
    }

    func testRegistryKeepsOldThemes() {
        for (id, specs, targets) in [(MidnightSteinwayModel.id, MidnightSteinwayModel.parameters, MidnightSteinwayModel.macroTargets),
                                     (ButterflyGardenModel.id, ButterflyGardenModel.parameters, ButterflyGardenModel.macroTargets)] {
            XCTAssertEqual(ThemeRegistry.resolve(id), id)
            XCTAssertEqual(ThemeRegistry.parameters(for: id).map(\.id), specs.map(\.id))
            XCTAssertEqual(Set(ThemeRegistry.macroTargets(for: id).keys), Set(targets.keys))
            XCTAssertNotNil(ThemeRegistry.all.first { $0.id == id })
        }
        XCTAssertEqual(ThemeRegistry.all.first?.id, MidnightSteinwayModel.id)
        XCTAssertEqual(Set(ThemeRegistry.entries.map(\.id)).count, ThemeRegistry.entries.count, "unique ids")
    }

    /// A model that records what it is given.
    struct Probe: ThemeModel, MoodAware, SkyAware {
        static let id = "probe", displayName = "Probe"
        static let parameters: [ParamSpec] = []
        static let macroTargets: [Macro: [(id: String, weight: Double)]] = [:]
        var mood = Mood.neutral
        var sky: SkyState?
        init() {}
        mutating func handle(_ e: PerformanceEvent) {}
        mutating func setSky(_ s: SkyState) { sky = s }
        mutating func step(dt: Double, params: ParameterSet, roles: RoleValues, inputs: InputFrame, quality: QualityLevel) -> (Mood, SkyState?) {
            (mood, sky)
        }
    }

    func testMoodAndSkyReachModels() {
        let d = SceneDirector(entry: ThemeEntry.make(Probe.self), state: ThemeState(), reaction: ReactionPresets.expressivePianist)
        var s = SkySettings(); s.timeMode = .frozen; s.frozenHour = 22; s.cityID = "melbourne"
        d.sky.settings = s
        d.mood = .dreamy
        let f = d.step(dt: 1.0 / 60, t: 0, quality: .high) as? (Mood, SkyState?)
        XCTAssertEqual(f?.0, .dreamy)
        XCTAssertNotNil(f?.1 ?? nil)
        XCTAssertLessThan(f?.1?.sun.altitude ?? 0, 0, "22:00 is night")
    }

    /// A world that holds the light (golden hour by default).
    struct HoldProbe: ThemeModel, SkyAware {
        static let id = "hold-probe", displayName = "Hold probe"
        static let parameters: [ParamSpec] = [SkyHold.spec(default: .goldenHour)]
        static let macroTargets: [Macro: [(id: String, weight: Double)]] = [:]
        var sky: SkyState?
        init() {}
        mutating func handle(_ e: PerformanceEvent) {}
        mutating func setSky(_ s: SkyState) { sky = s }
        mutating func step(dt: Double, params: ParameterSet, roles: RoleValues, inputs: InputFrame, quality: QualityLevel) -> SkyState? { sky }
    }

    func testWorldHoldReachesTheSky() {
        var s = SkySettings(); s.timeMode = .frozen; s.frozenHour = 2; s.cityID = "melbourne"
        let held = SceneDirector(entry: ThemeEntry.make(HoldProbe.self), state: ThemeState(), reaction: ReactionPresets.expressivePianist)
        held.sky.settings = s
        _ = held.step(dt: 1.0 / 60, t: 0, quality: .high)
        XCTAssertEqual(held.lastSky?.sun.altitude ?? 0, 5, accuracy: 1e-9)
        let lake = SceneDirector(themeID: MoonlitLakeModel.id, state: ThemeState(), reaction: ReactionPresets.expressivePianist)
        lake.sky.settings = s
        _ = lake.step(dt: 1.0 / 60, t: 0, quality: .high)
        XCTAssertLessThan(lake.lastSky?.sun.altitude ?? 0, -20, "the lake follows the real 2 am sky")
        XCTAssertEqual(SkyHold.spec(default: .blueHour).defaultValue, .choice("Blue hour"))
        XCTAssertEqual(SkyHold.allCases.map(\.rawValue), ["Follow the sky", "Golden hour", "Blue hour"])
    }

    func testMoodLookIsNeutralAtHalf() {
        let n = Mood.neutral
        XCTAssertEqual(MoodLook.exposure(n), 1, accuracy: 1e-6)
        XCTAssertEqual(MoodLook.warmthOffset(n), 0, accuracy: 1e-6)
        for f in [MoodLook.hazeScale, MoodLook.driftScale, MoodLook.reactionScale, MoodLook.lingerScale] { XCTAssertEqual(f(n), 1, accuracy: 1e-6) }
        XCTAssertEqual(MoodLook.ambienceCloseness(base: 0.5, n), 0.5, accuracy: 1e-9)
        XCTAssertEqual(MoodLook.ambienceDensity(n), 1, accuracy: 1e-9)
        XCTAssertGreaterThan(MoodLook.hazeScale(.serene), MoodLook.hazeScale(n))
        XCTAssertLessThan(MoodLook.reactionScale(.serene), MoodLook.reactionScale(n))
        XCTAssertGreaterThan(MoodLook.driftScale(.dreamy), MoodLook.driftScale(.serene))
        XCTAssertLessThan(MoodLook.ambienceCloseness(base: 0.5, .dreamy), 0.5, "spacious moods sound further away")
        XCTAssertEqual(MoodLook.ambienceCloseness(base: 0.05, .dreamy), 0, accuracy: 1e-9, "clamped")
    }
}
