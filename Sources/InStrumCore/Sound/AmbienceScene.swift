/// The ambience sources a world can blend (spec §5).
public enum AmbienceSource: String, Codable, CaseIterable {
    case water, crickets, breeze, owl, rainOnWater, rainOnGlass, dawnChorus, shipHum, airFlow, chime, hullTicks, wind
}

/// What a world wants to hear right now. Levels are 0…1; anything missing is silent.
public struct AmbienceScene: Equatable {
    public var levels: [AmbienceSource: Double]
    /// 0 warm early night … 1 cool late night.
    public var nightCool: Double
    /// 0…1 while playing: the ambience ducks under the instrument.
    public var activity: Double
    /// One-shot: thunder at this distance (0 near … 1 far).
    public var thunder: Double?
    /// 0 distant … 1 all around you (the user's setting with the mood on top).
    public var closeness: Double
    /// 0.5…1.5: how often things happen (from the mood's energy).
    public var density: Double

    public init(levels: [AmbienceSource: Double] = [:], nightCool: Double = 0, activity: Double = 0, thunder: Double? = nil,
                closeness: Double = 0.5, density: Double = 1) {
        self.levels = levels
        self.nightCool = nightCool
        self.activity = activity
        self.thunder = thunder
        self.closeness = closeness
        self.density = density
    }

    public static let silent = AmbienceScene()

    public func level(_ source: AmbienceSource) -> Double { levels[source] ?? 0 }
}

/// The user's ambience controls (persisted).
public struct AmbienceSettings: Codable, Equatable {
    public var enabled = true
    /// 0…1 (default 25%).
    public var volume: Double = 0.25
    /// 0 distant … 1 all around you.
    public var closeness: Double = 0.5

    public init() {}

    enum CodingKeys: String, CodingKey { case enabled, volume, closeness }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AmbienceSettings()
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? d.enabled
        volume = min(1, max(0, (try? c.decodeIfPresent(Double.self, forKey: .volume)) ?? d.volume))
        closeness = min(1, max(0, (try? c.decodeIfPresent(Double.self, forKey: .closeness)) ?? d.closeness))
    }
}
