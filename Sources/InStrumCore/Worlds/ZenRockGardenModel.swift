import Foundation
import simd

/// The garden's season (spec §9.1): the maple's colour and the bush warbler follow it.
public enum GardenSeason: String, CaseIterable {
    case spring = "Spring", summer = "Summer", autumn = "Autumn", winter = "Winter"
}

/// The bamboo water-knocker by the stone basin, for the picture: it fills under the spout for 15–40 s (longer in calm
/// moods), tips and pours, swings back and clacks on its stone. It keeps its own seeded cycle, as long as the
/// ambience's knocker's (the two are not tied to each other).
public struct KnockerState: Equatable {
    /// 0 just emptied … 1 full: the bamboo filling under the spout.
    public var fill: Float
    /// 0 at rest … 1 tipped down and pouring: 0.6 s down, 0.25 s back up.
    public var tip: Float
    /// 1 as it clacks on the stone, fading over 0.3 s (for the splash).
    public var clack: Float
    /// 0…1 through this cycle (fill, tip, swing back).
    public var phase: Float
    /// Cycles completed (wrapping).
    public var cycles: Int
}

/// Everything the Zen Rock Garden renderer needs for a frame.
public struct ZenGardenFrame: AmbienceProviding {
    /// The Living Sky as it is (the garden is not a cold world: rain stays rain).
    public var sky: SkyState
    /// Rake Lines: the gravel's height field (upload it when `field.version` moves on), the latest rings and run
    /// curves, and a chord's wave while it crosses the bed (its brightness through `FlashLimiter`).
    public var field: RakeField
    public var rings: [RakeRing]
    public var strokes: [RakeStroke]
    public var wave: RakeWave?
    /// The season (by the sky city's date and hemisphere, or the setting), the maple's leaves (linear RGB: green,
    /// turning gold, orange and red through autumn) and how full its canopy is (0 bare … 1).
    public var season: GardenSeason
    public var maple: SIMD3<Float>
    public var mapleLeaves: Float
    /// The water-knocker's swing.
    public var knocker: KnockerState
    /// Fireflies over the moss on a humid night (0…1: the sky's, more with more moss).
    public var fireflies: Float
    /// How dark and dull the rain has made the gravel (0…1: at once with the rain, drying after).
    public var wetness: Float
    /// Snow lying in the grooves and on the stones: 0 none … 1 grooves full and stones capped (builds over minutes
    /// of snow, melts after; faster in sun and rain). Rime is the sky's (`sky.rime`).
    public var snowCover: Float
    public var keys: [KeyVisual]
    public var ambience: AmbienceScene
    public var mood: Mood
    public var time: Double
    /// Galaxy Warp over the garden's sky, when it's the chosen visual (notes then streak instead of raking).
    public var warp: WarpFrame?
}

/// Set 10's world: from the veranda of a temple hall, a dry garden of raked white gravel with five stones in three
/// groups on moss islands, a low earthen wall with a tiled cap, a maple that turns with the season, a bamboo
/// water-knocker by a stone basin and a tall cedar beyond the wall. Its visual, Rake Lines, rakes your playing into
/// the gravel.
public struct ZenRockGardenModel: ThemeModel, MoodAware, SkyAware {
    public typealias Frame = ZenGardenFrame
    public static let id = "zen-rock-garden"
    public static let displayName = "Zen Rock Garden"
    public static let visuals = ["Rake Lines", "Galaxy Warp"]
    /// The season setting: follow the sky city's date, or keep one season.
    public static let followTheDate = "Follow the date"
    public static let seasons = [followTheDate] + GardenSeason.allCases.map(\.rawValue)
    /// The water-knocker: its tip down and swing back (seconds), and the clack's fade.
    static let tipTime = 0.6, returnTime = 0.25, clackFade = 0.3
    /// Snow fills the grooves with τ 4 min of full snow; it melts with τ 15 min in the shade, faster in sun and rain.
    static let snowFill = 240.0, snowMeltShade = 900.0, snowMeltSun = 300.0, snowMeltRain = 120.0

