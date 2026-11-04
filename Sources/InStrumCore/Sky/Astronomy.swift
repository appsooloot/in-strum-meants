import Foundation

/// A place on Earth in degrees (east and north positive).
public struct GeoPoint: Codable, Equatable {
    public var latitude, longitude: Double
    public init(latitude: Double, longitude: Double) { self.latitude = latitude; self.longitude = longitude }
}

/// Where something is in the sky, in degrees: azimuth from north clockwise, altitude above the horizon.
public struct SkyDirection: Equatable {
    public var azimuth, altitude: Double
    public init(azimuth: Double, altitude: Double) { self.azimuth = azimuth; self.altitude = altitude }
}

public enum MoonPhaseEvent { case new, firstQuarter, full, lastQuarter }

// MARK: - Shared helpers

enum Astro {
    static func rad(_ d: Double) -> Double { d * .pi / 180 }
    static func deg(_ r: Double) -> Double { r * 180 / .pi }
    static func norm(_ d: Double) -> Double { let x = d.truncatingRemainder(dividingBy: 360); return x < 0 ? x + 360 : x }
    static func julianDay(_ t: Date) -> Double { t.timeIntervalSince1970 / 86_400 + 2_440_587.5 }
    static func centuries(_ t: Date) -> Double { (julianDay(t) - 2_451_545) / 36_525 }

    /// Standard atmospheric refraction (NOAA), degrees to add to a geometric altitude.
    static func refraction(_ alt: Double) -> Double {
        if alt > 85 { return 0 }
        let te = tan(rad(alt))
        let arcsec: Double
        if alt > 5 { arcsec = 58.1 / te - 0.07 / (te * te * te) + 0.000086 / pow(te, 5) }
        else if alt > -0.575 { arcsec = 1735 + alt * (-518.2 + alt * (103.4 + alt * (-12.79 + alt * 0.711))) }
        else { arcsec = -20.774 / te }
        return arcsec / 3600
    }

    /// Azimuth (from north, clockwise) and altitude of an object at hour angle `ha` and declination `dec`.
    static func horizontal(hourAngle ha: Double, declination dec: Double, latitude lat: Double) -> (az: Double, alt: Double) {
        let h = rad(ha), d = rad(dec), p = rad(lat)
        let sinAlt = sin(p) * sin(d) + cos(p) * cos(d) * cos(h)
        let alt = deg(asin(max(-1, min(1, sinAlt))))
        let az = norm(deg(atan2(sin(h), cos(h) * sin(p) - tan(d) * cos(p))) + 180)
        return (az, alt)
    }

    /// The local calendar day containing `day`: [start, next start).
    static func dayBounds(_ day: Date, _ zone: TimeZone) -> (Date, Date) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let start = cal.startOfDay(for: day)
        return (start, cal.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400))
    }

    /// Times within the local day when `f` crosses zero upward (rises) and downward (sets),
    /// sampled every 10 minutes and refined to under a second.
    static func crossings(_ day: Date, _ zone: TimeZone, _ f: (Date) -> Double) -> (rises: [Date], sets: [Date]) {
        let (start, end) = dayBounds(day, zone)
        var rises: [Date] = [], sets: [Date] = []
        var t = start, prev = f(t)
        while t < end {
            let t2 = min(t.addingTimeInterval(600), end), cur = f(t2)
            if (prev < 0) != (cur < 0) {
                var a = t, b = t2, fa = prev
                for _ in 0..<20 {
                    let m = a.addingTimeInterval(b.timeIntervalSince(a) / 2), fm = f(m)
                    if (fm < 0) == (fa < 0) { a = m; fa = fm } else { b = m }
                }
                let at = a.addingTimeInterval(b.timeIntervalSince(a) / 2)
                if prev < 0 { rises.append(at) } else { sets.append(at) }
            }
            t = t2; prev = cur
        }
        return (rises, sets)
    }
}

// MARK: - Sun (NOAA)

public enum Solar {
    struct Core { var longitude, declination, equationOfTime: Double }

