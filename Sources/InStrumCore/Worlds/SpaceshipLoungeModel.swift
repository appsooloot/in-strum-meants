import Foundation
import simd

/// Everything the Spaceship Lounge renderer needs for a frame.
public struct LoungeFrame: AmbienceProviding {
    public var sky: SkyState
    public var warp: WarpFrame
    public var earthRotation: Float
    public var keys: [KeyVisual]
    public var ambience: AmbienceScene
    public var mood: Mood
    public var time: Double
}

/// Set 2's world (RED stub).
public struct SpaceshipLoungeModel: ThemeModel, MoodAware, SkyAware {
    public typealias Frame = LoungeFrame
    public static let id = "spaceship-lounge"
    public static let displayName = "Spaceship Lounge"
    public static let parameters: [ParamSpec] = []
    public static let macroTargets: [Macro: [(id: String, weight: Double)]] = [:]
    public var mood = Mood.neutral
    public init() {}
    public mutating func handle(_ e: PerformanceEvent) {}
    public mutating func setSky(_ s: SkyState) {}
    public mutating func step(dt: Double, params: ParameterSet, roles: RoleValues, inputs: InputFrame, quality: QualityLevel) -> LoungeFrame {
        LoungeFrame(sky: SkyState(), warp: WarpFrame(streaks: [], warpSpeed: 0, nebula: 0, nebulaHue: 0), earthRotation: 0,
                    keys: [], ambience: AmbienceScene(levels: [:], nightCool: 0, activity: 0, thunder: nil), mood: mood, time: 0)
    }
}
