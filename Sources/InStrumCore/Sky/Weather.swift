import Foundation

public enum WeatherKind: String, Codable, CaseIterable { case clear, lightCloud, overcast, mist, drizzle, rain, storm, snow, blizzard, afterRain }

/// Pick one yourself, or let the sky wander through beautiful weathers. (`.real` comes later.)
public enum WeatherMode: String, Codable, CaseIterable { case pick, randomBeautiful }

/// How much of each element a weather has, 0…1.
public struct WeatherValues: Equatable {
    public var cloud, rain, snow, mist, wind: Float
    /// Ice halos and sundogs; frost on glass (some kinds only at night, see `frostFormsOnlyAtNight`); gustiness.
    public var halo: Float = 0, frost: Float = 0, gust: Float = 0

    static func mix(_ a: WeatherValues, _ b: WeatherValues, _ t: Float) -> WeatherValues {
        func m(_ x: Float, _ y: Float) -> Float { x + (y - x) * t }
        return WeatherValues(cloud: m(a.cloud, b.cloud), rain: m(a.rain, b.rain), snow: m(a.snow, b.snow), mist: m(a.mist, b.mist),
                             wind: m(a.wind, b.wind), halo: m(a.halo, b.halo), frost: m(a.frost, b.frost), gust: m(a.gust, b.gust))
    }
}

public extension WeatherKind {
    var values: WeatherValues {
        switch self {
        case .clear: return WeatherValues(cloud: 0, rain: 0, snow: 0, mist: 0.1, wind: 0.1, frost: 0.15)
        case .lightCloud: return WeatherValues(cloud: 0.35, rain: 0, snow: 0, mist: 0.15, wind: 0.2, halo: 0.7, frost: 0.1, gust: 0.1)
        case .overcast: return WeatherValues(cloud: 0.85, rain: 0, snow: 0, mist: 0.25, wind: 0.3, frost: 0.1, gust: 0.1)
        case .mist: return WeatherValues(cloud: 0.4, rain: 0, snow: 0, mist: 0.9, wind: 0.05, halo: 0.15, frost: 0.2)
        case .drizzle: return WeatherValues(cloud: 0.8, rain: 0.3, snow: 0, mist: 0.4, wind: 0.2, gust: 0.1)
        case .rain: return WeatherValues(cloud: 0.9, rain: 0.75, snow: 0, mist: 0.3, wind: 0.4, gust: 0.2)
        case .storm: return WeatherValues(cloud: 1, rain: 1, snow: 0, mist: 0.2, wind: 0.9, gust: 0.6)
        case .snow: return WeatherValues(cloud: 0.85, rain: 0, snow: 0.8, mist: 0.3, wind: 0.25, halo: 0.2, frost: 0.6, gust: 0.2)
        case .blizzard: return WeatherValues(cloud: 1, rain: 0, snow: 1, mist: 0.6, wind: 1, frost: 0.9, gust: 1)
        case .afterRain: return WeatherValues(cloud: 0.45, rain: 0, snow: 0, mist: 0.55, wind: 0.1)
        }
    }

    /// Clear, light-cloud, overcast and misty frost forms only at night (scaled by darkness); snow's any time.
    var frostFormsOnlyAtNight: Bool {
        switch self {
        case .clear, .lightCloud, .overcast, .mist: return true
        default: return false
        }
    }

    /// Drizzle, rain and storms: what "after the rain" follows.
    var isWet: Bool { self == .drizzle || self == .rain || self == .storm }

    /// How often "random beautiful" picks it (overcast only when chosen).
    var beautyWeight: Float {
        switch self {
        case .clear, .lightCloud: return 3
        case .mist: return 2
        case .drizzle, .rain: return 1
        case .storm, .snow: return 0.5
        case .blizzard: return 0.3
        case .afterRain: return 1.5
        case .overcast: return 0
        }
    }
}

/// Weather over time: every change blends over 60 s; random spells last 5–20 minutes and never repeat a kind back to back.
struct WeatherMachine {
    static let transitionSeconds = 60.0