    static func core(_ t: Date) -> Core {
        let T = Astro.centuries(t)
        let L0 = Astro.norm(280.46646 + T * (36_000.76983 + T * 0.0003032))
        let M = 357.52911 + T * (35_999.05029 - 0.0001537 * T)
        let e = 0.016708634 - T * (0.000042037 + 0.0000001267 * T)
        let C = sin(Astro.rad(M)) * (1.914602 - T * (0.004817 + 0.000014 * T))
            + sin(Astro.rad(2 * M)) * (0.019993 - 0.000101 * T) + sin(Astro.rad(3 * M)) * 0.000289
        let omega = 125.04 - 1934.136 * T
        let lambda = L0 + C - 0.00569 - 0.00478 * sin(Astro.rad(omega))
        let eps0 = 23 + (26 + (21.448 - T * (46.815 + T * (0.00059 - T * 0.001813))) / 60) / 60
        let eps = eps0 + 0.00256 * cos(Astro.rad(omega))
        let decl = Astro.deg(asin(sin(Astro.rad(eps)) * sin(Astro.rad(lambda))))
        let y = pow(tan(Astro.rad(eps / 2)), 2)
        let l0 = Astro.rad(L0), m = Astro.rad(M)
        let eot = 4 * Astro.deg(y * sin(2 * l0) - 2 * e * sin(m) + 4 * e * y * sin(m) * cos(2 * l0)
                                - 0.5 * y * y * sin(4 * l0) - 1.25 * e * e * sin(2 * m))
        return Core(longitude: Astro.norm(lambda), declination: decl, equationOfTime: eot)
    }

    /// Geometric (unrefracted) direction of the sun's centre.
    static func geometric(at t: Date, from p: GeoPoint) -> SkyDirection {
        let c = core(t)
        let minutes = t.timeIntervalSince1970.truncatingRemainder(dividingBy: 86_400) / 60
        let solarTime = (minutes + c.equationOfTime + 4 * p.longitude).truncatingRemainder(dividingBy: 1440)
        let h = Astro.horizontal(hourAngle: solarTime / 4 - 180, declination: c.declination, latitude: p.latitude)
        return SkyDirection(azimuth: h.az, altitude: h.alt)
    }

    /// Local apparent solar time at `longitude` (east +), hours 0…<24: 12 when the sun crosses the meridian.
    static func apparentSolarHour(at t: Date, longitude: Double) -> Double {
        let minutes = t.timeIntervalSince1970.truncatingRemainder(dividingBy: 86_400) / 60
        var solar = (minutes + core(t).equationOfTime + 4 * longitude).truncatingRemainder(dividingBy: 1440)
        if solar < 0 { solar += 1440 }
        return solar / 60
    }

    /// Refraction-corrected direction of the sun.
    public static func direction(at t: Date, from p: GeoPoint) -> SkyDirection {
        var d = geometric(at: t, from: p)
        d.altitude += Astro.refraction(d.altitude)
        return d
    }

    /// When the upper limb clears the horizon (−0.833°) on that local day; nil if it doesn't (polar night/day).
    public static func sunrise(on day: Date, at p: GeoPoint, timeZone: TimeZone) -> Date? {
        Astro.crossings(day, timeZone) { geometric(at: $0, from: p).altitude + 0.833 }.rises.first
    }

    public static func sunset(on day: Date, at p: GeoPoint, timeZone: TimeZone) -> Date? {
        Astro.crossings(day, timeZone) { geometric(at: $0, from: p).altitude + 0.833 }.sets.first
    }

    /// Where the sun is overhead right now.
    public static func subsolarPoint(at t: Date) -> GeoPoint {
        let c = core(t)
        let hours = t.timeIntervalSince1970.truncatingRemainder(dividingBy: 86_400) / 3600
        var lon = -15 * (hours - 12 + c.equationOfTime / 60)
        lon = (lon + 180).truncatingRemainder(dividingBy: 360)
        if lon < 0 { lon += 360 }
        return GeoPoint(latitude: c.declination, longitude: lon - 180)
    }
}

