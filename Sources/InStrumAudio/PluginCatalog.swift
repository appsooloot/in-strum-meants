import AVFoundation
import AudioToolbox
import InStrumCore

/// An installed instrument plugin (Audio Unit music device).
public struct PluginInfo: Identifiable, Equatable {
    public let id: String
    public let name: String
    public let manufacturer: String
    public let description: AudioComponentDescription

    public static func == (a: PluginInfo, b: PluginInfo) -> Bool { a.id == b.id }

    /// The settings record for choosing this plugin (no saved state yet).
    public func choice() -> InstrumentChoice {
        InstrumentChoice(name: name,
                         componentType: description.componentType,
                         componentSubType: description.componentSubType,
                         componentManufacturer: description.componentManufacturer)
    }
}

public enum PluginCatalog {
    /// Every installed instrument plugin, sorted by manufacturer then name.
    public static func instruments() -> [PluginInfo] {
        var match = AudioComponentDescription()
        match.componentType = kAudioUnitType_MusicDevice
        return AVAudioUnitComponentManager.shared().components(matching: match)
            .filter { $0.audioComponentDescription.componentType == kAudioUnitType_MusicDevice }
            .map { c in
                let d = c.audioComponentDescription
                return PluginInfo(id: "\(d.componentType)-\(d.componentSubType)-\(d.componentManufacturer)",
                                  name: c.name, manufacturer: c.manufacturerName, description: d)
            }
            .sorted { ($0.manufacturer.lowercased(), $0.name.lowercased()) < ($1.manufacturer.lowercased(), $1.name.lowercased()) }
    }

    static func component(for choice: InstrumentChoice) -> AVAudioUnitComponent? {
        var d = AudioComponentDescription()
        d.componentType = choice.componentType
        d.componentSubType = choice.componentSubType
        d.componentManufacturer = choice.componentManufacturer
        return AVAudioUnitComponentManager.shared().components(matching: d).first
    }
}
