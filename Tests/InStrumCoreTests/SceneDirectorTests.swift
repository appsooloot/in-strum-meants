import XCTest
@testable import InStrumCore

final class SceneDirectorTests: XCTestCase {
    func director(_ id: String = ButterflyGardenModel.id) -> SceneDirector {
        SceneDirector(themeID: id, state: ThemeState(), reaction: ReactionPresets.expressivePianist)
    }

    func testRegistryListsBothThemes() {
        XCTAssertEqual(ThemeRegistry.all.map(\.id), [MidnightSteinwayModel.id, ButterflyGardenModel.id])
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
}
