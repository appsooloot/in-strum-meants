import Foundation

/// One of the IMO's meteor showers (spec §6.3): its activity window and peak in solar longitude (J2000, degrees), its
/// radiant and the radiant's daily drift, its speed, population index and peak ZHR, and Jenniskens' activity curve.
public struct MeteorShower {
    public var code: String
    public var name: String
    /// The activity window, λ⊙ in degrees, from `activeFrom` to `activeTo` (wrapping through 360 if `activeTo` is the
    /// smaller): the IMO's first and last dates, from 0h UT on the first to 24h UT on the last.
    public var activeFrom: Double
    public var activeTo: Double
    /// The peak, λ⊙ in degrees.
    public var peak: Double
    /// The radiant at the peak (right ascension and declination, degrees) and its drift (degrees per day; days counted
    /// from the peak in λ⊙ at the Sun's mean motion, `SolarLongitude.degreesPerDay`).
    public var alpha: Double
    public var delta: Double
    public var driftAlpha: Double
    public var driftDelta: Double
    /// V∞, km/s.
    public var speed: Double
    /// The population index: each magnitude fainter, r times as many meteors.
    public var r: Double
    /// The IMO's peak ZHR.
    public var zhr: Double
    /// Jenniskens' slopes B before the peak (`bp`, the rising side) and after it (`bm`): ZHR ∝ 10^(−B·|λ⊙ − peak|).
    public var peakSlope: (bp: Double, bm: Double)
    /// A broad base under the peak, with its own ZHR and slopes, or nil.
    public var base: (zhr: Double, bp: Double, bm: Double)?

    public init(code: String, name: String, activeFrom: Double, activeTo: Double, peak: Double, alpha: Double, delta: Double,
                driftAlpha: Double, driftDelta: Double, speed: Double, r: Double, zhr: Double,
                peakSlope: (bp: Double, bm: Double), base: (zhr: Double, bp: Double, bm: Double)? = nil) {
        self.code = code; self.name = name
        self.activeFrom = activeFrom; self.activeTo = activeTo; self.peak = peak
        self.alpha = alpha; self.delta = delta; self.driftAlpha = driftAlpha; self.driftDelta = driftDelta
        self.speed = speed; self.r = r; self.zhr = zhr
        self.peakSlope = peakSlope; self.base = base
    }

    /// Whether λ⊙ lies inside the activity window.
    public func isActive(at lambda: Double) -> Bool {
        let l = SolarLongitude.norm(lambda)
        if activeFrom <= activeTo { return l >= activeFrom && l <= activeTo }
        return l >= activeFrom || l <= activeTo
    }

    /// The calendar's ZHR at λ⊙ (spec §6.3): Jenniskens' curve, its peak and base rescaled together so that they sum to
    /// the IMO's `zhr` at the peak; 0 outside the activity window.
    public func zhr(at lambda: Double) -> Double {
        let c = components(at: lambda)
        return c.peak + c.base
    }

    /// The two parts of the curve at λ⊙, each already rescaled (both 0 outside the window).
    func components(at lambda: Double) -> (peak: Double, base: Double) {
        guard lambda.isFinite, isActive(at: lambda) else { return (0, 0) }
        let d = SolarLongitude.difference(lambda, peak)
        let before = d < 0
        let away = abs(d)
        let top: Double = self.zhr
        let baseTop: Double = base?.zhr ?? 0
        let scale = top / (top + baseTop)
        let slope = before ? peakSlope.bp : peakSlope.bm
        let peakPart = scale * top * pow(10, -slope * away)
        guard let b = base else { return (peakPart, 0) }
        let baseSlope = before ? b.bp : b.bm
        return (peakPart, scale * b.zhr * pow(10, -baseSlope * away))
    }

    /// The radiant at λ⊙ (right ascension and declination, degrees): drifted linearly from its place at the peak.
    public func radiant(at lambda: Double) -> (alpha: Double, delta: Double) {
        let days = -daysToPeak(from: lambda)
        let a = SolarLongitude.norm(alpha + driftAlpha * days)
        let dec = min(90, max(-90, delta + driftDelta * days))
        return (a, dec)
    }

