import Foundation

/// The instrument plugin the user chose, plus its saved state (e.g. which preset).
public struct InstrumentChoice: Codable, Equatable {
    public var name: String
    public var componentType: UInt32
    public var componentSubType: UInt32
    public var componentManufacturer: UInt32
    /// The plugin's full state as a binary property list.
    public var stateData: Data?

    public init(name: String, componentType: UInt32, componentSubType: UInt32,
                componentManufacturer: UInt32, stateData: Data? = nil) {
        self.name = name
        self.componentType = componentType
        self.componentSubType = componentSubType
        self.componentManufacturer = componentManufacturer
        self.stateData = stateData
    }
}

public struct AppSettings: Codable, Equatable {
    public var instrument: InstrumentChoice?
    public var themeID: String = "midnight-steinway"
    public var masterVolume: Float = 0.8
    public var touchCurve: TouchCurve = .normal
    /// Audio output buffer in frames: 128 (fastest), 256 (balanced), 512 (safest).
    public var bufferFrames: UInt32 = 256
    public var themeStates: [String: ThemeState] = [:]
    /// Smooth (lite) by default: fastest and lowest latency; raise it in Display → Quality.
    public var quality: QualitySetting = .lite
    /// 2 = saved after the performance fix (older files start on Smooth once).
    public var qualityVersion: Int = 2
    public var gentleVisuals: Bool = false
    /// The active reaction style; nil means the built-in named by `reactionName`.
    public var reaction: ReactionMap?
    public var reactionName: String = "Expressive Pianist"
    public var sky = SkySettings()
    public var ambience = AmbienceSettings()
    /// The Set (world + visual + instrument + ambience) last chosen, if any.
    public var activeSetID: String?

    public static let `default` = AppSettings()

    public init() {}

    enum CodingKeys: String, CodingKey { case instrument, themeID, masterVolume, touchCurve, bufferFrames, themeStates, quality, gentleVisuals, reaction, reactionName, qualityVersion }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        instrument = try c.decodeIfPresent(InstrumentChoice.self, forKey: .instrument)
        themeID = try c.decodeIfPresent(String.self, forKey: .themeID) ?? d.themeID
        masterVolume = try c.decodeIfPresent(Float.self, forKey: .masterVolume) ?? d.masterVolume
        touchCurve = (try? c.decodeIfPresent(TouchCurve.self, forKey: .touchCurve)) ?? d.touchCurve
        bufferFrames = try c.decodeIfPresent(UInt32.self, forKey: .bufferFrames) ?? d.bufferFrames
        themeStates = (try? c.decodeIfPresent([String: ThemeState].self, forKey: .themeStates)) ?? d.themeStates
        quality = (try? c.decodeIfPresent(QualitySetting.self, forKey: .quality)) ?? d.quality
        qualityVersion = (try? c.decodeIfPresent(Int.self, forKey: .qualityVersion)) ?? 1
        if qualityVersion < 2 { quality = .lite; qualityVersion = 2 }
        gentleVisuals = (try? c.decodeIfPresent(Bool.self, forKey: .gentleVisuals)) ?? d.gentleVisuals
        reaction = try? c.decodeIfPresent(ReactionMap.self, forKey: .reaction)
        reactionName = (try? c.decodeIfPresent(String.self, forKey: .reactionName)) ?? d.reactionName
    }
}

/// Reads and writes settings.json. Never throws on load.
public final class SettingsStore {
    private let directory: URL
    private var fileURL: URL { directory.appendingPathComponent("settings.json") }
    private var corruptURL: URL { directory.appendingPathComponent("settings.corrupt.json") }

    public init(directory: URL) { self.directory = directory }

    public func load() -> AppSettings {
        guard let data = try? Data(contentsOf: fileURL) else { return .default }
        if let settings = try? JSONDecoder().decode(AppSettings.self, from: data) { return settings }
        let fm = FileManager.default
        try? fm.removeItem(at: corruptURL)
        try? fm.moveItem(at: fileURL, to: corruptURL)
        return .default
    }

    public func save(_ settings: AppSettings) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: fileURL, options: .atomic)
    }
}
