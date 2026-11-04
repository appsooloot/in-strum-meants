import Foundation

/// Everything the Tea House Snow renderer needs for a frame.
public struct TeaHouseFrame: AmbienceProviding {
    /// The sky after `WorldWeather.cold`: rain falls as snow, storms are blizzards, no lightning, never wet (rime frost
    /// and diamond dust stay).
    public var sky: SkyState
    /// Steam Lines (empty, straight, 0, still and nil while Frost Grow plays): the wisps notes send off the steam; the
    /// ribbon's path (`SteamLines.pathPoints` lateral offsets, −1…1, index 0 at the bowl: the latest run's contour); the
    /// steam's brightening from held notes (0…1); a chord's puff; the latest snowflake knocked off the lantern's cap.
    public var wisps: [SteamWisp]
    public var ribbonPath: [Float]
    public var steamGlow: Float
    public var puff: SteamPuff
    public var lanternFlake: LanternFlake?
    /// How many soft ribbons the tea's steam rises in (2…4 by the Tea steam setting, whatever the visual).
    public var ribbons: Int
    /// Frost on the screens' paper (0…0.85: the cold sky's, whatever the visual) and the warm patches notes melt in it
    /// when Frost Grow is the visual.
    public var frostLevel: Float
    public var patches: [FrostPatch]
    /// How far the shōji are slid open: 0 closed (the room is all paper light) … 1 open on the snow garden.
    public var screensOpen: Float
    /// The plum's red blossoms, 0…1: the setting, hidden while it snows hard.
    public var blossom: Float
    public var keys: [KeyVisual]
    public var ambience: AmbienceScene
    public var mood: Mood
    public var time: Double
    /// Always nil: the tea house's visuals are Steam Lines and Frost Grow (spec §8.1), not Galaxy Warp. The field is
    /// kept so the frame reads like every other world's.
    public var warp: WarpFrame?
}

/// Set 9's world: kneeling at a low table in a small tea house, the tea bowl steaming and the iron kettle on its
/// brazier, the paper screens slid half open on a snow garden (a stone lantern capped with snow, a pine bent under it,
/// a stone basin with a bamboo ladle, a low fence and a plum tree in a few red blossoms). Its visual, Steam Lines, lets
/// your notes curl the tea's steam; Frost Grow works on the screens' paper instead.
public struct TeaHouseSnowModel: ThemeModel, MoodAware, SkyAware {
    public typealias Frame = TeaHouseFrame
    public static let id = "tea-house-snow"
    public static let displayName = "Tea House Snow"
    public static let visuals = ["Steam Lines", "Frost Grow"]
    /// How far Frost Grow lets the frost creep over the paper (FrostGrow's own default: the tea house has no Frost
    /// setting of its own).
    static let paperFrost: Float = 0.6

    public var mood = Mood.neutral
    private var sky = SkyState()
    private var steam = SteamLines()
    private var frost = FrostGrow()
    private var pending: [PerformanceEvent] = []
    private var held: [UInt8: Float] = [:]
    private var keyGlow = [Float](repeating: 0, count: 88)
    private var lastVisual: String?
    private var time = 0.0

    private static let layout = KeyboardLayout.keys()

    public init() {}

    public mutating func handle(_ e: PerformanceEvent) { pending.append(e) }

    /// It's cold here: the cold-world rule (`WorldWeather.cold`), as at the cabin.
    public mutating func setSky(_ s: SkyState) { sky = WorldWeather.cold(s) }

    /// How much of the outdoors the room keeps out (the scene's `indoors` before the rime's hush): paper lets more
    /// through than glass, so 0.8 with the screens closed, and 0.3 slid open on the garden (0.8 − 0.5 × screens).
    public static func indoors(screens: Double) -> Double {
        let s = screens.isFinite ? min(max(screens, 0), 1) : 0.5
        return 0.8 - 0.5 * s
    }

