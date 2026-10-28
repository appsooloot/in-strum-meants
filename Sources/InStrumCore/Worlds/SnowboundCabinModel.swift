import Foundation
import simd

/// Everything the Snowbound Cabin renderer needs for a frame.
public struct CabinFrame: AmbienceProviding {
    /// The sky after `coldSky`: rain falls as snow, storms are blizzards, no lightning, never wet.
    public var sky: SkyState
    /// The frost level on the glass (0…0.85) and the warm patches notes melt in it.
    public var frostLevel: Float
    public var patches: [FrostPatch]
    /// The fire's flare from chords (0…1) and its colour (1 gold, 0 ember, 0.5 between).
    public var flare: Float
    public var flareWarm: Float
    /// High notes this frame: flakes near these x (0…1 across the window) catch the light.
    public var flakeGlints: [Float]
    /// The fire's light, flickering (0…1, deterministic).
    public var fireFlicker: Float
    /// The far cabin's window is lit (dusk until late at night).
    public var farCabinLit: Bool
    public var keys: [KeyVisual]
    public var ambience: AmbienceScene
    public var mood: Mood
    public var time: Double
    /// Galaxy Warp past the window, when it's the chosen visual (notes then streak instead of melting patches).
    public var warp: WarpFrame?
}

/// Set 5's world: a log cabin's window on a snowy valley at night or day, frost on the glass, the fire behind you.
/// Its visual, Frost Grow, lets the frost creep further while you hold notes, and each note melts a warm patch.
public struct SnowboundCabinModel: ThemeModel, MoodAware, SkyAware {
    public typealias Frame = CabinFrame
    public static let id = "snowbound-cabin"
    public static let displayName = "Snowbound Cabin Window"
    public static let visuals = ["Frost Grow", "Galaxy Warp"]

    public var mood = Mood.neutral
    private var sky = SkyState()
    private var frost = FrostGrow()
    private var warp = GalaxyWarp()
    private var pending: [PerformanceEvent] = []
    private var held: [UInt8: Float] = [:]
    private var keyGlow = [Float](repeating: 0, count: 88)
    private var time = 0.0

    private static let layout = KeyboardLayout.keys()

    public init() {}

    public mutating func handle(_ e: PerformanceEvent) { pending.append(e) }

    public mutating func setSky(_ s: SkyState) { sky = Self.coldSky(s) }

    /// It's cold here: rain falls as snow (and frosts the glass), storms become blizzards (gliding in and out with the
    /// weather, whiting out with each gust), no lightning and never wet.
    public static func coldSky(_ s: SkyState) -> SkyState {
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
        func cold(_ k: WeatherKind) -> WeatherKind {
            switch k {
            case .drizzle, .rain, .sunShower, .sleet, .hail: return .snow
            case .smokeHaze: return .mist
            case .monsoon: return .blizzard
            case .fogBank: return .mist
            case .storm: return .blizzard
            case .afterRain: return .lightCloud
            default: return k
            }
        }
        s.weather = cold(s.weather)
        s.nextWeather = cold(s.nextWeather)
        return s
    }

    /// The fire's flicker: a few incommensurate wobbles, always 0…1.
    static func flicker(_ t: Double) -> Float {
        let w = 0.5 * sin(t * 7.3) + 0.3 * sin(t * 13.1 + 1.3) + 0.2 * sin(t * 23.7 + 2.1) + 0.15 * sin(t * 3.1 + 0.4)
        return Float(min(1, max(0, 0.72 + 0.24 * w)))
    }

