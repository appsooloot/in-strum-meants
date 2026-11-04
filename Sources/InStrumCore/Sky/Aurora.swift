import Foundation

/// How a world shows the aurora: the real (simulated) activity, always on, or never.
public enum AuroraMode: String, Codable, CaseIterable {
    case follow = "Follow the sky", always = "Always", never = "Never"

    /// The world parameter that chooses it (a world parameter, so leaving the world leaves its aurora behind).
    public static func spec(default d: AuroraMode) -> ParamSpec {
        ParamSpec(id: "aurora.mode", name: "Aurora", group: "Sky",
                  help: "Follow the sky (the aurora comes and goes with the activity and your city's latitude), always show it, or never",
                  kind: .choice(allCases.map(\.rawValue)), defaultValue: .choice(d.rawValue))
    }
}

/// The aurora's activity over time (seeded, deterministic): a slow Kp index 0…9 wandering about 2.5 with a
/// 6–18 h correlation time, and substorms (a 1 min onset, a 3–8 min expansion with rays, a slow recovery) that
/// come every 20–60 min while Kp ≥ 3. "Always" holds Kp at 6 with a substorm every 8–12 min and the band 25–60° up.
public struct AuroraMachine {
    public static let meanKp = 2.5
    /// The stationary spread of Kp about its mean.
    static let kpSpread = 1.6

    /// The follow-mode activity (it keeps wandering whatever the mode, so switching back never jumps).
    public private(set) var kp: Double
    private var tau: Double, tauLeft: Double
    private var rng: SeededRandom

    // The substorm in progress (age ≥ 0), its shape, and the countdown to the next onset.
    private var stormAge = -1.0, stormLength = 600.0, stormExpansion = 300.0
    private var nextStorm: Double
    private var lastMode = AuroraMode.follow
    /// "Always": the band's altitude wanders slowly between 25° and 60°.
    private var wander: Double

    public init(seed: UInt64) {
        rng = SeededRandom(seed: seed &* 0xD1B5_4A32_D192_ED03 &+ 0xA0A0)
        kp = 0; tau = 0; tauLeft = 0; nextStorm = 0; wander = 0
        let noise = gauss()
        kp = min(9, max(0, Self.meanKp + Self.kpSpread * noise))
        tau = Double(rng.range(6, 18)) * 3600; tauLeft = tau
        nextStorm = Double(rng.range(20, 60)) * 60
        wander = Double(rng.unit()) * 2 * .pi
    }

    /// The oval's equatorward edge (geomagnetic ≈ geographic latitude here), degrees.
    public static func edgeLatitude(kp: Double) -> Double { 67 - 3.2 * kp }

    /// Where the band's base sits above the pole-ward horizon, degrees: overhead (90) at or pole-ward of the edge;
    /// equatorward of it, the elevation of glow 120 km up seen across the gap over the curved Earth (about 45° one
    /// degree of latitude away, 15° at three, 6° at seven, below the horizon from about nine).
    public static func bandAltitude(latitude: Double, kp: Double) -> Double {
        let gap = edgeLatitude(kp: kp) - abs(latitude)
        guard gap > 0 else { return 90 }
        let d = gap * 111.2                                   // km along the ground
        let rise = emissionHeight - d * d / (2 * 6371)        // the glow's height above the local horizon plane
        return min(90, max(0, atan2(rise, d) * 180 / .pi))
    }

    /// The height of the green glow (km).
    static let emissionHeight = 120.0

    /// How bright the aurora is at this latitude and activity, 0…1 (before night, cloud and mist).
    public static func brightness(latitude: Double, kp: Double) -> Double {
        let gap = edgeLatitude(kp: kp) - abs(latitude)
        return smoothstep(0, 2, kp - gap / 8)
    }

    /// Advances by `dt` seconds: the activity, the substorm envelope (0…1), the band altitude (degrees) and how
    /// visible it is (0…1; it fades out as the band sinks below 2°).
    public mutating func step(dt rawDt: Double, mode: AuroraMode, latitude: Double) -> (kp: Double, storm: Float, altitude: Float, visible: Float) {
        let dt = max(0, rawDt)
        // Kp: an Ornstein–Uhlenbeck walk about the mean, its correlation time re-rolled every spell.
        tauLeft -= dt
        if tauLeft <= 0 { tau = Double(rng.range(6, 18)) * 3600; tauLeft += tau }
        if dt > 0 {
            let k = min(1, dt / tau)
            let noise = gauss()
            kp = min(9, max(0, kp - (kp - Self.meanKp) * k + Self.kpSpread * (2 * k).squareRoot() * noise))
        }
        wander += dt * 2 * .pi / 1500   // a 25-minute sway
        if mode != lastMode {
            if mode == .always { nextStorm = min(nextStorm, Double(rng.range(0.5, 2)) * 60) }
            lastMode = mode
        }

        let activity: Double
        switch mode {
        case .follow: activity = kp
        case .always: activity = 6
        case .never: activity = 0
        }

        // Substorms: onset to onset every 20–60 min (8–12 in "Always") while the activity is 3 or more.
        if stormAge >= 0 {
            stormAge += dt
            if stormAge >= stormLength { stormAge = -1 }
        }
        if activity >= 3 {
            nextStorm -= dt
            if nextStorm <= 0 {
                let gap = mode == .always ? Double(rng.range(8, 12)) * 60 : Double(rng.range(20, 60)) * 60
                stormExpansion = Double(rng.range(3, 8)) * 60
                stormLength = max(60 + stormExpansion + 60, Double(rng.range(5, 15)) * 60)
                stormLength = min(stormLength, gap - 30)
                stormExpansion = min(stormExpansion, stormLength - 90)
                stormAge = 0
                nextStorm += gap
                if nextStorm <= 0 { nextStorm = gap }
            }
        }
        let storm: Float = mode == .never ? 0 : Float(Self.envelope(age: stormAge, expansion: stormExpansion, length: stormLength))

        switch mode {
        case .never:
            return (0, 0, 0, 0)
        case .always:
            let altitude = 42.5 + 17.5 * sin(wander)
            return (6, storm, Float(altitude), 1)
        case .follow:
            let altitude = Self.bandAltitude(latitude: latitude, kp: kp)
            let visible = Self.brightness(latitude: latitude, kp: kp) * Self.smoothstep(0, 2, altitude)
            return (kp, storm, Float(altitude), Float(visible))
        }
    }

    /// The substorm's 0…1 shape: a 1-minute onset to 0.5, an expansion to 1, then a slow recovery to 0.
    static func envelope(age: Double, expansion: Double, length: Double) -> Double {
        guard age >= 0, age < length else { return 0 }
        if age < 60 { return 0.5 * smoothstep(0, 60, age) }
        let peak = 60 + expansion
        if age < peak { return 0.5 + 0.5 * smoothstep(60, peak, age) }
        let x = (age - peak) / max(1, length - peak)
        return (1 - x) * (1 - x)
    }

    static func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = min(1, max(0, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    /// A standard normal draw (Box–Muller).
    private mutating func gauss() -> Double {
        let u1 = max(1e-7, Double(rng.unit())), u2 = Double(rng.unit())
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}
