public protocol AmbienceProviding { var ambience: AmbienceScene { get } }
public struct LakeFrame: AmbienceProviding {
    public var sky = SkyState(); public var ripples: [Ripple] = []; public var fireflies: [Firefly] = []; public var glitter: Float = 0
    public var keys: [KeyVisual] = []; public var ambience = AmbienceScene.silent; public var mood = Mood.neutral; public var time = 0.0
}
public struct MoonlitLakeModel: ThemeModel, MoodAware, SkyAware {
    public static let id = "moonlit-lake", displayName = "Moonlit Lake"
    public static let parameters: [ParamSpec] = []
    public static let macroTargets: [Macro: [(id: String, weight: Double)]] = [:]
    public var mood = Mood.neutral
    public init() {}
    public mutating func handle(_ e: PerformanceEvent) {}
    public mutating func setSky(_ s: SkyState) {}
    public mutating func step(dt: Double, params: ParameterSet, roles: RoleValues, inputs: InputFrame, quality: QualityLevel) -> LakeFrame { LakeFrame() }
}
