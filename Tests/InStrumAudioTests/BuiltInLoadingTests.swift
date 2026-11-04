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

    func testK_TeaHouseKotoShowsDialsButNotTestHooks() throws {
        let au = try BuiltInInstrumentAU(componentDescription: BuiltInCatalog.description(for: .teaHouseKoto), options: [])
        XCTAssertEqual(au.engine, .teaHouseKoto)
        let ids = Set(au.parameterTree?.allParameters.map(\.identifier) ?? [])
        XCTAssertEqual(ids, ["fineTune", "transpose", "pick", "silk", "body", "bloom", "yuri", "space", "width",
                             "moodEnergy", "moodWarmth", "moodBrightness", "moodSpace", "moodMotion"])
        XCTAssertFalse(ids.contains { $0.hasPrefix("debug") })
        XCTAssertNil(au.parameterTree?.parameter(withAddress: AUParameterAddress(ISD_P_DEBUG_NO_SYMPATHY)))
        XCTAssertNil(au.parameterTree?.parameter(withAddress: AUParameterAddress(ISD_P_DEBUG_NO_BODY)))
        // A fresh koto is its default preset, Tea House Koto (spec §4.2: the dials' defaults are that preset's values).
        let preset = PatchLibrary.defaultPatch(for: .teaHouseKoto)
        XCTAssertEqual(preset.id, "tea-house-koto")
        for p in au.parameterTree?.allParameters ?? [] {
            guard let value = preset.values[p.identifier] else { continue }
            XCTAssertEqual(Double(p.value), value, accuracy: 1e-6, p.identifier)
        }
    }

    func testN_BlueDepthShowsDialsButNotTestHooks() throws {
        let au = try BuiltInInstrumentAU(componentDescription: BuiltInCatalog.description(for: .blueDepth), options: [])
        XCTAssertEqual(au.engine, .blueDepth)
        XCTAssertEqual(BuiltInCatalog.description(for: .blueDepth).componentSubType, BuiltInCatalog.fourCC("isBD"))
        XCTAssertEqual(BuiltInCatalog.isdEngine(.blueDepth).rawValue, ISD_ENGINE_BLUE_DEPTH.rawValue)
        let params = au.parameterTree?.allParameters ?? []
        let ids = Set(params.map(\.identifier))
        XCTAssertEqual(ids, ["fineTune", "transpose", "blink", "murk", "ghosts", "echo", "bass", "tempo", "space", "width",
                             "moodEnergy", "moodWarmth", "moodBrightness", "moodSpace", "moodMotion"])
        XCTAssertFalse(ids.contains { $0.hasPrefix("debug") })
        XCTAssertNil(au.parameterTree?.parameter(withAddress: AUParameterAddress(ISD_P_DEBUG_NO_ARP)))
        XCTAssertNil(au.parameterTree?.parameter(withAddress: AUParameterAddress(ISD_P_DEBUG_DRY)))
        // The dials in their order (spec §4.2), Tempo in BPM over 70…160.
        let dials = params.map(\.identifier).filter { !Mood.parameterIdentifiers.contains($0) && $0 != "fineTune" && $0 != "transpose" }
        XCTAssertEqual(dials, ["blink", "murk", "ghosts", "echo", "bass", "tempo", "space", "width"])
        let tempo = au.parameterTree?.parameter(withAddress: AUParameterAddress(ISD_P_TEMPO))
        XCTAssertEqual(tempo?.minValue, 70)
        XCTAssertEqual(tempo?.maxValue, 160)
        // A fresh Blue Depth is its default preset, Blue Depth (spec §4.2: the dials' defaults are that preset's values).
        let preset = PatchLibrary.defaultPatch(for: .blueDepth)
        XCTAssertEqual(preset.id, "blue-depth")
        XCTAssertEqual(Set(preset.values.keys), Set(dials))
        for p in params {
            guard let value = preset.values[p.identifier] else { continue }
            XCTAssertEqual(Double(p.value), value, accuracy: 1e-6, p.identifier)
        }
    }
}
