import Foundation

/// A pale slab of ice drifting on the fjord.
public struct Floe: Equatable {
    /// Across the view (0…1, wrapping behind the walls at the edges).
    public var x: Float
    /// Down the fjord: 0 near the jetty … 1 at the far, sea end.
    public var depth: Float
    /// Its size (0…1 of the largest slab).
    public var size: Float
    /// Its turn about the vertical (radians).
    public var angle: Float
    /// Its own drift across the view with the current (per second, signed; the wind adds to it).
    public var drift: Float
}

/// Everything the Aurora Fjord renderer needs for a frame.
public struct FjordFrame: AmbienceProviding {
    /// The sky after `fjordSky`: rain falls as sleet, storms are blizzards, no lightning.
    public var sky: SkyState
    /// Curtain Lights: the ripples to draw (at most `CurtainLights.cap`, the strongest, in order), the held-note glow
    /// (0…1), the hue shift (−1 cool … +1 warm), a tense chord's purple-fringe pulse (0…1) and the shimmer speed (1…2).
    public var ripples: [CurtainRipple]
    public var glow: Float
    public var hueShift: Float
    public var tensePulse: Float
    public var shimmer: Float
    /// The ice floes on the water (6…14 by the Ice floes setting).
    public var floes: [Floe]
    /// The fishing village's lights are on (the sun below −4°).
    public var villageLit: Bool
    public var keys: [KeyVisual]
    public var ambience: AmbienceScene
    public var mood: Mood
    public var time: Double
    /// Galaxy Warp over the fjord's sky, when it's the chosen visual (notes then streak instead of rippling the curtain).
    public var warp: WarpFrame?
}

/// Set 7's world: a jetty at the head of a fjord looking down it toward the pole, the aurora over the sea end,
/// still black water mirroring it, a fishing village's lights and drifting ice. Its visual, Curtain Lights, lets
/// your notes ripple the aurora.
public struct AuroraFjordModel: ThemeModel, MoodAware, SkyAware {
    public typealias Frame = FjordFrame
    public static let id = "aurora-fjord"
    public static let displayName = "Aurora Fjord"
    public static let visuals = ["Curtain Lights", "Galaxy Warp"]
    /// The most floes the setting can ask for (the pool is built once, seeded).
    public static let maxFloes = 14, minFloes = 6

    public var mood = Mood.neutral
    private var sky = SkyState()
    private var lights = CurtainLights()
    private var warp = GalaxyWarp()
    private var pool: [Floe]
    private var pending: [PerformanceEvent] = []
    private var held: [UInt8: Float] = [:]
    private var keyGlow = [Float](repeating: 0, count: 88)
    private var time = 0.0
    private var lastVisual = ""
    private var lastLightning: Float = 0
    private var thunderRng = SeededRandom(seed: 0xF7_0AD)

    private static let layout = KeyboardLayout.keys()

    public init() {
        var r = SeededRandom(seed: 0xF10E_5EED)
        pool = (0..<Self.maxFloes).map { _ in
            let side: Float = r.unit() < 0.5 ? -1 : 1
            return Floe(x: r.range(0.05, 0.95), depth: r.range(0.08, 0.95), size: r.range(0.35, 1),
                        angle: r.range(0, 2 * .pi), drift: side * r.range(0.002, 0.008))
        }
    }

    public mutating func handle(_ e: PerformanceEvent) { pending.append(e) }

    public mutating func setSky(_ s: SkyState) { sky = Self.fjordSky(s) }

    /// It's cold here, but by the sea: the cold-world rule (`WorldWeather.cold`: storms become blizzards, no
    /// lightning, no fireflies, frost from the cold rain), except that rain falls as sleet, half rain and half snow,
    /// and leaves the jetty half as wet as rain would.
    public static func fjordSky(_ s: SkyState) -> SkyState {
        var c = WorldWeather.cold(s)
        // How much storm is in the sky right now (the same glide `cold` uses): that part is already a blizzard.
        let t = min(max(s.weatherBlend, 0), 1), glide = t * t * (3 - 2 * t)
        let storm = (s.weather == .storm ? 1 - glide : 0) + (s.nextWeather == .storm ? glide : 0)
        let sleet = max(0, s.rain) * (1 - storm)
        c.rain = 0.5 * sleet
        c.snow = max(s.snow, 0.5 * sleet, storm)
        c.wetness = 0.5 * s.wetness * (1 - storm)
        func sleety(_ k: WeatherKind, _ chilled: WeatherKind) -> WeatherKind {
            switch k {
            case .drizzle, .rain, .sunShower, .sleet, .freezingDrizzle: return .sleet
            default: return chilled
            }
        }
        c.weather = sleety(s.weather, c.weather)
        c.nextWeather = sleety(s.nextWeather, c.nextWeather)
        return c
    }