    public var mood = Mood.neutral
    private var sky = SkyState()
    private var rake = RakeLines()
    private var warp = GalaxyWarp()
    private var pending: [PerformanceEvent] = []
    private var held: [UInt8: Float] = [:]
    private var keyGlow = [Float](repeating: 0, count: 88)
    private var lastVisual: String?
    private var time = 0.0
    private var lastLightning: Float = 0
    private var thunderRng = SeededRandom(seed: 0x2E_9A4D)
    private var knockerRng: SeededRandom
    private var knockerT: Double
    private var knockerFill: Double
    private var knockerCycles = 0
    private var snowCover: Float = 0

    private static let layout = KeyboardLayout.keys()

    public init() {
        var r = SeededRandom(seed: 0x5415_0D05)
        knockerFill = Double(r.range(15, 40))
        knockerT = knockerFill * 0.35   // part-filled when you arrive
        knockerRng = r
    }

    public mutating func handle(_ e: PerformanceEvent) { pending.append(e) }

    public mutating func setSky(_ s: SkyState) { sky = s }

    static func clamp01(_ v: Float) -> Float { v.isFinite ? min(max(v, 0), 1) : 0 }

    // MARK: - Seasons

    /// The season on a day of the year (1…366): spring from 1 March, summer from 1 June, autumn from 1 September,
    /// winter from 1 December; the other way round south of the equator.
    public static func season(dayOfYear day: Int, southern: Bool) -> GardenSeason {
        seasonAndProgress(dayOfYear: day, southern: southern).season
    }

    /// The season and how far through it (0…1) the day is.
    static func seasonAndProgress(dayOfYear day: Int, southern: Bool) -> (season: GardenSeason, progress: Float) {
        let d = min(max(day, 1), 366)
        let span: (GardenSeason, Int, Int)
        switch d {
        case 60..<152: span = (.spring, 60, 92)
        case 152..<244: span = (.summer, 152, 92)
        case 244..<335: span = (.autumn, 244, 91)
        default: span = (.winter, 335, 90)
        }
        let (north, start, length) = span
        let into = ((d - start) % 365 + 365) % 365
        let progress = min(0.999, Float(into) / Float(length))
        guard southern else { return (north, progress) }
        let flipped: GardenSeason
        switch north {
        case .spring: flipped = .autumn
        case .summer: flipped = .winter
        case .autumn: flipped = .spring
        case .winter: flipped = .summer
        }
        return (flipped, progress)
    }

    /// The season the garden shows: the setting's, at its height, or the sky city's by its date and hemisphere.
    static func season(for sky: SkyState, setting: String) -> (season: GardenSeason, progress: Float) {
        guard let chosen = GardenSeason(rawValue: setting) else {
            return seasonAndProgress(dayOfYear: sky.dayOfYear, southern: sky.hemisphere < 0)
        }
        switch chosen {
        case .spring: return (chosen, 0.45)
        case .summer: return (chosen, 0.5)
        case .autumn: return (chosen, 0.8)
        case .winter: return (chosen, 0.5)
        }
    }

    /// The maple through each season: (how far through it, leaf colour in linear RGB, how full the canopy is).
    private typealias MapleKey = (at: Float, colour: SIMD3<Float>, leaves: Float)
    private static let springMaple: [MapleKey] = [
        (0, SIMD3<Float>(0.40, 0.20, 0.12), 0.12),
        (0.35, SIMD3<Float>(0.34, 0.56, 0.18), 1),
        (1, SIMD3<Float>(0.24, 0.48, 0.14), 1),
    ]
    private static let summerMaple: [MapleKey] = [
        (0, SIMD3<Float>(0.24, 0.48, 0.14), 1),
        (0.5, SIMD3<Float>(0.13, 0.36, 0.09), 1),
        (1, SIMD3<Float>(0.14, 0.36, 0.09), 1),
    ]
    private static let autumnMaple: [MapleKey] = [
        (0, SIMD3<Float>(0.16, 0.36, 0.09), 1),
        (0.35, SIMD3<Float>(0.58, 0.48, 0.08), 1),
        (0.6, SIMD3<Float>(0.84, 0.34, 0.05), 1),
        (0.8, SIMD3<Float>(0.74, 0.08, 0.04), 0.95),
        (1, SIMD3<Float>(0.50, 0.08, 0.05), 0.3),
    ]
    private static let winterMaple: [MapleKey] = [
        (0, SIMD3<Float>(0.50, 0.08, 0.05), 0.3),
        (0.25, SIMD3<Float>(0.36, 0.16, 0.08), 0.12),
        (1, SIMD3<Float>(0.40, 0.20, 0.12), 0.12),
    ]

