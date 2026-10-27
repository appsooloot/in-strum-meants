import XCTest
@testable import InStrumCore

final class PerformanceStateTests: XCTestCase {
    var s = PerformanceState()
    override func setUp() { s = PerformanceState() }

    private func isChord(_ e: PerformanceEvent) -> Bool { if case .chord = e { return true }; return false }

    func testNoteOnHoldsNoteWithNormalisedVelocity() {
        let ev = s.apply(.noteOn(channel: 0, note: 60, velocity: 127), at: 0)
        XCTAssertEqual(ev, [.noteOn(note: 60, velocity: 1.0)])
        XCTAssertEqual(s.heldNotes[60], 1.0)
    }
    func testNoteOffReleases() {
        _ = s.apply(.noteOn(channel: 0, note: 60, velocity: 64), at: 0)
        XCTAssertEqual(s.apply(.noteOff(channel: 0, note: 60), at: 0.1).first, .noteOff(note: 60))
        XCTAssertNil(s.heldNotes[60])
    }
    func testPedalThreshold() {
        XCTAssertEqual(s.apply(.controlChange(channel: 0, controller: 64, value: 63), at: 0), [.pedal(down: false, amount: Float(63) / 127)])
        XCTAssertEqual(s.apply(.controlChange(channel: 0, controller: 64, value: 64), at: 0), [.pedal(down: true, amount: Float(64) / 127)])
        XCTAssertTrue(s.pedalDown)
    }
    func testPedalUpDoesNotReleaseHeldNotes() {
        _ = s.apply(.noteOn(channel: 0, note: 60, velocity: 80), at: 0)
        _ = s.apply(.controlChange(channel: 0, controller: 64, value: 127), at: 0)
        _ = s.apply(.controlChange(channel: 0, controller: 64, value: 0), at: 0.1)
        XCTAssertNotNil(s.heldNotes[60])
    }
    func testThreeNotesWithinWindowEmitChord() {
        _ = s.apply(.noteOn(channel: 0, note: 64, velocity: 80), at: 0.000)
        _ = s.apply(.noteOn(channel: 0, note: 60, velocity: 80), at: 0.010)
        let ev = s.apply(.noteOn(channel: 0, note: 67, velocity: 80), at: 0.020)
        XCTAssertTrue(ev.contains(.chord(notes: [60, 64, 67])))
    }
    func testNotesOutsideWindowAreNotAChord() {
        _ = s.apply(.noteOn(channel: 0, note: 60, velocity: 80), at: 0)
        _ = s.apply(.noteOn(channel: 0, note: 64, velocity: 80), at: 0.2)
        XCTAssertFalse(s.apply(.noteOn(channel: 0, note: 67, velocity: 80), at: 0.4).contains(where: isChord))
    }
    func testRepeatedNoteRetriggers() {
        _ = s.apply(.noteOn(channel: 0, note: 60, velocity: 40), at: 0)
        XCTAssertEqual(s.apply(.noteOn(channel: 0, note: 60, velocity: 120), at: 0.1).first, .noteOn(note: 60, velocity: Float(120) / 127))
    }
    func testAllNotesOffCCClearsEverything() {
        _ = s.apply(.noteOn(channel: 0, note: 60, velocity: 80), at: 0)
        _ = s.apply(.controlChange(channel: 0, controller: 64, value: 127), at: 0)
        XCTAssertEqual(s.apply(.controlChange(channel: 0, controller: 123, value: 0), at: 0.1), [.allNotesOff])
        XCTAssertTrue(s.heldNotes.isEmpty)
        XCTAssertFalse(s.pedalDown)
    }
    func testAllSoundOffCC120ClearsEverything() {
        _ = s.apply(.noteOn(channel: 0, note: 60, velocity: 80), at: 0)
        XCTAssertEqual(s.apply(.controlChange(channel: 0, controller: 120, value: 0), at: 0.1), [.allNotesOff])
        XCTAssertTrue(s.heldNotes.isEmpty)
    }
    func testResetWhileHoldingClearsNotesAndPedal() {
        _ = s.apply(.noteOn(channel: 0, note: 60, velocity: 80), at: 0)
        _ = s.apply(.controlChange(channel: 0, controller: 64, value: 127), at: 0)
        XCTAssertEqual(s.reset(), [.allNotesOff])
        XCTAssertTrue(s.heldNotes.isEmpty)
        XCTAssertFalse(s.pedalDown)
    }
    func testIntensityRisesWithFastPlayingAndHalvesAfterOneSecond() {
        for i in 0..<20 { _ = s.apply(.noteOn(channel: 0, note: UInt8(60 + i % 12), velocity: 100), at: Double(i) * 0.05) }
        let peak = s.intensity
        XCTAssertGreaterThan(peak, 0.5)
        s.decay(to: 0.95 + 1.0)
        XCTAssertEqual(s.intensity, peak / 2, accuracy: 0.02)
    }
    func testNotesOutside88KeysStillReportedForSound() {
        XCTAssertEqual(s.apply(.noteOn(channel: 0, note: 10, velocity: 100), at: 0), [.noteOn(note: 10, velocity: Float(100) / 127)])
    }
    func testOtherMessagesProduceNoEvents() {
        XCTAssertEqual(s.apply(.other, at: 0), [])
    }
    func testControllersBecomeControlEvents() {
        XCTAssertEqual(s.apply(.controlChange(channel: 0, controller: 1, value: 127), at: 0), [.control(controller: 1, value: 1)])
    }
    func testPitchBendIsSigned() {
        XCTAssertEqual(s.apply(.pitchBend(channel: 0, value: 8192), at: 0), [.pitchBend(0)])
        guard case let .pitchBend(v)? = s.apply(.pitchBend(channel: 0, value: 16383), at: 0).first else { return XCTFail() }
        XCTAssertEqual(v, 1, accuracy: 0.001)
        guard case let .pitchBend(lo)? = s.apply(.pitchBend(channel: 0, value: 0), at: 0).first else { return XCTFail() }
        XCTAssertEqual(lo, -1, accuracy: 0.001)
    }
    func testPressureEvents() {
        XCTAssertEqual(s.apply(.channelPressure(channel: 0, value: 127), at: 0), [.pressure(1)])
        XCTAssertEqual(s.apply(.polyPressure(channel: 0, note: 60, value: 0), at: 0), [.pressure(0)])
    }
    func testReleaseSpeedFromNoteOffVelocity() {
        _ = s.apply(.noteOn(channel: 0, note: 60, velocity: 80), at: 0)
        XCTAssertEqual(s.apply(.noteOff(channel: 0, note: 60, velocity: 127), at: 0.1), [.noteOff(note: 60), .release(note: 60, speed: 1)])
    }
}
