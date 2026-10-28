import Foundation

/// Everything a world needs to draw and hear its sky this frame.
public struct SkyState: Equatable {
    public var sun = SkyDirection(azimuth: 0, altitude: -30)
    public var moon = SkyDirection(azimuth: 0, altitude: -30)
    /// 0…1: 0 new, 0.5 full.
    public var moonPhase = 0.0
    /// Lit fraction of the disc, 0…1.
    public var moonLit = 0.0
    /// Local sidereal time (degrees) and latitude, for turning the stars.
    public var siderealDegrees = 0.0
    public var latitude = 0.0
    /// Sky colours (linear RGB, 0…1).
    public var zenith = SIMD3<Float>(repeating: 0), horizon = SIMD3<Float>(repeating: 0)
    public var starVisibility: Float = 0
    public var weather = WeatherKind.clear
    /// 0…1 toward `nextWeather` while a change is under way (0 when steady).
    public var weatherBlend: Float = 0
    public var nextWeather = WeatherKind.clear
    public var cloudCover: Float = 0, rain: Float = 0, snow: Float = 0, mist: Float = 0, wind: Float = 0
    /// 0…1: a lightning flash request (storms), fading in a fraction of a second.
    public var lightning: Float = 0
    /// Local hour at the sky's city (0…<24).
    public var hourOfDay = 0.0
    public var subsolar = GeoPoint(latitude: 0, longitude: 0)
    /// Ice halos and sundogs, 0…1 (light cloud above all).
    public var halo: Float = 0
    /// Frost on glass, 0…1 (snow and blizzards any time; clear and cloudy skies only at night; rain melts it).
    public var frost: Float = 0
    /// How wet the world is, 0…1: rises in rain, dries over minutes, held at 0.85 after the rain.
    public var wetness: Float = 0
    /// The live gust, 0…1: the weather's gustiness times an envelope that comes every 3–8 s.
    public var gust: Float = 0
    /// 0…1: how pastel this dawn is (about one morning in three, gliding in and out).
    public var dawnPastel: Float = 0

    public init() {}
}

/// The Living Sky: sun, moon, stars, colour and weather for a time mode and a city.
public final class LivingSky {
    public var settings: SkySettings {
        didSet { if settings.cityID != oldValue.cityID { clock.place(cityID: settings.cityID, homeZone: homeZone) } }
    }
    public var location: GeoPoint { clock.location }
    public var timeZone: TimeZone { clock.timeZone }

    private let homeZone: TimeZone
    private let seed: UInt64
    private var clock = SkyClock()
    private var weather: WeatherMachine
    private var rng: SeededRandom
    private var lightning: Float = 0
    private var nextFlash = 3.0
    private var wetness: Float = 0
    private var gustRng: SeededRandom
    private var gustAge = 10.0, nextGust = 4.0
    private var dawnPastel: Float = 0

    public init(settings: SkySettings, seed: UInt64 = 1, homeZone: TimeZone = .current) {
        self.settings = settings
        self.homeZone = homeZone
        self.seed = seed
        weather = WeatherMachine(settings: settings, seed: seed)
        rng = SeededRandom(seed: seed &+ 0x11_9E37)
        gustRng = SeededRandom(seed: seed &+ 0x6057)
        clock.place(cityID: settings.cityID, homeZone: homeZone)
        nextGust = Double(gustRng.range(3, 8))
    }

    /// Starts over with these settings: the weather begins settled instead of blending from the old one
    /// (launch and previews; setting `settings` later blends as usual).
    public func reset(settings: SkySettings) {
        self.settings = settings
        weather = WeatherMachine(settings: settings, seed: seed)
        lightning = 0
        nextFlash = 3
        wetness = 0
        dawnPastel = 0
        gustRng = SeededRandom(seed: seed &+ 0x6057)
        gustAge = 10
        nextGust = Double(gustRng.range(3, 8))
    }

