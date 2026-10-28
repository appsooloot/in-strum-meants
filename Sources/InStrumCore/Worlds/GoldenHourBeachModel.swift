import Foundation
import simd

/// Everything the Golden Hour Beach renderer needs for a frame.
public struct BeachFrame: AmbienceProviding {
    public var sky: SkyState
    public var lines: [TideLine]
    /// Golden foam on the latest break (from chords), 0…1.
    public var foam: Float
    /// The swell's four component phases (wrapped, for the shaders).
    public var swellPhases: SIMD4<Float>
    /// The next waves to break and the last few that did.
    public var upcoming: [Wave]
    public var recent: [Wave]
    /// How far up the sand the wash reaches now (0 waterline … 1 top of the wet sand).
    public var washFront: Float
    public var swellScale: Float
    public var swellTime: Double
    /// 0…1: how much the sun (or moon) path sparkles.
    public var glitter: Float
    public var keys: [KeyVisual]
    public var ambience: AmbienceScene
    public var mood: Mood
    public var time: Double
    /// Galaxy Warp over the beach's sky, when it's the chosen visual (notes then streak instead of writing).
    public var warp: WarpFrame?
}

/// Set 3's world: a wide beach at the waterline facing a low sun, long swells breaking softly, the wash sliding
/// up the sand. Its visual, Tide Lines, writes your notes into the wet sand for the tide to erase.
public struct GoldenHourBeachModel: ThemeModel, MoodAware, SkyAware {
    public typealias Frame = BeachFrame
    public static let id = "golden-hour-beach"
    public static let displayName = "Golden Hour Beach"
    public static let visuals = ["Tide Lines", "Galaxy Warp"]

    public var mood = Mood.neutral
    private var sky = SkyState()
    private var swell = OceanSwell(seed: 0xBEAC4)
    private var tide = TideLines()
    private var warp = GalaxyWarp()
    private var pending: [PerformanceEvent] = []
    private var held: [UInt8: Float] = [:]
    private var pedal = false
    private var keyGlow = [Float](repeating: 0, count: 88)
    private var glitter: Float = 0
    private var time = 0.0
    private var lastLightning: Float = 0
    private var thunderRng = SeededRandom(seed: 0xBEAC)

    private static let layout = KeyboardLayout.keys()

    public init() {}

    public mutating func handle(_ e: PerformanceEvent) { pending.append(e) }

    public mutating func setSky(_ s: SkyState) { sky = s }

    public mutating func step(dt: Double, params p: ParameterSet, roles: RoleValues, inputs: InputFrame, quality: QualityLevel) -> BeachFrame {
        time += dt
        tide.glow = Float(p.number("lines.glow"))
        tide.linger = Float(p.number("lines.linger"))
        tide.foamAmount = Float(p.number("foam"))
        tide.reactionScale = MoodLook.reactionScale(mood)
        tide.lingerScale = MoodLook.lingerScale(mood)
        let warping = p.choice("visual") == "Galaxy Warp"
        for e in pending {
            switch e {
            case let .noteOn(note, velocity):
                held[note] = velocity
                let v = UInt8(min(127, max(0, (velocity * 127).rounded())))
                if warping { warp.noteOn(note, velocity: v, at: time) } else { tide.noteOn(note, velocity: v, pedal: pedal, at: time) }
            case let .noteOff(note):
                held[note] = nil
                tide.noteOff(note)
                warp.noteOff(note)
            case let .pedal(down, _):
                pedal = down
            case .allNotesOff:
                held.removeAll()
                tide.allNotesOff()
                warp.allNotesOff()
                keyGlow = .init(repeating: 0, count: 88)
            default:
                break
            }
        }
        pending.removeAll(keepingCapacity: true)

        swell.scale = OceanSwell.weatherScale(sky)
        let breaks = swell.step(dt: dt)
        let front = swell.washFront(at: swell.time)
        tide.step(dt: dt, washFront: front, breaks: breaks, roles: roles)
        let warpFrame = warp.step(dt: dt, roles: roles, inputs: inputs)
        let target = min(1, Float(held.count) / 4)
        glitter += (target - glitter) * (1 - exp(-Float(dt) / 0.35))

        // Keys glow golden amber while held, then fade (longer when lingering).
        let fall = Float(pow(0.5, dt / (roles[.linger] > 0.5 ? 1.2 : 0.3)))
        for i in 0..<88 {
            let note = UInt8(i + 21)
            if let v = held[note] { keyGlow[i] = max(keyGlow[i] * fall, v * 0.7) } else { keyGlow[i] *= fall }
        }
        let keys = Self.layout.map { k in KeyVisual(key: k, pressed: held[k.note] != nil, glow: keyGlow[Int(k.note) - 21]) }

        return BeachFrame(sky: sky, lines: tide.lines, foam: tide.foam, swellPhases: swell.phases(at: swell.time),
                          upcoming: swell.upcoming(3), recent: swell.recent, washFront: front, swellScale: swell.scale,
                          swellTime: swell.time, glitter: glitter, keys: keys,
                          ambience: ambience(roles: roles, params: p, breaks: breaks), mood: mood, time: time,
                          warp: warping ? warpFrame : nil)
    }

