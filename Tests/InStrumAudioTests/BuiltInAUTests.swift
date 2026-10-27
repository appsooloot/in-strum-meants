import XCTest
import AVFoundation
@testable import InStrumAudio
@testable import InStrumCore
import InStrumDSP

@MainActor
final class BuiltInAUTests: XCTestCase {
    private func choice(_ name: String = "Felt Glass") throws -> InstrumentChoice {
        try XCTUnwrap(BuiltInCatalog.instruments.first { $0.name == name }).choice()
    }

    private func makeEngine(rate: Double = 48_000, _ name: String = "Felt Glass") async throws -> AudioEngine {
        let e = AudioEngine(manualRendering: true, manualSampleRate: rate)
        try e.start()
        try await e.loadInstrument(try choice(name))
        return e
    }

    private func setParam(_ e: AudioEngine, _ address: Int, _ value: Float) {
        e.loadedBuiltIn?.parameterTree?.parameter(withAddress: AUParameterAddress(address))?.value = value
    }

    /// Left channel of `seconds` of manual rendering in `block`-frame calls.
    private func render(_ e: AudioEngine, seconds: Double, block: Int = 256, rate: Double = 48_000) throws -> [Float] {
        var out: [Float] = []
        let total = Int(seconds * rate)
        out.reserveCapacity(total)
        while out.count < total {
            let n = min(block, total - out.count)
            let b = try e.renderOffline(frames: AVAudioFrameCount(n))
            out.append(contentsOf: UnsafeBufferPointer(start: b.floatChannelData![0], count: Int(b.frameLength)))
        }
        return out
    }

    func testLoadsAndPlaysFeltGlass() async throws {
        let e = try await makeEngine()
        XCTAssertNotNil(e.loadedBuiltIn)
        e.send([0x90, 60, 100])
        XCTAssertGreaterThan(DSPTestKit.dBFS(try render(e, seconds: 0.5)), -40)
    }

    func testFullStateRoundTrip() async throws {
        let e = try await makeEngine()
        setParam(e, Int(ISD_P_GLASS), 0.8)
        setParam(e, Int(ISD_P_FINE_TUNE), 12)
        var saved = try choice()
        saved.stateData = try XCTUnwrap(e.currentInstrumentState())
        let e2 = AudioEngine(manualRendering: true)
        try e2.start()
        try await e2.loadInstrument(saved)
        let tree = try XCTUnwrap(e2.loadedBuiltIn?.parameterTree)
        XCTAssertEqual(tree.parameter(withAddress: AUParameterAddress(ISD_P_GLASS))?.value ?? 0, 0.8, accuracy: 1e-5)
        XCTAssertEqual(tree.parameter(withAddress: AUParameterAddress(ISD_P_FINE_TUNE))?.value ?? 0, 12, accuracy: 1e-5)
    }

    func testDialReaderSeesDialsButNotMood() async throws {
        let e = try await makeEngine()
        let reader = DialReader(audioUnit: try XCTUnwrap(e.loadedBuiltIn))
        XCTAssertTrue(reader.dials.contains { $0.name == "Glass" })
        XCTAssertFalse(reader.dials.contains { $0.address >= AUParameterAddress(ISD_P_MOOD_ENERGY) })
    }

    func testCatalogListsAvailableInstruments() throws {
        let all = BuiltInCatalog.instruments
        XCTAssertTrue(all.contains { $0.name == "Felt Glass" })
        XCTAssertTrue(all.allSatisfy { $0.manufacturer == "In Strum Meants" })
        for info in all {
            let engine = try XCTUnwrap(BuiltInCatalog.engine(for: info.choice()))
            XCTAssertEqual(BuiltInCatalog.description(for: engine).componentSubType, info.description.componentSubType)
        }
        XCTAssertNil(BuiltInCatalog.engine(for: InstrumentChoice(name: "x", componentType: kAudioUnitType_MusicDevice,
                                                                 componentSubType: kAudioUnitSubType_DLSSynth,
                                                                 componentManufacturer: kAudioUnitManufacturer_Apple)))
    }

    func testTuningHoldsAt44_1And96k() async throws {
        for rate in [44_100.0, 96_000.0] {
            let e = try await makeEngine(rate: rate)
            setParam(e, Int(ISD_P_SPACE), 0)
            e.send([0x90, 69, 100])
            let out = try render(e, seconds: 1.4, block: 512, rate: rate)
            let slice = Array(out[Int(0.3 * rate)..<Int(1.3 * rate)])
            let f = DSPTestKit.fundamental(slice, sampleRate: rate, near: 440)
            XCTAssertEqual(DSPTestKit.cents(f, 440), 0, accuracy: 2, "at \(rate) Hz")
        }
    }

    func testRendersAnyBufferSize() async throws {
        var levels: [Double] = []
        for block in [256, 4096, 1] {
            let e = try await makeEngine()
            e.send([0x90, 60, 100])
            levels.append(DSPTestKit.dBFS(try render(e, seconds: 0.5, block: block)))
        }
        XCTAssertEqual(levels[1], levels[0], accuracy: 0.5)
        XCTAssertEqual(levels[2], levels[0], accuracy: 0.5)
    }

    func testSwitchingWhileHeldIsSafe() async throws {
        let e = try await makeEngine()
        e.send([0x90, 60, 110])
        _ = try render(e, seconds: 0.2)
        try await e.loadInstrument(try choice())   // Orbit Pad once Task 6 lands
        let after = try render(e, seconds: 0.25)
        XCTAssertTrue(after.allSatisfy(\.isFinite))
        XCTAssertLessThan(DSPTestKit.dBFS(after[Int(0.05 * 48_000)...]), -100)
    }

    func testMoodReachesTheInstrument() async throws {
        let e = try await makeEngine()
        e.setMood(.serene)
        let tree = try XCTUnwrap(e.loadedBuiltIn?.parameterTree)
        XCTAssertEqual(tree.parameter(withAddress: AUParameterAddress(ISD_P_MOOD_SPACE))?.value ?? 0, Float(Mood.serene.space), accuracy: 1e-5)
    }

    func testPatchesApply() async throws {
        let e = try await makeEngine()
        let lullaby = try XCTUnwrap(PatchLibrary.all.first { $0.id == "lullaby" })
        e.loadedBuiltIn?.apply(lullaby)
        let tree = try XCTUnwrap(e.loadedBuiltIn?.parameterTree)
        XCTAssertEqual(Double(tree.parameter(withAddress: AUParameterAddress(ISD_P_FELT))?.value ?? 0), lullaby.values["felt"] ?? -1, accuracy: 1e-5)
        XCTAssertEqual(e.loadedBuiltIn?.patchID, "lullaby")
    }
}
