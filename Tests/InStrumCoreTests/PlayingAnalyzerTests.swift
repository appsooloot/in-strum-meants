import XCTest
@testable import InStrumCore

final class PlayingAnalyzerTests: XCTestCase {
    private func on(_ a: inout PlayingAnalyzer, _ notes: [UInt8], at t: Double, v: Float = 0.7) {
        for n in notes { a.handle(.noteOn(note: n, velocity: v), at: t) }
    }
    private func off(_ a: inout PlayingAnalyzer, _ notes: [UInt8], at t: Double) {
        for n in notes { a.handle(.noteOff(note: n), at: t) }
    }
    private func value(_ a: inout PlayingAnalyzer, _ id: InputID, at t: Double) -> Double {
        let hub = InputHub()
        a.publish(to: hub, at: t)
        return hub.rawTarget(id)
    }

    func testChordQualities() {
        var a = PlayingAnalyzer(); on(&a, [60, 64, 67], at: 0); XCTAssertEqual(a.chord, .major)
        a = PlayingAnalyzer(); on(&a, [57, 60, 64], at: 0); XCTAssertEqual(a.chord, .minor)
        a = PlayingAnalyzer(); on(&a, [60, 66], at: 0); XCTAssertEqual(a.chord, .tense)
        a = PlayingAnalyzer(); on(&a, [60, 67], at: 0); XCTAssertEqual(a.chord, .open)
        a = PlayingAnalyzer(); on(&a, [60], at: 0); XCTAssertEqual(a.chord, ChordQuality.none)
    }
    func testChordPublishedAsInputs() {
        var a = PlayingAnalyzer(); on(&a, [60, 64, 67], at: 0)
        XCTAssertEqual(value(&a, .chordMajor, at: 0), 1)
        XCTAssertEqual(value(&a, .chordMinor, at: 0), 0)
    }
    func testRisingAndFallingMelody() {
        var a = PlayingAnalyzer()
        for (i, n) in [60, 62, 64, 65, 67, 69, 71].enumerated() { on(&a, [UInt8(n)], at: Double(i) * 0.2); off(&a, [UInt8(n)], at: Double(i) * 0.2 + 0.1) }
        XCTAssertGreaterThan(value(&a, .direction, at: 1.4), 0.5)
        var b = PlayingAnalyzer()
        for (i, n) in [71, 69, 67, 65, 64, 62, 60].enumerated() { on(&b, [UInt8(n)], at: Double(i) * 0.2); off(&b, [UInt8(n)], at: Double(i) * 0.2 + 0.1) }
        XCTAssertLessThan(value(&b, .direction, at: 1.4), -0.5)
    }
    func testOctaveLeapIsFull() {
        var a = PlayingAnalyzer(); on(&a, [60], at: 0); off(&a, [60], at: 0.1); on(&a, [72], at: 0.2)
        XCTAssertEqual(value(&a, .leap, at: 0.2), 1, accuracy: 0.01)
    }
    func testBusyness() {
        var a = PlayingAnalyzer()
        for i in 0..<24 { on(&a, [UInt8(60 + i % 12)], at: Double(i) * 2.0 / 24) }
        XCTAssertEqual(value(&a, .busyness, at: 1.95), 1, accuracy: 0.05)
    }
    func testCrescendo() {
        var a = PlayingAnalyzer()
        for i in 0..<9 { on(&a, [60], at: Double(i) * 0.25, v: Float(40 + i * 10) / 127); off(&a, [60], at: Double(i) * 0.25 + 0.1) }
        XCTAssertGreaterThan(value(&a, .crescendo, at: 2.0), 0.5)
    }
    func testSpread() {
        var a = PlayingAnalyzer(); on(&a, [36, 84], at: 0)
        XCTAssertEqual(value(&a, .spread, at: 0), 1, accuracy: 0.01)
    }
    func testRepetition() {
        var a = PlayingAnalyzer()
        for (i, n) in [60, 62, 60, 62, 60, 62, 60, 62].enumerated() { on(&a, [UInt8(n)], at: Double(i) * 0.2); off(&a, [UInt8(n)], at: Double(i) * 0.2 + 0.1) }
        XCTAssertGreaterThan(value(&a, .repetition, at: 1.6), 0.7)
    }
    func testSilence() {
        var a = PlayingAnalyzer(); on(&a, [60], at: 0); off(&a, [60], at: 0.1)
        XCTAssertEqual(value(&a, .silence, at: 8), 1, accuracy: 0.01)
        XCTAssertEqual(value(&a, .silence, at: 0), 0, accuracy: 0.01)
    }
    func testKeyDetection() {
        var a = PlayingAnalyzer()
        let scale: [UInt8] = [60, 62, 64, 65, 67, 69, 71, 72]
        for (i, n) in (scale + scale + [60, 64, 67, 60]).enumerated() { on(&a, [n], at: Double(i) * 0.2); off(&a, [n], at: Double(i) * 0.2 + 0.1) }
        XCTAssertEqual(a.keyRoot, 0)
    }
    func testAllNotesOffClearsChord() {
        var a = PlayingAnalyzer(); on(&a, [60, 64, 67], at: 0); a.handle(.allNotesOff, at: 0.1)
        XCTAssertEqual(a.chord, ChordQuality.none)
    }
}
