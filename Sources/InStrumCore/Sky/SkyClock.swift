import Foundation

/// Quick (a whole day in minutes), real time (your Mac's clock at a city), or frozen at a chosen hour and moon.
public enum TimeMode: String, Codable, CaseIterable { case quick, realTime, frozen }

public struct SkySettings: Codable, Equatable {
    public var timeMode: TimeMode = .quick
    /// Quick mode: one day lasts this many minutes (2…60).
    public var dayMinutes: Double = 12
    /// Frozen mode: local hour (0…<24) and moon phase (0 new … 0.5 full … 1).
    public var frozenHour: Double = 21
    public var frozenPhase: Double = 0.5
    /// nil follows the Mac's time zone.
    public var cityID: String?
    public var weatherMode: WeatherMode = .randomBeautiful
    public var weather: WeatherKind = .clear
    /// Advanced: how long a weather you pick takes to blend in (1…120 s), how long random weather blends (10…300 s),
    /// and how long a random spell lasts on average (2…60 min).
    public var pickBlendSeconds: Double = 12
    public var randomBlendSeconds: Double = 60
    public var spellMinutes: Double = 12.5
    /// Advanced: how bright rainbows are, 0 (none) … 1 (full).
    public var rainbowStrength: Double = 1
    /// Advanced: how long the ground takes to dry after rain (2…60 min).
    public var dryingMinutes: Double = 8
    /// Advanced: scale the wind and the mist/haze (0…2), halo strength and frost (0…1.5); 1 is as designed.
    public var windScale: Double = 1
    public var mistScale: Double = 1
    public var haloScale: Double = 1
    public var frostScale: Double = 1
    /// Advanced: scale how hard it rains and snows, and how gusty it is (0…2).
    public var rainScale: Double = 1
    public var snowScale: Double = 1
    public var gustScale: Double = 1
    /// Advanced: keep random weather gentle (no storms, blizzards, monsoons, hail, squalls or dust storms).
    public var calmRandom: Bool = false
    /// Advanced: how often a storm flashes (0.25…3, 1 = every 6–20 s), cloud cover (0…1.5) and star brightness (0…1.5).
    public var lightningFrequency: Double = 1
    public var cloudScale: Double = 1
    public var starScale: Double = 1
    /// Advanced: how big the moon and the sun look (0.5…3; 1 is true size ~; try 2 for a supermoon).
    public var moonSize: Double = 1
    public var sunSize: Double = 1

    public init() {}

    enum CodingKeys: String, CodingKey { case timeMode, dayMinutes, frozenHour, frozenPhase, cityID, weatherMode, weather, pickBlendSeconds, randomBlendSeconds, spellMinutes, rainbowStrength, dryingMinutes, windScale, mistScale, haloScale, frostScale, rainScale, snowScale, gustScale, calmRandom, lightningFrequency, cloudScale, starScale, moonSize, sunSize }

    /// Each field falls back on its own, and numbers are clamped, so one bad value never loses the rest.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SkySettings()
        timeMode = (try? c.decodeIfPresent(TimeMode.self, forKey: .timeMode)) ?? d.timeMode
        dayMinutes = min(60, max(2, (try? c.decodeIfPresent(Double.self, forKey: .dayMinutes)) ?? d.dayMinutes))
        frozenHour = min(23.99, max(0, (try? c.decodeIfPresent(Double.self, forKey: .frozenHour)) ?? d.frozenHour))
        frozenPhase = min(1, max(0, (try? c.decodeIfPresent(Double.self, forKey: .frozenPhase)) ?? d.frozenPhase))
        cityID = (try? c.decodeIfPresent(String.self, forKey: .cityID)) ?? nil
        weatherMode = (try? c.decodeIfPresent(WeatherMode.self, forKey: .weatherMode)) ?? d.weatherMode
        weather = (try? c.decodeIfPresent(WeatherKind.self, forKey: .weather)) ?? d.weather
        pickBlendSeconds = min(120, max(1, (try? c.decodeIfPresent(Double.self, forKey: .pickBlendSeconds)) ?? d.pickBlendSeconds))
        randomBlendSeconds = min(300, max(10, (try? c.decodeIfPresent(Double.self, forKey: .randomBlendSeconds)) ?? d.randomBlendSeconds))
        rainbowStrength = min(1, max(0, (try? c.decodeIfPresent(Double.self, forKey: .rainbowStrength)) ?? d.rainbowStrength))
        dryingMinutes = min(60, max(2, (try? c.decodeIfPresent(Double.self, forKey: .dryingMinutes)) ?? d.dryingMinutes))
        windScale = min(2, max(0, (try? c.decodeIfPresent(Double.self, forKey: .windScale)) ?? d.windScale))
        mistScale = min(2, max(0, (try? c.decodeIfPresent(Double.self, forKey: .mistScale)) ?? d.mistScale))
        haloScale = min(1.5, max(0, (try? c.decodeIfPresent(Double.self, forKey: .haloScale)) ?? d.haloScale))
        frostScale = min(1.5, max(0, (try? c.decodeIfPresent(Double.self, forKey: .frostScale)) ?? d.frostScale))
        rainScale = min(2, max(0, (try? c.decodeIfPresent(Double.self, forKey: .rainScale)) ?? d.rainScale))
        snowScale = min(2, max(0, (try? c.decodeIfPresent(Double.self, forKey: .snowScale)) ?? d.snowScale))
        gustScale = min(2, max(0, (try? c.decodeIfPresent(Double.self, forKey: .gustScale)) ?? d.gustScale))
        calmRandom = (try? c.decodeIfPresent(Bool.self, forKey: .calmRandom)) ?? d.calmRandom
        lightningFrequency = min(3, max(0.25, (try? c.decodeIfPresent(Double.self, forKey: .lightningFrequency)) ?? d.lightningFrequency))
        cloudScale = min(1.5, max(0, (try? c.decodeIfPresent(Double.self, forKey: .cloudScale)) ?? d.cloudScale))
        starScale = min(1.5, max(0, (try? c.decodeIfPresent(Double.self, forKey: .starScale)) ?? d.starScale))
        moonSize = min(3, max(0.5, (try? c.decodeIfPresent(Double.self, forKey: .moonSize)) ?? d.moonSize))
        sunSize = min(3, max(0.5, (try? c.decodeIfPresent(Double.self, forKey: .sunSize)) ?? d.sunSize))
        spellMinutes = min(60, max(2, (try? c.decodeIfPresent(Double.self, forKey: .spellMinutes)) ?? d.spellMinutes))
    }
}

