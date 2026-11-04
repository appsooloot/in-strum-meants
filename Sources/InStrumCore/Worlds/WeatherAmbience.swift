/// What the weather adds to any outdoor world's soundscape: drips while things are wet after the rain, and a
/// howling wind in a blizzard's gusts, and birdsong when a rainbow stands; and rime frost's hush.
public enum WeatherAmbience {
    public static func levels(_ sky: SkyState, base levels: inout [AmbienceSource: Double]) {
        if sky.rain < 0.05, sky.wetness > 0 { levels[.drips] = Double(sky.wetness) }
        // Birds sing up as the sun comes out through a shower, while the rainbow stands.
        if sky.rainbow > 0.05, sky.rain < 0.5 { levels[.dawnChorus] = max(levels[.dawnChorus] ?? 0, 0.4 * Double(sky.rainbow)) }
        // Rime frost is still, freezing fog: the wind drops (a blizzard's howl, below, still comes through).
        if inRime(sky), let wind = levels[.wind] { levels[.wind] = min(wind, 0.15) }
        if sky.snow >= 0.9 { levels[.wind] = max(levels[.wind] ?? 0, 0.3 + 0.7 * Double(sky.gust)) }
    }

    /// In rime: the world is rimed past 0.3, or rime-frost weather is more than 0.3 of the sky.
    public static func inRime(_ sky: SkyState) -> Bool { sky.rime > 0.3 || rimeWeather(sky) > 0.3 }

    /// How much rime-frost weather is in the sky, 0…1 (the weather machine's smoothstep glide between the kinds).
    public static func rimeWeather(_ sky: SkyState) -> Float {
        let t = sky.weatherBlend.isFinite ? min(max(sky.weatherBlend, 0), 1) : 0, glide = t * t * (3 - 2 * t)
        return sky.weather.values.rime * (1 - glide) + sky.nextWeather.values.rime * glide
    }

    /// Rimed trees and stones soak up sound, so a world's outdoor sources come through a little muffled: worlds may
    /// add this to their `indoors` (0.15 × min(1, rime / 0.6): the full hush once the world is 0.6 rimed).
    public static func indoorsLift(_ sky: SkyState) -> Double {
        let rime = sky.rime.isFinite ? min(max(Double(sky.rime), 0), 1) : 0
        return 0.15 * min(1, rime / 0.6)
    }
}