    /// The plum's blossoms: the setting, thinning away as the snow gets heavy (all there below snow 0.5, gone at 0.85).
    public static func blossom(_ setting: Double, snow: Float) -> Float {
        let b = setting.isFinite ? min(max(setting, 0), 1) : 0
        let s = snow.isFinite ? Double(min(max(snow, 0), 1)) : 0
        return Float(b * (1 - MoonlitLakeModel.smooth(0.5, 0.85, s)))
    }

    /// The temple bell's hours: 0 with the sun 6° up … 1 from 4° below the horizon (dusk, the night and the dark
    /// before dawn).
    static func nightAndDusk(_ s: SkyState) -> Double { MoonlitLakeModel.smooth(6, -4, s.sun.altitude) }

    public mutating func step(dt: Double, params p: ParameterSet, roles: RoleValues, inputs: InputFrame, quality: QualityLevel) -> TeaHouseFrame {
        let fdt = dt.isFinite ? min(max(dt, 0), 0.25) : 0
        time += fdt
        let visual = p.choice("visual")
        let frostVisual = visual == "Frost Grow"
        // Switching visuals lets held notes go: no wisp stays drawn up, no patch stays warm.
        if let lastVisual, lastVisual != visual { steam.allNotesOff(); frost.allNotesOff() }
        lastVisual = visual
        steam.reactionScale = MoodLook.reactionScale(mood)
        steam.lingerScale = MoodLook.lingerScale(mood)
        frost.frost = Self.paperFrost
        frost.reactionScale = MoodLook.reactionScale(mood)
        frost.lingerScale = MoodLook.lingerScale(mood)
        for e in pending {
            switch e {
            case let .noteOn(note, velocity):
                held[note] = velocity
                if frostVisual { frost.noteOn(note, velocity: velocity, at: time) } else { steam.noteOn(note, velocity: velocity, at: time) }
            case let .noteOff(note):
                held[note] = nil
                steam.noteOff(note); frost.noteOff(note)
            case let .pedal(down, _):
                steam.setPedal(down); frost.setPedal(down)
            case .allNotesOff:
                // A panic (or an unplugged keyboard) lets the pedal go too: no pedal-up will ever come for it.
                held.removeAll()
                steam.allNotesOff(); steam.setPedal(false)
                frost.allNotesOff(); frost.setPedal(false)
                keyGlow = .init(repeating: 0, count: 88)
            default:
                break
            }
        }
        pending.removeAll(keepingCapacity: true)

        steam.step(dt: fdt, roles: roles)
        frost.step(dt: fdt, baseFrost: sky.frost * frost.frost, roles: roles)

        // Keys glow a warm lantern amber while held, then fade (longer when lingering).
        let fall = Float(pow(0.5, fdt / (roles[.linger] > 0.5 ? 1.2 : 0.35)))
        for i in 0..<88 {
            let note = UInt8(i + 21)
            if let v = held[note] { keyGlow[i] = max(keyGlow[i] * fall, v * 0.7) } else { keyGlow[i] *= fall }
        }
        let keys = Self.layout.map { k in KeyVisual(key: k, pressed: held[k.note] != nil, glow: keyGlow[Int(k.note) - 21]) }

        let screens = p.number("screens")
        let steaming = !frostVisual
        return TeaHouseFrame(sky: sky,
                             wisps: steaming ? steam.wisps : [],
                             ribbonPath: steaming ? steam.ribbonPath : SteamLines.straight,
                             steamGlow: steaming ? steam.glow : 0,
                             puff: steaming ? steam.puff : .still,
                             lanternFlake: steaming ? steam.lanternFlake : nil,
                             ribbons: SteamLines.ribbonCount(steam: Float(p.number("steam"))),
                             frostLevel: frost.level, patches: frostVisual ? frost.patches : [],
                             screensOpen: Float(min(max(screens, 0), 1)),
                             blossom: Self.blossom(p.number("blossom"), snow: sky.snow),
                             keys: keys, ambience: ambience(roles: roles, screens: screens), mood: mood, time: time,
                             warp: nil)
    }

