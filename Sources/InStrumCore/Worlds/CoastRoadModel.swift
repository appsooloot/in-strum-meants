import Foundation
import simd

/// Everything the Coast Road renderer needs for a frame.
public struct RoadFrame: AmbienceProviding {
    public var sky: SkyState
    public var lights: [CoastLight]
    /// The car's speed, 0…1 of 30…100 km/h (cruise 0.35).
    public var speed: Float
    /// Metres travelled (the renderer wraps it for each layer's scroll).
    public var distance: Double
    /// The chord bloom on the sea's glitter path (0…1) and its hue.
    public var bloom: Float
    public var bloomHue: Float
    /// The swell's four component phases (wrapped) and the last few breaks (white water at the cliff base).
    public var swellPhases: SIMD4<Float>
    public var recent: [Wave]
    public var swellScale: Float
    public var swellTime: Double
    /// The road's gentle curves: the view's roll and yaw in degrees (at most ±1.5° and ±2°).
    public var roll: Double
    public var yaw: Double
    public var keys: [KeyVisual]
    public var ambience: AmbienceScene
    public var mood: Mood
    public var time: Double
    /// Galaxy Warp over the coast's sky, when it's the chosen visual (notes then streak instead of passing).
    public var warp: WarpFrame?
}

/// Set 4's world: the passenger seat on a coast road high above the sea, the window looking out over cliffs
/// and swell at blue hour. Its visual, Coast Lights, turns notes into lights streaming past; playing speeds
/// the car up, chords bloom the glitter on the sea.
public struct CoastRoadModel: ThemeModel, MoodAware, SkyAware {
    public typealias Frame = RoadFrame
    public static let id = "coast-road"
    public static let displayName = "Coast Road"
    public static let visuals = ["Coast Lights", "Galaxy Warp"]

    /// The sway's periods (seconds): slow enough never to feel queasy.
    static let rollPeriod = 11.0, yawPeriod = 17.0

    public var mood = Mood.neutral
    private var sky = SkyState()
    private var swell = OceanSwell(seed: 0xC0A5)
    private var coast = CoastLights()
    private var warp = GalaxyWarp()
    private var pending: [PerformanceEvent] = []
    private var held = Set<UInt8>()
    private var keyGlow = [Float](repeating: 0, count: 88)
    private var time = 0.0
    private var lastLightning: Float = 0
    private var thunderRng = SeededRandom(seed: 0xC0A)

    private static let layout = KeyboardLayout.keys()

    public init() {}

    public mutating func handle(_ e: PerformanceEvent) { pending.append(e) }

    public mutating func setSky(_ s: SkyState) { sky = s }

    public mutating func step(dt: Double, params p: ParameterSet, roles: RoleValues, inputs: InputFrame, quality: QualityLevel) -> RoadFrame {
        time += dt
        coast.trails = Float(p.number("lights.trails"))
        coast.speedResponse = Float(p.number("speed.response"))
        coast.bloomAmount = Float(p.number("bloom"))
        coast.reactionScale = MoodLook.reactionScale(mood)
        coast.lingerScale = MoodLook.lingerScale(mood)
        let warping = p.choice("visual") == "Galaxy Warp"
        for e in pending {
            switch e {
            case let .noteOn(note, velocity):
                held.insert(note)
                let v = UInt8(min(127, max(0, (velocity * 127).rounded())))
                if warping { warp.noteOn(note, velocity: v, at: time) } else { coast.noteOn(note, velocity: v, at: time) }
                if (21...108).contains(note) { keyGlow[Int(note) - 21] = max(keyGlow[Int(note) - 21], velocity * 0.7) }
            case let .noteOff(note):
                held.remove(note)
                coast.noteOff(note)
                warp.noteOff(note)
            case .allNotesOff:
                held.removeAll()
                coast.allNotesOff()
                warp.allNotesOff()
                keyGlow = .init(repeating: 0, count: 88)
            default:
                break
            }
        }
        pending.removeAll(keepingCapacity: true)

        coast.step(dt: dt, roles: roles)
        swell.scale = OceanSwell.weatherScale(sky)
        let breaks = swell.step(dt: dt)
        let warpFrame = warp.step(dt: dt, roles: roles, inputs: inputs)

        // Dashboard amber on the keys while held, then fading.
        let fall = Float(pow(0.5, dt / (roles[.linger] > 0.5 ? 1.2 : 0.3)))
        for i in 0..<88 where !held.contains(UInt8(i + 21)) { keyGlow[i] *= fall }
        let keys = Self.layout.map { k in KeyVisual(key: k, pressed: held.contains(k.note), glow: keyGlow[Int(k.note) - 21]) }

        let sway = p.number("sway")
        let roll = 1.5 * sway * sin(2 * .pi * time.truncatingRemainder(dividingBy: Self.rollPeriod) / Self.rollPeriod)
        let yaw = 2 * sway * sin(2 * .pi * time.truncatingRemainder(dividingBy: Self.yawPeriod) / Self.yawPeriod + 1)

        return RoadFrame(sky: sky, lights: coast.lights, speed: coast.speed, distance: coast.distance,
                         bloom: coast.bloom, bloomHue: coast.bloomHue, swellPhases: swell.phases(at: swell.time),
                         recent: swell.recent, swellScale: swell.scale, swellTime: swell.time, roll: roll, yaw: yaw, keys: keys,
                         ambience: ambience(roles: roles, breaks: breaks), mood: mood, time: time,
                         warp: warping ? warpFrame : nil)
    }

