/// What the weather adds to any outdoor world's soundscape: drips while things are wet after the rain, and a
/// howling wind in a blizzard's gusts.
public enum WeatherAmbience {
    public static func levels(_ sky: SkyState, base levels: inout [AmbienceSource: Double]) {
        if sky.rain < 0.05, sky.wetness > 0 { levels[.drips] = Double(sky.wetness) }
        if sky.snow >= 0.9 { levels[.wind] = max(levels[.wind] ?? 0, 0.3 + 0.7 * Double(sky.gust)) }
    }
}
