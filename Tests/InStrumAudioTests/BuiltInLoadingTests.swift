import XCTest
import AVFoundation
@testable import InStrumAudio
@testable import InStrumCore
import InStrumDSP

/// Synchronous loading paths for the built-in Audio Unit.
final class BuiltInLoadingTests: XCTestCase {
    func testA_RegisterIsIdempotent() {
        BuiltInCatalog.registerAll()
        BuiltInCatalog.registerAll()
    }

    func testB_DirectInstantiation() throws {
        let au = try BuiltInInstrumentAU(componentDescription: BuiltInCatalog.description(for: .feltGlass), options: [])
        let count = au.parameterTree?.allParameters.count ?? 0
        XCTAssertEqual(count, 13)
    }

    func testC_CallbackInstantiation() {
        BuiltInCatalog.registerAll()
        let done = expectation(description: "instantiated")
        var ok = false
        AVAudioUnit.instantiate(with: BuiltInCatalog.description(for: .feltGlass), options: []) { unit, error in
            ok = unit?.auAudioUnit is BuiltInInstrumentAU && error == nil
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertTrue(ok)
    }

    func testD_OrbitPadShowsDialsButNotTestHooks() throws {
        let au = try BuiltInInstrumentAU(componentDescription: BuiltInCatalog.description(for: .orbitPad), options: [])
        let ids = Set(au.parameterTree?.allParameters.map(\.identifier) ?? [])
        XCTAssertEqual(ids, ["fineTune", "transpose", "space", "bloom", "drift", "motion", "shimmer", "brightness",
                             "moodEnergy", "moodWarmth", "moodBrightness", "moodSpace", "moodMotion"])
        XCTAssertNil(au.parameterTree?.parameter(withAddress: AUParameterAddress(ISD_P_DEBUG_LAYER_A_ONLY)))
    }

    func testE_HoneyTapeShowsDialsButNotTestHooks() throws {
        let au = try BuiltInInstrumentAU(componentDescription: BuiltInCatalog.description(for: .honeyTape), options: [])
        let ids = Set(au.parameterTree?.allParameters.map(\.identifier) ?? [])
        XCTAssertEqual(ids, ["fineTune", "transpose", "breath", "strings", "wow", "age", "reel", "space", "width",
                             "moodEnergy", "moodWarmth", "moodBrightness", "moodSpace", "moodMotion"])
        XCTAssertNil(au.parameterTree?.parameter(withAddress: AUParameterAddress(ISD_P_DEBUG_NO_VIBRATO)))
    }

    func testF_HazeBellsShowsItsDials() throws {
        let au = try BuiltInInstrumentAU(componentDescription: BuiltInCatalog.description(for: .hazeBells), options: [])
        let ids = Set(au.parameterTree?.allParameters.map(\.identifier) ?? [])
        XCTAssertEqual(ids, ["fineTune", "transpose", "bells", "organ", "echo", "crush", "drift", "space",
                             "moodEnergy", "moodWarmth", "moodBrightness", "moodSpace", "moodMotion"])
    }

    func testG_CabinFeltShowsDialsButNotTestHooks() throws {
        let au = try BuiltInInstrumentAU(componentDescription: BuiltInCatalog.description(for: .cabinFelt), options: [])
        let ids = Set(au.parameterTree?.allParameters.map(\.identifier) ?? [])
        XCTAssertEqual(ids, ["fineTune", "transpose", "felt", "horn", "fire", "wood", "space", "width",
                             "moodEnergy", "moodWarmth", "moodBrightness", "moodSpace", "moodMotion"])
        XCTAssertFalse(ids.contains { $0.hasPrefix("debug") })
        XCTAssertNil(au.parameterTree?.parameter(withAddress: AUParameterAddress(ISD_P_DEBUG_NO_MECHANICS)))
        XCTAssertNil(au.parameterTree?.parameter(withAddress: AUParameterAddress(ISD_P_DEBUG_HORN_ONLY)))
    }

    func testH_MorningBoxShowsDialsButNotTestHooks() throws {
        let au = try BuiltInInstrumentAU(componentDescription: BuiltInCatalog.description(for: .morningBox), options: [])
        let ids = Set(au.parameterTree?.allParameters.map(\.identifier) ?? [])
        XCTAssertEqual(ids, ["fineTune", "transpose", "bars", "box", "bloom", "build", "haze", "space", "width",
                             "moodEnergy", "moodWarmth", "moodBrightness", "moodSpace", "moodMotion"])
        XCTAssertFalse(ids.contains { $0.hasPrefix("debug") })
        XCTAssertNil(au.parameterTree?.parameter(withAddress: AUParameterAddress(ISD_P_DEBUG_BOX_ONLY)))
        XCTAssertNil(au.parameterTree?.parameter(withAddress: AUParameterAddress(ISD_P_DEBUG_WALL_ONLY)))
    }

    func testI_PolarChoirShowsDialsButNotTestHooks() throws {
        let au = try BuiltInInstrumentAU(componentDescription: BuiltInCatalog.description(for: .polarChoir), options: [])
        let ids = Set(au.parameterTree?.allParameters.map(\.identifier) ?? [])
        XCTAssertEqual(ids, ["fineTune", "transpose", "vowel", "breath", "glass", "swell", "shimmer", "space", "width",
                             "moodEnergy", "moodWarmth", "moodBrightness", "moodSpace", "moodMotion"])
        XCTAssertFalse(ids.contains { $0.hasPrefix("debug") })
        XCTAssertNil(au.parameterTree?.parameter(withAddress: AUParameterAddress(ISD_P_DEBUG_VOICES_ONLY)))
    }

    func testJ_PlanktonKeysShowsDialsButNotTestHooks() throws {
        let au = try BuiltInInstrumentAU(componentDescription: BuiltInCatalog.description(for: .planktonKeys), options: [])
        let ids = Set(au.parameterTree?.allParameters.map(\.identifier) ?? [])
        XCTAssertEqual(ids, ["fineTune", "transpose", "tine", "bark", "sparkle", "tremolo", "phase", "space", "width",
                             "moodEnergy", "moodWarmth", "moodBrightness", "moodSpace", "moodMotion"])
        XCTAssertFalse(ids.contains { $0.hasPrefix("debug") })
        XCTAssertNil(au.parameterTree?.parameter(withAddress: AUParameterAddress(ISD_P_DEBUG_NO_SPARKLE)))
        XCTAssertNil(au.parameterTree?.parameter(withAddress: AUParameterAddress(ISD_P_DEBUG_NO_TREMOLO)))
    }
}
