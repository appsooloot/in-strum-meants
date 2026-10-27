extension ButterflyGardenModel {
    private static func look(_ name: String, _ v: [String: ParamValue], _ m: [Macro: Double] = [:]) -> LookPreset {
        LookPreset(name: name, themeID: id, state: ThemeState(values: v, macros: m))
    }

    public static let builtInLooks: [LookPreset] = [
        look("Monarch Morning", ["wings.style": .choice("Monarch"), "time": .choice("Morning"), "rays": .number(0.45),
                                 "grade": .choice("Natural"), "petals": .number(0.3)]),
        look("Morpho Dream", ["wings.style": .choice("Morpho Blue"), "wings.iridescence": .number(0.9), "time": .choice("Dawn"),
                              "grade": .choice("Dreamy"), "mist": .number(0.45), "trail.length": .number(0.6)], [.glow: 0.3]),
        look("Golden Hour Meadow", ["wings.style": .choice("Mix"), "time": .choice("Golden Hour"), "rays": .number(0.8),
                                    "flowers.types": .choice("Wildflowers"), "pollen.sparkle": .number(0.8), "grade": .choice("Warm Film")]),
        look("Moonlit Moths", ["wings.style": .choice("Moth"), "time": .choice("Moonlight"), "fireflies": .bool(true),
                               "mist": .number(0.4), "grade": .choice("Cool Film"), "trail.glow": .number(0.8)], [.speed: -0.3]),
        look("Crystal Garden", ["wings.style": .choice("Crystal"), "time": .choice("Morning"), "grade": .choice("Cool Film"),
                                "wings.shimmer": .number(0.9), "flowers.types": .choice("Lotus"), "glow": .number(0.7)]),
        look("Neon Night", ["wings.style": .choice("Neon"), "time": .choice("Moonlight"), "grade": .choice("Vivid"),
                            "trail.length": .number(0.8), "trail.glow": .number(1), "glow": .number(0.85),
                            "flowers.types": .choice("Cherry Blossom")], [.chaos: 0.3]),
    ]
}