// MARK: - Sidereal time

public enum Sidereal {
    /// Mean sidereal time at `longitude` (east +), degrees 0…360 (Meeus 12.4).
    public static func localSiderealDegrees(at t: Date, longitude: Double) -> Double {
        let jd = Astro.julianDay(t), T = (jd - 2_451_545) / 36_525
        let gmst = 280.46061837 + 360.98564736629 * (jd - 2_451_545) + 0.000387933 * T * T - T * T * T / 38_710_000
        return Astro.norm(gmst + longitude)
    }
}

// MARK: - Moon (Meeus ch. 47, main terms)

public enum Lunar {
    // (D, M, M', F, Σl ×1e-6 °, Σr ×1e-3 km)
    private static let lr: [(Double, Double, Double, Double, Double, Double)] = [
        (0, 0, 1, 0, 6_288_774, -20_905_355), (2, 0, -1, 0, 1_274_027, -3_699_111), (2, 0, 0, 0, 658_314, -2_955_968),
        (0, 0, 2, 0, 213_618, -569_925), (0, 1, 0, 0, -185_116, 48_888), (0, 0, 0, 2, -114_332, -3_149),
        (2, 0, -2, 0, 58_793, 246_158), (2, -1, -1, 0, 57_066, -152_138), (2, 0, 1, 0, 53_322, -170_733),
        (2, -1, 0, 0, 45_758, -204_586), (0, 1, -1, 0, -40_923, -129_620), (1, 0, 0, 0, -34_720, 108_743),
        (0, 1, 1, 0, -30_383, 104_755), (2, 0, 0, -2, 15_327, 10_321), (0, 0, 1, 2, -12_528, 0),
        (0, 0, 1, -2, 10_980, 79_661), (4, 0, -1, 0, 10_675, -34_782), (0, 0, 3, 0, 10_034, -23_210),
        (4, 0, -2, 0, 8_548, -21_636), (2, 1, -1, 0, -7_888, 24_208), (2, 1, 0, 0, -6_766, 30_824),
        (1, 0, -1, 0, -5_163, -8_379), (1, 1, 0, 0, 4_987, -16_675), (2, -1, 1, 0, 4_036, -12_831),
        (2, 0, 2, 0, 3_994, -10_445), (4, 0, 0, 0, 3_861, -11_650), (2, 0, -3, 0, 3_665, 14_403),
        (0, 1, -2, 0, -2_689, -7_003), (2, 0, -1, 2, -2_602, 0), (2, -1, -2, 0, 2_390, 10_056),
        (1, 0, 1, 0, -2_348, 6_322), (2, -2, 0, 0, 2_236, -9_884), (0, 1, 2, 0, -2_120, 5_751),
        (0, 2, 0, 0, -2_069, 0), (2, -2, -1, 0, 2_048, -4_950), (2, 0, 1, -2, -1_773, 4_130),
        (2, 0, 0, 2, -1_595, 0), (4, -1, -1, 0, 1_215, -3_958), (0, 0, 2, 2, -1_110, 0), (3, 0, -1, 0, -892, 3_258),
    ]
    // (D, M, M', F, Σb ×1e-6 °)
    private static let b: [(Double, Double, Double, Double, Double)] = [
        (0, 0, 0, 1, 5_128_122), (0, 0, 1, 1, 280_602), (0, 0, 1, -1, 277_693), (2, 0, 0, -1, 173_237),
        (2, 0, -1, 1, 55_413), (2, 0, -1, -1, 46_271), (2, 0, 0, 1, 32_573), (0, 0, 2, 1, 17_198),
        (2, 0, 1, -1, 9_266), (0, 0, 2, -1, 8_822), (2, -1, 0, -1, 8_216), (2, 0, -2, -1, 4_324),
        (2, 0, 1, 1, 4_200), (2, 1, 0, -1, -3_359), (2, -1, -1, 1, 2_463), (2, -1, 0, 1, 2_211),
        (2, -1, -1, -1, 2_065), (0, 1, -1, -1, -1_870), (4, 0, -1, -1, 1_828), (0, 1, 0, 1, -1_794),
        (0, 0, 0, 3, -1_749), (0, 1, -1, 1, -1_565), (1, 0, 0, 1, -1_491), (0, 1, 1, 1, -1_475),
        (0, 1, 1, -1, -1_410), (0, 1, 0, -1, -1_344), (1, 0, 0, -1, -1_335), (0, 0, 3, 1, 1_107),
        (4, 0, 0, -1, 1_021), (4, 0, -1, 1, 833),
    ]

