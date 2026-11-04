import XCTest
@testable import InStrumCore

final class MIDIParserTests: XCTestCase {
    var p = MIDIParser()
    override func setUp() { p = MIDIParser() }

    func testNoteOn() {
        XCTAssertEqual(p.parse([0x90, 60, 100]), [.noteOn(channel: 0, note: 60, velocity: 100)])
    }
    func testVelocityZeroNoteOnIsNoteOff() {
        XCTAssertEqual(p.parse([0x91, 60, 0]), [.noteOff(channel: 1, note: 60)])
    }
    func testNoteOffMessage() {
        XCTAssertEqual(p.parse([0x80, 60, 64]), [.noteOff(channel: 0, note: 60)])
    }
    func testRunningStatus() {
        XCTAssertEqual(p.parse([0x90, 60, 100, 64, 90, 60, 0]),
                       [.noteOn(channel: 0, note: 60, velocity: 100),
                        .noteOn(channel: 0, note: 64, velocity: 90),
                        .noteOff(channel: 0, note: 60)])
    }
    func testRunningStatusAcrossCalls() {
        _ = p.parse([0x90, 60, 100])
        XCTAssertEqual(p.parse([62, 80]), [.noteOn(channel: 0, note: 62, velocity: 80)])
    }
    func testMessageSplitAcrossCalls() {
        XCTAssertEqual(p.parse([0x90, 60]), [])
        XCTAssertEqual(p.parse([100]), [.noteOn(channel: 0, note: 60, velocity: 100)])
    }
    func testRealTimeBytesMidMessageAreIgnored() {
        XCTAssertEqual(p.parse([0x90, 0xFE, 60, 0xF8, 100]), [.noteOn(channel: 0, note: 60, velocity: 100)])
    }
    func testSustainPedalCC() {
        XCTAssertEqual(p.parse([0xB0, 64, 127]), [.controlChange(channel: 0, controller: 64, value: 127)])
    }
    func testPitchBend() {
        XCTAssertEqual(p.parse([0xE0, 0x00, 0x40]), [.pitchBend(channel: 0, value: 8192)])
    }
    func testSysExIsSkipped() {
        XCTAssertEqual(p.parse([0xF0, 0x7E, 0x01, 0xF7, 0x90, 60, 100]), [.noteOn(channel: 0, note: 60, velocity: 100)])
    }
    func testDataBytesWithoutStatusAreIgnored() {
        var fresh = MIDIParser()
        XCTAssertEqual(fresh.parse([60, 100]), [])
    }
    func testChannelPressure() {
        XCTAssertEqual(p.parse([0xD0, 90]), [.channelPressure(channel: 0, value: 90)])
    }
    func testPolyPressure() {
        XCTAssertEqual(p.parse([0xA0, 60, 70]), [.polyPressure(channel: 0, note: 60, value: 70)])
    }
    func testNoteOffKeepsReleaseVelocity() {
        XCTAssertEqual(p.parse([0x80, 60, 127]), [.noteOff(channel: 0, note: 60, velocity: 127)])
    }
    func testProgramChangeIsOther() {
        XCTAssertEqual(p.parse([0xC0, 5]), [.other])
    }
    func testSystemCommonClearsRunningStatus() {
        _ = p.parse([0x90, 60, 100])
        XCTAssertEqual(p.parse([0xF6, 62, 80]), [])
    }
}

final class MIDIMessageBytesTests: XCTestCase {
    func testEncodingRoundTripsThroughTheParser() {
        let messages: [MIDIMessage] = [.noteOn(channel: 0, note: 60, velocity: 100), .noteOff(channel: 2, note: 61, velocity: 40),
                                       .controlChange(channel: 0, controller: 64, value: 127), .pitchBend(channel: 1, value: 9000),
                                       .channelPressure(channel: 0, value: 90), .pitchBend(channel: 0, value: 16383)]
        var parser = MIDIParser()
        XCTAssertEqual(parser.parse(messages.flatMap(\.bytes)), messages)
    }

