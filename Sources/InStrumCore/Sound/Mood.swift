/// The feeling a set shares across its world, visual, instrument and ambience. Each value 0…1; 0.5 is neutral.
public struct Mood: Codable, Equatable {
    public var energy, warmth, brightness, space, motion: Double

    public init(energy: Double, warmth: Double, brightness: Double, space: Double, motion: Double) {
        self.energy = energy; self.warmth = warmth; self.brightness = brightness; self.space = space; self.motion = motion
    }

    public static let neutral = Mood(energy: 0.5, warmth: 0.5, brightness: 0.5, space: 0.5, motion: 0.5)
    /// Moonlit Lake.
    public static let serene = Mood(energy: 0.2, warmth: 0.45, brightness: 0.3, space: 0.85, motion: 0.25)
    /// Spaceship Lounge.
    public static let dreamy = Mood(energy: 0.35, warmth: 0.3, brightness: 0.5, space: 0.95, motion: 0.6)

    /// The built-in instruments' hidden mood parameters (Audio Unit identifiers can't contain dots).
    public static let parameterIdentifiers: Set<String> = ["moodEnergy", "moodWarmth", "moodBrightness", "moodSpace", "moodMotion"]

    /// Values keyed by those identifiers.
    public var parameterValues: [String: Double] {
        ["moodEnergy": energy, "moodWarmth": warmth, "moodBrightness": brightness, "moodSpace": space, "moodMotion": motion]
    }
}
