import XCTest
@testable import InStrumCore

/// Tide Lines: notes write glowing lines in the wet sand; the tide erases them.
final class TideLinesTests: XCTestCase {
    private func step(_ t: inout TideLines, seconds: Double, front: Float = 0, breaks: [Wave] = []) {
        var first = true
        for _ in 0..<Int(seconds * 60) {
            t.step(dt: 1.0 / 60, washFront: front, breaks: first ? breaks : [], roles: RoleValues())
            first = false
        }
    }

    private let wave = Wave(breakTime: 0, strength: 0.8, period: 10, big: true)

    func testLinesArePlacedByPitch() {
        var t = TideLines()
        for (i, n) in [21, 60, 108].enumerated() { t.noteOn(UInt8(n), velocity: 100, pedal: false, at: Double(i)) }
        XCTAssertLessThan(t.lines[0].x, 0.05)
        XCTAssertGreaterThan(t.lines[2].x, 0.95)
        XCTAssertLessThan(t.lines[0].x, t.lines[1].x)
        XCTAssertLessThan(t.lines[1].x, t.lines[2].x)
        XCTAssertTrue(t.lines.allSatisfy { (0.25...0.65).contains($0.y) })
    }

    func testHarderWritesLongerBrighterLines() {
        var t = TideLines()
        t.noteOn(60, velocity: 127, pedal: false, at: 0)
        t.noteOn(62, velocity: 40, pedal: false, at: 1)
        XCTAssertGreaterThan(t.lines[0].length, t.lines[1].length)
        XCTAssertGreaterThan(t.lines[0].strength, 1.5 * t.lines[1].strength)
    }

    func testWashErasesLinesItPasses() {
        var t = TideLines()
        t.noteOn(60, velocity: 100, pedal: false, at: 0)
        let y = t.lines[0].y
        step(&t, seconds: 0.5, front: y - 0.1)
        XCTAssertEqual(t.lines.first?.washed ?? -1, 0, "a wash that stops short leaves it")
        step(&t, seconds: 0.6, front: y + 0.1)
        XCTAssertTrue(t.lines.isEmpty, "a wash that reaches it erases it")
    }

    func testPedalLinesSurviveOneWash() {
        var t = TideLines()
        t.noteOn(60, velocity: 100, pedal: true, at: 0)
        let y = t.lines[0].y, before = t.lines[0].strength
        step(&t, seconds: 1, front: y + 0.1)
        step(&t, seconds: 1, front: 0)   // the sand drains
        XCTAssertEqual(t.lines.count, 1, "a deep line survives its first wash")
        XCTAssertLessThan(t.lines[0].strength, 0.5 * before, "as a faint trace")
        step(&t, seconds: 1, front: y + 0.1)
        XCTAssertTrue(t.lines.isEmpty, "and the next wash takes it")
    }

    func testHeldLinesKeepGlowing() {
        var t = TideLines()
        t.noteOn(60, velocity: 100, pedal: false, at: 0)
        let s = t.lines[0].strength
        step(&t, seconds: 3)
        XCTAssertEqual(t.lines[0].strength, s, accuracy: 0.05 * s)
        t.noteOff(60)
        step(&t, seconds: 3)
        XCTAssertLessThan(t.lines.first?.strength ?? 0, 0.9 * s, "released lines fade")
    }

    func testChordsFoamTheNextBreak() {
        var t = TideLines()
        t.foamAmount = 0.8
        for (i, n) in [60, 64, 67].enumerated() { t.noteOn(UInt8(n), velocity: 100, pedal: false, at: Double(i) * 0.02) }
        XCTAssertTrue(t.chordPending)
        step(&t, seconds: 0.1)
        XCTAssertEqual(t.foam, 0, "no foam until a wave breaks")
        t.step(dt: 1.0 / 60, washFront: 0, breaks: [wave], roles: RoleValues())
        XCTAssertFalse(t.chordPending)
        XCTAssertLessThan(t.foam, 0.3 * 0.8, "the golden foam swells in, it doesn't flash on")
        step(&t, seconds: 0.3)
        XCTAssertGreaterThan(t.foam, 0.4 * 0.8)
        var single = TideLines()
        single.noteOn(60, velocity: 100, pedal: false, at: 0)
        single.step(dt: 1.0 / 60, washFront: 0, breaks: [wave], roles: RoleValues())
        XCTAssertEqual(single.foam, 0, "a single note makes no foam")
    }