    /// `hold` keeps the sun at a chosen altitude for worlds that hold the light; everything else keeps running.
    public func step(now: Date, dt rawDt: Double, hold: SkyHold = .follow) -> SkyState {
        let dt = min(1, max(0, rawDt))
        let reading = clock.read(now: now, dt: dt, settings: settings)
        var s = SkyState()
        let t = reading.instant
        s.sun = Solar.direction(at: t, from: clock.location)
        if let altitude = hold.altitude { s.sun.altitude = altitude }
        s.moonPhase = reading.moonPhase
        if reading.virtualMoon {
            s.moon = clock.virtualMoon(at: t, phase: reading.moonPhase)
            s.moonLit = (1 - cos(2 * .pi * reading.moonPhase)) / 2
        } else {
            s.moon = Lunar.direction(at: t, from: clock.location)
            s.moonLit = Lunar.illuminatedFraction(at: t)
        }
        s.siderealDegrees = Sidereal.localSiderealDegrees(at: t, longitude: clock.location.longitude)
        s.latitude = clock.location.latitude
        s.hourOfDay = reading.hourOfDay
        s.subsolar = Solar.subsolarPoint(at: t)

        weather.step(dt: dt, settings: settings)
        let w = weather.values
        s.weather = weather.current
        s.nextWeather = weather.transitioning ? weather.next : weather.current
        s.weatherBlend = weather.transitioning ? Float(weather.blend) : 0
        s.cloudCover = w.cloud; s.rain = w.rain; s.snow = w.snow; s.mist = w.mist; s.wind = w.wind

        // Gusts: one every 3–8 s while the weather is gusty (a 0.5 s rise and a 1.5 s fall).
        if w.gust > 0 {
            nextGust -= dt
            if nextGust <= 0 { gustAge = 0; nextGust = max(0.5, nextGust + Double(gustRng.range(3, 8))) }
        }
        gustAge += dt
        s.gust = w.gust * Self.gustEnvelope(gustAge)
        if w.snow >= 0.9 { s.mist = min(1, w.mist + 0.3 * s.gust) }   // a blizzard whites out with each gust

        // Frost: night-only for clear and cloudy skies, any time for snow; rain melts it within seconds.
        let darkness = 1 - SkyPalette.smoothstep(-12, -2, Float(s.sun.altitude))
        var frost: Float = 0
        for k in Set([weather.current, weather.next]) {
            frost += weather.weight(of: k) * k.values.frost * (k.frostFormsOnlyAtNight ? darkness : 1)
        }
        s.frost = frost * (1 - SkyPalette.smoothstep(0, 0.05, w.rain))
        s.halo = Self.halo(weather)

        // Wetness: rain soaks (faster the harder it rains), dry weather dries it over minutes; after the rain stays wet.
        if w.rain > 0.1 { wetness += (1 - wetness) * Float(1 - exp(-dt * Double(w.rain) / 90)) }
        else { wetness *= Float(exp(-dt / 480)) }
        wetness = max(wetness, 0.85 * weather.weight(of: .afterRain))
        s.wetness = wetness

        // Pastel dawns: about one morning in three, chosen by the local date and the city.
        if hold.forcesPastel {
            dawnPastel = 1
        } else {
            let target: Float = reading.hourOfDay < 12 && Self.dawnIsPastel(day: reading.day, cityID: settings.cityID) ? 1 : 0
            dawnPastel += (target - dawnPastel) * Float(1 - exp(-dt / 20))
        }
        s.dawnPastel = dawnPastel

        // Lightning: a flash every 6–20 s while the storm holds.
        let storm = stormAmount()
        if storm > 0.5 {
            nextFlash -= dt
            if nextFlash <= 0 { lightning = 1; nextFlash = Double(rng.range(6, 20)) }
        } else {
            nextFlash = Double(rng.range(2, 8))
        }
        s.lightning = lightning
        lightning *= Float(exp(-dt / 0.12))

        let moonUp = Float(max(0, sin(Astro.rad(s.moon.altitude)))) * Float(s.moonLit)
        let colours = SkyPalette.colours(sunAltitude: s.sun.altitude, cloud: w.cloud, mist: w.mist, moonlight: moonUp, pastel: dawnPastel)
        s.zenith = colours.zenith; s.horizon = colours.horizon
        let night = 1 - SkyPalette.smoothstep(-15, -4, Float(s.sun.altitude))
        s.starVisibility = night * (1 - 0.9 * w.cloud) * (1 - 0.6 * w.mist) * (1 - 0.3 * moonUp)
        return s
    }

