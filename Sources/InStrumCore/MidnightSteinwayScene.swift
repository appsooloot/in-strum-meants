import Foundation

/// Glossy black stage; each key glows by how hard it was struck and
/// casts a warm spotlight. Held notes stay lit, the pedal makes them linger,
/// chords bloom across the stage.
public struct MidnightSteinwayScene: VisualScene {
    public static let id = "midnight-steinway"
    public static let displayName = "Midnight Steinway"
    public static let releaseHalfLife: Double = 0.25
    public static let pedalHalfLife: Double = 1.5
    public static let heldFloor: Float = 0.6
    public static let bloomHalfLife: Double = 0.6
    static let spotlightThreshold: Float = 0.05

    private static let layout = KeyboardLayout.keys()
    private static let lowest = Int(KeyboardLayout.lowestNote)

    // Indexed by note - 21.
    private var glow = [Float](repeating: 0, count: 88)
    private var strike = [Float](repeating: 0, count: 88)
    private var held = [Bool](repeating: false, count: 88)
    private var pedalDown = false
    private var bloom: Float = 0

    public init() {}

    private static func slot(_ note: UInt8) -> Int? {
        let i = Int(note) - lowest
        return (0..<88).contains(i) ? i : nil
    }

    public mutating func handle(_ event: PerformanceEvent) {
        switch event {
        case let .noteOn(note, velocity):
            guard let i = Self.slot(note) else { return }
            glow[i] = max(glow[i], velocity)
            strike[i] = velocity
            held[i] = true
        case let .noteOff(note):
            guard let i = Self.slot(note) else { return }
            held[i] = false
        case let .pedal(down, _):
            pedalDown = down
        case .chord:
            bloom = 1
        case .allNotesOff:
            glow = .init(repeating: 0, count: 88)
            strike = .init(repeating: 0, count: 88)
            held = .init(repeating: false, count: 88)
            pedalDown = false
            bloom = 0
        case .control, .pitchBend, .pressure, .release:
            break
        }
    }

    public mutating func step(dt: Double, intensity: Float, audioLevel: Float) -> SceneFrame {
        let releaseFactor = Float(pow(0.5, dt / Self.releaseHalfLife))
        let freeFactor = pedalDown ? Float(pow(0.5, dt / Self.pedalHalfLife)) : releaseFactor
        for i in 0..<88 {
            if held[i] {
                let floor = strike[i] * Self.heldFloor
                if glow[i] > floor { glow[i] = floor + (glow[i] - floor) * releaseFactor }
            } else {
                glow[i] *= freeFactor
            }
        }
        bloom *= Float(pow(0.5, dt / Self.bloomHalfLife))

        var keys: [KeyVisual] = []
        keys.reserveCapacity(88)
        var spotlights: [Spotlight] = []
        for rect in Self.layout {
            let i = Int(rect.note) - Self.lowest
            keys.append(KeyVisual(key: rect, pressed: held[i], glow: glow[i]))
            if glow[i] > Self.spotlightThreshold {
                spotlights.append(Spotlight(x: rect.x + rect.width / 2, intensity: glow[i]))
            }
        }
        let ambience = min(1, 0.15 + 0.5 * intensity + 0.35 * audioLevel)
        return SceneFrame(keys: keys, spotlights: spotlights, bloom: bloom, ambience: ambience)
    }
}
