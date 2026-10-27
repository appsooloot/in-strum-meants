import XCTest
import CoreMIDI
@testable import InStrumAudio

final class MIDIInputTests: XCTestCase {
    private var client = MIDIClientRef()
    private var source = MIDIEndpointRef()

    private func makeVirtualSource(named name: String) throws {
        guard MIDIClientCreateWithBlock("InStrumTestClient" as CFString, &client, nil) == noErr else {
            throw XCTSkip("CoreMIDI unavailable on this machine")
        }
        guard MIDISourceCreateWithProtocol(client, name as CFString, ._1_0, &source) == noErr else {
            throw XCTSkip("Could not create a virtual MIDI source")
        }
    }

    private func sendMIDI1(_ status: UInt8, _ d1: UInt8, _ d2: UInt8) {
        // MIDI 1.0 channel voice message as a 32-bit UMP (message type 2, group 0).
        var word: UInt32 = 0x2000_0000 | UInt32(status) << 16 | UInt32(d1) << 8 | UInt32(d2)
        var list = MIDIEventList()
        let packet = MIDIEventListInit(&list, ._1_0)
        _ = MIDIEventListAdd(&list, MemoryLayout<MIDIEventList>.size, packet, 0, 1, &word)
        MIDIReceivedEventList(source, &list)
    }

    override func tearDown() {
        if source != 0 { MIDIEndpointDispose(source) }
        if client != 0 { MIDIClientDispose(client) }
    }

    func testReceivesBytesFromNewSource() throws {
        let got = expectation(description: "bytes")
        let seen = expectation(description: "source seen")
        seen.assertForOverFulfill = false
        var received: [UInt8] = []
        let input: MIDIInput
        do {
            input = try MIDIInput(onBytes: { bytes, _ in
                if bytes == [0x90, 60, 100] { received = bytes; got.fulfill() }
            }, onSourcesChanged: { names, _ in
                if names.contains("InStrum Test Keys") { seen.fulfill() }
            })
        } catch { throw XCTSkip("CoreMIDI unavailable: \(error)") }
        try makeVirtualSource(named: "InStrum Test Keys")
        wait(for: [seen], timeout: 2)
        XCTAssertTrue(input.sourceNames.contains("InStrum Test Keys"))
        sendMIDI1(0x90, 60, 100)
        wait(for: [got], timeout: 2)
        XCTAssertEqual(received, [0x90, 60, 100])
    }

    func testRemovingSourceReportsRemoval() throws {
        let seen = expectation(description: "source seen"); seen.assertForOverFulfill = false
        let removed = expectation(description: "removed"); removed.assertForOverFulfill = false
        let input: MIDIInput
        do {
            input = try MIDIInput(onBytes: { _, _ in }, onSourcesChanged: { names, wasRemoved in
                if names.contains("InStrum Gone Keys") { seen.fulfill() }
                if wasRemoved && !names.contains("InStrum Gone Keys") { removed.fulfill() }
            })
        } catch { throw XCTSkip("CoreMIDI unavailable: \(error)") }
        try makeVirtualSource(named: "InStrum Gone Keys")
        wait(for: [seen], timeout: 2)
        MIDIEndpointDispose(source); source = 0
        wait(for: [removed], timeout: 2)
        XCTAssertFalse(input.sourceNames.contains("InStrum Gone Keys"))
    }

    func testUMPWordToBytes() {
        XCTAssertEqual(MIDIInput.bytes(fromUMP: 0x2090_3C64), [0x90, 0x3C, 0x64])
        XCTAssertEqual(MIDIInput.bytes(fromUMP: 0x20C0_0500), [0xC0, 0x05])      // program change: 1 data byte
        XCTAssertEqual(MIDIInput.bytes(fromUMP: 0x10F8_0000), [0xF8])            // system real-time
        XCTAssertEqual(MIDIInput.bytes(fromUMP: 0x4090_3C00), [])                // MIDI 2.0 type ignored
    }
}