    /// How many floes the setting asks for (6…14).
    public static func floeCount(_ amount: Double) -> Int {
        let a = amount.isFinite ? min(max(amount, 0), 1) : 0.6
        return minFloes + Int((Double(maxFloes - minFloes) * a).rounded())
    }

    public mutating func step(dt: Double, params p: ParameterSet, roles: RoleValues, inputs: InputFrame, quality: QualityLevel) -> FjordFrame {
        let fdt = dt.isFinite ? min(max(dt, 0), 0.25) : 0
        time += fdt
        let visual = p.choice("visual")
        let warping = visual == "Galaxy Warp"
        if visual != lastVisual {
            // Switching visuals lets held notes go: no stuck ripples or streaks.
            lights.allNotesOff(); warp.allNotesOff()
            lastVisual = visual
        }
        lights.reactionScale = MoodLook.reactionScale(mood)
        lights.lingerScale = MoodLook.lingerScale(mood)
        for e in pending {
            switch e {
            case let .noteOn(note, velocity):
                held[note] = velocity
                if warping { warp.noteOn(note, velocity: UInt8(min(127, max(0, (velocity * 127).rounded()))), at: time) }
                else { lights.noteOn(note, velocity: velocity, at: time) }
            case let .noteOff(note):
                held[note] = nil
                lights.noteOff(note)
                warp.noteOff(note)
            case let .pedal(down, _):
                lights.setPedal(down)
            case .allNotesOff:
                // A panic (or an unplugged keyboard) lets the pedal go too: no pedal-up will ever come for it.
                held.removeAll()
                lights.allNotesOff(); lights.setPedal(false)
                warp.allNotesOff()
                keyGlow = .init(repeating: 0, count: 88)
            default:
                break
            }
        }
        pending.removeAll(keepingCapacity: true)

        lights.step(dt: fdt, roles: roles)
        let warpFrame = warp.step(dt: fdt, roles: roles, inputs: inputs)

        // The floes drift with the current and the wind (more with the swell), turning slowly, wrapping behind the walls.
        let swell = Float(min(max(p.number("swell"), 0), 1))
        let wind = sky.wind.isFinite ? min(max(sky.wind, 0), 1) : 0
        let fstep = Float(fdt)
        for i in pool.indices {
            var f = pool[i]
            let along: Float = f.drift < 0 ? -1 : 1
            let push = (f.drift + 0.006 * wind * along) * (0.6 + swell)
            f.x += push * fstep / (0.4 + 0.6 * f.depth)          // near floes cross the view faster
            if f.x < 0 { f.x += 1 } else if f.x > 1 { f.x -= 1 }
            f.angle += (f.drift * 6 + 0.01 * wind) * fstep
            if f.angle > 2 * .pi { f.angle -= 2 * .pi } else if f.angle < 0 { f.angle += 2 * .pi }
            pool[i] = f
        }
        let floes = Array(pool.prefix(Self.floeCount(p.number("floes"))))

        // Keys glow ice-blue while held, then fade (longer when lingering).
        let fall = Float(pow(0.5, fdt / (roles[.linger] > 0.5 ? 1.2 : 0.3)))
        for i in 0..<88 {
            let note = UInt8(i + 21)
            if let v = held[note] { keyGlow[i] = max(keyGlow[i] * fall, v * 0.7) } else { keyGlow[i] *= fall }
        }
        let keys = Self.layout.map { k in KeyVisual(key: k, pressed: held[k.note] != nil, glow: keyGlow[Int(k.note) - 21]) }

        let villageLit = p.number("village") > 0.02 && sky.sun.altitude < -4

        return FjordFrame(sky: sky,
                          ripples: warping ? [] : CurtainLights.visible(lights.ripples, limit: CurtainLights.cap),
                          glow: warping ? 0 : lights.glow, hueShift: lights.hueShift,
                          tensePulse: warping ? 0 : lights.tensePulse, shimmer: lights.shimmerSpeed,
                          floes: floes, villageLit: villageLit, keys: keys,
                          ambience: ambience(roles: roles), mood: mood, time: time, warp: warping ? warpFrame : nil)
    }

