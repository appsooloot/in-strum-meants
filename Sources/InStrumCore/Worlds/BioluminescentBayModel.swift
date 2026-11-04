import Foundation
import simd

/// Everything the Bioluminescent Bay renderer needs for a frame.
public struct BayFrame: AmbienceProviding {
    public var sky: SkyState
    /// Glow Wake (every brightness already times `glowScale`; empty while Galaxy Warp plays).
    public var patches: [GlowPatch]
    public var wakes: [GlowWakeLine]
    public var darts: [Dart]
    public var pool: GlowPool
    /// 0 by day … 1 at night: the plankton needs the dark (rain dulls it to 0.4×).
    public var glowScale: Float
    /// The lighthouse on the far point: a 0.4 s flash every 6 s once the sun is down (0…1).
    public var lighthouseFlash: Float
    /// The moored boat's lantern is lit (the sun below −3°).
    public var lanternLit: Bool
    /// The bay's small swell (`OceanSwell` at a fraction of the beach's height; storms whip it up).
    public var swellPhases: SIMD4<Float>
    public var swellScale: Float
    public var swellTime: Double
    /// How far the latest small wave's wash reaches up the sand (0 waterline … 1).
    public var washFront: Float
    public var keys: [KeyVisual]
    public var ambience: AmbienceScene
    public var mood: Mood
    public var time: Double
    /// Galaxy Warp over the bay's sky, when it's the chosen visual (notes then streak instead of glowing).
    public var warp: WarpFrame?
}

/// Set 8's world: a sheltered cove at night, headlands with palms and mangroves, a still bay mirroring the real
/// stars, a moored boat's lantern, a lighthouse blinking on the far point, and plankton glowing along the
/// waterline. Its visual, Glow Wake, lights the water where your notes fall.
public struct BioluminescentBayModel: ThemeModel, MoodAware, SkyAware {
    public typealias Frame = BayFrame
    public static let id = "bioluminescent-bay"
    public static let displayName = "Bioluminescent Bay"
    public static let visuals = ["Glow Wake", "Galaxy Warp"]

    /// The lighthouse's period and flash length (seconds).
    public static let lighthousePeriod = 6.0, lighthouseFlashLength = 0.4
    /// The bay's swell is this fraction of the open sea's: still in calm weather, whipped up in a storm.
    static let calmSwell: Float = 0.12, stormSwell: Float = 0.5

    public var mood = Mood.neutral
    private var sky = SkyState()
    private var glow = GlowWake()
    private var warp = GalaxyWarp()
    private var swell = OceanSwell(seed: 0xB10_1A7)
    private var pending: [PerformanceEvent] = []
    private var held: [UInt8: Float] = [:]
    private var keyGlow = [Float](repeating: 0, count: 88)
    private var lastVisual: String?
    private var time = 0.0
    private var lastLightning: Float = 0
    private var thunderRng = SeededRandom(seed: 0xB1A7)

    private static let layout = KeyboardLayout.keys()

    public init() {}

    public mutating func handle(_ e: PerformanceEvent) { pending.append(e) }

    public mutating func setSky(_ s: SkyState) { sky = s }

    /// 0 with the sun above −2° … 1 below −8°.
    public static func night(_ s: SkyState) -> Double { MoonlitLakeModel.smooth(-2, -8, s.sun.altitude) }

    /// The plankton's glow: the dark, dulled by rain (×(1 − 0.6·rain)).
    public static func glowScale(_ s: SkyState) -> Float {
        let rain = s.rain.isFinite ? min(max(s.rain, 0), 1) : 0
        return Float(night(s)) * (1 - 0.6 * rain)
    }

    /// A smooth 0.4 s pulse at the start of every 6 s (0 between).
    public static func lighthouse(at t: Double) -> Float {
        guard t.isFinite else { return 0 }
        var phase = t.truncatingRemainder(dividingBy: lighthousePeriod)
        if phase < 0 { phase += lighthousePeriod }
        guard phase < lighthouseFlashLength else { return 0 }
        return Float(sin(Double.pi * phase / lighthouseFlashLength))
    }

    /// The swell's height for the weather: calm 0.12 of the open sea's, a storm (open-sea scale 1.8) 0.5.
    static func swellScale(_ s: SkyState) -> Float {
        let w = OceanSwell.weatherScale(s)
        let storm = min(1, max(0, (w - 1) / 0.8))
        return calmSwell + (stormSwell - calmSwell) * storm
    }

