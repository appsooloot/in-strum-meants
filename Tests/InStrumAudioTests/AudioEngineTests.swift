import XCTest
import AVFoundation
import AudioToolbox
@testable import InStrumAudio
@testable import InStrumCore

@MainActor
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

    func testListsOutputDevicesWithNames() {
        let devices = AudioEngine.listOutputDevices()
        XCTAssertEqual(Set(devices.map(\.uid)).count, devices.count, "each output once")
        XCTAssertTrue(devices.allSatisfy { !$0.name.isEmpty && !$0.uid.isEmpty })
    }

    func testAnUnknownOutputIsRefused() async throws {
        let e = try await makeEngine()
        XCTAssertFalse(e.selectOutputDevice(uid: "no-such-device"))
        XCTAssertNil(e.checkHealth(), "offline rendering never needs fixing")
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

    func testStartTwiceIsHarmless() throws {
        let e = AudioEngine(manualRendering: true)
        try e.start()
        XCTAssertNoThrow(try e.start())
    }

    /// RMS over both channels, in dB.
    private func level(_ b: AVAudioPCMBuffer) -> Double {
        var sum = 0.0
        let n = Int(b.frameLength), channels = Int(b.format.channelCount)
        for ch in 0..<channels {
            let d = b.floatChannelData![ch]
            for i in 0..<n { sum += Double(d[i]) * Double(d[i]) }
        }
        let rms = (sum / Double(max(1, n * channels))).squareRoot()
        return rms > 0 ? 20 * log10(rms) : -200
    }

    /// A DLS engine at master 0.7 and ambience 0.4 with this sleep gain, holding middle C: the level of its second
    /// 4096 frames, past the attack. The ambience starts after the gain is set, so its bus takes the gain as it's attached.
    private func heldNote(sleepGain: Float) async throws -> (engine: AudioEngine, dB: Double) {
        let e = try await makeEngine()
        e.masterVolume = 0.7
        e.ambienceVolume = 0.4
        e.sleepGain = sleepGain
        await e.startAmbience()
        e.send([0x90, 60, 110])
        _ = try e.renderOffline(frames: 4096)
        let held = try e.renderOffline(frames: 4096)
        return (e, level(held))
    }

    /// The sleep fade's gain (Small Wins spec §3) is the two buses' input volume on the main mixer: the saved volumes
    /// read back unchanged, and a held note at gain 0.25 comes out 20·log10(0.25) = 12.04 dB quieter. It clamps to 0…1.
    func testSleepGainLeavesTheVolumesAlone() async throws {
        let full = try await heldNote(sleepGain: 1)
        let faded = try await heldNote(sleepGain: 0.25)
        let e = faded.engine
        let master = e.masterVolume, ambience = e.ambienceVolume, ambienceBus = e.ambienceBusVolume
        let gains = e.busSleepGains, gain = e.sleepGain
        XCTAssertEqual(master, 0.7, accuracy: 1e-6)
        XCTAssertEqual(ambience, 0.4, accuracy: 1e-6)
        XCTAssertEqual(ambienceBus, 0.4, accuracy: 1e-6)
        XCTAssertEqual(gain, 0.25)
        XCTAssertEqual(gains.instrument, 0.25, accuracy: 1e-6)
        XCTAssertEqual(gains.ambience, 0.25, accuracy: 1e-6)
        XCTAssertGreaterThan(full.dB, -60, "the note sounds")
        XCTAssertEqual(full.dB - faded.dB, 12.0, accuracy: 0.5)
        e.sleepGain = 1.7
        let high = e.sleepGain
        e.sleepGain = -0.2
        let low = e.sleepGain
        XCTAssertEqual(high, 1)
        XCTAssertEqual(low, 0)
    }

    func testInstrumentRendersAtOutputRate() async throws {
        let e = AudioEngine(manualRendering: true, manualSampleRate: 48_000)
        try e.start()
        try await e.loadInstrument(dls)
        let rate = try XCTUnwrap(e.loadedAudioUnit).outputBusses[0].format.sampleRate
        XCTAssertEqual(rate, 48_000)
    }
}
