import Foundation

/// A model that wants the set's mood (spec §6).
public protocol MoodAware { var mood: Mood { get set } }

/// A model that wants the Living Sky each frame.
public protocol SkyAware { mutating func setSky(_ s: SkyState) }

/// How the mood shapes worlds, visuals and ambience. 0.5 everywhere is neutral (every scale 1).
public enum MoodLook {
    public static func exposure(_ m: Mood) -> Float { Float(0.8 + 0.4 * m.brightness) }
    /// Added to PostSettings.warmth.
    public static func warmthOffset(_ m: Mood) -> Float { Float((m.warmth - 0.5) * 0.6) }
    /// Mist and depth haze.
    public static func hazeScale(_ m: Mood) -> Float { Float(0.5 + m.space) }
    /// Cloud, water and star drift.
    public static func driftScale(_ m: Mood) -> Float { Float(0.5 + m.motion) }
    /// Ripple strength, streak speed: how far reactions travel.
    public static func reactionScale(_ m: Mood) -> Float { Float(0.7 + 0.6 * m.energy) }
    /// Ripple and streak lifetime: how long reactions linger.
    public static func lingerScale(_ m: Mood) -> Float { Float(0.7 + 0.6 * m.motion) }
    /// Spacious moods sound further away.
    public static func ambienceCloseness(base: Double, _ m: Mood) -> Double { min(1, max(0, base - (m.space - 0.5) * 0.4)) }
    /// Multiplies how often ambience events happen.
    public static func ambienceDensity(_ m: Mood) -> Double { 0.7 + 0.6 * m.energy }
}

/// One theme the app can show: its settings and how to make its model.
public struct ThemeEntry {
    public let id, name: String
    public let parameters: [ParamSpec]
    public let macroTargets: [Macro: [(id: String, weight: Double)]]
    let make: () -> AnyThemeBoxProtocol

    static func make<T: ThemeModel>(_ type: T.Type) -> ThemeEntry {
        ThemeEntry(id: T.id, name: T.displayName, parameters: T.parameters, macroTargets: T.macroTargets, make: { ThemeBox<T>() })
    }
}

/// The themes the app knows about, in menu order.
public enum ThemeRegistry {
    public static let entries: [ThemeEntry] = [
        .make(MidnightSteinwayModel.self),
        .make(ButterflyGardenModel.self),
        .make(MoonlitLakeModel.self),
        .make(SpaceshipLoungeModel.self),
        .make(GoldenHourBeachModel.self),
        .make(CoastRoadModel.self),
        .make(SnowboundCabinModel.self),
        .make(BedroomDawnModel.self),
        .make(BioluminescentBayModel.self),
    ]

    public static var all: [(id: String, name: String)] { entries.map { ($0.id, $0.name) } }

    /// Unknown ids fall back to Midnight Steinway.
    public static func resolve(_ id: String) -> String {
        entries.contains { $0.id == id } ? id : MidnightSteinwayModel.id
    }

    static func entry(_ id: String) -> ThemeEntry {
        let resolved = resolve(id)
        return entries.first { $0.id == resolved } ?? entries[0]
    }

    public static func parameters(for id: String) -> [ParamSpec] { entry(id).parameters }

    /// Worlds live under the Living Sky and play an ambience.
    public static func isWorld(_ id: String) -> Bool { entry(id).make().wantsSky }

    public static func macroTargets(for id: String) -> [Macro: [(id: String, weight: Double)]] { entry(id).macroTargets }

    public static func parameterSet(for id: String, state: ThemeState) -> ParameterSet {
        ParameterSet(specs: parameters(for: id), saved: state.values, macros: state.macros, macroTargets: macroTargets(for: id))
    }
}

protocol AnyThemeBoxProtocol {
    var wantsSky: Bool { get }
    mutating func handle(_ e: PerformanceEvent)
    mutating func setMood(_ m: Mood)
    mutating func setSky(_ s: SkyState)
    mutating func step(dt: Double, params: ParameterSet, roles: RoleValues, inputs: InputFrame, quality: QualityLevel) -> Any
}

