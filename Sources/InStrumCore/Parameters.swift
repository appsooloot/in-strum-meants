import Foundation

public struct RGBA: Codable, Equatable {
    public var r, g, b, a: Double
    public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) { self.r = r; self.g = g; self.b = b; self.a = a }
}

public struct GradientStop: Codable, Equatable {
    public var position: Double
    public var color: RGBA
    public init(position: Double, color: RGBA) { self.position = position; self.color = color }
}

public enum ParamKind: Equatable {
    case slider(ClosedRange<Double>)
    case integer(ClosedRange<Int>)
    case toggle
    case choice([String])
    case color
    case gradient
}

public enum ParamValue: Codable, Equatable {
    case number(Double)
    case bool(Bool)
    case choice(String)
    case color(RGBA)
    case gradient([GradientStop])
}

/// One setting a theme declares.
public struct ParamSpec: Identifiable {
    public let id: String, name: String, group: String, help: String
    public let kind: ParamKind
    public let defaultValue: ParamValue
    /// Shown on the front panel.
    public let hero: Bool
    /// Sliders/integers: tasteful range Surprise me may pick from. Non-nil for other kinds = may randomise.
    public let surprise: ClosedRange<Double>?

    public init(id: String, name: String, group: String, help: String, kind: ParamKind,
                defaultValue: ParamValue, hero: Bool = false, surprise: ClosedRange<Double>? = nil) {
        self.id = id; self.name = name; self.group = group; self.help = help
        self.kind = kind; self.defaultValue = defaultValue; self.hero = hero; self.surprise = surprise
    }

    /// Numeric span of a slider or integer, else nil.
    public var range: ClosedRange<Double>? {
        switch kind {
        case let .slider(r): return r
        case let .integer(r): return Double(r.lowerBound)...Double(r.upperBound)
        default: return nil
        }
    }

    /// The value made valid for this spec, or nil if it is the wrong kind.
    func validated(_ v: ParamValue) -> ParamValue? {
        switch (kind, v) {
        case let (.slider(r), .number(x)): return .number(min(max(x, r.lowerBound), r.upperBound))
        case let (.integer(r), .number(x)):
            return .number(Double(min(max(Int(x.rounded()), r.lowerBound), r.upperBound)))
        case (.toggle, .bool): return v
        case let (.choice(options), .choice(c)): return options.contains(c) ? v : nil
        case (.color, .color): return v
        case let (.gradient, .gradient(stops)):
            var s = Array(stops.prefix(6))
            if s.count == 1 { s.append(GradientStop(position: 1, color: s[0].color)) }
            return s.isEmpty ? nil : .gradient(s)
        default: return nil
        }
    }
}

public enum Macro: String, CaseIterable, Codable, CodingKeyRepresentable {
    case intensity, speed, density, glow, chaos, temperature
}

/// A theme's current setting values, with macros and live offsets applied on read.
public struct ParameterSet {
    public let specs: [ParamSpec]
    public let macroTargets: [Macro: [(id: String, weight: Double)]]
    /// -1...1, 0 = neutral.
    public var macros: [Macro: Double]
    private var base: [String: ParamValue] = [:]
    private var offsets: [String: Double] = [:]
    private let index: [String: Int]

    public init(specs: [ParamSpec], saved: [String: ParamValue] = [:], macros: [Macro: Double] = [:],
                macroTargets: [Macro: [(id: String, weight: Double)]] = [:]) {
        self.specs = specs
        self.macros = macros
        self.macroTargets = macroTargets
        var idx: [String: Int] = [:]
        for (i, s) in specs.enumerated() { idx[s.id] = i }
        index = idx
        for (id, v) in saved { set(id, v) }
    }

    private func spec(_ id: String) -> ParamSpec? { index[id].map { specs[$0] } }

    public func baseValue(_ id: String) -> ParamValue? {
        guard let s = spec(id) else { return nil }
        return base[id] ?? s.defaultValue
    }

    public func baseNumber(_ id: String) -> Double { Self.asNumber(baseValue(id)) }

    /// Effective value (macros and offsets applied to numbers).
    public func value(_ id: String) -> ParamValue {
        guard let s = spec(id), let b = baseValue(id) else { return .number(0) }
        guard let r = s.range, case let .number(x) = b else { return b }
        let half = (r.upperBound - r.lowerBound) / 2
        var v = x
        for (macro, targets) in macroTargets {
            let m = macros[macro] ?? 0
            guard m != 0 else { continue }
            for t in targets where t.id == id { v += m * t.weight * half }
        }
        if let o = offsets[id] { v += o * (r.upperBound - r.lowerBound) }
        v = min(max(v, r.lowerBound), r.upperBound)
        if case .integer = s.kind { v = v.rounded() }
        return .number(v)
    }

    public func number(_ id: String) -> Double { Self.asNumber(value(id)) }

    public func choice(_ id: String) -> String {
        if case let .choice(c) = value(id) { return c }
        return ""
    }

    public func color(_ id: String) -> RGBA {
        if case let .color(c) = value(id) { return c }
        return RGBA(1, 1, 1)
    }

    public func gradient(_ id: String) -> [GradientStop] {
        if case let .gradient(g) = value(id) { return g }
        return []
    }

    public mutating func set(_ id: String, _ v: ParamValue) {
        guard let s = spec(id), let valid = s.validated(v) else { return }
        base[id] = valid
    }

    public mutating func reset(_ id: String) { base[id] = nil }
    public mutating func resetGroup(_ group: String) {
        for s in specs where s.group == group { base[s.id] = nil }
    }
    public mutating func resetAll() { base.removeAll() }

    /// Only base values that differ from defaults.
    public var saved: [String: ParamValue] {
        var out: [String: ParamValue] = [:]
        for s in specs { if let v = base[s.id], v != s.defaultValue { out[s.id] = v } }
        return out
    }

    /// Adds live link offsets, in fractions of each setting's range.
    public func withOffsets(_ o: [String: Double]) -> ParameterSet {
        var copy = self
        copy.offsets = o
        return copy
    }

    private static func asNumber(_ v: ParamValue?) -> Double {
        switch v {
        case let .number(x)?: return x
        case let .bool(b)?: return b ? 1 : 0
        default: return 0
        }
    }
}

/// What a theme remembers between sessions.
public struct ThemeState: Codable, Equatable {
    public var values: [String: ParamValue]
    public var macros: [Macro: Double]
    public var lookPresetName: String?
    public init(values: [String: ParamValue] = [:], macros: [Macro: Double] = [:], lookPresetName: String? = nil) {
        self.values = values; self.macros = macros; self.lookPresetName = lookPresetName
    }
}

public enum QualitySetting: String, Codable, CaseIterable { case auto, lite, high, ultra }
