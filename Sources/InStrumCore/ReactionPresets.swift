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
}
