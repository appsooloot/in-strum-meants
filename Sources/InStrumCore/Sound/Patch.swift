/// The app's own instruments (made entirely in the app, no recordings).
public enum BuiltInEngine: String, Codable, CaseIterable {
    case feltGlass, orbitPad, honeyTape, hazeBells, cabinFelt, morningBox, polarChoir, planktonKeys, teaHouseKoto
    case blueDepth

    public var displayName: String {
        switch self {
        case .feltGlass: return "Felt Glass"
        case .orbitPad: return "Orbit Pad"
        case .honeyTape: return "Honey Tape"
        case .hazeBells: return "Haze Bells"
        case .cabinFelt: return "Cabin Felt"
        case .morningBox: return "Morning Box"
        case .polarChoir: return "Polar Choir"
        case .planktonKeys: return "Plankton Keys"
        case .teaHouseKoto: return "Tea House Koto"
        case .blueDepth: return "Blue Depth"
        }
    }
}

/// A recipe for a built-in instrument: which engine, and its dial values (keyed by parameter identifier).
public struct Patch: Codable, Equatable, Identifiable {
    public let id: String
    public var name: String
    public var engine: BuiltInEngine
    public var values: [String: Double]
    /// The song that inspired it (see `CreditLibrary`), if any.
    public var creditID: String?

    public init(id: String, name: String, engine: BuiltInEngine, values: [String: Double], creditID: String? = nil) {
        self.id = id; self.name = name; self.engine = engine; self.values = values; self.creditID = creditID
    }
}

