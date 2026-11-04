import Foundation

/// Weather rules shared by worlds (the Snowbound Cabin and the Aurora Fjord; the warm rule for warm worlds).
public enum WorldWeather {
    /// It's cold here: rain falls as snow (and frosts the glass), storms become blizzards (gliding in and out with the
    /// weather, whiting out with each gust), no lightning and never wet.
    public static func cold(_ s: SkyState) -> SkyState {
        var s = s
        // How much storm is in the sky right now: the weather machine's own smoothstep glide between kinds.
        let t = min(max(s.weatherBlend, 0), 1), glide = t * t * (3 - 2 * t)
        let storm = (s.weather == .storm ? 1 - glide : 0) + (s.nextWeather == .storm ? glide : 0)
        let rainAsSnow = s.rain
        s.snow = max(s.snow, rainAsSnow, storm)
        s.wind += (1 - s.wind) * storm
        s.gust = min(1, s.gust * (1 + 0.67 * storm))          // a storm's gusts (0.6) become a blizzard's (1)
        s.frost = max(s.frost, 0.6 * rainAsSnow, 0.9 * storm)  // rain melts frost; here it's snow, and frosts the glass
        s.mist = min(1, s.mist + 0.3 * s.gust * storm)          // the blizzard's whiteout with each gust
        s.rain = 0
        s.lightning = 0
        s.wetness = 0
        s.rainbow = 0                                           // it snows here; no rainbows
        s.fireflies = 0                                         // and no fireflies in the cold
        func chill(_ k: WeatherKind) -> WeatherKind {
            switch k {
            case .drizzle, .rain, .sunShower, .sleet, .hail, .freezingDrizzle: return .snow
            case .squall: return .blizzard
            case .dryLightning: return .overcast
            case .flurries: return .snow
            case .smokeHaze, .iceFog, .dustStorm: return .mist
            case .thunderheads: return .overcast
            case .monsoon: return .blizzard
            case .fogBank: return .mist
            case .storm: return .blizzard
            case .afterRain: return .lightCloud
            case .humid: return .clear
            default: return k   // diamond dust, rime frost and sea smoke are at home in the cold
            }
        }
        s.weather = chill(s.weather)
        s.nextWeather = chill(s.nextWeather)
        return s
    }

    /// It's warm here (spec §7.5): snow and flurries fall as rain, blizzards become squalls, and sleet and hail become
    /// rain. Frost, rime, diamond dust, ice fog and sea smoke never happen: sea smoke and ice fog become a light haze
    /// (no steam, mist 0.25) and the halos of their ice (and of diamond dust's) go with them, as do light pillars.
    /// Fireflies are left alone (a world that has none zeroes them itself).
    public static func warm(_ sky: SkyState) -> SkyState {
        var s = sky
        let b = sky.weatherBlend.isFinite ? min(max(sky.weatherBlend, 0), 1) : 0
        let glide = b * b * (3 - 2 * b)
        let haze = share(in: sky, glide: glide) { $0 == .iceFog || $0 == .seaSmoke }
        let ice = share(in: sky, glide: glide) { $0 == .iceFog || $0 == .seaSmoke || $0 == .diamondDust }
        s.rain = min(1, max(s.rain, s.snow))   // snow, flurries, blizzards, sleet and hail all fall as rain
        s.snow = 0
        s.frost = 0
        s.rime = 0
        s.diamondDust = 0
        s.pillar = 0
        s.steam = 0
        s.mist = s.mist * (1 - haze) + 0.25 * haze   // a light haze where the fog would have been (exactly 0.25 in it)
        s.halo *= 1 - ice
        s.weather = warmed(s.weather)
        s.nextWeather = warmed(s.nextWeather)
        return s
    }

    /// A weather as a warm world has it.
    static func warmed(_ k: WeatherKind) -> WeatherKind {
        switch k {
        case .snow, .flurries, .sleet, .hail: return .rain
        case .blizzard: return .squall
        case .freezingDrizzle: return .drizzle
        case .iceFog, .seaSmoke, .diamondDust: return .clear   // a light haze under a clear sky
        case .rime: return .mist                               // fog that never freezes
        default: return k
        }
    }

    /// How much of the kinds that `matches` is in the sky right now (the weather machine's glide between kinds), 0…1.
    private static func share(in s: SkyState, glide: Float, _ matches: (WeatherKind) -> Bool) -> Float {
        var w: Float = 0
        if matches(s.weather) { w += 1 - glide }
        if matches(s.nextWeather) { w += glide }
        return min(1, w)
    }
}
