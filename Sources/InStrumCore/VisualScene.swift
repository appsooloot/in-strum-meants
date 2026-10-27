/// One key's visual state in a frame.
public struct KeyVisual: Equatable {
    public let key: KeyRect
    public var pressed: Bool
    /// 0...1
    public var glow: Float
}

/// A warm light rising from a glowing key.
public struct Spotlight: Equatable {
    /// Centre of the key, 0...1 across the keyboard.
    public let x: Float
    public var intensity: Float
}

/// Everything a renderer needs to draw one frame.
public struct SceneFrame {
    /// All 88 keys, white keys first then black (draw order).
    public var keys: [KeyVisual]
    public var spotlights: [Spotlight]
    /// 0...1, chord bloom across the stage.
    public var bloom: Float
    /// 0...1, from playing intensity and audio level.
    public var ambience: Float
}

/// A theme's behaviour, independent of how it is drawn.
public protocol VisualScene {
    static var id: String { get }
    static var displayName: String { get }
    mutating func handle(_ event: PerformanceEvent)
    mutating func step(dt: Double, intensity: Float, audioLevel: Float) -> SceneFrame
}