/// The built-in presets (values from docs/superpowers/briefs).
public enum PatchLibrary {
    public static let all: [Patch] = [
        Patch(id: "felt-glass", name: "Felt Glass", engine: .feltGlass, values: dials(felt: 0.55, glass: 0.35, warmth: 0.60, ring: 0.55, space: 0.45, width: 0.50), creditID: "come-back-to-earth"),
        Patch(id: "bare-felt", name: "Bare Felt", engine: .feltGlass, values: dials(felt: 0.70, glass: 0.00, warmth: 0.65, ring: 0.50, space: 0.35, width: 0.45), creditID: "come-back-to-earth"),
        Patch(id: "glass-choir", name: "Glass Choir", engine: .feltGlass, values: dials(felt: 0.40, glass: 0.75, warmth: 0.50, ring: 0.70, space: 0.60, width: 0.70), creditID: "come-back-to-earth"),
        Patch(id: "lullaby", name: "Lullaby", engine: .feltGlass, values: dials(felt: 0.85, glass: 0.20, warmth: 0.80, ring: 0.45, space: 0.30, width: 0.35), creditID: "come-back-to-earth"),
        Patch(id: "orbit-pad", name: "Orbit Pad", engine: .orbitPad, values: pad(bloom: 0.55, drift: 0.40, motion: 0.45, shimmer: 0.25, brightness: 0.50, space: 0.55), creditID: "innerbloom"),
        Patch(id: "earthrise", name: "Earthrise", engine: .orbitPad, values: pad(bloom: 0.75, drift: 0.30, motion: 0.30, shimmer: 0.15, brightness: 0.40, space: 0.50), creditID: "innerbloom"),
        Patch(id: "weightless", name: "Weightless", engine: .orbitPad, values: pad(bloom: 0.50, drift: 0.45, motion: 0.55, shimmer: 0.60, brightness: 0.55, space: 0.75), creditID: "innerbloom"),
        Patch(id: "re-entry", name: "Re-entry", engine: .orbitPad, values: pad(bloom: 0.25, drift: 0.35, motion: 0.50, shimmer: 0.20, brightness: 0.75, space: 0.45), creditID: "innerbloom"),
        Patch(id: "honey-tape", name: "Honey Tape", engine: .honeyTape, values: tape(breath: 0.45, strings: 0.30, wow: 0.35, age: 0.40, reel: 0, space: 0.50, width: 0.50), creditID: "music-to-watch-boys-to"),
        Patch(id: "sea-flute", name: "Sea Flute", engine: .honeyTape, values: tape(breath: 0.70, strings: 0, wow: 0.30, age: 0.35, reel: 0, space: 0.55, width: 0.45), creditID: "music-to-watch-boys-to"),
        Patch(id: "velvet-strings", name: "Velvet Strings", engine: .honeyTape, values: tape(breath: 0.20, strings: 1, wow: 0.25, age: 0.35, reel: 0, space: 0.50, width: 0.70), creditID: "music-to-watch-boys-to"),
        Patch(id: "old-reel", name: "Old Reel", engine: .honeyTape, values: tape(breath: 0.45, strings: 0.35, wow: 0.70, age: 0.75, reel: 1, space: 0.45, width: 0.50), creditID: "music-to-watch-boys-to"),
        Patch(id: "haze-bells", name: "Haze Bells", engine: .hazeBells, values: bells(bells: 0.80, organ: 0.25, echo: 0.35, crush: 0.15, drift: 0.30, space: 0.50), creditID: "high-by-the-beach"),
        Patch(id: "church-keys", name: "Church Keys", engine: .hazeBells, values: bells(bells: 0.45, organ: 0.80, echo: 0.25, crush: 0.10, drift: 0.20, space: 0.60), creditID: "high-by-the-beach"),
        Patch(id: "night-drive", name: "Night Drive", engine: .hazeBells, values: bells(bells: 0.80, organ: 0.30, echo: 0.65, crush: 0.15, drift: 0.35, space: 0.70), creditID: "high-by-the-beach"),
        Patch(id: "lo-fi", name: "Lo-Fi", engine: .hazeBells, values: bells(bells: 0.75, organ: 0.30, echo: 0.40, crush: 0.60, drift: 0.60, space: 0.45), creditID: "high-by-the-beach"),
        Patch(id: "cabin-felt", name: "Cabin Felt", engine: .cabinFelt, values: cabin(felt: 0.60, horn: 0.30, fire: 0.50, wood: 0.50, space: 0.35, width: 0.50), creditID: "stay"),
        Patch(id: "fireside", name: "Fireside", engine: .cabinFelt, values: cabin(felt: 0.55, horn: 0, fire: 0.70, wood: 0.60, space: 0.30, width: 0.45), creditID: "stay"),
        Patch(id: "snow-horn", name: "Snow Horn", engine: .cabinFelt, values: cabin(felt: 0.70, horn: 0.75, fire: 0.45, wood: 0.45, space: 0.50, width: 0.55), creditID: "stay"),
        Patch(id: "late-night", name: "Late Night", engine: .cabinFelt, values: cabin(felt: 0.85, horn: 0.20, fire: 0.60, wood: 0.35, space: 0.25, width: 0.40), creditID: "stay"),
        Patch(id: "morning-box", name: "Morning Box", engine: .morningBox, values: morning(bars: 0.60, box: 0.20, bloom: 0.40, build: 0.50, haze: 0.35, space: 0.50, width: 0.55), creditID: "dunno"),
        Patch(id: "music-box", name: "Music Box", engine: .morningBox, values: morning(bars: 0.50, box: 1, bloom: 0.10, build: 0.20, haze: 0.25, space: 0.40, width: 0.40), creditID: "dunno"),
        Patch(id: "wall-of-light", name: "Wall of Light", engine: .morningBox, values: morning(bars: 0.45, box: 0.15, bloom: 0.85, build: 0.90, haze: 0.45, space: 0.65, width: 0.80), creditID: "dunno"),
        Patch(id: "snooze", name: "Snooze", engine: .morningBox, values: morning(bars: 0.35, box: 0.30, bloom: 0.55, build: 0.40, haze: 0.70, space: 0.55, width: 0.50), creditID: "dunno"),
        Patch(id: "polar-choir", name: "Polar Choir", engine: .polarChoir, values: choir(vowel: 0.55, breath: 0.35, glass: 0.30, swell: 0.55, shimmer: 0.25, space: 0.60, width: 0.60), creditID: "wings"),
        Patch(id: "far-voices", name: "Far Voices", engine: .polarChoir, values: choir(vowel: 0.70, breath: 0.55, glass: 0.10, swell: 0.75, shimmer: 0.40, space: 0.80, width: 0.75), creditID: "wings"),
        Patch(id: "bowed-glass", name: "Bowed Glass", engine: .polarChoir, values: choir(vowel: 0.40, breath: 0.10, glass: 0.85, swell: 0.45, shimmer: 0.30, space: 0.55, width: 0.50), creditID: "wings"),
        Patch(id: "hush", name: "Hush", engine: .polarChoir, values: choir(vowel: 0.30, breath: 0.50, glass: 0.20, swell: 0.35, shimmer: 0.10, space: 0.45, width: 0.40), creditID: "wings"),
        Patch(id: "plankton-keys", name: "Plankton Keys", engine: .planktonKeys, values: keys(tine: 0.55, bark: 0.40, sparkle: 0.50, tremolo: 0.35, phase: 0.20, space: 0.50, width: 0.55), creditID: "happiness-is-a-butterfly"),
        Patch(id: "glow-wake", name: "Glow Wake", engine: .planktonKeys, values: keys(tine: 0.65, bark: 0.30, sparkle: 0.85, tremolo: 0.50, phase: 0.35, space: 0.65, width: 0.70), creditID: "happiness-is-a-butterfly"),
        Patch(id: "tide-tines", name: "Tide Tines", engine: .planktonKeys, values: keys(tine: 0.85, bark: 0.60, sparkle: 0.25, tremolo: 0.20, phase: 0.10, space: 0.40, width: 0.50), creditID: "happiness-is-a-butterfly"),
        Patch(id: "midnight-bay", name: "Midnight Bay", engine: .planktonKeys, values: keys(tine: 0.35, bark: 0.20, sparkle: 0.40, tremolo: 0.45, phase: 0.30, space: 0.70, width: 0.60), creditID: "happiness-is-a-butterfly"),
        // Tea House Koto is born from its place (Tea House Snow), not from a song: no credit, so the names stay plain.
        Patch(id: "tea-house-koto", name: "Tea House Koto", engine: .teaHouseKoto, values: koto(pick: 0.55, silk: 0.45, body: 0.50, bloom: 0.40, yuri: 0.30, space: 0.35, width: 0.50)),
        Patch(id: "winter-strings", name: "Winter Strings", engine: .teaHouseKoto, values: koto(pick: 0.35, silk: 0.70, body: 0.60, bloom: 0.55, yuri: 0.20, space: 0.45, width: 0.55)),
        Patch(id: "near-the-bridge", name: "Near the Bridge", engine: .teaHouseKoto, values: koto(pick: 0.15, silk: 0.25, body: 0.40, bloom: 0.25, yuri: 0.35, space: 0.25, width: 0.45)),
        Patch(id: "night-tea", name: "Night Tea", engine: .teaHouseKoto, values: koto(pick: 0.45, silk: 0.60, body: 0.55, bloom: 0.60, yuri: 0.40, space: 0.50, width: 0.50)),
        // Blue Depth, after "Underwater" (spec §4.2): every preset at the record's 118 BPM.
        Patch(id: "blue-depth", name: "Blue Depth", engine: .blueDepth, values: blueDepth(blink: 0.60, murk: 0.55, ghosts: 0.40, echo: 0.50, bass: 0.55, tempo: 118, space: 0.55, width: 0.60), creditID: "underwater"),
        Patch(id: "ghost-signal", name: "Ghost Signal", engine: .blueDepth, values: blueDepth(blink: 0.35, murk: 0.45, ghosts: 0.75, echo: 0.65, bass: 0.30, tempo: 118, space: 0.70, width: 0.70), creditID: "underwater"),
        Patch(id: "pressure-hull", name: "Pressure Hull", engine: .blueDepth, values: blueDepth(blink: 0.75, murk: 0.80, ghosts: 0.25, echo: 0.40, bass: 0.80, tempo: 118, space: 0.45, width: 0.50), creditID: "underwater"),
        Patch(id: "surface-light", name: "Surface Light", engine: .blueDepth, values: blueDepth(blink: 0.50, murk: 0.25, ghosts: 0.35, echo: 0.55, bass: 0.40, tempo: 118, space: 0.50, width: 0.65), creditID: "underwater"),
    ]