    /// The beach's soundscape: surf in step with the waves, fronds in the wind, gulls by day, crickets at dusk.
    private mutating func ambience(roles: RoleValues, params p: ParameterSet, breaks: [Wave]) -> AmbienceScene {
        let sunAlt = sky.sun.altitude
        let night = MoonlitLakeModel.smooth(-3, -9, sunAlt)
        let day = MoonlitLakeModel.smooth(-4, 2, sunAlt)
        let wind = Double(sky.wind)
        var levels: [AmbienceSource: Double] = [
            .surf: 0.9,
            .palms: min(1, 0.25 + wind) * p.number("palms"),
            .gulls: p.number("gulls") * day,
            .crickets: 0.6 * night,
            .breeze: min(1, 0.3 + wind),
            .rainOnWater: Double(sky.rain),
        ]
        if sky.wind > 0.6 { levels[.wind] = Double(sky.wind - 0.6) * 2 }
        WeatherAmbience.levels(sky, base: &levels)
        let sinceDusk = (sky.hourOfDay - 19 + 24).truncatingRemainder(dividingBy: 24)
        let nightCool = night > 0 ? min(1, sinceDusk / 8) : 0
        var thunder: Double?
        if sky.lightning > 0.9, lastLightning <= 0.9 { thunder = Double(thunderRng.range(0.15, 0.9)) }
        lastLightning = sky.lightning
        let activity = min(1, 0.6 * roles[.energy] + 0.4 * roles[.density])
        let wave = breaks.map { Double($0.strength) }.max()
        return AmbienceScene(levels: levels, nightCool: nightCool, activity: activity, thunder: thunder,
                             closeness: MoodLook.ambienceCloseness(base: 0.5, mood), density: MoodLook.ambienceDensity(mood),
                             wave: wave, speed: 0, surfDistance: 0.15, wetness: Double(sky.wetness))
    }
}

extension GoldenHourBeachModel {
    private static func slider(_ id: String, _ name: String, _ group: String, _ range: ClosedRange<Double>, _ def: Double,
                               hero: Bool = false, surprise: ClosedRange<Double>? = nil, help: String) -> ParamSpec {
        ParamSpec(id: id, name: name, group: group, help: help, kind: .slider(range), defaultValue: .number(def), hero: hero, surprise: surprise)
    }

    public static let parameters: [ParamSpec] = [
        ParamSpec(id: "visual", name: "Visual", group: "Visual", help: "What your playing draws on the beach",
                  kind: .choice(visuals), defaultValue: .choice("Tide Lines")),
        SkyHold.spec(default: .goldenHour),
        slider("lines.glow", "Line glow", "Tide Lines", 0...1, 0.6, hero: true, surprise: 0.2...1,
               help: "How brightly each note's line glows in the wet sand"),
        slider("lines.linger", "Lines linger", "Tide Lines", 0...1, 0.5, hero: true, surprise: 0.2...0.9,
               help: "How long a released note's line keeps glowing before it fades"),
        slider("foam", "Foam from chords", "Tide Lines", 0...1, 0.6, surprise: 0.2...1,
               help: "Chords make the next wave break in golden foam"),
        slider("glitter", "Sun path glitter", "Beach", 0...1, 0.7, hero: true, surprise: 0.3...1,
               help: "How much the sun's (or moon's) path sparkles while you hold notes"),
        slider("haze", "Haze", "Beach", 0...1, 0.4, surprise: 0...0.8, help: "Warm haze over the sea"),
        slider("palms", "Palms", "Beach", 0...1, 0.7, surprise: 0...1, help: "Palms swaying at the edges"),
        slider("gulls", "Gulls", "Beach", 0...1, 0, help: "Distant gulls by day (off until they pass your ear test)"),
        ParamSpec(id: "keys.show", name: "Show keys", group: "Keys", help: "A keyboard along the sand",
                  kind: .toggle, defaultValue: .bool(true)),
        slider("keys.height", "Keyboard height", "Keys", 0.06...0.3, 0.12, help: "How tall the keyboard is"),
    ]

    public static let macroTargets: [Macro: [(id: String, weight: Double)]] = [
        .intensity: [("lines.glow", 0.8), ("glitter", 0.6)],
        .speed: [],
        .density: [("foam", 0.8), ("palms", 0.5)],
        .glow: [("glitter", 1), ("lines.glow", 0.5)],
        .chaos: [("foam", 0.4)],
        .temperature: [],
    ]
}