    func testDemoPhrasesAreOriginalAndPlayable() {
        for phrase in [DemoPhrases.feltGlass, DemoPhrases.orbitPad, DemoPhrases.honeyTape, DemoPhrases.hazeBells,
                       DemoPhrases.cabinFelt, DemoPhrases.morningBox, DemoPhrases.polarChoir, DemoPhrases.planktonKeys,
                       DemoPhrases.teaHouseKoto] {
            XCTAssertGreaterThan(phrase.last?.time ?? 0, 18)
            XCTAssertEqual(phrase.map(\.time), phrase.map(\.time).sorted())
            var held = Set<UInt8>()
            var wheel: UInt16 = 8192, pressure: UInt8 = 0
            for (_, m) in phrase {
                if case let .noteOn(_, n, _) = m { held.insert(n) }
                if case let .noteOff(_, n, _) = m { held.remove(n) }
                if case let .pitchBend(_, v) = m { wheel = v }
                if case let .channelPressure(_, p) = m { pressure = p }
            }
            XCTAssertTrue(held.isEmpty, "every note is released")
            XCTAssertEqual(wheel, 8192, "the wheel is let go")
            XCTAssertEqual(pressure, 0, "the pressure is let go")
        }
    }

    /// The koto's demo stays in hirajōshi on E, presses three strings up after the pluck and lets them go, swells the
    /// pressure (yuri) on two long notes, never rests long enough (1.5 s) to re-root the open strings off its opening E,
    /// and ends on an open fifth, E and B, struck together and left to ring. The wheel and pressure reach every sounding
    /// string, so each press and each swell happens with one key down.
    func testTeaHouseKotoDemoPressesAndBreathes() {
        let phrase = DemoPhrases.teaHouseKoto
        var held = Set<UInt8>(), allUp: Double? = nil
        var wheel: UInt16 = 8192, pressure: UInt8 = 0, presses = 0, swells = 0, highest: UInt16 = 8192
        var onsets: [(time: Double, note: UInt8)] = []
        for (t, m) in phrase {
            switch m {
            case let .noteOn(_, n, _):
                XCTAssertTrue([4, 5, 9, 11, 0].contains(Int(n) % 12), "note \(n) at \(t) s is outside hirajōshi on E")
                if held.isEmpty, let rest = allUp { XCTAssertLessThan(t - rest, 1.5, "the rest before \(t) s re-roots the open strings") }
                held.insert(n)
                onsets.append((t, n))
            case let .noteOff(_, n, _):
                held.remove(n)
                if held.isEmpty { allUp = t }
            case let .pitchBend(_, v):
                XCTAssertGreaterThanOrEqual(v, 8192, "a press only raises the string")
                if wheel == 8192, v > 8192 {
                    presses += 1
                    XCTAssertEqual(held.count, 1, "the press at \(t) s bends one string alone")
                }
                wheel = v
                highest = max(highest, v)
            case let .channelPressure(_, p):
                if pressure == 0, p > 0 {
                    swells += 1
                    XCTAssertEqual(held.count, 1, "the yuri at \(t) s sways one string alone")
                }
                pressure = p
            default:
                XCTFail("unexpected \(m) at \(t) s")
            }
        }
        XCTAssertEqual(presses, 3)
        XCTAssertEqual(highest, 16383, "one press goes the wheel's whole way (a whole tone)")
        XCTAssertEqual(swells, 2)
        XCTAssertEqual(wheel, 8192); XCTAssertEqual(pressure, 0)
        XCTAssertEqual(onsets.first?.note, 52, "it opens on E")
        XCTAssertGreaterThanOrEqual(onsets.count, 2)
        guard onsets.count >= 2 else { return }
        let fifth = onsets.suffix(2).map(\.note), struck = onsets.suffix(2).map(\.time)
        XCTAssertEqual(fifth.map { Int($0) % 12 }, [4, 11], "it ends on E and B")
        XCTAssertEqual(Int(fifth[1]) - Int(fifth[0]), 7, "an open fifth")
        XCTAssertLessThan(struck[1] - struck[0], 0.05, "struck together")
        XCTAssertGreaterThanOrEqual((phrase.last?.time ?? 0) - struck[1], 3, "and left to ring")
    }
}