    /// The tea house's soundscape: the iron kettle on the brazier, the paper screens rustling in the draught, the temple
    /// bell (fuller from dusk and through the night), the wind, snow ticking on the paper and birds at dawn. The garden
    /// comes in as far as the screens are open, a little hushed once it is rimed.
    private func ambience(roles: RoleValues, screens: Double) -> AmbienceScene {
        let sunAlt = sky.sun.altitude
        let dawn = sky.hourOfDay < 12 ? MoonlitLakeModel.smooth(-7, -5, sunAlt) * MoonlitLakeModel.smooth(9, 6, sunAlt) : 0
        let paper = Self.indoors(screens: screens)
        var levels: [AmbienceSource: Double] = [
            .kettle: 0.35,
            .paperScreens: min(1, 0.4 * (0.4 + Double(sky.wind))),
            .templeBell: 0.5 * (0.5 + 0.5 * Self.nightAndDusk(sky)),
            .wind: min(1, 0.1 + Double(sky.gust)),
            .rainOnGlass: Double(sky.snow) * paper,   // with `snowOnGlass`, the snow's soft ticks on the paper
            .dawnChorus: 0.2 * dawn,
        ]
        WeatherAmbience.levels(sky, base: &levels)
        let activity = min(1, 0.6 * roles[.energy] + 0.4 * roles[.density])
        return AmbienceScene(levels: levels, nightCool: 0, activity: activity, thunder: nil,
                             closeness: MoodLook.ambienceCloseness(base: 0.75, mood), density: MoodLook.ambienceDensity(mood),
                             indoors: min(1, paper + WeatherAmbience.indoorsLift(sky)), wetness: Double(sky.wetness),
                             snowOnGlass: Double(sky.snow))
    }
}

extension TeaHouseSnowModel {
    private static func slider(_ id: String, _ name: String, _ group: String, _ range: ClosedRange<Double>, _ def: Double,
                               hero: Bool = false, surprise: ClosedRange<Double>? = nil, help: String) -> ParamSpec {
        ParamSpec(id: id, name: name, group: group, help: help, kind: .slider(range), defaultValue: .number(def), hero: hero, surprise: surprise)
    }

    public static let parameters: [ParamSpec] = [
        ParamSpec(id: "visual", name: "Visual", group: "Visual", help: "What your playing does in the tea house",
                  kind: .choice(visuals), defaultValue: .choice("Steam Lines")),
        SkyHold.spec(default: .follow),
        AuroraMode.spec(default: .follow),
        slider("screens", "Screens open", "Tea House", 0...1, 0.5, hero: true, surprise: 0.2...1,
               help: "How far the paper screens are slid open on the snow garden; closed, the room is all paper light"),
        slider("steam", "Tea steam", "Steam Lines", 0...1, 0.6, hero: true, surprise: 0.3...1,
               help: "How much the tea steams: two to four soft ribbons rising from the bowl"),
        slider("blossom", "Plum blossom", "Tea House", 0...1, 0.4, surprise: 0...1,
               help: "Red blossoms on the plum tree in the garden, hidden while it snows hard"),
        ParamSpec(id: "keys.show", name: "Show keys", group: "Keys", help: "A keyboard along the edge of the low table",
                  kind: .toggle, defaultValue: .bool(true)),
        slider("keys.height", "Keyboard height", "Keys", 0.06...0.3, 0.12, help: "How tall the keyboard is"),
    ]

    public static let macroTargets: [Macro: [(id: String, weight: Double)]] = [
        .intensity: [("steam", 0.8)],
        .speed: [],
        .density: [("steam", 0.5), ("blossom", 0.5)],
        .glow: [("steam", 0.6)],
        .chaos: [],
        .temperature: [("blossom", 0.3)],
    ]
}
