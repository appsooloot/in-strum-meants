import Foundation

/// The Sun's apparent ecliptic longitude λ⊙ (Meeus, low precision, ch. 25), referred to the equinox of J2000.0 as the
/// IMO's meteor calendar is: accurate to about 0.01°, about 15 minutes on a shower's peak (spec §6.3). It depends on the
/// instant alone (Universal Time), so the calendar works for any year, on either side of the date line.
public enum SolarLongitude {
    /// λ⊙ at `date`, degrees 0…<360.
    public static func degrees(at date: Date) -> Double {
        let T = (date.timeIntervalSince1970 / 86_400 + 2_440_587.5 - 2_451_545) / 36_525
        let L0 = 280.46646 + T * (36_000.76983 + T * 0.0003032)
        let M = (357.52911 + T * (35_999.05029 - 0.0001537 * T)) * .pi / 180
        let c1 = sin(M) * (1.914602 - T * (0.004817 + 0.000014 * T))
        let c2 = sin(2 * M) * (0.019993 - 0.000101 * T) + sin(3 * M) * 0.000289
        let omega = (125.04 - 1934.136 * T) * .pi / 180
        // The true longitude (L0 + C), less aberration and nutation (apparent), less the precession since J2000
        // (0.01397° a year, Meeus 25.2).
        let lambda = L0 + c1 + c2 - 0.00569 - 0.00478 * sin(omega) - 1.397 * T
        return norm(lambda)
    }

    /// The Sun's mean motion along the ecliptic, degrees per day (360° in a tropical year): how "days to the peak"
    /// are counted.
    public static let degreesPerDay = 0.985_647_36

    /// `d` wrapped to 0…<360.
    static func norm(_ d: Double) -> Double {
        guard d.isFinite else { return 0 }
        let x = d.truncatingRemainder(dividingBy: 360)
        return x < 0 ? x + 360 : x
    }

    /// The signed angle from `b` to `a`, wrapped to −180…<180 (negative when `a` comes before `b`).
    static func difference(_ a: Double, _ b: Double) -> Double {
        let d = norm(a - b)
        return d >= 180 ? d - 360 : d
    }
}
