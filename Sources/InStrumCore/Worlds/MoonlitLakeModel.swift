import Foundation
import simd

/// A world that tells the ambience what it should sound like this frame.
public protocol AmbienceProviding { var ambience: AmbienceScene { get } }

/// Everything the Moonlit Lake renderer needs for a frame.
public struct LakeFrame: AmbienceProviding {
    public var sky: SkyState
    public var ripples: [Ripple]
    public var fireflies: [Firefly]
    /// 0…1: how much the moon (or sun) path sparkles.
    public var glitter: Float
    public var keys: [KeyVisual]
    public var ambience: AmbienceScene
    public var mood: Mood
    public var time: Double
    /// Galaxy Warp over the lake's sky, when it's the chosen visual (notes then streak instead of rippling).
    public var warp: WarpFrame?
}

/// Set 1's world: a still lake under the Living Sky, ridges and pines, reeds and mist.
/// Its visual, Lake Ripples, answers your notes on the water.
public struct MoonlitLakeModel: ThemeModel, MoodAware, SkyAware {
    public typealias Frame = LakeFrame
    public static let id = "moonlit-lake"
    public static let displayName = "Moonlit Lake"
    public static let visuals = ["Lake Ripples", "Galaxy Warp"]

    public var mood = Mood.neutral
    private var sky = SkyState()
    private var lake = LakeRipples()
    private var warp = GalaxyWarp()
    private var pending: [PerformanceEvent] = []
    private var held: [UInt8: Float] = [:]
    private var pedal = false
    private var keyGlow = [Float](repeating: 0, count: 88)
    private var time = 0.0
    private var lastLightning: Float = 0
    private var thunderRng = SeededRandom(seed: 0x7E11)

    private static let layout = KeyboardLayout.keys()

    public init() {}

    public mutating func handle(_ e: PerformanceEvent) { pending.append(e) }

    public mutating func setSky(_ s: SkyState) { sky = s }

    public mutating func step(dt: Double, params p: ParameterSet, roles: RoleValues, inputs: InputFrame, quality: QualityLevel) -> LakeFrame {
        time += dt
        lake.size = Float(p.number("ripples.size"))
        lake.linger = Float(p.number("ripples.linger"))
        lake.fireflyAmount = Float(p.number("fireflies"))
        lake.reactionScale = MoodLook.reactionScale(mood)
        lake.lingerScale = MoodLook.lingerScale(mood)
        let warping = p.choice("visual") == "Galaxy Warp"
        for e in pending {
            switch e {
            case let .noteOn(note, velocity):
                held[note] = velocity
                let v = UInt8(min(127, max(0, (velocity * 127).rounded())))
                if warping { warp.noteOn(note, velocity: v, at: time) } else { lake.noteOn(note, velocity: v, pedal: pedal, at: time) }
            case let .noteOff(note):
                held[note] = nil
                lake.noteOff(note)
                warp.noteOff(note)
            case let .pedal(down, _):
                pedal = down
            case .allNotesOff:
                held.removeAll()
                lake.allNotesOff()
                warp.allNotesOff()
                keyGlow = .init(repeating: 0, count: 88)
            default:
                break
            }
        }
        pending.removeAll(keepingCapacity: true)
        lake.step(dt: dt, roles: roles)
        let warpFrame = warp.step(dt: dt, roles: roles, inputs: inputs)

        // Keys glow moon-silver while held, then fade (longer when lingering).
        let fall = Float(pow(0.5, dt / (roles[.linger] > 0.5 ? 1.2 : 0.3)))
        for i in 0..<88 {
            let note = UInt8(i + 21)
            if let v = held[note] { keyGlow[i] = max(keyGlow[i] * fall, v * 0.7) } else { keyGlow[i] *= fall }
        }
        let keys = Self.layout.map { k in KeyVisual(key: k, pressed: held[k.note] != nil, glow: keyGlow[Int(k.note) - 21]) }

        return LakeFrame(sky: sky, ripples: lake.ripples, fireflies: lake.fireflies, glitter: lake.glitter, keys: keys,
                         ambience: ambience(roles: roles), mood: mood, time: time, warp: warping ? warpFrame : nil)
    }

