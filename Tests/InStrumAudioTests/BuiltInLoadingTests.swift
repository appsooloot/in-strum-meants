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

    func testL_ZenShakuhachiShowsDialsButNotTestHooks() throws {
        let au = try BuiltInInstrumentAU(componentDescription: BuiltInCatalog.description(for: .zenShakuhachi), options: [])
        XCTAssertEqual(au.engine, .zenShakuhachi)
        let ids = Set(au.parameterTree?.allParameters.map(\.identifier) ?? [])
        XCTAssertEqual(ids, ["fineTune", "transpose", "breath", "air", "bend", "bamboo", "yuri", "echo", "space", "width",
                             "moodEnergy", "moodWarmth", "moodBrightness", "moodSpace", "moodMotion"])
        XCTAssertFalse(ids.contains { $0.hasPrefix("debug") })
        XCTAssertNil(au.parameterTree?.parameter(withAddress: AUParameterAddress(ISD_P_DEBUG_TONE_ONLY)))
        XCTAssertNil(au.parameterTree?.parameter(withAddress: AUParameterAddress(ISD_P_DEBUG_NO_FOLD)))
        // A fresh shakuhachi is its default preset, Zen Shakuhachi (spec §4.4: the dials' defaults are that preset's values).
        let preset = PatchLibrary.defaultPatch(for: .zenShakuhachi)
        XCTAssertEqual(preset.id, "zen-shakuhachi")
        XCTAssertEqual(Set(preset.values.keys), ["breath", "air", "bend", "bamboo", "yuri", "echo", "space", "width"])
        for p in au.parameterTree?.allParameters ?? [] {
            guard let value = preset.values[p.identifier] else { continue }
            XCTAssertEqual(Double(p.value), value, accuracy: 1e-6, p.identifier)
        }
    }

    func testM_ReefMarimbaShowsDialsButNotTestHooks() throws {
        let au = try BuiltInInstrumentAU(componentDescription: BuiltInCatalog.description(for: .reefMarimba), options: [])
        XCTAssertEqual(au.engine, .reefMarimba)
        let ids = Set(au.parameterTree?.allParameters.map(\.identifier) ?? [])
        XCTAssertEqual(ids, ["fineTune", "transpose", "mallet", "strike", "tube", "roll", "steel", "space", "width",
                             "moodEnergy", "moodWarmth", "moodBrightness", "moodSpace", "moodMotion"])
        XCTAssertFalse(ids.contains { $0.hasPrefix("debug") })
        XCTAssertNil(au.parameterTree?.parameter(withAddress: AUParameterAddress(ISD_P_DEBUG_NO_ROLL)))
        XCTAssertNil(au.parameterTree?.parameter(withAddress: AUParameterAddress(ISD_P_DEBUG_BAR_ONLY)))
        // A fresh marimba is its default preset, Reef Marimba (spec §4.4: the dials' defaults are that preset's values),
        // and every dial the preset sets is one the marimba shows.
        let preset = PatchLibrary.defaultPatch(for: .reefMarimba)
        XCTAssertEqual(preset.id, "reef-marimba")
        XCTAssertTrue(Set(preset.values.keys).isSubset(of: ids), "\(preset.values.keys.sorted())")
        for p in au.parameterTree?.allParameters ?? [] {
            guard let value = preset.values[p.identifier] else { continue }
            XCTAssertEqual(Double(p.value), value, accuracy: 1e-6, p.identifier)
        }
    }
}