struct ThemeBox<T: ThemeModel>: AnyThemeBoxProtocol {
    var model = T()
    var wantsSky: Bool { T.self is SkyAware.Type }
    mutating func handle(_ e: PerformanceEvent) { model.handle(e) }
    mutating func setMood(_ m: Mood) {
        guard var aware = model as? MoodAware, aware.mood != m else { return }
        aware.mood = m
        if let back = aware as? T { model = back }
    }
    mutating func setSky(_ s: SkyState) {
        guard var aware = model as? SkyAware else { return }
        aware.setSky(s)
        if let back = aware as? T { model = back }
    }
    mutating func step(dt: Double, params: ParameterSet, roles: RoleValues, inputs: InputFrame, quality: QualityLevel) -> Any {
        model.step(dt: dt, params: params, roles: roles, inputs: inputs, quality: quality)
    }
}

/// Ties playing, inputs, reactions, settings and the active theme together each frame.
/// Use from one thread (the render loop).
public final class SceneDirector {
    public private(set) var themeID: String
    public var parameters: ParameterSet
    public var reaction: ReactionMap
    public var listenStrength: Double = 0.6
    public let hub = InputHub()
    public private(set) var lastRoles = RoleValues()

    /// The set's mood, pushed into mood-aware models every step.
    public var mood = Mood.neutral
    /// Stepped each frame for sky-aware models (worlds).
    public let sky = LivingSky(settings: SkySettings())
    /// The latest sky state, when the active theme uses one.
    public private(set) var lastSky: SkyState?
    /// Wall clock for the sky (previews and tests freeze it).
    public var clock: () -> Date = { Date() }

    private var box: AnyThemeBoxProtocol
    private var analyzer = PlayingAnalyzer()
    private var held: Set<UInt8> = []

    public init(themeID: String, state: ThemeState, reaction: ReactionMap) {
        let id = ThemeRegistry.resolve(themeID)
        self.themeID = id
        self.parameters = ThemeRegistry.parameterSet(for: id, state: state)
        self.reaction = reaction
        self.box = ThemeRegistry.entry(id).make()
    }

    /// A director for any entry (tests).
    init(entry: ThemeEntry, state: ThemeState, reaction: ReactionMap) {
        themeID = entry.id
        parameters = ParameterSet(specs: entry.parameters, saved: state.values, macros: state.macros, macroTargets: entry.macroTargets)
        self.reaction = reaction
        box = entry.make()
    }

    /// Starts the theme fresh (no held notes carried over).
    public func switchTheme(to id: String, state: ThemeState) {
        let resolved = ThemeRegistry.resolve(id)
        themeID = resolved
        parameters = ThemeRegistry.parameterSet(for: resolved, state: state)
        box = ThemeRegistry.entry(resolved).make()
        lastSky = nil
    }

    public func handle(_ events: [PerformanceEvent], at t: Double) {
        for e in events {
            switch e {
            case let .noteOn(note, _): held.insert(note)
            case let .noteOff(note): held.remove(note)
            case .allNotesOff: held.removeAll()
            default: break
            }
            box.handle(e)
            analyzer.handle(e, at: t)
            InputRouting.route(e, into: hub, at: t)
        }
    }

    /// Returns the theme's frame (GardenFrame, SteinwayFrame or a world's frame).
    public func step(dt: Double, t: Double, quality: QualityLevel) -> Any {
        hub.set(.held, held.isEmpty ? 0 : 1, at: t)
        analyzer.publish(to: hub, at: t)
        let frame = hub.frame(at: t, listenStrength: listenStrength)
        let (roles, offsets) = reaction.evaluate(frame)
        lastRoles = roles
        box.setMood(mood)
        if box.wantsSky {
            // Both are world parameters, read every step: a world without them (choice "") follows the sky, so
            // leaving a world whose aurora is "Always" leaves its aurora behind.
            let hold = SkyHold(rawValue: parameters.choice("light.hold")) ?? .follow
            let aurora = AuroraMode(rawValue: parameters.choice("aurora.mode")) ?? .follow
            let s = sky.step(now: clock(), dt: dt, hold: hold, aurora: aurora)
            lastSky = s
            box.setSky(s)
        }
        return box.step(dt: dt, params: parameters.withOffsets(offsets), roles: roles, inputs: frame, quality: quality)
    }
}
