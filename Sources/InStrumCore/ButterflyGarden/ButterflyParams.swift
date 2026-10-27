extension ButterflyGardenModel {
    public static let wingStyles = ["Mix", "Monarch", "Glasswing", "Morpho Blue", "Moth", "Origami", "Crystal", "Neon", "Petal"]
    public static let timesOfDay = ["Dawn", "Morning", "Golden Hour", "Dusk", "Moonlight"]

    private static func slider(_ id: String, _ name: String, _ group: String, _ range: ClosedRange<Double>, _ def: Double,
                               hero: Bool = false, surprise: ClosedRange<Double>? = nil, help: String = "") -> ParamSpec {
        ParamSpec(id: id, name: name, group: group, help: help, kind: .slider(range), defaultValue: .number(def), hero: hero, surprise: surprise)
    }
    private static func choice(_ id: String, _ name: String, _ group: String, _ options: [String], _ def: String,
                               hero: Bool = false, surprise: Bool = true, help: String = "") -> ParamSpec {
        ParamSpec(id: id, name: name, group: group, help: help, kind: .choice(options), defaultValue: .choice(def), hero: hero, surprise: surprise ? 0...1 : nil)
    }
    private static func toggle(_ id: String, _ name: String, _ group: String, _ def: Bool, help: String = "") -> ParamSpec {
        ParamSpec(id: id, name: name, group: group, help: help, kind: .toggle, defaultValue: .bool(def))
    }

    public static let parameters: [ParamSpec] = [
        // Butterflies
        choice("wings.style", "Wing style", "Butterflies", wingStyles, "Mix", hero: true),
        slider("wings.mix", "Species variety", "Butterflies", 0...1, 0.6, surprise: 0.2...1),
        ParamSpec(id: "butterflies.max", name: "How many", group: "Butterflies", help: "Upper limit on butterflies at once",
                  kind: .integer(20...1200), defaultValue: .number(300), hero: true, surprise: 120...500),
        slider("size.min", "Smallest size", "Butterflies", 0.2...1, 0.45),
        slider("size.max", "Largest size", "Butterflies", 0.5...2.5, 1.4, surprise: 0.9...2),
        slider("flutter.speed", "Flutter speed", "Butterflies", 0.2...3, 1, hero: true, surprise: 0.6...1.8),
        slider("wings.iridescence", "Iridescence", "Butterflies", 0...1, 0.35, hero: true, surprise: 0...0.9),
        slider("wings.shimmer", "Wing shimmer", "Butterflies", 0...1, 0.4, surprise: 0.1...0.8),
        slider("trail.length", "Trail length", "Butterflies", 0...1, 0.35, surprise: 0...0.8),
        slider("trail.glow", "Trail glow", "Butterflies", 0...1, 0.5, surprise: 0.2...0.9),
        slider("lifespan", "Lifespan (s)", "Butterflies", 2...60, 20),
        slider("flocking", "Calm drift ↔ wild swarm", "Butterflies", 0...1, 0.35, surprise: 0.1...0.8),
        toggle("land.onHeld", "Hover on held keys", "Butterflies", true),
        choice("color.source", "Colour from", "Butterflies", ["Pitch", "Chord", "Velocity", "Palette"], "Pitch"),
        // Notes
        slider("spawn.rate", "Butterflies per note", "Notes", 0.2...1, 1),
        slider("chord.spiral", "Chord spiral", "Notes", 0...1, 0.8, surprise: 0.3...1),
        slider("spawn.minVelocity", "Softest note that spawns", "Notes", 0...0.5, 0),
        // Garden
        choice("flowers.types", "Flowers", "Garden", ["Mixed", "Roses", "Poppies", "Lotus", "Wildflowers", "Cherry Blossom"], "Mixed"),
        slider("bloom.speed", "Bloom speed", "Garden", 0.2...3, 1, hero: true, surprise: 0.5...2),
        slider("bloom.lifetime", "Bloom lifetime (s)", "Garden", 2...60, 18),
        slider("petals", "Petals in the air", "Garden", 0...1, 0.4, surprise: 0...0.8),
        slider("breeze.strength", "Breeze", "Garden", 0...1, 0.3, surprise: 0...0.7),
        slider("breeze.direction", "Breeze direction", "Garden", -1...1, 0.3),
        slider("foliage", "Foliage", "Garden", 0...1, 0.6, surprise: 0.3...0.9),
        slider("pollen.sparkle", "Pollen sparkle", "Garden", 0...1, 0.5, surprise: 0.2...0.9),
        toggle("fireflies", "Fireflies at night", "Garden", true),
        // Light & atmosphere
        choice("time", "Time of day", "Light & atmosphere", timesOfDay, "Golden Hour", hero: true),
        slider("sun.angle", "Sun position", "Light & atmosphere", 0...1, 0.7, surprise: 0.2...0.9),
        slider("rays", "God-rays", "Light & atmosphere", 0...1, 0.55, hero: true, surprise: 0.2...0.9),
        slider("mist", "Mist", "Light & atmosphere", 0...1, 0.25, surprise: 0...0.6),
        slider("dof", "Depth of field", "Light & atmosphere", 0...1, 0.5, surprise: 0.2...0.8),
        slider("glow", "Glow", "Light & atmosphere", 0...1, 0.5, surprise: 0.2...0.8),
        slider("grain", "Film grain", "Light & atmosphere", 0...1, 0.15, surprise: 0...0.4),
        choice("grade", "Colour grade", "Light & atmosphere", ["Natural", "Warm Film", "Cool Film", "Dreamy", "Vivid"], "Warm Film"),
        // Camera
        choice("camera.motion", "Camera", "Camera", ["Still", "Drift", "Follow melody"], "Drift"),
        slider("camera.zoom", "Zoom", "Camera", 0.8...1.4, 1),
        slider("parallax", "Parallax depth", "Camera", 0...1, 0.5, surprise: 0.2...0.8),
        // Keys
        toggle("keys.show", "Show keys", "Keys", true),
        slider("keys.height", "Keyboard height", "Keys", 0.1...0.35, 0.16),
        choice("keys.finish", "Key finish", "Keys", ["Lacquer", "Satin", "Ivory", "Brushed metal", "Gold", "Pearl"], "Lacquer"),
        ParamSpec(id: "keys.glowColor", name: "Key glow colour", group: "Keys", help: "", kind: .color,
                  defaultValue: .color(RGBA(1, 0.78, 0.45)), surprise: 0...1),
    ]

    public static let macroTargets: [Macro: [(id: String, weight: Double)]] = [
        .intensity: [("rays", 0.8), ("glow", 0.8), ("size.max", 0.5)],
        .speed: [("flutter.speed", 0.8), ("bloom.speed", 0.8)],
        .density: [("butterflies.max", 0.8), ("petals", 0.8), ("pollen.sparkle", 0.6)],
        .glow: [("glow", 1), ("trail.glow", 0.8)],
        .chaos: [("flocking", 1), ("chord.spiral", 0.6)],
        .temperature: [],   // read directly as colour warmth
    ]
}
