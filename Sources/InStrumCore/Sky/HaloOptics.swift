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
