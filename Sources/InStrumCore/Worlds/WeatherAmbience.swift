/// What the weather adds to any outdoor world's soundscape: drips while things are wet after the rain, and a
/// howling wind in a blizzard's gusts, and birdsong when a rainbow stands.
public enum WeatherAmbience {
    public static func levels(_ sky: SkyState, base levels: inout [AmbienceSource: Double]) {
        if sky.rain < 0.05, sky.wetness > 0 { levels[.drips] = Double(sky.wetness) }
        // Birds sing up as the sun comes out through a shower, while the rainbow stands.
        if sky.rainbow > 0.05, sky.rain < 0.5 { levels[.dawnChorus] = max(levels[.dawnChorus] ?? 0, 0.4 * Double(sky.rainbow)) }
        if sky.snow >= 0.9 { levels[.wind] = max(levels[.wind] ?? 0, 0.3 + 0.7 * Double(sky.gust)) }
    }
}