    /// Days from λ⊙ to the peak at the Sun's mean motion: positive before it, negative after.
    public func daysToPeak(from lambda: Double) -> Double {
        SolarLongitude.difference(peak, lambda) / SolarLongitude.degreesPerDay
    }

    /// The hourly rate this shower shows over the whole sky right now, before the Advanced "Meteors" setting (spec
    /// §6.3): ZHR(λ⊙) × sin(radiant altitude) × r^(LM − 6.5) × (1 − 0.95·cloud) × (1 − 0.5·mist), with the limiting
    /// magnitude LM lowered by moonlight and twilight; 0 with its radiant below the horizon or the sun above −6°.
    public func visibleRate(at lambda: Double, sky: SkyState) -> Double {
        let z = zhr(at: lambda)
        guard z > 0 else { return 0 }
        let f = MeteorSky.factors(sky)
        guard f.dark else { return 0 }
        let rad = radiant(at: lambda)
        let up = MeteorSky.direction(alpha: rad.alpha, delta: rad.delta, sky: sky).z
        guard up > 0 else { return 0 }
        return z * up * pow(r, f.lmExcess) * f.weather
    }
}

/// The IMO 2026 working list's major showers (spec §6.3, in its order; Tables 5 and 6), with Jenniskens' curves as the
/// NASA Meteoroid Environment Office tabulated them, and the steady shower of "Always a shower".
public enum MeteorShowers {
    public static let all: [MeteorShower] = [
        MeteorShower(code: "QUA", name: "Quadrantids", activeFrom: 276.13, activeTo: 292.44, peak: 283.15,
                     alpha: 230, delta: 49, driftAlpha: 0, driftDelta: 0,   // the table's "small": a short window
                     speed: 41, r: 2.1, zhr: 80, peakSlope: (2.5, 2.5), base: (20, 0.37, 0.45)),
        MeteorShower(code: "ACE", name: "α-Centaurids", activeFrom: 310.75, activeTo: 332.0, peak: 319.4,
                     alpha: 211, delta: -58, driftAlpha: 0, driftDelta: 0,
                     speed: 58, r: 2.0, zhr: 6, peakSlope: (0.2, 0.2)),   // no published slope: the typical B
        MeteorShower(code: "LYR", name: "April Lyrids", activeFrom: 23.7, activeTo: 40.28, peak: 32.32,
                     alpha: 271, delta: 34, driftAlpha: 1.1, driftDelta: 0,
                     speed: 49, r: 2.1, zhr: 18, peakSlope: (0.22, 0.22)),
        MeteorShower(code: "ETA", name: "η-Aquariids", activeFrom: 28.59, activeTo: 67.3, peak: 45.5,
                     alpha: 338, delta: -1, driftAlpha: 0.9, driftDelta: 0.4,
                     speed: 66, r: 2.4, zhr: 50, peakSlope: (0.08, 0.08)),
        MeteorShower(code: "SDA", name: "Southern δ-Aquariids", activeFrom: 109.32, activeTo: 150.5, peak: 127,
                     alpha: 340, delta: -16, driftAlpha: 0.8, driftDelta: 0.2,
                     speed: 41, r: 2.5, zhr: 25, peakSlope: (0.091, 0.091)),
        MeteorShower(code: "PER", name: "Perseids", activeFrom: 114.09, activeTo: 151.46, peak: 140.0,
                     alpha: 48, delta: 58, driftAlpha: 1.35, driftDelta: 0.12,
                     speed: 59, r: 2.2, zhr: 100, peakSlope: (0.35, 0.35), base: (23, 0.050, 0.092)),
        MeteorShower(code: "DRA", name: "October Draconids", activeFrom: 192.39, activeTo: 197.32, peak: 195.4,
                     alpha: 262, delta: 54, driftAlpha: 0, driftDelta: 0,
                     speed: 20, r: 2.6, zhr: 5, peakSlope: (7.2, 7.2)),   // hours long
        MeteorShower(code: "ORI", name: "Orionids", activeFrom: 188.45, activeTo: 225.22, peak: 208,
                     alpha: 95, delta: 16, driftAlpha: 0.7, driftDelta: 0.1,
                     speed: 66, r: 2.5, zhr: 20, peakSlope: (0.12, 0.12)),
        MeteorShower(code: "STA", name: "Southern Taurids", activeFrom: 176.69, activeTo: 238.3, peak: 223,
                     alpha: 52, delta: 15, driftAlpha: 0.8, driftDelta: 0.05,
                     speed: 27, r: 2.3, zhr: 7, peakSlope: (0.026, 0.026)),
        MeteorShower(code: "NTA", name: "Northern Taurids", activeFrom: 206.24, activeTo: 258.57, peak: 230,
                     alpha: 58, delta: 22, driftAlpha: 0.9, driftDelta: 0.15,
                     speed: 29, r: 2.3, zhr: 5, peakSlope: (0.026, 0.026)),
        MeteorShower(code: "LEO", name: "Leonids", activeFrom: 223.21, activeTo: 248.42, peak: 235.27,
                     alpha: 152, delta: 22, driftAlpha: 0.6, driftDelta: -0.3,
                     speed: 71, r: 2.5, zhr: 15, peakSlope: (0.55, 0.55), base: (4, 0.025, 0.15)),
        MeteorShower(code: "PUV", name: "Puppid-Velids", activeFrom: 248.42, activeTo: 263.65, peak: 255,
                     alpha: 123, delta: -45, driftAlpha: 0.6, driftDelta: 0,
                     speed: 44, r: 2.9, zhr: 10, peakSlope: (0.034, 0.034)),
        MeteorShower(code: "GEM", name: "Geminids", activeFrom: 251.46, activeTo: 268.74, peak: 262.2,
                     alpha: 112, delta: 33, driftAlpha: 1.0, driftDelta: -0.05,
                     speed: 35, r: 2.6, zhr: 150, peakSlope: (0.59, 0.81), base: (18, 0.09, 0.31)),
        MeteorShower(code: "URS", name: "Ursids", activeFrom: 264.67, activeTo: 274.85, peak: 270.7,
                     alpha: 217, delta: 76, driftAlpha: 0, driftDelta: -0.4,
                     speed: 33, r: 3.0, zhr: 10, peakSlope: (0.9, 0.9), base: (2, 0.08, 0.20)),
    ]

