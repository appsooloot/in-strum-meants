import Foundation
import simd

/// A star launched by a note, streaking out from the vanishing point.
public struct Streak: Equatable {
    public var direction: SIMD2<Float>
    public var distance: Float
    public var speed: Float
    public var brightness: Float
    public var hue: Float
    public var age: Float = 0
}

/// What Galaxy Warp draws this frame.
public struct WarpFrame: Equatable {
    public var streaks: [Streak]
    public var warpSpeed: Float
    public var nebula: Float
    public var nebulaHue: Float
}

/// Galaxy Warp (RED stub).
public struct GalaxyWarp {
    public static let cap = 400
    public static let maxAge: Float = 7
    public init() {}
    public mutating func noteOn(_ note: UInt8, velocity: UInt8, at t: Double) {}
    public mutating func noteOff(_ note: UInt8) {}
    public mutating func allNotesOff() {}
    public mutating func step(dt: Double, roles: RoleValues, inputs: InputFrame) -> WarpFrame {
        WarpFrame(streaks: [], warpSpeed: 0, nebula: 0, nebulaHue: 0)
    }
}
