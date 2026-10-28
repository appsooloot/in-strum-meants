import simd
public struct Ripple: Equatable { public var x: Float = 0, depth: Float = 0, age: Float = 0, strength: Float = 0, lifetime: Float = 0 }
public struct Firefly: Equatable { public var position = SIMD3<Float>(repeating: 0); public var age: Float = 0; public var hue: Float = 0 }
public struct LakeRipples {
    public static let cap = 64
    public static func lakeX(keyCentre: Float) -> Float { 0 }
    public private(set) var ripples: [Ripple] = []
    public private(set) var fireflies: [Firefly] = []
    public private(set) var glitter: Float = 0
    public init() {}
    public mutating func noteOn(_ note: UInt8, velocity: UInt8, pedal: Bool, at t: Double) {}
    public mutating func noteOff(_ note: UInt8) {}
    public mutating func step(dt: Double, roles: RoleValues) {}
}