    /// "Always a shower" (spec §7.1): a steady ZHR 60 all year from a radiant held 80° up (its right ascension and
    /// declination are unused: the radiant stays put in the horizon frame), Perseid-fast and -rich in bright meteors.
    public static let always = MeteorShower(code: "ALW", name: "Steady shower", activeFrom: 0, activeTo: 360, peak: 0,
                                            alpha: 0, delta: 90, driftAlpha: 0, driftDelta: 0,
                                            speed: 59, r: 2.2, zhr: 60, peakSlope: (0, 0))
    /// The steady shower's altitude, degrees.
    public static let alwaysAltitude = 80.0
    /// `Meteor.shower` for the steady shower (the calendar's showers are 0…13, sporadic meteors −1).
    public static let alwaysIndex = Int8(14)

    /// Sporadic meteors (spec §6.3): 7 an hour × (1 + 0.6·cos(2π(t − 6 h)/24 h)) in local solar time, with this
    /// population index (the usual sporadic background's).
    public static let sporadicPerHour = 7.0
    public static let sporadicR = 3.0

    /// The calendar's shower with this IMO code ("GEM"), or nil.
    public static func shower(code: String) -> MeteorShower? {
        if code == always.code { return always }
        return all.first { $0.code == code }
    }

    /// The shower a meteor came from (`Meteor.shower`): nil for a sporadic meteor.
    public static func shower(index: Int8) -> MeteorShower? {
        if index == alwaysIndex { return always }
        guard index >= 0, Int(index) < all.count else { return nil }
        return all[Int(index)]
    }
}