    /// The maple's leaf colour (linear RGB) and canopy (0 bare … 1 full) at a point in a season: fresh green in
    /// spring, deep green in summer, gold to orange to red through autumn (reddest four-fifths of the way through:
    /// late November in Kyoto, early May in Melbourne), the last leaves falling early in winter.
    public static func maple(_ season: GardenSeason, progress: Float) -> (colour: SIMD3<Float>, leaves: Float) {
        let p = progress.isFinite ? min(max(progress, 0), 1) : 0.5
        let keys: [MapleKey]
        switch season {
        case .spring: keys = springMaple
        case .summer: keys = summerMaple
        case .autumn: keys = autumnMaple
        case .winter: keys = winterMaple
        }
        guard let first = keys.first else { return (SIMD3<Float>(0.13, 0.36, 0.09), 1) }
        var previous = first
        for k in keys.dropFirst() {
            if p <= k.at {
                let t = (p - previous.at) / max(k.at - previous.at, 1e-6)
                return (previous.colour + (k.colour - previous.colour) * t, previous.leaves + (k.leaves - previous.leaves) * t)
            }
            previous = k
        }
        return (previous.colour, previous.leaves)
    }

    /// The morning, 0…1: from first light (the sun 6° below the horizon, all the way by 2° below) until late
    /// morning (easing out from 10:00 to 11:30).
    static func morning(_ s: SkyState) -> Double {
        guard s.hourOfDay < 12 else { return 0 }
        return MoonlitLakeModel.smooth(-6, -2, s.sun.altitude) * (1 - MoonlitLakeModel.smooth(10, 11.5, s.hourOfDay))
    }

    // MARK: - Step

