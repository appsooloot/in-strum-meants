/// Built-in reaction styles. They target roles, so each feels right in every theme.
public enum ReactionPresets {
    private static func l(_ i: InputID, _ t: Target, _ a: Double, _ c: Curve = .linear) -> Link {
        Link(input: i, target: t, amount: a, curve: c)
    }

    /// Default: touch, holds and pedal lead everything.
    public static let expressivePianist = ReactionMap(links: [
        l(.velocity, .role(.energy), 1),
        l(.velocity, .role(.size), 0.8),
        l(.held, .role(.linger), 0.3),
        l(.pedal, .role(.linger), 0.9),
        l(.softPedal, .role(.brightness), -0.4),
        l(.modWheel, .param("wings.iridescence"), 0.8),
        l(.pitchBend, .role(.direction), 1),
        l(.pressure, .role(.energy), 0.4),
        l(.releaseSpeed, .role(.motion), 0.5),
        l(.busyness, .role(.chaos), 0.8),
        l(.busyness, .role(.density), 0.6),
        l(.direction, .role(.direction), 0.5),
        l(.leap, .role(.motion), 0.4),
        l(.crescendo, .role(.brightness), 0.6),
        l(.spread, .role(.size), 0.3),
        l(.silence, .role(.chaos), -0.5),
        l(.chordMajor, .role(.warmth), 0.5),
        l(.chordMinor, .role(.warmth), -0.5),
        l(.chordTense, .role(.chaos), 0.3),
        l(.attack, .role(.motion), 0.6),
        l(.brightness, .role(.warmth), -0.6),
        l(.ring, .role(.linger), 0.5),
        l(.texture, .role(.atmosphere), 0.8),
        l(.loudness, .role(.energy), 0.5),
        l(.bass, .role(.atmosphere), 0.3),
        l(.beat, .role(.energy), 0.3),
        l(.level, .role(.brightness), 0.2),
    ])

    /// Slow, smooth, gentle; the sound's character shapes the mood.
    public static let calmAmbient = ReactionMap(links: [
        l(.velocity, .role(.energy), 0.5, .gentle),
        l(.held, .role(.linger), 0.6),
        l(.pedal, .role(.linger), 1),
        l(.busyness, .role(.motion), 0.2, .gentle),
        l(.ring, .role(.linger), 0.7),
        l(.texture, .role(.atmosphere), 1),
        l(.brightness, .role(.warmth), -0.4),
        l(.chordMajor, .role(.warmth), 0.4),
        l(.chordMinor, .role(.warmth), -0.4),
        l(.silence, .role(.chaos), -0.8),
        l(.loudness, .role(.brightness), 0.4, .gentle),
        l(.bass, .role(.atmosphere), 0.2, .gentle),
    ], groupStrength: [.keys: 0.7])

    /// The sound itself leads: sharp, bright and textured synths reshape the scene.
    public static let synthExplorer = ReactionMap(links: [
        l(.attack, .role(.motion), 1, .snappy),
        l(.attack, .role(.chaos), 0.5),
        l(.brightness, .role(.warmth), -1),
        l(.brightness, .role(.brightness), 0.6),
        l(.ring, .role(.linger), 1),
        l(.texture, .role(.atmosphere), 1),
        l(.texture, .role(.density), 0.5),
        l(.loudness, .role(.energy), 0.9),
        l(.width, .role(.size), 0.6),
        l(.velocity, .role(.energy), 0.4),
        l(.modWheel, .role(.colorShift), 1),
        l(.pitchBend, .role(.direction), 1),
        l(.pedal, .role(.linger), 0.6),
    ], groupStrength: [.sound: 1])

    /// Spotify/YouTube beat and bass drive energy and density.
    public static let musicParty = ReactionMap(links: [
        l(.beat, .role(.energy), 1, .snappy),
        l(.bass, .role(.size), 0.8),
        l(.bass, .role(.atmosphere), 0.5),
        l(.treble, .role(.density), 0.8),
        l(.mid, .role(.brightness), 0.6),
        l(.level, .role(.motion), 0.7),
        l(.beat, .role(.chaos), 0.4),
        l(.velocity, .role(.energy), 0.6),
        l(.pedal, .role(.linger), 0.6),
    ], groupStrength: [.listening: 1])

    /// Just notes and touch. Very clean.
    public static let minimal = ReactionMap(links: [
        l(.velocity, .role(.energy), 1),
        l(.velocity, .role(.size), 0.6),
        l(.pedal, .role(.linger), 0.8),
    ])

    /// Everything turned up; chaos welcome.
    public static let wild = ReactionMap(links: [
        l(.velocity, .role(.energy), 1, .snappy),
        l(.velocity, .role(.size), 1),
        l(.busyness, .role(.chaos), 1, .snappy),
        l(.busyness, .role(.density), 1),
        l(.leap, .role(.motion), 1),
        l(.attack, .role(.motion), 1),
        l(.crescendo, .role(.brightness), 1),
        l(.pitchBend, .role(.direction), 1),
        l(.modWheel, .role(.colorShift), 1),
        l(.chordTense, .role(.chaos), 1),
        l(.beat, .role(.energy), 0.8),
        l(.bass, .role(.size), 0.6),
        l(.pedal, .role(.linger), 1),
        l(.texture, .role(.atmosphere), 1),
    ])

    public static let all: [ReactionPreset] = [
        ReactionPreset(name: "Expressive Pianist", map: expressivePianist),
        ReactionPreset(name: "Calm Ambient", map: calmAmbient),
        ReactionPreset(name: "Synth Explorer", map: synthExplorer),
        ReactionPreset(name: "Music Party", map: musicParty),
        ReactionPreset(name: "Minimal", map: minimal),
        ReactionPreset(name: "Wild", map: wild),
    ]
}