    public mutating func step(dt: Double, params p: ParameterSet, roles: RoleValues, inputs: InputFrame, quality: QualityLevel) -> BayFrame {
        time += dt
        let glowScale = Self.glowScale(sky)
        glow.nightScale = glowScale
        glow.reactionScale = MoodLook.reactionScale(mood)
        glow.lingerScale = MoodLook.lingerScale(mood)
        let visual = p.choice("visual")
        let warping = visual == "Galaxy Warp"
        // Switching visuals lets held notes go: no patch stays lit, no streak waits for a release.
        if let lastVisual, lastVisual != visual { glow.allNotesOff(); warp.allNotesOff() }
        lastVisual = visual
        for e in pending {
            switch e {
            case let .noteOn(note, velocity):
                held[note] = velocity
                if warping {
                    warp.noteOn(note, velocity: UInt8(min(127, max(0, (velocity * 127).rounded()))), at: time)
                } else {
                    glow.noteOn(note, velocity: velocity, at: time)
                }
            case let .noteOff(note):
                held[note] = nil
                glow.noteOff(note)
                warp.noteOff(note)
            case let .pedal(down, _):
                glow.setPedal(down)
            case .allNotesOff:
                // A panic (or an unplugged keyboard) lets the pedal go too: no pedal-up will ever come for it.
                held.removeAll()
                glow.allNotesOff(); glow.setPedal(false)
                warp.allNotesOff()
                keyGlow = .init(repeating: 0, count: 88)
            default:
                break
            }
        }
        pending.removeAll(keepingCapacity: true)

        glow.step(dt: dt, roles: roles)
        let warpFrame = warp.step(dt: dt, roles: roles, inputs: inputs)
        swell.scale = Self.swellScale(sky)
        _ = swell.step(dt: dt)
        let front = swell.washFront(at: swell.time)

        // Keys glow cyan while held, then fade (longer when lingering).
        let fall = Float(pow(0.5, dt / (roles[.linger] > 0.5 ? 1.2 : 0.35)))
        for i in 0..<88 {
            let note = UInt8(i + 21)
            if let v = held[note] { keyGlow[i] = max(keyGlow[i] * fall, v * 0.7) } else { keyGlow[i] *= fall }
        }
        let keys = Self.layout.map { k in KeyVisual(key: k, pressed: held[k.note] != nil, glow: keyGlow[Int(k.note) - 21]) }

        let down = sky.sun.altitude < -3
        let flash = down && p.number("lighthouse") > 0.02 ? Self.lighthouse(at: time) : 0

        return BayFrame(sky: sky, patches: warping ? [] : glow.patches, wakes: warping ? [] : glow.wakes,
                        darts: warping ? [] : glow.darts, pool: warping ? GlowPool.still : glow.pool, glowScale: glowScale,
                        lighthouseFlash: flash, lanternLit: down && p.number("lantern") > 0.02,
                        swellPhases: swell.phases(at: swell.time), swellScale: swell.scale, swellTime: swell.time,
                        washFront: front, keys: keys, ambience: ambience(roles: roles), mood: mood, time: time,
                        warp: warping ? warpFrame : nil)
    }

    /// The bay's soundscape: small waves lapping the hull and rocks, crickets and an owl on the headlands at
    /// night, a far boat now and then, gulls by day.
    private mutating func ambience(roles: RoleValues) -> AmbienceScene {
        let sunAlt = sky.sun.altitude
        let night = Self.night(sky)
        let day = MoonlitLakeModel.smooth(-4, 2, sunAlt)
        var levels: [AmbienceSource: Double] = [
            .lapping: 0.7,
            .water: 0.3,
            .crickets: 0.5 * night,
            .boat: 0.4,
            .breeze: min(1, 0.25 + Double(sky.wind)),
            .owl: 0.15 * night,
            .rainOnWater: Double(sky.rain),
            .gulls: 0.2 * day,
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
                             closeness: MoodLook.ambienceCloseness(base: 0.6, mood), density: MoodLook.ambienceDensity(mood),
                             wetness: Double(sky.wetness))
    }
}

extension BioluminescentBayModel {
    private static func slider(_ id: String, _ name: String, _ group: String, _ range: ClosedRange<Double>, _ def: Double,
                               hero: Bool = false, surprise: ClosedRange<Double>? = nil, help: String) -> ParamSpec {
        ParamSpec(id: id, name: name, group: group, help: help, kind: .slider(range), defaultValue: .number(def), hero: hero, surprise: surprise)
    }

    public static let parameters: [ParamSpec] = [
        ParamSpec(id: "visual", name: "Visual", group: "Visual", help: "What your playing draws on the bay",
                  kind: .choice(visuals), defaultValue: .choice("Glow Wake")),
        SkyHold.spec(default: .deepNight),
        AuroraMode.spec(default: .follow),
        slider("glow", "Plankton glow", "Glow Wake", 0...1, 0.7, hero: true, surprise: 0.3...1,
               help: "How brightly the plankton lights where your notes fall and along the waterline"),
        slider("lantern", "Boat lantern", "Bay", 0...1, 0.6, surprise: 0.2...1,
               help: "The moored boat's lantern and its light on the water"),
        slider("lighthouse", "Lighthouse", "Bay", 0...1, 0.5, surprise: 0...1,
               help: "The lighthouse on the far point, blinking every six seconds"),
        ParamSpec(id: "keys.show", name: "Show keys", group: "Keys", help: "A dark glass keyboard along the sand",
                  kind: .toggle, defaultValue: .bool(true)),
        slider("keys.height", "Keyboard height", "Keys", 0.06...0.3, 0.12, help: "How tall the keyboard is"),
    ]

    public static let macroTargets: [Macro: [(id: String, weight: Double)]] = [
        .intensity: [("glow", 0.8)],
        .speed: [],
        .density: [("glow", 0.4)],
        .glow: [("glow", 1), ("lantern", 0.5)],
        .chaos: [],
        .temperature: [("lantern", 0.6)],
    ]
}