    public mutating func step(dt: Double, params p: ParameterSet, roles: RoleValues, inputs: InputFrame, quality: QualityLevel) -> ZenGardenFrame {
        let fdt = dt.isFinite ? min(max(dt, 0), 0.25) : 0
        time += fdt
        let visual = p.choice("visual")
        let warping = visual == "Galaxy Warp"
        // Switching visuals lets held notes go: no rake keeps circling, no streak waits for a release.
        if let lastVisual, lastVisual != visual { rake.allNotesOff(); warp.allNotesOff() }
        lastVisual = visual
        rake.reactionScale = MoodLook.reactionScale(mood)
        rake.lingerScale = MoodLook.lingerScale(mood)
        for e in pending {
            switch e {
            case let .noteOn(note, velocity):
                held[note] = velocity
                if warping {
                    warp.noteOn(note, velocity: UInt8(min(127, max(0, (velocity * 127).rounded()))), at: time)
                } else {
                    rake.noteOn(note, velocity: velocity, at: time)
                }
            case let .noteOff(note):
                held[note] = nil
                rake.noteOff(note)
                warp.noteOff(note)
            case let .pedal(down, _):
                rake.setPedal(down)
            case .allNotesOff:
                // A panic (or an unplugged keyboard) lets the pedal go too: no pedal-up will ever come for it.
                held.removeAll()
                rake.allNotesOff(); rake.setPedal(false)
                warp.allNotesOff()
                keyGlow = .init(repeating: 0, count: 88)
            default:
                break
            }
        }
        pending.removeAll(keepingCapacity: true)

        rake.step(dt: fdt, roles: roles)
        let warpFrame = warp.step(dt: fdt, roles: roles, inputs: inputs)
        let knocker = stepKnocker(fdt)
        stepSnow(fdt)
        let (season, progress) = Self.season(for: sky, setting: p.choice("season"))
        let maple = Self.maple(season, progress: progress)

        // Keys glow pale gold while held, then fade (longer when lingering).
        let fall = Float(pow(0.5, fdt / (roles[.linger] > 0.5 ? 1.2 : 0.3)))
        for i in 0..<88 {
            let note = UInt8(i + 21)
            if let v = held[note] { keyGlow[i] = max(keyGlow[i] * fall, v * 0.7) } else { keyGlow[i] *= fall }
        }
        let keys = Self.layout.map { k in KeyVisual(key: k, pressed: held[k.note] != nil, glow: keyGlow[Int(k.note) - 21]) }

        let moss = Float(min(max(p.number("moss"), 0), 1))
        let fireflies = Self.clamp01(sky.fireflies) * (0.3 + 0.7 * moss)
        let wetness = min(1, max(Self.clamp01(sky.wetness), 0.6 * Self.clamp01(sky.rain)))

        return ZenGardenFrame(sky: sky, field: rake.field, rings: rake.rings, strokes: rake.strokes, wave: rake.wave,
                              season: season, maple: maple.colour, mapleLeaves: maple.leaves, knocker: knocker,
                              fireflies: fireflies, wetness: wetness, snowCover: snowCover, keys: keys,
                              ambience: ambience(roles: roles, season: season), mood: mood, time: time,
                              warp: warping ? warpFrame : nil)
    }

    /// The water-knocker: fill, tip and pour, swing back and clack; each fill 15–40 s ÷ the ambience's density.
    private mutating func stepKnocker(_ dt: Double) -> KnockerState {
        let density = min(1.5, max(0.5, MoodLook.ambienceDensity(mood)))
        knockerT += dt
        var cycle = knockerFill + Self.tipTime + Self.returnTime
        if knockerT >= cycle {
            knockerT -= cycle
            knockerCycles &+= 1
            knockerFill = Double(knockerRng.range(15, 40)) / density
            cycle = knockerFill + Self.tipTime + Self.returnTime
        }
        let t = knockerT
        var fill = 0.0, tip = 0.0
        if t < knockerFill {
            fill = t / knockerFill
        } else if t < knockerFill + Self.tipTime {
            tip = MoonlitLakeModel.smooth(0, 1, (t - knockerFill) / Self.tipTime)
            fill = 1 - tip
        } else {
            tip = 1 - MoonlitLakeModel.smooth(0, 1, (t - knockerFill - Self.tipTime) / Self.returnTime)
        }
        let clack = knockerCycles > 0 && t < Self.clackFade ? 1 - t / Self.clackFade : 0
        return KnockerState(fill: Float(fill), tip: Float(tip), clack: Float(clack), phase: Float(min(1, t / cycle)),
                            cycles: knockerCycles)
    }

    /// Snow lies in the grooves and on the stones while it snows, and melts after.
    private mutating func stepSnow(_ dt: Double) {
        let snow = Double(Self.clamp01(sky.snow)), rain = Double(Self.clamp01(sky.rain))
        if snow > 0.02 {
            snowCover += (1 - snowCover) * Float(1 - exp(-dt * snow / Self.snowFill))
        } else {
            let melt = 1 / Self.snowMeltShade + (sky.sun.altitude > 5 ? 1 / Self.snowMeltSun : 0) + rain / Self.snowMeltRain
            snowCover *= Float(exp(-dt * melt))
        }
        snowCover = snowCover > 1e-4 ? min(1, snowCover) : 0
    }