    /// Halo strength: the weather's halo, with each light-cloud spell's own ice.
    static func halo(_ m: WeatherMachine) -> Float {
        let light = m.weight(of: .lightCloud)
        return m.values.halo * (1 - light + light * m.ice)
    }

    static func gustEnvelope(_ age: Double) -> Float {
        if age < 0.5 { let x = Float(age / 0.5); return x * x * (3 - 2 * x) }
        if age < 2 { let x = Float((age - 0.5) / 1.5); return 1 - x * x * (3 - 2 * x) }
        return 0
    }

    /// Whether this local day's dawn is pastel at this city (about one in three, the same every time).
    public static func dawnIsPastel(day: Int, cityID: String?) -> Bool {
        var h: UInt64 = 0xCBF2_9CE4_8422_2325   // FNV-1a: stable across launches, unlike Hasher
        for b in (cityID ?? "home").utf8 { h ^= UInt64(b); h = h &* 0x0000_0100_0000_01B3 }
        var r = SeededRandom(seed: (UInt64(bitPattern: Int64(day)) &* 0x9E37_79B9_7F4A_7C15) ^ h)
        return r.next() % 3 == 0
    }

    /// Days since 1970-01-01 on the local calendar of `zone`.
    static func localDay(_ instant: Date, zone: TimeZone) -> Int {
        Int(floor((instant.timeIntervalSince1970 + Double(zone.secondsFromGMT(for: instant))) / 86_400))
    }

    private func stormAmount() -> Float {
        let t = Float(weather.blend), b = t * t * (3 - 2 * t)
        if weather.transitioning {
            return (weather.current == .storm ? 1 - b : 0) + (weather.next == .storm ? b : 0)
        }
        return weather.current == .storm ? 1 : 0
    }
}

/// A world can hold the light at a favourite moment: only the sun's altitude is held (its direction, the moon,
/// the clock and the weather keep running), and the Living Sky settings are never changed.
public enum SkyHold: String, CaseIterable, Codable {
    case follow = "Follow the sky", goldenHour = "Golden hour", blueHour = "Blue hour", pastelDawn = "Pastel dawn"

    /// The held sun altitude in degrees, or nil to follow the sky.
    public var altitude: Double? {
        switch self {
        case .follow: return nil
        case .goldenHour: return 5
        case .blueHour: return -6
        case .pastelDawn: return 1.5
        }
    }

    /// Pastel dawn also makes the dawn pastel, whatever the day.
    public var forcesPastel: Bool { self == .pastelDawn }

    /// The world parameter that chooses it.
    public static func spec(default d: SkyHold) -> ParamSpec {
        ParamSpec(id: "light.hold", name: "Hold the light", group: "Light",
                  help: "Keep the world at golden hour, blue hour or a pastel dawn, or follow the Living Sky",
                  kind: .choice(allCases.map(\.rawValue)), defaultValue: .choice(d.rawValue))
    }
}

/// Sky colours keyed to the sun's altitude, greyed by cloud and lifted by moonlight.
enum SkyPalette {
    struct Anchor { var altitude: Float; var zenith, horizon: SIMD3<Float> }

    static let anchors: [Anchor] = [
        Anchor(altitude: -18, zenith: [0.010, 0.014, 0.035], horizon: [0.020, 0.028, 0.060]),      // night
        Anchor(altitude: -12, zenith: [0.015, 0.022, 0.065], horizon: [0.040, 0.050, 0.110]),      // astronomical twilight
        Anchor(altitude: -6, zenith: [0.040, 0.060, 0.160], horizon: [0.200, 0.170, 0.260]),       // nautical
        Anchor(altitude: -0.833, zenith: [0.160, 0.240, 0.450], horizon: [0.850, 0.480, 0.300]),   // civil: sunset glow
        Anchor(altitude: 6, zenith: [0.300, 0.480, 0.780], horizon: [0.980, 0.700, 0.420]),        // golden hour
        Anchor(altitude: 20, zenith: [0.260, 0.520, 0.920], horizon: [0.700, 0.840, 0.970]),       // day
    ]

