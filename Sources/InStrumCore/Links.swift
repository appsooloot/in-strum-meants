import Foundation

/// What a link drives: a role, or one specific theme setting.
public enum Target: Codable, Hashable {
    case role(Role)
    case param(String)
}

/// Response shape: gentle (x²), linear, snappy (√x). Sign is preserved.
public enum Curve: String, Codable, CaseIterable {
    case gentle, linear, snappy

    public func apply(_ x: Double) -> Double {
        let m = abs(x)
        let y: Double
        switch self {
        case .gentle: y = m * m
        case .linear: y = m
        case .snappy: y = m.squareRoot()
        }
        return x < 0 ? -y : y
    }
}

/// input → target, with amount (-1...1), curve and on/off.
public struct Link: Codable, Equatable, Identifiable {
    public var id: UUID
    public var input: InputID
    public var target: Target
    public var amount: Double
    public var curve: Curve
    public var enabled: Bool

    public init(id: UUID = UUID(), input: InputID, target: Target, amount: Double, curve: Curve = .linear, enabled: Bool = true) {
        self.id = id; self.input = input; self.target = target
        self.amount = max(-1, min(1, amount)); self.curve = curve; self.enabled = enabled
    }
}

/// A full set of reactions. Works in every theme because it targets roles.
public struct ReactionMap: Codable, Equatable {
    public var links: [Link]
    /// Per input family, default 1.
    public var groupStrength: [InputFamily: Double]

    public init(links: [Link], groupStrength: [InputFamily: Double] = [:]) {
        self.links = links
        self.groupStrength = groupStrength
    }

    /// Role values (clamped) and theme-setting offsets (fractions of range; the theme clamps).
    public func evaluate(_ frame: InputFrame) -> (roles: RoleValues, offsets: [String: Double]) {
        var sums: [Role: Double] = [:]
        var offsets: [String: Double] = [:]
        for link in links where link.enabled {
            let strength = groupStrength[link.input.family] ?? 1
            let v = link.curve.apply(frame[link.input]) * link.amount * strength
            switch link.target {
            case let .role(r): sums[r, default: 0] += v
            case let .param(id): offsets[id, default: 0] += v
            }
        }
        var roles = RoleValues()
        for (r, v) in sums { roles[r] = v }
        return (roles, offsets)
    }
}

/// Avoids clashing with SwiftUI.Link in views.
public typealias ReactionLink = Link
