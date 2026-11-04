import Foundation

/// Weather rules shared by worlds (the Snowbound Cabin and the Aurora Fjord).
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
            default: return k   // diamond dust and rime frost are at home in the cold
            }
        }
        s.weather = chill(s.weather)
        s.nextWeather = chill(s.nextWeather)
        return s
    }
}
