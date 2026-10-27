import XCTest
@testable import InStrumCore

final class MidnightSteinwaySceneTests: XCTestCase {
    private func glow(_ f: SceneFrame, _ n: UInt8) -> Float { f.keys.first { $0.key.note == n }!.glow }
    private func pressed(_ f: SceneFrame, _ n: UInt8) -> Bool { f.keys.first { $0.key.note == n }!.pressed }

    func testIdentity() {
        XCTAssertEqual(MidnightSteinwayScene.id, "midnight-steinway")
        XCTAssertEqual(MidnightSteinwayScene.displayName, "Midnight Steinway")
    }
    func testFrameHas88KeysInDrawOrder() {
        var s = MidnightSteinwayScene()
        let f = s.step(dt: 0, intensity: 0, audioLevel: 0)
        XCTAssertEqual(f.keys.count, 88)
        XCTAssertEqual(f.keys.map(\.key), KeyboardLayout.keys())
    }
    func testHardNoteGlowsMoreThanSoft() {
        var s = MidnightSteinwayScene()
        s.handle(.noteOn(note: 60, velocity: 0.2)); s.handle(.noteOn(note: 72, velocity: 1.0))
        let f = s.step(dt: 0, intensity: 0, audioLevel: 0)
        XCTAssertGreaterThan(glow(f, 72), glow(f, 60))
        XCTAssertEqual(glow(f, 72), 1.0, accuracy: 0.01)
    }
    func testHeldNoteNeverDropsBelowFloor() {
        var s = MidnightSteinwayScene(); s.handle(.noteOn(note: 60, velocity: 1.0))
        let f = s.step(dt: 10, intensity: 0, audioLevel: 0)
        XCTAssertEqual(glow(f, 60), 0.6, accuracy: 0.01)
        XCTAssertTrue(pressed(f, 60))
    }
    func testReleasedNoteFadesWithReleaseHalfLife() {
        var s = MidnightSteinwayScene(); s.handle(.noteOn(note: 60, velocity: 1.0)); s.handle(.noteOff(note: 60))
        let f = s.step(dt: 0.25, intensity: 0, audioLevel: 0)
        XCTAssertEqual(glow(f, 60), 0.5, accuracy: 0.02)
        XCTAssertFalse(pressed(f, 60))
    }
    func testPedalMakesReleasedNotesLinger() {
        var s = MidnightSteinwayScene()
        s.handle(.pedal(down: true, amount: 1)); s.handle(.noteOn(note: 60, velocity: 1.0)); s.handle(.noteOff(note: 60))
        XCTAssertEqual(glow(s.step(dt: 1.5, intensity: 0, audioLevel: 0), 60), 0.5, accuracy: 0.02)
    }
    func testPedalUpReturnsToNormalFade() {
        var s = MidnightSteinwayScene()
        s.handle(.pedal(down: true, amount: 1)); s.handle(.noteOn(note: 60, velocity: 1.0)); s.handle(.noteOff(note: 60))
        s.handle(.pedal(down: false, amount: 0))
        XCTAssertEqual(glow(s.step(dt: 0.25, intensity: 0, audioLevel: 0), 60), 0.5, accuracy: 0.02)
    }
    func testRepeatedStrikeRelightsKey() {
        var s = MidnightSteinwayScene(); s.handle(.noteOn(note: 60, velocity: 1.0)); s.handle(.noteOff(note: 60))
        _ = s.step(dt: 1, intensity: 0, audioLevel: 0)
        s.handle(.noteOn(note: 60, velocity: 0.9))
        XCTAssertEqual(glow(s.step(dt: 0, intensity: 0, audioLevel: 0), 60), 0.9, accuracy: 0.01)
    }
    func testChordTriggersBloomThatFades() {
        var s = MidnightSteinwayScene(); s.handle(.chord(notes: [60, 64, 67]))
        XCTAssertGreaterThan(s.step(dt: 0, intensity: 0, audioLevel: 0).bloom, 0.9)
        XCTAssertEqual(s.step(dt: 0.6, intensity: 0, audioLevel: 0).bloom, 0.5, accuracy: 0.02)
    }
    func testSpotlightsFollowGlowingKeys() {
        var s = MidnightSteinwayScene(); s.handle(.noteOn(note: 60, velocity: 0.8))
        let f = s.step(dt: 0, intensity: 0, audioLevel: 0)
        XCTAssertEqual(f.spotlights.count, 1)
        let k = KeyboardLayout.key(for: 60)!
        XCTAssertEqual(f.spotlights[0].x, k.x + k.width / 2, accuracy: 1e-6)
        XCTAssertEqual(f.spotlights[0].intensity, 0.8, accuracy: 0.01)
    }
    func testAmbienceFollowsIntensityAndAudio() {
        var s = MidnightSteinwayScene()
        let quiet = s.step(dt: 0, intensity: 0, audioLevel: 0).ambience
        let loud = s.step(dt: 0, intensity: 1, audioLevel: 0.5).ambience
        XCTAssertGreaterThan(loud, quiet)
        XCTAssertLessThanOrEqual(s.step(dt: 0, intensity: 1, audioLevel: 1).ambience, 1)
    }
    func testAllNotesOffClearsWithinOneFrame() {
        var s = MidnightSteinwayScene()
        s.handle(.noteOn(note: 60, velocity: 1)); s.handle(.chord(notes: [60, 64, 67])); s.handle(.allNotesOff)
        let f = s.step(dt: 1.0 / 60, intensity: 0, audioLevel: 0)
        XCTAssertFalse(pressed(f, 60)); XCTAssertEqual(glow(f, 60), 0)
        XCTAssertEqual(f.bloom, 0); XCTAssertTrue(f.spotlights.isEmpty)
    }
    func testOutOfRangeNoteIgnoredVisually() {
        var s = MidnightSteinwayScene(); s.handle(.noteOn(note: 10, velocity: 1)); s.handle(.noteOff(note: 120))
        XCTAssertTrue(s.step(dt: 0, intensity: 0, audioLevel: 0).keys.allSatisfy { $0.glow == 0 })
    }
    func testBurstOf2000EventsStepsWithinFrameBudget() {
        var s = MidnightSteinwayScene()
        let start = DispatchTime.now().uptimeNanoseconds
        for i in 0..<2000 { s.handle(.noteOn(note: UInt8(21 + i % 88), velocity: 0.8)) }
        _ = s.step(dt: 1.0 / 60, intensity: 1, audioLevel: 1)
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
        XCTAssertLessThan(ms, 4)
    }
}
