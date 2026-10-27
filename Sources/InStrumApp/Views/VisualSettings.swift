import InStrumCore

/// Pure helpers behind the Visuals panel (kept separate so they can be tested).
enum VisualSettings {
    static let macroSnap = 0.05

    static func heroSpecs(for themeID: String) -> [ParamSpec] {
        ThemeRegistry.parameters(for: themeID).filter(\.hero)
    }

    /// Applies one edit through the theme's validation; invalid values are ignored.
    static func updated(_ state: ThemeState, themeID: String, id: String, to value: ParamValue) -> ThemeState {
        var set = ThemeRegistry.parameterSet(for: themeID, state: state)
        set.set(id, value)
        var out = state
        out.values = set.saved
        out.lookPresetName = nil
        return out
    }

    /// Macros snap to neutral within ±0.05 so "centre" is easy to hit.
    static func updatedMacro(_ state: ThemeState, _ macro: Macro, to value: Double) -> ThemeState {
        var out = state
        let v = max(-1, min(1, value))
        out.macros[macro] = abs(v) < macroSnap ? 0 : v
        out.lookPresetName = nil
        return out
    }

    static func reset(_ state: ThemeState) -> ThemeState { ThemeState() }

    static func macroName(_ m: Macro) -> String {
        switch m {
        case .intensity: return "Intensity"
        case .speed: return "Speed"
        case .density: return "Density"
        case .glow: return "Glow"
        case .chaos: return "Calm ↔ Chaos"
        case .temperature: return "Colour temperature"
        }
    }
}
