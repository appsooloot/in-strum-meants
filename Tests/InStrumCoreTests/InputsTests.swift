import XCTest
@testable import InStrumCore

final class InputsTests: XCTestCase {
    func testRiseIsFastFallIsSlow() {
        let hub = InputHub()
        hub.set(.pedal, 1, at: 0)
        XCTAssertGreaterThanOrEqual(hub.frame(at: 0.03, listenStrength: 1)[.pedal], 0.6)
        _ = hub.frame(at: 1, listenStrength: 1)
        hub.set(.pedal, 0, at: 1)
        XCTAssertEqual(hub.frame(at: 1.25, listenStrength: 1)[.pedal], 0.37, accuracy: 0.05)
    }
    func testPulseJumpsThenFades() {
        let hub = InputHub()
        hub.pulse(.velocity, 0.9, at: 0)
        XCTAssertEqual(hub.frame(at: 0, listenStrength: 1)[.velocity], 0.9, accuracy: 0.001)
        XCTAssertLessThan(hub.frame(at: 1, listenStrength: 1)[.velocity], 0.05)
    }
    func testListenStrengthScalesOnlyListening() {
        let hub = InputHub()
        hub.set(.bass, 1, at: 0); hub.set(.pedal, 1, at: 0)
        let f = hub.frame(at: 5, listenStrength: 0.5)
        XCTAssertEqual(f[.bass], 0.5, accuracy: 0.01)
        XCTAssertEqual(f[.pedal], 1, accuracy: 0.01)
    }
    func testInputFamilyFromPrefix() {
        XCTAssertEqual(InputID.velocity.family, .keys)
        XCTAssertEqual(InputID.busyness.family, .playing)
        XCTAssertEqual(InputID.brightness.family, .sound)
        XCTAssertEqual(InputID.dial(42).family, .dials)
        XCTAssertEqual(InputID.beat.family, .listening)
        XCTAssertEqual(InputID.cc(21).rawValue, "keys.cc21")
    }
    func testMissingInputReadsZero() {
        XCTAssertEqual(InputHub().frame(at: 0, listenStrength: 1)[.loudness], 0)
    }
}

final class LinksTests: XCTestCase {
    private func link(_ i: InputID, _ t: Target, _ a: Double, _ c: Curve = .linear, on: Bool = true) -> Link {
        Link(input: i, target: t, amount: a, curve: c, enabled: on)
    }
    private func frame(_ v: [InputID: Double]) -> InputFrame { InputFrame(values: v) }

    func testCurves() {
        XCTAssertEqual(Curve.gentle.apply(0.5), 0.25, accuracy: 1e-9)
        XCTAssertEqual(Curve.snappy.apply(0.25), 0.5, accuracy: 1e-9)
        XCTAssertEqual(Curve.linear.apply(0.3), 0.3, accuracy: 1e-9)
        XCTAssertEqual(Curve.gentle.apply(-0.5), -0.25, accuracy: 1e-9)
    }
    func testLinksAddAndClamp() {
        let m = ReactionMap(links: [link(.velocity, .role(.energy), 0.8), link(.loudness, .role(.energy), 0.8)])
        XCTAssertEqual(m.evaluate(frame([.velocity: 1, .loudness: 1])).roles[.energy], 1.0)
    }
    func testNegativeAmountClampsAtZero() {
        let m = ReactionMap(links: [link(.softPedal, .role(.brightness), -1)])
        XCTAssertEqual(m.evaluate(frame([.softPedal: 1])).roles[.brightness], 0)
    }
    func testDirectionRangeIsSigned() {
        let m = ReactionMap(links: [link(.pitchBend, .role(.direction), 1)])
        XCTAssertEqual(m.evaluate(frame([.pitchBend: -0.7])).roles[.direction], -0.7, accuracy: 1e-9)
        XCTAssertEqual(m.evaluate(frame([.pitchBend: -3])).roles[.direction], -1)
    }
    func testDisabledLinkIgnored() {
        let m = ReactionMap(links: [link(.velocity, .role(.energy), 1, on: false)])
        XCTAssertEqual(m.evaluate(frame([.velocity: 1])).roles[.energy], 0)
    }
    func testGroupStrengthScales() {
        var m = ReactionMap(links: [link(.velocity, .role(.energy), 1)])
        m.groupStrength[.keys] = 0.5
        XCTAssertEqual(m.evaluate(frame([.velocity: 1])).roles[.energy], 0.5, accuracy: 1e-9)
    }
    func testParamTargetProducesOffset() {
        let m = ReactionMap(links: [link(.modWheel, .param("wings.iridescence"), 0.8)])
        XCTAssertEqual(m.evaluate(frame([.modWheel: 0.5])).offsets["wings.iridescence"] ?? 0, 0.4, accuracy: 1e-9)
    }
    func testExpressivePianistVelocityDrivesEnergy() {
        let r = ReactionPresets.expressivePianist.evaluate(frame([.velocity: 1])).roles
        XCTAssertGreaterThan(r[.energy], 0.9)
    }
    func testReactionMapCodableRoundTrip() throws {
        let m = ReactionPresets.expressivePianist
        let back = try JSONDecoder().decode(ReactionMap.self, from: JSONEncoder().encode(m))
        XCTAssertEqual(back, m)
    }
}