    private(set) var current: WeatherKind
    private(set) var next: WeatherKind
    private(set) var blend = 0.0
    private(set) var transitioning = false
    private var from: WeatherValues
    private var spellLeft: Double
    private var rng: SeededRandom
    private var mode: WeatherMode
    /// Separate streams, so ice and "after the rain" never shift the weather sequence itself.
    private var iceRng: SeededRandom
    private var afterRng: SeededRandom
    /// How icy this light-cloud spell is: 0.5–1 in "Random, beautiful" (rolled per spell), 1 when picked.
    private(set) var ice: Float = 1

    init(settings: SkySettings, seed: UInt64) {
        rng = SeededRandom(seed: seed &* 0x2545_F491_4F6C_DD1D &+ 0xA5)
        iceRng = SeededRandom(seed: seed &* 0x9E37_79B9 &+ 0x1CE)
        afterRng = SeededRandom(seed: seed &* 0xBF58_476D &+ 0xAF7E)
        mode = settings.weatherMode
        let first: WeatherKind
        if settings.weatherMode == .pick { first = settings.weather }
        else { var r = rng; first = Self.pick(excluding: nil, &r); rng = r }
        current = first; next = first; from = first.values
        var r = rng
        spellLeft = Self.spell(&r)
        rng = r
        if mode == .randomBeautiful && first == .lightCloud { ice = iceRng.range(0.5, 1) }
    }

    /// How much of `kind` is in the sky right now (1 when settled on it; shared while blending).
    func weight(of kind: WeatherKind) -> Float {
        guard transitioning else { return current == kind ? 1 : 0 }
        let t = Float(blend), s = t * t * (3 - 2 * t)
        return (current == kind ? 1 - s : 0) + (next == kind ? s : 0)
    }

    var values: WeatherValues {
        guard transitioning else { return current.values }
        let t = Float(blend), s = t * t * (3 - 2 * t)
        return WeatherValues.mix(from, next.values, s)
    }

    mutating func step(dt: Double, settings: SkySettings) {
        if settings.weatherMode != mode {
            mode = settings.weatherMode
            if mode == .pick { ice = 1 }
            spellLeft = Self.spell(&rng)
            if mode == .randomBeautiful { begin(Self.pick(excluding: transitioning ? next : current, &rng)) }
        }
        switch mode {
        case .pick:
            if settings.weather != (transitioning ? next : current) { begin(settings.weather) }
        case .randomBeautiful:
            spellLeft -= dt
            if spellLeft <= 0, !transitioning {
                // After a wet spell, "after the rain" comes next 6 times in 10; otherwise the usual pick (without it).
                if current.isWet && afterRng.unit() < 0.6 { begin(.afterRain) }
                else { begin(Self.pick(excluding: current, also: current.isWet ? .afterRain : nil, &rng)) }
                spellLeft += Self.spell(&rng)
            }
        }
        if transitioning {
            blend += dt / Self.transitionSeconds
            if blend >= 1 { current = next; blend = 0; transitioning = false }
        }
    }

    private mutating func begin(_ kind: WeatherKind) {
        if kind == .lightCloud { ice = mode == .randomBeautiful ? iceRng.range(0.5, 1) : 1 }
        from = values
        next = kind
        blend = 0
        transitioning = kind != current || transitioning
        if !transitioning { next = current }
    }

    private static func spell(_ rng: inout SeededRandom) -> Double { 300 + 900 * Double(rng.unit()) }

    private static func pick(excluding: WeatherKind?, also: WeatherKind? = nil, _ rng: inout SeededRandom) -> WeatherKind {
        let choices = WeatherKind.allCases.filter { $0 != excluding && $0 != also && $0.beautyWeight > 0 }
        let total = choices.reduce(0) { $0 + $1.beautyWeight }
        var x = rng.unit() * total
        for k in choices {
            x -= k.beautyWeight
            if x < 0 { return k }
        }
        return choices.last ?? .clear
    }
}
