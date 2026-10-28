import Foundation

/// Ice-crystal and twilight optics for the sky dome: the 22° and 46° halos, sundogs and the Belt of Venus.
/// The sky shader mirrors these (`haloRing`, `sundogs`, `beltOfVenus` in SkyShaders.common).
public enum HaloOptics {
    /// Ring radii and the outer edge's fade, in degrees.
    public static let haloRadius = 22.0, outerRadius = 46.0, width = 1.5

    /// The ring's colour weights at `angle` degrees from the light: red just inside the radius, yellow on it,
    /// a bluish-white edge fading outward over `width`, and nothing well inside it.
    public static func ring(angle: Double, radius: Double) -> SIMD3<Float> {
        let x = angle - radius
        let a = (x + 0.2) / 0.3, b = (x - 0.15) / 0.35
        let red = Float(exp(-a * a)), yellow = Float(exp(-b * b))
        let tail = Float(smoothstep(-0.1, 0.3, x) * exp(-max(0, x - 0.1) / width))
        return red * SIMD3(1.0, 0.25, 0.05) + yellow * SIMD3(0.9, 0.85, 0.3) + tail * SIMD3(0.55, 0.65, 0.85)
    }

    /// How far either side of the sun the sundogs sit (degrees of azimuth): they move out as the sun climbs.
    public static func sundogOffset(sunAltitude: Double) -> Double {
        haloRadius / cos(sunAltitude * .pi / 180)
    }

    /// 1 up to a sun 30° high, fading to 0 by 45°, and 0 once the sun is more than 1° down.
    public static func sundogStrength(sunAltitude: Double) -> Double {
        sunAltitude < -1 ? 0 : 1 - smoothstep(30, 45, sunAltitude)
    }

    /// The pink twilight band opposite the sun: full with the sun between −4° and 0°, gone by −6° and +1°.
    public static func beltOfVenus(sunAltitude: Double) -> Double {
        smoothstep(-6, -4, sunAltitude) * (1 - smoothstep(0, 1, sunAltitude))
    }

    static func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = min(1, max(0, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }
}

/// Rainbow optics: the primary bow 40.5°–42.5° from the antisolar point (red outside), a fainter secondary 50.5°–53.5°
/// with the colours reversed (red inside), and Alexander's dark band between. The sky shader mirrors `bow`.
public enum RainbowOptics {
    /// 0 at the violet edge to 1 at the red edge across the primary bow; nil outside it.
    public static func primaryPosition(angle: Double) -> Double? {
        let t = (angle - 40.5) / 2.0
        return t >= 0 && t <= 1 ? t : nil
    }
    /// 0 at the red edge to 1 at the violet edge across the secondary bow; nil outside it.
    public static func secondaryPosition(angle: Double) -> Double? {
        let t = (angle - 50.5) / 3.0
        return t >= 0 && t <= 1 ? t : nil
    }
    /// Spectrum at `t` (0 violet … 1 red).
    public static func spectrum(_ t: Double) -> SIMD3<Float> {
        func g(_ x: Double, _ c: Double, _ w: Double) -> Float { Float(exp(-((x - c) / w) * ((x - c) / w))) }
        return SIMD3(g(t, 0.88, 0.2), g(t, 0.5, 0.18), g(t, 0.12, 0.2))
    }
    /// Light added at `angle` degrees from the antisolar point (before the sky's strength): the primary at 1,
    /// the secondary at 0.35, nothing between them or beyond.
    public static func bow(angle: Double) -> SIMD3<Float> {
        if let t = primaryPosition(angle: angle) { return spectrum(t) * edge(t) }
        if let t = secondaryPosition(angle: angle) { return spectrum(1 - t) * edge(t) * 0.35 }
        return SIMD3(0, 0, 0)
    }
    static func edge(_ t: Double) -> Float {
        Float(HaloOptics.smoothstep(0, 0.12, t) * (1 - HaloOptics.smoothstep(0.88, 1, t)))
    }
}