    public static func defaultPatch(for engine: BuiltInEngine) -> Patch {
        all.first { $0.engine == engine }!
    }

    public static func patches(for engine: BuiltInEngine) -> [Patch] { all.filter { $0.engine == engine } }

    private static func dials(felt: Double, glass: Double, warmth: Double, ring: Double, space: Double, width: Double) -> [String: Double] {
        ["felt": felt, "glass": glass, "warmth": warmth, "ring": ring, "space": space, "width": width]
    }

    private static func bells(bells: Double, organ: Double, echo: Double, crush: Double, drift: Double, space: Double) -> [String: Double] {
        ["bells": bells, "organ": organ, "echo": echo, "crush": crush, "drift": drift, "space": space]
    }

    private static func tape(breath: Double, strings: Double, wow: Double, age: Double, reel: Double, space: Double, width: Double) -> [String: Double] {
        ["breath": breath, "strings": strings, "wow": wow, "age": age, "reel": reel, "space": space, "width": width]
    }

    private static func cabin(felt: Double, horn: Double, fire: Double, wood: Double, space: Double, width: Double) -> [String: Double] {
        ["felt": felt, "horn": horn, "fire": fire, "wood": wood, "space": space, "width": width]
    }

    private static func morning(bars: Double, box: Double, bloom: Double, build: Double, haze: Double, space: Double, width: Double) -> [String: Double] {
        ["bars": bars, "box": box, "bloom": bloom, "build": build, "haze": haze, "space": space, "width": width]
    }

    private static func choir(vowel: Double, breath: Double, glass: Double, swell: Double, shimmer: Double, space: Double, width: Double) -> [String: Double] {
        ["vowel": vowel, "breath": breath, "glass": glass, "swell": swell, "shimmer": shimmer, "space": space, "width": width]
    }

    private static func keys(tine: Double, bark: Double, sparkle: Double, tremolo: Double, phase: Double, space: Double, width: Double) -> [String: Double] {
        ["tine": tine, "bark": bark, "sparkle": sparkle, "tremolo": tremolo, "phase": phase, "space": space, "width": width]
    }

    private static func koto(pick: Double, silk: Double, body: Double, bloom: Double, yuri: Double, space: Double, width: Double) -> [String: Double] {
        ["pick": pick, "silk": silk, "body": body, "bloom": bloom, "yuri": yuri, "space": space, "width": width]
    }

    /// Tempo is in BPM (70…160); every other dial 0…1.
    private static func blueDepth(blink: Double, murk: Double, ghosts: Double, echo: Double, bass: Double, tempo: Double, space: Double, width: Double) -> [String: Double] {
        ["blink": blink, "murk": murk, "ghosts": ghosts, "echo": echo, "bass": bass, "tempo": tempo, "space": space, "width": width]
    }

    private static func pad(bloom: Double, drift: Double, motion: Double, shimmer: Double, brightness: Double, space: Double) -> [String: Double] {
        ["bloom": bloom, "drift": drift, "motion": motion, "shimmer": shimmer, "brightness": brightness, "space": space]
    }
}
