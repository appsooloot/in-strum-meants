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
        XCTAssertEqual(MIDIParser().parse([60, 100]), [])
    }
    func testProgramChangeIsOther() {
        XCTAssertEqual(p.parse([0xC0, 5]), [.other])
    }
    func testSystemCommonClearsRunningStatus() {
        _ = p.parse([0x90, 60, 100])
        XCTAssertEqual(p.parse([0xF6, 62, 80]), [])
    }
}
