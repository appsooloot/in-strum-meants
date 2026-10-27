/// What a reaction does, independent of theme. Each theme decides how a role looks.
public enum Role: String, CaseIterable, Codable, CodingKeyRepresentable {
    case energy, size, motion, direction, brightness, warmth, colorShift, linger, density, atmosphere, chaos

    /// Direction is signed (-1...1); every other role is 0...1.
    public var isSigned: Bool { self == .direction }

    public var displayName: String {
        switch self {
        case .energy: return "Energy"
        case .size: return "Size"
        case .motion: return "Motion speed"
        case .direction: return "Direction"
        case .brightness: return "Brightness"
        case .warmth: return "Warmth"
        case .colorShift: return "Colour shift"
        case .linger: return "Linger"
        case .density: return "Density"
        case .atmosphere: return "Atmosphere"
        case .chaos: return "Calm ↔ Chaos"
        }
    }
}

public struct RoleValues: Equatable {
    private var values: [Role: Double] = [:]
    public init() {}
    public subscript(_ r: Role) -> Double {
        get { values[r] ?? 0 }
        set { values[r] = r.isSigned ? max(-1, min(1, newValue)) : max(0, min(1, newValue)) }
    }
}
