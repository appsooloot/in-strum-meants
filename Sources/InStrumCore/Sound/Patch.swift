/// The app's own instruments (made entirely in the app, no recordings).
public enum BuiltInEngine: String, Codable, CaseIterable {
    case feltGlass, orbitPad

    public var displayName: String {
        switch self {
        case .feltGlass: return "Felt Glass"
        case .orbitPad: return "Orbit Pad"
        }
    }
}

/// A recipe for a built-in instrument: which engine, and its dial values (keyed by parameter identifier).
public struct Patch: Codable, Equatable, Identifiable {
    public let id: String
    public var name: String
    public var engine: BuiltInEngine
    public var values: [String: Double]
    /// The song that inspired it (see `CreditLibrary`), if any.
    public var creditID: String?

    public init(id: String, name: String, engine: BuiltInEngine, values: [String: Double], creditID: String? = nil) {
        self.id = id; self.name = name; self.engine = engine; self.values = values; self.creditID = creditID
    }
}

/// The built-in presets (values from docs/superpowers/briefs).
public enum PatchLibrary {
    public static let all: [Patch] = [
        Patch(id: "felt-glass", name: "Felt Glass", engine: .feltGlass, values: dials(felt: 0.55, glass: 0.35, warmth: 0.60, ring: 0.55, space: 0.45, width: 0.50), creditID: "come-back-to-earth"),
        Patch(id: "bare-felt", name: "Bare Felt", engine: .feltGlass, values: dials(felt: 0.70, glass: 0.00, warmth: 0.65, ring: 0.50, space: 0.35, width: 0.45), creditID: "come-back-to-earth"),
        Patch(id: "glass-choir", name: "Glass Choir", engine: .feltGlass, values: dials(felt: 0.40, glass: 0.75, warmth: 0.50, ring: 0.70, space: 0.60, width: 0.70), creditID: "come-back-to-earth"),
        Patch(id: "lullaby", name: "Lullaby", engine: .feltGlass, values: dials(felt: 0.85, glass: 0.20, warmth: 0.80, ring: 0.45, space: 0.30, width: 0.35), creditID: "come-back-to-earth"),
        Patch(id: "orbit-pad", name: "Orbit Pad", engine: .orbitPad, values: pad(bloom: 0.55, drift: 0.40, motion: 0.45, shimmer: 0.25, brightness: 0.50, space: 0.55), creditID: "innerbloom"),
        Patch(id: "earthrise", name: "Earthrise", engine: .orbitPad, values: pad(bloom: 0.75, drift: 0.30, motion: 0.30, shimmer: 0.15, brightness: 0.40, space: 0.50), creditID: "innerbloom"),
        Patch(id: "weightless", name: "Weightless", engine: .orbitPad, values: pad(bloom: 0.50, drift: 0.45, motion: 0.55, shimmer: 0.60, brightness: 0.55, space: 0.75), creditID: "innerbloom"),
        Patch(id: "re-entry", name: "Re-entry", engine: .orbitPad, values: pad(bloom: 0.25, drift: 0.35, motion: 0.50, shimmer: 0.20, brightness: 0.75, space: 0.45), creditID: "innerbloom"),
    ]

    public static func defaultPatch(for engine: BuiltInEngine) -> Patch {
        all.first { $0.engine == engine }!
    }

    public static func patches(for engine: BuiltInEngine) -> [Patch] { all.filter { $0.engine == engine } }

    private static func dials(felt: Double, glass: Double, warmth: Double, ring: Double, space: Double, width: Double) -> [String: Double] {
        ["felt": felt, "glass": glass, "warmth": warmth, "ring": ring, "space": space, "width": width]
    }

    private static func pad(bloom: Double, drift: Double, motion: Double, shimmer: Double, brightness: Double, space: Double) -> [String: Double] {
        ["bloom": bloom, "drift": drift, "motion": motion, "shimmer": shimmer, "brightness": brightness, "space": space]
    }
}