    /// The lake's soundscape, following the sky and your playing.
    private mutating func ambience(roles: RoleValues) -> AmbienceScene {
        let sunAlt = sky.sun.altitude
        let night = Self.smooth(-3, -9, sunAlt)
        let rising = sky.hourOfDay < 12
        let dawn = rising ? Self.smooth(-7, -5, sunAlt) * Self.smooth(9, 6, sunAlt) : 0
        var levels: [AmbienceSource: Double] = [
            .water: 0.8,
            .crickets: 0.7 * night,
            .dawnChorus: 0.5 * dawn,
            .breeze: min(1, 0.3 + Double(sky.wind)),
            .owl: 0.3 * night,
            .rainOnWater: Double(sky.rain),
        ]
        if sky.wind > 0.6 { levels[.wind] = Double(sky.wind - 0.6) * 2 }
        WeatherAmbience.levels(sky, base: &levels)
        // Night cools from dusk (about 19:00) over eight hours.
        let sinceDusk = (sky.hourOfDay - 19 + 24).truncatingRemainder(dividingBy: 24)
        let nightCool = night > 0 ? min(1, sinceDusk / 8) : 0
        var thunder: Double?
        if sky.lightning > 0.9, lastLightning <= 0.9 { thunder = Double(thunderRng.range(0.15, 0.9)) }
        lastLightning = sky.lightning
        let activity = min(1, 0.6 * roles[.energy] + 0.4 * roles[.density])
        return AmbienceScene(levels: levels, nightCool: nightCool, activity: activity, thunder: thunder,
                             closeness: MoodLook.ambienceCloseness(base: 0.5, mood), density: MoodLook.ambienceDensity(mood),
                             indoors: WeatherAmbience.indoorsLift(sky), wetness: Double(sky.wetness))
    }

    static func smooth(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = min(1, max(0, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }
}

extension MoonlitLakeModel {
    private static func slider(_ id: String, _ name: String, _ group: String, _ range: ClosedRange<Double>, _ def: Double,
                               hero: Bool = false, surprise: ClosedRange<Double>? = nil, help: String) -> ParamSpec {
        ParamSpec(id: id, name: name, group: group, help: help, kind: .slider(range), defaultValue: .number(def), hero: hero, surprise: surprise)
    }

    public static let parameters: [ParamSpec] = [
        ParamSpec(id: "visual", name: "Visual", group: "Visual", help: "What your playing draws on the lake",
                  kind: .choice(visuals), defaultValue: .choice("Lake Ripples")),
        MeteorMode.spec(default: .follow),
        slider("ripples.size", "Ripple size", "Lake Ripples", 0...1, 0.5, hero: true, surprise: 0.2...0.9,
               help: "How far each note's ring spreads"),
        slider("ripples.linger", "Ripples linger", "Lake Ripples", 0...1, 0.5, hero: true, surprise: 0.2...0.9,
               help: "How long the rings keep moving"),
        slider("fireflies", "Fireflies from chords", "Lake Ripples", 0...1, 0.6, surprise: 0.2...1,
               help: "Chords lift fireflies off the water"),
        slider("glitter", "Moon path glitter", "Lake", 0...1, 0.7, hero: true, surprise: 0.3...1,
               help: "How much the moon's path sparkles while you hold notes"),
        slider("mist", "Mist", "Lake", 0...1, 0.4, surprise: 0...0.8, help: "Mist lying on the water"),
        slider("reeds", "Reeds", "Lake", 0...1, 0.6, surprise: 0...1, help: "Reeds at the water's edge"),
        ParamSpec(id: "keys.show", name: "Show keys", group: "Keys", help: "A glassy keyboard along the shore",
                  kind: .toggle, defaultValue: .bool(true)),
        slider("keys.height", "Keyboard height", "Keys", 0.06...0.3, 0.12, help: "How tall the keyboard is"),
    ]

    public static let macroTargets: [Macro: [(id: String, weight: Double)]] = [
        .intensity: [("ripples.size", 0.8), ("glitter", 0.6)],
        .speed: [],
        .density: [("fireflies", 0.8), ("reeds", 0.5)],
        .glow: [("glitter", 1)],
        .chaos: [("ripples.size", 0.4)],
        .temperature: [],
    ]
}
