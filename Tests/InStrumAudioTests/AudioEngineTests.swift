import XCTest
import AVFoundation
import AudioToolbox
@testable import InStrumAudio
@testable import InStrumCore

final class AudioEngineTests: XCTestCase {
    let dls = InstrumentChoice(name: "Apple DLS Synth",
                               componentType: kAudioUnitType_MusicDevice,
                               componentSubType: kAudioUnitSubType_DLSSynth,
                               componentManufacturer: kAudioUnitManufacturer_Apple)

    private func peak(_ b: AVAudioPCMBuffer, lastFrames: Int? = nil) -> Float {
        let n = Int(b.frameLength), start = max(0, n - (lastFrames ?? n))
        var m: Float = 0
        for ch in 0..<Int(b.format.channelCount) {
            let d = b.floatChannelData![ch]
            for i in start..<n { m = max(m, abs(d[i])) }
        }
        return m
    }

    private func makeEngine() async throws -> AudioEngine {
        let e = AudioEngine(manualRendering: true)
        try e.start()
        try await e.loadInstrument(dls)
        return e
    }

    func testCatalogContainsAppleDLSSynthAndOnlyInstruments() {
        let all = PluginCatalog.instruments()
        XCTAssertTrue(all.contains { $0.description.componentSubType == kAudioUnitSubType_DLSSynth })
        XCTAssertTrue(all.allSatisfy { $0.description.componentType == kAudioUnitType_MusicDevice })
    }

    func testPluginInfoMakesMatchingChoice() {
        let info = PluginCatalog.instruments().first { $0.description.componentSubType == kAudioUnitSubType_DLSSynth }!
        let c = info.choice()
        XCTAssertEqual(c.componentSubType, kAudioUnitSubType_DLSSynth)
        XCTAssertEqual(c.componentManufacturer, kAudioUnitManufacturer_Apple)
        XCTAssertNil(c.stateData)
    }

    func testNoteProducesSound() async throws {
        let e = try await makeEngine()
        e.send([0x90, 60, 110])
        XCTAssertGreaterThan(peak(try e.renderOffline(frames: 4096)), 0.01)
    }

    func testSilentWithoutNotes() async throws {
        let e = try await makeEngine()
        XCTAssertLessThan(peak(try e.renderOffline(frames: 4096)), 0.0001)
    }

    func testPanicSilencesHeldNote() async throws {
        let e = try await makeEngine()
        e.send([0x90, 60, 110])
        _ = try e.renderOffline(frames: 4096)
        e.panic()
        var last: AVAudioPCMBuffer!
        for _ in 0..<33 { last = try e.renderOffline(frames: 4096) }   // ~3 s
        XCTAssertLessThan(peak(last), 0.001)
    }

    func testStateRoundTrips() async throws {
        let e = try await makeEngine()
        let state = try XCTUnwrap(e.currentInstrumentState())
        var choice = dls; choice.stateData = state
        let e2 = AudioEngine(manualRendering: true)
        try e2.start()
        try await e2.loadInstrument(choice)
        XCTAssertNotNil(e2.loadedAudioUnit)
    }

    func testMissingPluginThrowsPluginNotFound() async throws {
        let e = AudioEngine(manualRendering: true)
        try e.start()
        var missing = dls; missing.componentSubType = 0x7A7A7A7A; missing.name = "Ghost Piano"   // 'zzzz'
        do {
            try await e.loadInstrument(missing)
            XCTFail("expected pluginNotFound")
        } catch AudioEngineError.pluginNotFound(let name) {
            XCTAssertEqual(name, "Ghost Piano")
        }
    }

    func testMasterVolumeControlsMixer() async throws {
        let e = try await makeEngine()
        e.masterVolume = 0.25
        XCTAssertEqual(e.masterVolume, 0.25, accuracy: 0.001)
    }
}
