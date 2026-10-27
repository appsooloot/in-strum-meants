import Foundation

/// The themes the app knows about.
public enum ThemeRegistry {
    public static let all: [(id: String, name: String)] = [
        (MidnightSteinwayModel.id, MidnightSteinwayModel.displayName),
        (ButterflyGardenModel.id, ButterflyGardenModel.displayName),
    ]

    /// Unknown ids fall back to Midnight Steinway.
    public static func resolve(_ id: String) -> String {
        all.contains { $0.id == id } ? id : MidnightSteinwayModel.id
    }

    public static func parameters(for id: String) -> [ParamSpec] {
        resolve(id) == ButterflyGardenModel.id ? ButterflyGardenModel.parameters : MidnightSteinwayModel.parameters
    }

    public static func macroTargets(for id: String) -> [Macro: [(id: String, weight: Double)]] {
        resolve(id) == ButterflyGardenModel.id ? ButterflyGardenModel.macroTargets : MidnightSteinwayModel.macroTargets
    }

    public static func parameterSet(for id: String, state: ThemeState) -> ParameterSet {
        ParameterSet(specs: parameters(for: id), saved: state.values, macros: state.macros, macroTargets: macroTargets(for: id))
    }

    fileprivate static func makeBox(_ id: String) -> AnyThemeBox {
        resolve(id) == ButterflyGardenModel.id ? ThemeBox<ButterflyGardenModel>() : ThemeBox<MidnightSteinwayModel>()
    }
}

private protocol AnyThemeBox {
    mutating func handle(_ e: PerformanceEvent)
    mutating func step(dt: Double, params: ParameterSet, roles: RoleValues, inputs: InputFrame, quality: QualityLevel) -> Any
}

private struct ThemeBox<T: ThemeModel>: AnyThemeBox {
    var model = T()
    mutating func handle(_ e: PerformanceEvent) { model.handle(e) }
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

    private var box: AnyThemeBox
    private var analyzer = PlayingAnalyzer()
    private var held: Set<UInt8> = []

    public init(themeID: String, state: ThemeState, reaction: ReactionMap) {
        let id = ThemeRegistry.resolve(themeID)
        self.themeID = id
        self.parameters = ThemeRegistry.parameterSet(for: id, state: state)
        self.reaction = reaction
        self.box = ThemeRegistry.makeBox(id)
    }

    /// Starts the theme fresh (no held notes carried over).
    public func switchTheme(to id: String, state: ThemeState) {
        let resolved = ThemeRegistry.resolve(id)
        themeID = resolved
        parameters = ThemeRegistry.parameterSet(for: resolved, state: state)
        box = ThemeRegistry.makeBox(resolved)
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

    /// Returns the theme's frame (GardenFrame or SteinwayFrame).
    public func step(dt: Double, t: Double, quality: QualityLevel) -> Any {
        hub.set(.held, held.isEmpty ? 0 : 1, at: t)
        analyzer.publish(to: hub, at: t)
        let frame = hub.frame(at: t, listenStrength: listenStrength)
        let (roles, offsets) = reaction.evaluate(frame)
        lastRoles = roles
        return box.step(dt: dt, params: parameters.withOffsets(offsets), roles: roles, inputs: frame, quality: quality)
    }
}
