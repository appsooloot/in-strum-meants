/// Rendering detail level.
public enum QualityLevel: String, Codable, CaseIterable { case lite, high, ultra }

/// A theme's behaviour: its settings and how it reacts. Drawing lives in the app.
public protocol ThemeModel {
    associatedtype Frame
    static var id: String { get }
    static var displayName: String { get }
    static var parameters: [ParamSpec] { get }
    static var macroTargets: [Macro: [(id: String, weight: Double)]] { get }
    init()
    mutating func handle(_ e: PerformanceEvent)
    mutating func step(dt: Double, params: ParameterSet, roles: RoleValues, inputs: InputFrame, quality: QualityLevel) -> Frame
}

/// Small deterministic random generator (SplitMix64) so scenes and previews are repeatable.
public struct SeededRandom {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    /// Uniform in 0..<1.
    public mutating func unit() -> Float { Float(next() >> 40) / Float(1 << 24) }
    public mutating func range(_ lo: Float, _ hi: Float) -> Float { lo + (hi - lo) * unit() }
}
