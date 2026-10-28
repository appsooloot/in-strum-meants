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
                                       .controlChange(channel: 0, controller: 64, value: 127), .pitchBend(channel: 1, value: 9000)]
        var parser = MIDIParser()
        XCTAssertEqual(parser.parse(messages.flatMap(\.bytes)), messages)
    }

    func testDemoPhrasesAreOriginalAndPlayable() {
        for phrase in [DemoPhrases.feltGlass, DemoPhrases.orbitPad, DemoPhrases.honeyTape, DemoPhrases.hazeBells,
                       DemoPhrases.cabinFelt, DemoPhrases.morningBox] {
            XCTAssertGreaterThan(phrase.last?.time ?? 0, 18)
            XCTAssertEqual(phrase.map(\.time), phrase.map(\.time).sorted())
            var held = Set<UInt8>()
            for (_, m) in phrase {
                if case let .noteOn(_, n, _) = m { held.insert(n) }
                if case let .noteOff(_, n, _) = m { held.remove(n) }
            }
            XCTAssertTrue(held.isEmpty, "every note is released")
        }
    }
}