    /// The garden's soundscape: the water-knocker by the basin, a bush warbler on spring and summer mornings, the
    /// breeze in the maple and the cedar, summer nights' crickets, the dawn chorus, the hall's own bell (in key),
    /// rain on the basin and drips after.
    private mutating func ambience(roles: RoleValues, season: GardenSeason) -> AmbienceScene {
        let sunAlt = sky.sun.altitude
        let night = MoonlitLakeModel.smooth(-3, -9, sunAlt)
        let rising = sky.hourOfDay < 12
        let dawn = rising ? MoonlitLakeModel.smooth(-7, -5, sunAlt) * MoonlitLakeModel.smooth(9, 6, sunAlt) : 0
        let singing = season == .spring || season == .summer
        var levels: [AmbienceSource: Double] = [
            .waterKnocker: 0.6,
            .warbler: singing ? 0.5 * Self.morning(sky) : 0,
            .breeze: min(1, 0.25 + Double(sky.wind)),
            .crickets: season == .summer ? 0.4 * night : 0,
            .dawnChorus: 0.3 * dawn,
            .templeBell: 0.3,
            .rainOnWater: 0.5 * Double(sky.rain),
        ]
        WeatherAmbience.levels(sky, base: &levels)
        // Night cools from dusk (about 19:00) over eight hours.
        let sinceDusk = (sky.hourOfDay - 19 + 24).truncatingRemainder(dividingBy: 24)
        let nightCool = night > 0 ? min(1, sinceDusk / 8) : 0
        var thunder: Double?
        if sky.lightning > 0.9, lastLightning <= 0.9 { thunder = Double(thunderRng.range(0.15, 0.9)) }
        lastLightning = sky.lightning
        let activity = min(1, 0.6 * roles[.energy] + 0.4 * roles[.density])
        return AmbienceScene(levels: levels, nightCool: nightCool, activity: activity, thunder: thunder,
                             closeness: MoodLook.ambienceCloseness(base: 0.55, mood), density: MoodLook.ambienceDensity(mood),
                             indoors: WeatherAmbience.indoorsLift(sky), wetness: Double(sky.wetness))
    }
}

extension ZenRockGardenModel {
    private static func slider(_ id: String, _ name: String, _ group: String, _ range: ClosedRange<Double>, _ def: Double,
                               hero: Bool = false, surprise: ClosedRange<Double>? = nil, help: String) -> ParamSpec {
        ParamSpec(id: id, name: name, group: group, help: help, kind: .slider(range), defaultValue: .number(def), hero: hero, surprise: surprise)
    }

    public static let parameters: [ParamSpec] = [
        ParamSpec(id: "visual", name: "Visual", group: "Visual", help: "What your playing rakes into the gravel",
                  kind: .choice(visuals), defaultValue: .choice("Rake Lines")),
        SkyHold.spec(default: .follow),
        AuroraMode.spec(default: .follow),
        MeteorMode.spec(default: .follow),
        slider("ridge", "Rake depth", "Rake Lines", 0...1, 0.6, hero: true, surprise: 0.3...1,
               help: "How deep the rake cuts the gravel: the ridges' shadows in low light"),
        slider("moss", "Moss", "Garden", 0...1, 0.5, surprise: 0.2...1,
               help: "How far the moss spreads round the stones (fireflies keep to it on humid nights)"),
        ParamSpec(id: "season", name: "Season", group: "Garden",
                  help: "The maple's colour and the bush warbler's mornings: follow the sky city's date, or keep one season",
                  kind: .choice(seasons), defaultValue: .choice(followTheDate)),
        ParamSpec(id: "keys.show", name: "Show keys", group: "Keys", help: "A keyboard along the veranda's edge",
                  kind: .toggle, defaultValue: .bool(true)),
        slider("keys.height", "Keyboard height", "Keys", 0.06...0.3, 0.12, help: "How tall the keyboard is"),
    ]

    public static let macroTargets: [Macro: [(id: String, weight: Double)]] = [
        .intensity: [("ridge", 0.8)],
        .speed: [],
        .density: [("moss", 0.6)],
        .glow: [],
        .chaos: [("ridge", 0.4)],
        .temperature: [],
    ]
}