    struct Ecliptic { var longitude, latitude, distanceKm: Double }
    struct Equatorial { var rightAscension, declination, distanceKm: Double }

    /// Apparent geocentric ecliptic position (nutation in longitude included).
    static func ecliptic(_ T: Double) -> Ecliptic {
        let T2 = T * T, T3 = T2 * T, T4 = T3 * T
        let Lp = Astro.norm(218.3164477 + 481_267.88123421 * T - 0.0015786 * T2 + T3 / 538_841 - T4 / 65_194_000)
        let D = Astro.norm(297.8501921 + 445_267.1114034 * T - 0.0018819 * T2 + T3 / 545_868 - T4 / 113_065_000)
        let M = Astro.norm(357.5291092 + 35_999.0502909 * T - 0.0001536 * T2 + T3 / 24_490_000)
        let Mp = Astro.norm(134.9633964 + 477_198.8675055 * T + 0.0087414 * T2 + T3 / 69_699 - T4 / 14_712_000)
        let F = Astro.norm(93.2720950 + 483_202.0175233 * T - 0.0036539 * T2 - T3 / 3_526_000 + T4 / 863_310_000)
        let E = 1 - 0.002516 * T - 0.0000074 * T2
        let A1 = Astro.norm(119.75 + 131.849 * T), A2 = Astro.norm(53.09 + 479_264.290 * T), A3 = Astro.norm(313.45 + 481_266.484 * T)
        var sl = 0.0, sr = 0.0, sb = 0.0
        for (d, m, mp, f, cl, cr) in lr {
            let arg = Astro.rad(d * D + m * M + mp * Mp + f * F), ef = pow(E, abs(m))
            sl += cl * ef * sin(arg); sr += cr * ef * cos(arg)
        }
        for (d, m, mp, f, cb) in b {
            sb += cb * pow(E, abs(m)) * sin(Astro.rad(d * D + m * M + mp * Mp + f * F))
        }
        sl += 3958 * sin(Astro.rad(A1)) + 1962 * sin(Astro.rad(Lp - F)) + 318 * sin(Astro.rad(A2))
        sb += -2235 * sin(Astro.rad(Lp)) + 382 * sin(Astro.rad(A3)) + 175 * sin(Astro.rad(A1 - F)) + 175 * sin(Astro.rad(A1 + F))
            + 127 * sin(Astro.rad(Lp - Mp)) - 115 * sin(Astro.rad(Lp + Mp))
        let om = Astro.rad(125.04452 - 1934.136261 * T), ls = Astro.rad(280.4665 + 36_000.7698 * T), lm = Astro.rad(218.3165 + 481_267.8813 * T)
        let dpsi = (-17.20 * sin(om) - 1.32 * sin(2 * ls) - 0.23 * sin(2 * lm) + 0.21 * sin(2 * om)) / 3600
        return Ecliptic(longitude: Astro.norm(Lp + sl / 1e6 + dpsi), latitude: sb / 1e6, distanceKm: 385_000.56 + sr / 1000)
    }

    static func obliquity(_ T: Double) -> Double {
        23.439291 - 0.0130042 * T + 0.00256 * cos(Astro.rad(125.04452 - 1934.136261 * T))
    }

