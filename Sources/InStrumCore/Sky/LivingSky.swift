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
    private var clock = SkyClock()
    private var weather: WeatherMachine
    private var rng: SeededRandom
    private var lightning: Float = 0
    private var nextFlash = 3.0

    public init(settings: SkySettings, seed: UInt64 = 1, homeZone: TimeZone = .current) {
        self.settings = settings
        self.homeZone = homeZone
        weather = WeatherMachine(settings: settings, seed: seed)
        rng = SeededRandom(seed: seed &+ 0x11_9E37)
        clock.place(cityID: settings.cityID, homeZone: homeZone)
    }

    public func step(now: Date, dt rawDt: Double) -> SkyState {
        let dt = min(1, max(0, rawDt))
        let reading = clock.read(now: now, dt: dt, settings: settings)
        var s = SkyState()
        let t = reading.instant
        s.sun = Solar.direction(at: t, from: clock.location)
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
        let colours = SkyPalette.colours(sunAltitude: s.sun.altitude, cloud: w.cloud, mist: w.mist, moonlight: moonUp)
        s.zenith = colours.zenith; s.horizon = colours.horizon
        let night = 1 - SkyPalette.smoothstep(-15, -4, Float(s.sun.altitude))
        s.starVisibility = night * (1 - 0.9 * w.cloud) * (1 - 0.6 * w.mist) * (1 - 0.3 * moonUp)
        return s
    }

    private func stormAmount() -> Float {
        let t = Float(weather.blend), b = t * t * (3 - 2 * t)
        if weather.transitioning {
            return (weather.current == .storm ? 1 - b : 0) + (weather.next == .storm ? b : 0)
        }
        return weather.current == .storm ? 1 : 0
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

    static func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = min(1, max(0, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    static func colours(sunAltitude: Double, cloud: Float, mist: Float, moonlight: Float) -> (zenith: SIMD3<Float>, horizon: SIMD3<Float>) {
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
        // Moonlight: a cool lift.
        z += SIMD3<Float>(0.015, 0.022, 0.040) * moonlight
        h += SIMD3<Float>(0.012, 0.018, 0.032) * moonlight
        // Cloud greys and dims (up to 60% desaturation); mist softens the horizon.
        func grey(_ c: SIMD3<Float>, _ amount: Float, dim: Float) -> SIMD3<Float> {
            let l = 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z
            return (c + (SIMD3<Float>(repeating: l) - c) * amount) * (1 - dim)
        }
        z = grey(z, 0.6 * cloud, dim: 0.25 * cloud)
        h = grey(h, min(0.8, 0.6 * cloud + 0.3 * mist), dim: 0.2 * cloud)
        return (z, h)
    }
}