    public mutating func step(dt: Double, params p: ParameterSet, roles: RoleValues, inputs: InputFrame, quality: QualityLevel) -> CabinFrame {
        time += dt
        frost.frost = Float(p.number("frost"))
        frost.reactionScale = MoodLook.reactionScale(mood)
        frost.lingerScale = MoodLook.lingerScale(mood)
        let warping = p.choice("visual") == "Galaxy Warp"
        for e in pending {
            switch e {
            case let .noteOn(note, velocity):
                held[note] = velocity
                if warping {
                    warp.noteOn(note, velocity: UInt8(min(127, max(0, (velocity * 127).rounded()))), at: time)
                } else {
                    frost.noteOn(note, velocity: velocity, at: time)
                }
            case let .noteOff(note):
                held[note] = nil
                frost.noteOff(note)
                warp.noteOff(note)
            case let .pedal(down, _):
                frost.setPedal(down)
            case .allNotesOff:
                // A panic (or an unplugged keyboard) lets the pedal go too: no pedal-up will ever come for it.
                held.removeAll()
                frost.allNotesOff(); frost.setPedal(false)
                warp.allNotesOff()
                keyGlow = .init(repeating: 0, count: 88)
            default:
                break
            }
        }
        pending.removeAll(keepingCapacity: true)

        frost.step(dt: dt, baseFrost: sky.frost * frost.frost, roles: roles)
        let warpFrame = warp.step(dt: dt, roles: roles, inputs: inputs)

        // Keys glow ember amber while held, then fade.
        let fall = Float(pow(0.5, dt / (roles[.linger] > 0.5 ? 1.2 : 0.35)))
        for i in 0..<88 {
            let note = UInt8(i + 21)
            if let v = held[note] { keyGlow[i] = max(keyGlow[i] * fall, v * 0.7) } else { keyGlow[i] *= fall }
        }
        let keys = Self.layout.map { k in KeyVisual(key: k, pressed: held[k.note] != nil, glow: keyGlow[Int(k.note) - 21]) }

        let hour = sky.hourOfDay
        let farCabinLit = p.number("farCabin") > 0.02 && sky.sun.altitude < -4 && !(hour >= 1 && hour < 5)

        return CabinFrame(sky: sky, frostLevel: frost.level, patches: warping ? [] : frost.patches,
                          flare: frost.flare, flareWarm: frost.flareWarm, flakeGlints: frost.flakeGlints,
                          fireFlicker: Self.flicker(time), farCabinLit: farCabinLit, keys: keys,
                          ambience: ambience(roles: roles, params: p), mood: mood, time: time,
                          warp: warping ? warpFrame : nil)
    }

    /// The cabin's soundscape: the fire, the wind round the walls, snow ticking on the glass; all heard indoors.
    private func ambience(roles: RoleValues, params p: ParameterSet) -> AmbienceScene {
        var levels: [AmbienceSource: Double] = [
            .fire: 0.7 * p.number("fire"),
            .wind: min(1, 0.25 + Double(sky.gust)),
            .rainOnGlass: 0.4 * Double(sky.snow),
        ]
        WeatherAmbience.levels(sky, base: &levels)
        let activity = min(1, 0.6 * roles[.energy] + 0.4 * roles[.density])
        return AmbienceScene(levels: levels, nightCool: 0, activity: activity, thunder: nil,
                             closeness: MoodLook.ambienceCloseness(base: 0.7, mood), density: MoodLook.ambienceDensity(mood),
                             indoors: 1, wetness: 0, snowOnGlass: Double(sky.snow))
    }
}

extension SnowboundCabinModel {
    private static func slider(_ id: String, _ name: String, _ group: String, _ range: ClosedRange<Double>, _ def: Double,
                               hero: Bool = false, surprise: ClosedRange<Double>? = nil, help: String) -> ParamSpec {
        ParamSpec(id: id, name: name, group: group, help: help, kind: .slider(range), defaultValue: .number(def), hero: hero, surprise: surprise)
    }

    public static let parameters: [ParamSpec] = [
        ParamSpec(id: "visual", name: "Visual", group: "Visual", help: "What your playing does to the window",
                  kind: .choice(visuals), defaultValue: .choice("Frost Grow")),
        SkyHold.spec(default: .follow),
        slider("frost", "Frost", "Frost Grow", 0...1, 0.6, hero: true, surprise: 0.3...1,
               help: "How far the frost creeps over the glass while you hold notes"),
        slider("fire", "Fire glow", "Cabin", 0...1, 0.7, hero: true, surprise: 0.3...1,
               help: "The fire behind you: its light on the frame and its crackle"),
        slider("condensation", "Condensation", "Cabin", 0...1, 0.4, surprise: 0...0.8,
               help: "A soft fog along the bottom of the panes"),
        slider("farCabin", "Distant cabin", "Cabin", 0...1, 0.7, surprise: 0...1,
               help: "A far cabin across the valley whose window lights up at dusk"),
        ParamSpec(id: "keys.show", name: "Show keys", group: "Keys", help: "A keyboard below the sill",
                  kind: .toggle, defaultValue: .bool(true)),
        slider("keys.height", "Keyboard height", "Keys", 0.06...0.3, 0.12, help: "How tall the keyboard is"),
    ]

    public static let macroTargets: [Macro: [(id: String, weight: Double)]] = [
        .intensity: [("frost", 0.6), ("fire", 0.6)],
        .speed: [],
        .density: [("condensation", 0.5), ("frost", 0.4)],
        .glow: [("fire", 1), ("farCabin", 0.4)],
        .chaos: [("frost", 0.3)],
        .temperature: [("fire", 0.8)],
    ]
}