    static func equatorial(at t: Date) -> Equatorial {
        let T = Astro.centuries(t), e = ecliptic(T)
        let l = Astro.rad(e.longitude), bb = Astro.rad(e.latitude), eps = Astro.rad(obliquity(T))
        let ra = Astro.deg(atan2(sin(l) * cos(eps) - tan(bb) * sin(eps), cos(l)))
        let dec = Astro.deg(asin(sin(bb) * cos(eps) + cos(bb) * sin(eps) * sin(l)))
        return Equatorial(rightAscension: Astro.norm(ra), declination: dec, distanceKm: e.distanceKm)
    }

    /// Geocentric altitude/azimuth and horizontal parallax (degrees).
    static func geocentric(at t: Date, from p: GeoPoint) -> (direction: SkyDirection, parallax: Double) {
        let q = equatorial(at: t)
        let ha = Sidereal.localSiderealDegrees(at: t, longitude: p.longitude) - q.rightAscension
        let h = Astro.horizontal(hourAngle: ha, declination: q.declination, latitude: p.latitude)
        return (SkyDirection(azimuth: h.az, altitude: h.alt), Astro.deg(asin(6378.14 / q.distanceKm)))
    }

    /// Where the moon appears from this place: topocentric (parallax) and refraction-corrected.
    public static func direction(at t: Date, from p: GeoPoint) -> SkyDirection {
        let g = geocentric(at: t, from: p)
        var alt = g.direction.altitude - Astro.deg(asin(sin(Astro.rad(g.parallax)) * cos(Astro.rad(g.direction.altitude))))
        alt += Astro.refraction(alt)
        return SkyDirection(azimuth: g.direction.azimuth, altitude: alt)
    }

    /// Moon's ecliptic longitude minus the sun's: 0 new, 90 first quarter, 180 full, 270 last quarter.
    public static func phaseAngle(at t: Date) -> Double {
        Astro.norm(ecliptic(Astro.centuries(t)).longitude - Solar.core(t).longitude)
    }

    /// Fraction of the disc that is lit, 0…1 (Meeus ch. 48).
    public static func illuminatedFraction(at t: Date) -> Double {
        let m = ecliptic(Astro.centuries(t)), sun = Solar.core(t).longitude
        let psi = acos(cos(Astro.rad(m.latitude)) * cos(Astro.rad(m.longitude - sun)))
        let au = 149_597_870.7
        let i = atan2(au * sin(psi), m.distanceKm - au * cos(psi))
        return (1 + cos(i)) / 2
    }

    /// The next moment the moon reaches `phase` after `after` (solved on this ephemeris: a minute or two of the published times).
    public static func next(_ phase: MoonPhaseEvent, after: Date) -> Date {
        let target: Double
        switch phase { case .new: target = 0; case .firstQuarter: target = 90; case .full: target = 180; case .lastQuarter: target = 270 }
        let rate = 12.1907   // mean degrees per day
        var t = after.addingTimeInterval(Astro.norm(target - phaseAngle(at: after)) / rate * 86_400)
        for _ in 0..<8 {
            var d = Astro.norm(phaseAngle(at: t) - target)
            if d > 180 { d -= 360 }
            t = t.addingTimeInterval(-d / rate * 86_400)
        }
        if t <= after { return next(phase, after: after.addingTimeInterval(86_400)) }
        return t
    }

    /// Meeus' moonrise horizon: geocentric altitude h0 = 0.7275·parallax − 0.5667° (≈ +0.125°).
    private static func aboveHorizon(_ t: Date, _ p: GeoPoint) -> Double {
        let g = geocentric(at: t, from: p)
        return g.direction.altitude - (0.7275 * g.parallax - 0.5667)
    }

    public static func moonrise(on day: Date, at p: GeoPoint, timeZone: TimeZone) -> Date? {
        Astro.crossings(day, timeZone) { aboveHorizon($0, p) }.rises.first
    }

    public static func moonset(on day: Date, at p: GeoPoint, timeZone: TimeZone) -> Date? {
        Astro.crossings(day, timeZone) { aboveHorizon($0, p) }.sets.first
    }
}