    /// The fjord's soundscape: ice groaning and cracking (more at night), a far waterfall on the right wall, still
    /// water lapping at the jetty, the wind down the fjord; no crickets, no owl.
    private mutating func ambience(roles: RoleValues) -> AmbienceScene {
        let sunAlt = sky.sun.altitude
        let night = MoonlitLakeModel.smooth(-3, -9, sunAlt)
        var levels: [AmbienceSource: Double] = [
            .iceGroan: 0.5 + 0.3 * night,
            .waterfall: 0.35,
            .water: 0.5,
            .wind: min(1, 0.2 + 0.8 * Double(sky.wind)),
            .lapping: 0.3,
            .breeze: 0.2,
            .rainOnWater: Double(sky.rain),
        ]
        WeatherAmbience.levels(sky, base: &levels)
        let sinceDusk = (sky.hourOfDay - 19 + 24).truncatingRemainder(dividingBy: 24)
        let nightCool = night > 0 ? min(1, sinceDusk / 8) : 0
        // Thunder as the lake (the cold sky has no lightning, so it stays quiet unless that changes).
        var thunder: Double?
        if sky.lightning > 0.9, lastLightning <= 0.9 { thunder = Double(thunderRng.range(0.15, 0.9)) }
        lastLightning = sky.lightning
        let activity = min(1, 0.6 * roles[.energy] + 0.4 * roles[.density])
        return AmbienceScene(levels: levels, nightCool: nightCool, activity: activity, thunder: thunder,
                             closeness: MoodLook.ambienceCloseness(base: 0.45, mood), density: MoodLook.ambienceDensity(mood),
                             wetness: Double(sky.wetness))
    }
}

extension AuroraFjordModel {
    private static func slider(_ id: String, _ name: String, _ group: String, _ range: ClosedRange<Double>, _ def: Double,
                               hero: Bool = false, surprise: ClosedRange<Double>? = nil, help: String) -> ParamSpec {
        ParamSpec(id: id, name: name, group: group, help: help, kind: .slider(range), defaultValue: .number(def), hero: hero, surprise: surprise)
    }

    public static let parameters: [ParamSpec] = [
        ParamSpec(id: "visual", name: "Visual", group: "Visual", help: "What your playing does to the sky",
                  kind: .choice(visuals), defaultValue: .choice("Curtain Lights")),
        SkyHold.spec(default: .deepNight),
        AuroraMode.spec(default: .always),
        slider("floes", "Ice floes", "Fjord", 0...1, 0.6, hero: true, surprise: 0.2...1,
               help: "How much ice drifts on the water"),
        slider("village", "Village lights", "Fjord", 0...1, 0.7, surprise: 0.3...1,
               help: "The fishing village's lights on the far shore, from dusk"),
        slider("swell", "Swell", "Fjord", 0...1, 0.4, surprise: 0...0.8,
               help: "A slow swell on the still water"),
        ParamSpec(id: "keys.show", name: "Show keys", group: "Keys", help: "Ice-blue glass keys along the jetty",
                  kind: .toggle, defaultValue: .bool(true)),
        slider("keys.height", "Keyboard height", "Keys", 0.06...0.3, 0.12, help: "How tall the keyboard is"),
    ]

    public static let macroTargets: [Macro: [(id: String, weight: Double)]] = [
        .intensity: [("swell", 0.6), ("floes", 0.4)],
        .speed: [],
        .density: [("floes", 0.8), ("village", 0.4)],
        .glow: [("village", 1)],
        .chaos: [("swell", 0.5)],
        .temperature: [],
    ]
}