    /// Pastel dawn: a lavender-blue zenith over a peach-pink horizon, for the sun between −10° and +8°.
    static let pastelAnchors: [Anchor] = [
        Anchor(altitude: -10, zenith: [0.10, 0.10, 0.25], horizon: [0.35, 0.25, 0.40]),
        Anchor(altitude: -4, zenith: [0.30, 0.30, 0.55], horizon: [0.85, 0.55, 0.62]),
        Anchor(altitude: -0.833, zenith: [0.46, 0.44, 0.74], horizon: [0.98, 0.66, 0.62]),
        Anchor(altitude: 4, zenith: [0.45, 0.58, 0.85], horizon: [1.0, 0.78, 0.66]),
        Anchor(altitude: 8, zenith: [0.32, 0.52, 0.88], horizon: [0.92, 0.82, 0.74]),
    ]

    /// 1 for the sun between −6° and +4°, easing to 0 at −10° and +8°.
    static func pastelWindow(_ altitude: Float) -> Float {
        smoothstep(-10, -6, altitude) * (1 - smoothstep(4, 8, altitude))
    }

    static func interpolate(_ table: [Anchor], _ alt: Float) -> (zenith: SIMD3<Float>, horizon: SIMD3<Float>) {
        if alt <= table[0].altitude { return (table[0].zenith, table[0].horizon) }
        for i in 0..<(table.count - 1) where alt < table[i + 1].altitude {
            let s = smoothstep(table[i].altitude, table[i + 1].altitude, alt)
            return (table[i].zenith + (table[i + 1].zenith - table[i].zenith) * s,
                    table[i].horizon + (table[i + 1].horizon - table[i].horizon) * s)
        }
        return (table[table.count - 1].zenith, table[table.count - 1].horizon)
    }

    static func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = min(1, max(0, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    static func colours(sunAltitude: Double, cloud: Float, mist: Float, moonlight: Float, pastel: Float = 0) -> (zenith: SIMD3<Float>, horizon: SIMD3<Float>) {
        let alt = Float(sunAltitude)
        var z = anchors[0].zenith, h = anchors[0].horizon
        if alt >= anchors[anchors.count - 1].altitude {
            z = anchors[anchors.count - 1].zenith; h = anchors[anchors.count - 1].horizon
        } else if alt > anchors[0].altitude {
            for i in 0..<(anchors.count - 1) where alt < anchors[i + 1].altitude {
                let s = smoothstep(anchors[i].altitude, anchors[i + 1].altitude, alt)
                z = anchors[i].zenith + (anchors[i + 1].zenith - anchors[i].zenith) * s
                h = anchors[i].horizon + (anchors[i + 1].horizon - anchors[i].horizon) * s
                break
            }
        }
        // A pastel dawn: blend toward the pastel anchors inside the dawn window (exactly today's colours at 0).
        let weight = pastel * pastelWindow(alt)
        if weight > 0 {
            let p = interpolate(pastelAnchors, alt)
            z += (p.zenith - z) * weight
            h += (p.horizon - h) * weight
        }
        // Moonlight: a cool lift.
        z += SIMD3<Float>(0.015, 0.022, 0.040) * moonlight
        h += SIMD3<Float>(0.012, 0.018, 0.032) * moonlight
        // Cloud greys and dims (up to 60% desaturation); mist softens the horizon.
        func grey(_ c: SIMD3<Float>, _ amount: Float, dim: Float) -> SIMD3<Float> {
            let l = 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z
            let coolGrey = SIMD3<Float>(0.94, 0.98, 1.06) * l   // cloud light is cool, never muddy
            return (c + (coolGrey - c) * amount) * (1 - dim)
        }
        z = grey(z, 0.6 * cloud, dim: 0.25 * cloud)
        h = grey(h, min(0.8, 0.6 * cloud + 0.3 * mist), dim: 0.2 * cloud)
        return (z, h)
    }
}