/// Where the sky is and what time it shows there.
struct SkyClock {
    struct Reading {
        var instant: Date
        var moonPhase: Double          // 0…1, 0.5 full
        var virtualMoon: Bool          // quick and frozen modes place the moon by phase on the ecliptic
        var hourOfDay: Double
        /// The local calendar day the sky is showing (days since 1970): today's date in real time and frozen
        /// modes, a new day for every cycle in quick mode. It picks each dawn's character.
        var day: Int
    }

    private(set) var location = GeoPoint(latitude: 0, longitude: 0)
    private(set) var timeZone = TimeZone(identifier: "UTC")!
    private var equinoxMidnight = Date(timeIntervalSince1970: 0)
    private var quickDays: Double?
    private var quickStart = 0.0, quickPhase0 = 0.5, quickBaseDay = 0
    private var mode: TimeMode?

    /// Resolves the city: the chosen one, else the Mac's time zone's, else 0°, 0° in the Mac's zone.
    mutating func place(cityID: String?, homeZone: TimeZone) {
        let city = cityID.flatMap(Cities.city(id:)) ?? Cities.defaultCity(for: homeZone)
        location = city?.point ?? GeoPoint(latitude: 0, longitude: 0)
        timeZone = city?.timeZone ?? homeZone
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        equinoxMidnight = cal.date(from: DateComponents(year: 2026, month: 3, day: 20)) ?? equinoxMidnight
        quickDays = nil
    }

    func localHour(_ t: Date) -> Double {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.hour, .minute, .second, .nanosecond], from: t)
        return Double(c.hour ?? 0) + Double(c.minute ?? 0) / 60 + (Double(c.second ?? 0) + Double(c.nanosecond ?? 0) / 1e9) / 3600
    }

    mutating func read(now: Date, dt: Double, settings s: SkySettings) -> Reading {
        if s.timeMode != mode { mode = s.timeMode; quickDays = nil }
        switch s.timeMode {
        case .realTime:
            return Reading(instant: now, moonPhase: Lunar.phaseAngle(at: now) / 360, virtualMoon: false, hourOfDay: localHour(now),
                           day: LivingSky.localDay(now, zone: timeZone))
        case .frozen:
            let t = equinoxMidnight.addingTimeInterval(s.frozenHour * 3600)
            return Reading(instant: t, moonPhase: s.frozenPhase, virtualMoon: true, hourOfDay: s.frozenHour,
                           day: LivingSky.localDay(now, zone: timeZone))
        case .quick:
            if quickDays == nil {
                let start = localHour(now) / 24
                quickDays = start; quickStart = start
                quickPhase0 = Lunar.phaseAngle(at: now) / 360
                quickBaseDay = LivingSky.localDay(now, zone: timeZone)
            }
            quickDays! += dt / (min(60, max(2, s.dayMinutes)) * 60)
            let fraction = quickDays! - floor(quickDays!)
            var phase = (quickPhase0 + (quickDays! - quickStart) / 8).truncatingRemainder(dividingBy: 1)
            if phase < 0 { phase += 1 }
            return Reading(instant: equinoxMidnight.addingTimeInterval(fraction * 86_400), moonPhase: phase, virtualMoon: true,
                           hourOfDay: fraction * 24, day: quickBaseDay + Int(floor(quickDays!)))
        }
    }

    /// A moon on the ecliptic `phase` of a cycle ahead of the sun: rises at sunset when full, trails the sun as a crescent.
    func virtualMoon(at t: Date, phase: Double) -> SkyDirection {
        let T = Astro.centuries(t)
        let lam = Astro.rad(Solar.core(t).longitude + 360 * phase), eps = Astro.rad(Lunar.obliquity(T))
        let ra = Astro.norm(Astro.deg(atan2(sin(lam) * cos(eps), cos(lam))))
        let dec = Astro.deg(asin(sin(eps) * sin(lam)))
        let ha = Sidereal.localSiderealDegrees(at: t, longitude: location.longitude) - ra
        let h = Astro.horizontal(hourAngle: ha, declination: dec, latitude: location.latitude)
        var alt = h.alt - 0.95 * cos(Astro.rad(h.alt))   // parallax
        alt += Astro.refraction(alt)
        return SkyDirection(azimuth: h.az, altitude: alt)
    }
}
