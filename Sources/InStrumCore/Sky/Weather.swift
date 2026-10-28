import Foundation

public enum WeatherKind: String, Codable, CaseIterable { case clear, lightCloud, overcast, mist, drizzle, rain, storm, snow }

/// Pick one yourself, or let the sky wander through beautiful weathers. (`.real` comes later.)
public enum WeatherMode: String, Codable, CaseIterable { case pick, randomBeautiful }

/// How much of each element a weather has, 0…1.
public struct WeatherValues: Equatable {
    public var cloud, rain, snow, mist, wind: Float

    static func mix(_ a: WeatherValues, _ b: WeatherValues, _ t: Float) -> WeatherValues {
        WeatherValues(cloud: a.cloud + (b.cloud - a.cloud) * t, rain: a.rain + (b.rain - a.rain) * t,
                      snow: a.snow + (b.snow - a.snow) * t, mist: a.mist + (b.mist - a.mist) * t,
                      wind: a.wind + (b.wind - a.wind) * t)
    }
}

public extension WeatherKind {
    var values: WeatherValues {
        switch self {
        case .clear: return WeatherValues(cloud: 0, rain: 0, snow: 0, mist: 0.1, wind: 0.1)
        case .lightCloud: return WeatherValues(cloud: 0.35, rain: 0, snow: 0, mist: 0.15, wind: 0.2)
        case .overcast: return WeatherValues(cloud: 0.85, rain: 0, snow: 0, mist: 0.25, wind: 0.3)
        case .mist: return WeatherValues(cloud: 0.4, rain: 0, snow: 0, mist: 0.9, wind: 0.05)
        case .drizzle: return WeatherValues(cloud: 0.8, rain: 0.3, snow: 0, mist: 0.4, wind: 0.2)
        case .rain: return WeatherValues(cloud: 0.9, rain: 0.75, snow: 0, mist: 0.3, wind: 0.4)
        case .storm: return WeatherValues(cloud: 1, rain: 1, snow: 0, mist: 0.2, wind: 0.9)
        case .snow: return WeatherValues(cloud: 0.85, rain: 0, snow: 0.8, mist: 0.3, wind: 0.25)
        }
    }

    /// How often "random beautiful" picks it (overcast only when chosen).
    var beautyWeight: Float {
        switch self {
        case .clear, .lightCloud: return 3
        case .mist: return 2
        case .drizzle, .rain: return 1
        case .storm, .snow: return 0.5
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

    init(settings: SkySettings, seed: UInt64) {
        rng = SeededRandom(seed: seed &* 0x2545_F491_4F6C_DD1D &+ 0xA5)
        mode = settings.weatherMode
        let first: WeatherKind
        if settings.weatherMode == .pick { first = settings.weather }
        else { var r = rng; first = Self.pick(excluding: nil, &r); rng = r }
        current = first; next = first; from = first.values
        var r = rng
        spellLeft = Self.spell(&r)
        rng = r
    }

    var values: WeatherValues {
        guard transitioning else { return current.values }
        let t = Float(blend), s = t * t * (3 - 2 * t)
        return WeatherValues.mix(from, next.values, s)
    }

    mutating func step(dt: Double, settings: SkySettings) {
        if settings.weatherMode != mode {
            mode = settings.weatherMode
            spellLeft = Self.spell(&rng)
            if mode == .randomBeautiful { begin(Self.pick(excluding: transitioning ? next : current, &rng)) }
        }
        switch mode {
        case .pick:
            if settings.weather != (transitioning ? next : current) { begin(settings.weather) }
        case .randomBeautiful:
            spellLeft -= dt
            if spellLeft <= 0, !transitioning {
                begin(Self.pick(excluding: current, &rng))
                spellLeft += Self.spell(&rng)
            }
        }
        if transitioning {
            blend += dt / Self.transitionSeconds
            if blend >= 1 { current = next; blend = 0; transitioning = false }
        }
    }

    private mutating func begin(_ kind: WeatherKind) {
        from = values
        next = kind
        blend = 0
        transitioning = kind != current || transitioning
        if !transitioning { next = current }
    }

    private static func spell(_ rng: inout SeededRandom) -> Double { 300 + 900 * Double(rng.unit()) }

    private static func pick(excluding: WeatherKind?, _ rng: inout SeededRandom) -> WeatherKind {
        let choices = WeatherKind.allCases.filter { $0 != excluding && $0.beautyWeight > 0 }
        let total = choices.reduce(0) { $0 + $1.beautyWeight }
        var x = rng.unit() * total
        for k in choices {
            x -= k.beautyWeight
            if x < 0 { return k }
        }
        return choices.last ?? .clear
    }
}