    /// The drive's soundscape: road and engine under the window's rush, the surf far below thumping with each
    /// break, now and then a passing car; rain on the glass.
    private mutating func ambience(roles: RoleValues, breaks: [Wave]) -> AmbienceScene {
        let night = MoonlitLakeModel.smooth(-3, -9, sky.sun.altitude)
        var levels: [AmbienceSource: Double] = [
            .road: 0.8,
            .engine: 0.6,
            .windowWind: 0.5,
            .surf: 0.5,
            .passingCar: 0.3,
            .rainOnGlass: Double(sky.rain),
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
                             wave: wave, speed: Double(coast.speed), surfDistance: 0.9, indoors: WeatherAmbience.indoorsLift(sky), wetness: Double(sky.wetness))
    }
}

extension CoastRoadModel {
    private static func slider(_ id: String, _ name: String, _ group: String, _ range: ClosedRange<Double>, _ def: Double,
                               hero: Bool = false, surprise: ClosedRange<Double>? = nil, help: String) -> ParamSpec {
        ParamSpec(id: id, name: name, group: group, help: help, kind: .slider(range), defaultValue: .number(def), hero: hero, surprise: surprise)
    }

    public static let parameters: [ParamSpec] = [
        ParamSpec(id: "visual", name: "Visual", group: "Visual", help: "What your playing draws on the drive",
                  kind: .choice(visuals), defaultValue: .choice("Coast Lights")),
        SkyHold.spec(default: .blueHour),
        MeteorMode.spec(default: .follow),
        slider("lights.trails", "Light trails", "Coast Lights", 0...1, 0.6, hero: true, surprise: 0.2...1,
               help: "How long the passing lights streak"),
        slider("speed.response", "Speed response", "Coast Lights", 0...1, 0.6, hero: true, surprise: 0.2...1,
               help: "How much your playing speeds the car up"),
        slider("bloom", "Glitter bloom from chords", "Coast Lights", 0...1, 0.6, surprise: 0.2...1,
               help: "Chords bloom the glitter on the sea in their colour"),
        slider("lamps", "Lamps", "Coast Road", 0...1, 0.8, surprise: 0.3...1, help: "Road lamps lit from dusk"),
        slider("fog", "Sea fog", "Coast Road", 0...1, 0.3, surprise: 0...0.8, help: "Fog rolling in off the sea"),
        slider("sway", "Sway", "Coast Road", 0...1, 0.5, help: "How much the road's curves sway the view (never more than a gentle lean)"),
        ParamSpec(id: "keys.show", name: "Show keys", group: "Keys", help: "A keyboard along the dashboard",
                  kind: .toggle, defaultValue: .bool(true)),
        slider("keys.height", "Keyboard height", "Keys", 0.06...0.3, 0.12, help: "How tall the keyboard is"),
    ]

    public static let macroTargets: [Macro: [(id: String, weight: Double)]] = [
        .intensity: [("lights.trails", 0.8), ("bloom", 0.6)],
        .speed: [("speed.response", 1)],
        .density: [("lamps", 0.6)],
        .glow: [("bloom", 1), ("lamps", 0.5)],
        .chaos: [("sway", 0.4)],
        .temperature: [],
    ]
}
