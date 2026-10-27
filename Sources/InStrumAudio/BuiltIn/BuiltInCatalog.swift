import AVFoundation
import AudioToolbox
import InStrumCore
import InStrumDSP

/// The app's own instruments, registered in-process so they load exactly like installed plugins.
public enum BuiltInCatalog {
    public static let manufacturer: OSType = fourCC("IsMt")
    public static let manufacturerName = "In Strum Meants"

    public static func description(for engine: BuiltInEngine) -> AudioComponentDescription {
        AudioComponentDescription(componentType: kAudioUnitType_MusicDevice,
                                  componentSubType: engine == .feltGlass ? fourCC("isFG") : fourCC("isOP"),
                                  componentManufacturer: manufacturer, componentFlags: 0, componentFlagsMask: 0)
    }

    /// The ambience generator (Task 7).
    public static let ambienceDescription = AudioComponentDescription(componentType: kAudioUnitType_Generator,
                                                                      componentSubType: fourCC("isAM"),
                                                                      componentManufacturer: manufacturer,
                                                                      componentFlags: 0, componentFlagsMask: 0)

    /// Safe to call any number of times.
    public static func registerAll() { _ = registration }

    private static let registration: Void = {
        for engine in available {
            AUAudioUnit.registerSubclass(BuiltInInstrumentAU.self, as: description(for: engine),
                                         name: "\(manufacturerName): \(engine.displayName)", version: 1)
        }
    }()

    /// Engines the Sound Core can make right now.
    static var available: [BuiltInEngine] {
        BuiltInEngine.allCases.filter { isd_synth_param_count(isdEngine($0)) > 0 }
    }

    /// Picker entries for the built-in instruments.
    public static var instruments: [PluginInfo] {
        available.map { engine in
            let d = description(for: engine)
            return PluginInfo(id: "\(d.componentType)-\(d.componentSubType)-\(d.componentManufacturer)",
                              name: engine.displayName, manufacturer: manufacturerName, description: d)
        }
    }

    public static func engine(for choice: InstrumentChoice) -> BuiltInEngine? {
        guard choice.componentManufacturer == manufacturer, choice.componentType == kAudioUnitType_MusicDevice else { return nil }
        return BuiltInEngine.allCases.first { description(for: $0).componentSubType == choice.componentSubType }
    }

    static func engine(forSubType subType: OSType) -> BuiltInEngine? {
        BuiltInEngine.allCases.first { description(for: $0).componentSubType == subType }
    }

    static func isdEngine(_ engine: BuiltInEngine) -> ISDEngine {
        engine == .feltGlass ? ISD_ENGINE_FELT_GLASS : ISD_ENGINE_ORBIT_PAD
    }

    static func fourCC(_ s: String) -> OSType {
        s.utf8.reduce(0) { ($0 << 8) | OSType($1) }
    }
}