    func testChordQualityTintsTheLines() {
        var major = TideLines(), minor = TideLines()
        for n in [60, 64, 67] { major.noteOn(UInt8(n), velocity: 90, pedal: false, at: 0) }
        for n in [57, 60, 64] { minor.noteOn(UInt8(n), velocity: 90, pedal: false, at: 0) }
        step(&major, seconds: 0.1); step(&minor, seconds: 0.1)
        major.noteOn(72, velocity: 90, pedal: false, at: 1); minor.noteOn(69, velocity: 90, pedal: false, at: 1)
        XCTAssertEqual(major.lines.last?.hue, TideLines.majorHue)
        XCTAssertEqual(minor.lines.last?.hue, TideLines.minorHue)
    }

    func testAChordsOwnLinesTakeItsColour() {
        var t = TideLines()
        for n: UInt8 in [57, 60, 64] { t.noteOn(n, velocity: 90, pedal: false, at: 0) }   // A minor, played as one chord
        t.step(dt: 1.0 / 60, washFront: 0, breaks: [], roles: RoleValues())
        XCTAssertEqual(t.lines.map(\.hue), [TideLines.minorHue, TideLines.minorHue, TideLines.minorHue])
        for n: UInt8 in [57, 60, 64] { t.noteOff(n) }
        for n: UInt8 in [60, 64, 67] { t.noteOn(n, velocity: 90, pedal: false, at: 1) }    // then C major
        t.step(dt: 1.0 / 60, washFront: 0, breaks: [], roles: RoleValues())
        XCTAssertEqual(t.lines.suffix(3).map(\.hue), [TideLines.majorHue, TideLines.majorHue, TideLines.majorHue])
    }

    func testLinesWrittenUnderTheWashWaitForTheNextOne() {
        var t = TideLines()
        step(&t, seconds: 0.2, front: 0.9)                  // the wash is up the sand
        t.noteOn(60, velocity: 100, pedal: false, at: 0.2)
        step(&t, seconds: 1, front: 0.9)
        XCTAssertEqual(t.lines.first?.washed ?? -1, 0, "written into the wash, it stays until the sand drains")
        step(&t, seconds: 1, front: 0)
        XCTAssertEqual(t.lines.count, 1)
        step(&t, seconds: 1, front: 0.9)
        XCTAssertTrue(t.lines.isEmpty, "the next wash takes it")
    }

    func testSmoothKeepsTheStrongest24() {
        var lines: [TideLine] = []
        var t = TideLines()
        for i in 0..<40 { t.noteOn(UInt8(40 + i), velocity: UInt8(30 + (i * 37) % 97), pedal: false, at: Double(i)) }
        lines = t.lines
        let kept = TideLines.visible(lines, limit: 24)
        XCTAssertEqual(kept.count, 24)
        let weakestKept = kept.map(\.strength).min() ?? 0
        let dropped = lines.filter { l in !kept.contains { $0.note == l.note } }
        XCTAssertTrue(dropped.allSatisfy { $0.strength <= weakestKept })
        XCTAssertEqual(kept.map(\.note), lines.map(\.note).filter { n in kept.contains { $0.note == n } }, "original order")
    }

    func testBurstStaysCapped() {
        var t = TideLines()
        for i in 0..<2000 { t.noteOn(UInt8(21 + i % 88), velocity: 100, pedal: false, at: Double(i) * 0.0001) }
        t.step(dt: 1.0 / 60, washFront: 0, breaks: [], roles: RoleValues())
        XCTAssertLessThanOrEqual(t.lines.count, TideLines.cap)
    }
}
