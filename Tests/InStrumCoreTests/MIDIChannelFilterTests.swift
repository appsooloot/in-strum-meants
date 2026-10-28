import XCTest
@testable import InStrumCore

/// The MIDI channel filter: "All channels", or only the one chosen.
final class MIDIChannelFilterTests: XCTestCase {
    func testAllChannelsPassEverything() {
        for status: UInt8 in [0x90, 0x9F, 0x80, 0xB3, 0xE7] {
            XCTAssertTrue(MIDIChannelFilter.passes([status, 60, 100], channel: nil), String(format: "%02X", status))
        }
    }

    func testOnlyTheChosenChannelPasses() {
        XCTAssertTrue(MIDIChannelFilter.passes([0x91, 60, 100], channel: 2))
        XCTAssertTrue(MIDIChannelFilter.passes([0x81, 60, 0], channel: 2))
        XCTAssertTrue(MIDIChannelFilter.passes([0xB1, 64, 127], channel: 2))
        XCTAssertFalse(MIDIChannelFilter.passes([0x90, 60, 100], channel: 2))
        XCTAssertFalse(MIDIChannelFilter.passes([0xB0, 64, 127], channel: 2))
        XCTAssertTrue(MIDIChannelFilter.passes([0x9F, 60, 100], channel: 16))
    }

    func testSystemMessagesAlwaysPass() {
        XCTAssertTrue(MIDIChannelFilter.passes([0xF8], channel: 5))
        XCTAssertTrue(MIDIChannelFilter.passes([0xFE], channel: 5))
    }

    func testNothingIsDropped() {
        XCTAssertFalse(MIDIChannelFilter.passes([], channel: nil))
    }
}
