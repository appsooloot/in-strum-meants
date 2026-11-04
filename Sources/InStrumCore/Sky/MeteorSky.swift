import Foundation
import simd

/// How a world shows shooting stars (spec §7.1): the IMO calendar's real showers at the rate your city would see, a
/// steady shower all night, or none at all.
public enum MeteorMode: String, Codable, CaseIterable {
    case follow = "Follow the calendar", always = "Always a shower", never = "Never"

    /// The world parameter that chooses it (a world parameter, so leaving the world leaves its meteors behind).
    public static func spec(default d: MeteorMode) -> ParamSpec {
        ParamSpec(id: "meteors.mode", name: "Meteors", group: "Sky",
                  help: "Follow the calendar (the real showers on their real dates, at the rate your city sees), a steady shower all night, or no shooting stars",
                  kind: .choice(allCases.map(\.rawValue)), defaultValue: .choice(d.rawValue))
    }
}

/// The strongest shower in the sky right now (spec §6.2): the calendar's strongest active shower by its ZHR now (even
/// when its radiant is below your horizon), or the steady shower of "Always a shower".
public struct ShowerNow: Equatable {
    /// The IMO code ("GEM"; "ALW" for the steady shower) and the name ("Geminids").
    public var code: String
    public var name: String
    /// The calendar's ZHR now.
    public var zhr: Double
    /// The radiant in this sky (degrees: altitude, and azimuth from north clockwise), among the stars as drawn.
    public var radiantAltitude: Double
    public var radiantAzimuth: Double
    /// Days to the peak at the Sun's mean motion (negative after the peak; 0 for the steady shower).
    public var daysToPeak: Double
    /// The next local hour on the sky's clock (0…<24) at which the radiant climbs through 10°: if it is above 10° now,
    /// that is about a day away. Nil when it never does: it stays below 10° (`radiantHighest` < 10, the Perseids from
    /// Melbourne), or it never sinks below 10° (circumpolar, and the steady shower).
    public var radiantRises: Double?
    /// The radiant's altitude at its upper culmination, degrees (90 − |latitude − declination|): below 0, it never
    /// rises here.
    public var radiantHighest: Double

    public init(code: String, name: String, zhr: Double, radiantAltitude: Double, radiantAzimuth: Double,
                daysToPeak: Double, radiantRises: Double?, radiantHighest: Double) {
        self.code = code; self.name = name; self.zhr = zhr
        self.radiantAltitude = radiantAltitude; self.radiantAzimuth = radiantAzimuth
        self.daysToPeak = daysToPeak; self.radiantRises = radiantRises; self.radiantHighest = radiantHighest
    }

    /// A calendar shower as this sky shows it at λ⊙ (degrees): its ZHR then, its radiant placed by the sky's sidereal
    /// time and latitude (so it sits among the drawn stars), the days to its peak and when its radiant next clears 10°.
    public init(_ shower: MeteorShower, lambda: Double, sky: SkyState) {
        let rad = shower.radiant(at: lambda)
        let h = MeteorSky.horizontal(MeteorSky.direction(alpha: rad.alpha, delta: rad.delta, sky: sky))
        self.init(code: shower.code, name: shower.name, zhr: shower.zhr(at: lambda),
                  radiantAltitude: h.altitude, radiantAzimuth: h.azimuth,
                  daysToPeak: shower.daysToPeak(from: lambda),
                  radiantRises: MeteorSky.risingHour(alpha: rad.alpha, delta: rad.delta, sky: sky),
                  radiantHighest: 90 - abs(sky.latitude - rad.delta))
    }
}

/// One shooting star (spec §6.2–§6.3). `start`, `end` and `radiant` are unit vectors in the horizon frame (x east,
/// y north, z up: the frame `SkyLayer.enu` puts the sun and moon in), and `born` is on `SkyState.meteorTime`'s clock.
/// The head runs from `start` to `end` along the great circle away from its radiant; a fast bright one then leaves a
/// train along the same path.
public struct Meteor: Equatable {
    public var start: SIMD3<Float>
    public var end: SIMD3<Float>
    /// Where it came from: its shower's radiant or, for a sporadic meteor, its own (zero when unknown).
    public var radiant: SIMD3<Float>
    /// When the head appeared (seconds on `SkyState.meteorTime`'s clock) and how long it runs (0.08…2.5 s).
    public var born: Double
    public var duration: Float
    /// Its peak magnitude as seen (after the airmass), on the stars' scale (brighter is lower; −4 or brighter is a
    /// fireball).
    public var magnitude: Float
    /// The head's colour (linear RGB, brightest channel 1): warm when slow, white, blue-green when fast and bright;
    /// faint meteors look white.
    public var colour: SIMD3<Float>
    /// Its train, 0 none … 1 long: a fast meteor (V∞ ≥ 55 km/s) brighter than −1 leaves one.
    public var train: Float
    /// Its source: the shower's index in `MeteorShowers.all`, `MeteorShowers.alwaysIndex` for the steady shower, or
    /// −1 for a sporadic meteor.
    public var shower: Int8
    /// About one bright meteor in ten (magnitude 0 or brighter) ends in a terminal flare.
    public var flare: Bool

    public init(start: SIMD3<Float>, end: SIMD3<Float>, born: Double, duration: Float, magnitude: Float,
                colour: SIMD3<Float> = SIMD3<Float>(1.0, 0.97, 0.9), train: Float = 0, shower: Int8 = -1,
                flare: Bool = false, radiant: SIMD3<Float> = .zero) {
        self.start = start; self.end = end; self.radiant = radiant
        self.born = born; self.duration = duration; self.magnitude = magnitude
        self.colour = colour; self.train = train; self.shower = shower; self.flare = flare
    }
}

public extension Meteor {
    /// Sirius's magnitude: brightness 1 on the stars' scale (the real-star texture's peak, before the shader's star
    /// gain). Each magnitude brighter is ×2.512.
    static let siriusMagnitude: Float = -1.44
    /// The train's glow (linear RGB).
    static let trainColour = SIMD3<Float>(0.5, 1.0, 0.7)

    /// How far the head has run at `t` (seconds on `SkyState.meteorTime`'s clock): 0 at `born` … 1 at the end, clamped.
    func progress(at t: Double) -> Float {
        guard duration > 0, t.isFinite else { return t >= born ? 1 : 0 }
        return Float(min(1, max(0, (t - born) / Double(duration))))
    }

    /// Whether the head is still running at `t`.
    func isHead(at t: Double) -> Bool { t >= born && t < born + Double(duration) }

    /// The head's peak brightness on the stars' scale: 10^(−0.4·(magnitude + 1.44)), 1 for a meteor as bright as Sirius.
    var peakBrightness: Float { pow(10, -0.4 * (magnitude - Meteor.siriusMagnitude)) }

    /// The head's brightness at `t` on the stars' scale (0 outside its run): the peak × sin(πp)^0.7 over the run
    /// (p = `progress(at:)`; the sine is clamped at 0, so the power's base is never negative), × a terminal flare's
    /// burst (up to 3.5× near p = 0.9) when it has one. The shader gets this number, so it needs no `pow`.
    func headBrightness(at t: Double) -> Float {
        guard isHead(at: t) else { return 0 }
        let p = progress(at: t)
        let base = max(0, sin(Float.pi * p))
        var light = pow(base, 0.7)
        if flare {
            let x = (p - 0.9) / 0.07
            if abs(x) < 1 {
                let b = 1 - x * x
                light *= 1 + 2.5 * b * b
            }
        }
        return peakBrightness * light
    }

    /// How long the train glows after the head ends: 1…8 s, longer for brighter meteors (0 without one).
    var trainSeconds: Float { train > 0 ? 1 + 7 * train : 0 }
    /// The train's starting brightness as a share of the head's peak: 3…10% (0 without one).
    var trainShare: Float { train > 0 ? 0.03 + 0.07 * train : 0 }
    /// How far the train drifts and curls over its life, degrees: 0.2…1 (the shader's one-octave noise offset × this).
    var trainDrift: Float { train > 0 ? 0.2 + 0.8 * train : 0 }

    /// How far through its life the train is at `t`: 0 as the head ends … 1 as it fades out; nil outside its life (or
    /// with no train).
    func trainAge(at t: Double) -> Float? {
        guard train > 0, t.isFinite else { return nil }
        let a = (t - born - Double(duration)) / Double(trainSeconds)
        guard a >= 0, a <= 1 else { return nil }
        return Float(a)
    }

    /// The train's brightness at `t` on the stars' scale (0 outside its life): `trainShare` of the head's peak,
    /// fading as (1 − age)².
    func trainBrightness(at t: Double) -> Float {
        guard let a = trainAge(at: t) else { return 0 }
        let fade = (1 - a) * (1 - a)
        return peakBrightness * trainShare * fade
    }

    /// How far the train has widened at `t`: 1 as the head ends … 3 as it fades.
    func trainWidening(at t: Double) -> Float { 1 + 2 * (trainAge(at: t) ?? 0) }

    /// When it has gone, head and train (seconds on the same clock).
    var ends: Double { born + Double(duration) + Double(trainSeconds) }
}

/// The meteor machine (spec §6.3): Poisson arrivals at the sum of the sources' visible rates, each picking its source
/// by its share and drawing its meteor, on its own seeded streams (like the aurora's), so the rest of the sky never
/// shifts. Rates are per second of viewing, so frozen and quick skies shower as a real night does, and the arrivals
/// (an exponential gap after each) are the same whatever the step: 1/60 s or a second.
struct MeteorSky {
    /// The most meteors in the sky at once: SkyU's six slots.
    static let slots = 6
    /// A fireball's sky brightening at most (8%).
    static let maxFlash: Float = 0.08
    /// Fireballs (this magnitude or brighter) brighten the sky.
    static let fireball: Float = -4
    /// Meteors that would start lower than this (degrees) are dropped.
    static let lowestStart = 5.0
    /// The most arrivals one step may spawn (only a huge step reaches it).
    static let arrivalCap = 100_000

    /// Test seam: every new meteor's magnitude before the airmass (nil: drawn from its source's population index).
    var forceMagnitude: Double?

    /// The meteors' clock: seconds of viewing (the steps' sum).
    private(set) var time = 0.0
    /// λ⊙ at the last step's calendar date.
    private(set) var lambda = 0.0
    /// The meteors in the sky after the last step (heads and trains, at most `slots`).
    private(set) var live: [Meteor] = []
    /// Meteors spawned, by source (`Meteor.shower`): every one kept, whether or not it found a slot.
    private(set) var tally: [Int8: Int] = [:]
    /// Arrivals drawn, kept or dropped (below 5°).
    private(set) var arrivals = 0

    /// Nine draws per arrival (whether used or not, so the stream keeps its step), and the gaps between arrivals.
    private var rng: SeededRandom
    private var gapRng: SeededRandom
    /// Expected arrivals since the last one, and the exponential draw at which the next one comes.
    private var hazard = 0.0
    private var threshold: Double
    private var sources: [Source] = []

    struct Source {
        var index: Int8
        var perHour: Double
        var radiant: SIMD3<Double>
        var speed: Double
        var r: Double
    }

    /// What the sky lets through (spec §6.3): dark (the sun at −6° or below), LM − 6.5, and the cloud and mist factors.
    struct Factors {
        var dark: Bool
        var lmExcess: Double
        var weather: Double
    }

    init(seed: UInt64) {
        rng = SeededRandom(seed: seed &* 0xA24B_AED4_963E_E407 &+ 0x3E7E)
        var gaps = SeededRandom(seed: seed &* 0x9FB2_1C65_1E98_DF25 &+ 0x7A11)
        threshold = Self.gap(&gaps)
        gapRng = gaps
    }

    /// Advances `dt` seconds of viewing at the calendar instant `date` (UT) under `sky` (its sun, moon, sidereal time,
    /// latitude, cloud and mist), with the Advanced "Meteors" `rate` (0.5…10) and the local apparent solar hour for the
    /// sporadic meteors (nil: the sky's clock hour).
    mutating func step(dt rawDt: Double, date: Date, sky: SkyState, mode: MeteorMode, rate rawRate: Double,
                       solarHour: Double? = nil) -> (meteors: [Meteor], flash: Float, shower: ShowerNow?, perHour: Float) {
        let dt = rawDt.isFinite ? max(0, rawDt) : 0
        let start = time
        time += dt
        lambda = SolarLongitude.degrees(at: date)
        if mode == .never {
            live.removeAll()
            return ([], 0, nil, 0)
        }
        let rate = rawRate.isFinite ? min(10, max(0.5, rawRate)) : 2
        let f = Self.factors(sky)
        sources.removeAll(keepingCapacity: true)
        var shower: ShowerNow?
        if mode == .follow {
            shower = followSources(sky: sky, factors: f, rate: rate)
        } else {
            let steady = MeteorShowers.always
            let dir = Self.alwaysRadiant(latitude: sky.latitude)
            if f.dark {
                let perHour = steady.zhr(at: lambda) * dir.z * pow(steady.r, f.lmExcess) * f.weather * rate
                sources.append(Source(index: MeteorShowers.alwaysIndex, perHour: perHour, radiant: dir,
                                      speed: steady.speed, r: steady.r))
            }
            shower = Self.alwaysNow(sky: sky)
        }
        if f.dark {
            let hour = solarHour ?? sky.hourOfDay
            let diurnal = 1 + 0.6 * cos(2 * Double.pi * (hour - 6) / 24)
            let sporadic = MeteorShowers.sporadicPerHour * diurnal * pow(MeteorShowers.sporadicR, f.lmExcess)
            sources.append(Source(index: -1, perHour: sporadic * f.weather * rate, radiant: .zero, speed: 0,
                                  r: MeteorShowers.sporadicR))
        }
        var total = 0.0
        for s in sources { total += s.perHour }

        // Arrivals: each comes when the expected count since the last one reaches its exponential draw.
        let perSecond = total / 3600
        if perSecond > 0, perSecond.isFinite {
            var t = start, left = dt, count = 0
            while hazard + perSecond * left >= threshold && count < Self.arrivalCap {
                let wait = min(left, max(0, (threshold - hazard) / perSecond))
                t += wait
                left -= wait
                hazard = 0
                arrive(at: t, total: total)
                threshold = Self.gap(&gapRng)
                count += 1
            }
            hazard += perSecond * left
        }
        let now = time
        live.removeAll { $0.ends <= now }
        keepSlots()
        return (live, flash(), shower, Float(total))
    }

    /// The calendar's sources for this step (the active showers whose radiants are up, while it is dark), and the
    /// strongest active shower by its ZHR now.
    private mutating func followSources(sky: SkyState, factors f: Factors, rate: Double) -> ShowerNow? {
        var strongest: Int?
        var strongestZHR = 0.0
        for (i, shower) in MeteorShowers.all.enumerated() {
            let z = shower.zhr(at: lambda)
            guard z > 0 else { continue }
            if z > strongestZHR { strongestZHR = z; strongest = i }
            guard f.dark else { continue }
            let rad = shower.radiant(at: lambda)
            let dir = Self.direction(alpha: rad.alpha, delta: rad.delta, sky: sky)
            guard dir.z > 0 else { continue }
            let perHour = z * dir.z * pow(shower.r, f.lmExcess) * f.weather * rate
            sources.append(Source(index: Int8(i), perHour: perHour, radiant: dir, speed: shower.speed, r: shower.r))
        }
        guard let i = strongest else { return nil }
        return ShowerNow(MeteorShowers.all[i], lambda: lambda, sky: sky)
    }

    /// One arrival at `t`: its source by share, then its magnitude, path, speed, colour, train and flare (spec §6.3
    /// steps 1–7). A meteor that would start below 5° is dropped.
    private mutating func arrive(at t: Double, total: Double) {
        arrivals &+= 1
        let uSource = Self.unit(&rng), uMagnitude = Self.unit(&rng), uDistance = Self.unit(&rng)
        let uAngle = Self.unit(&rng), uLength = Self.unit(&rng), uFlare = Self.unit(&rng)
        let uHeight = Self.unit(&rng), uBearing = Self.unit(&rng), uSpeed = Self.unit(&rng)
        guard let source = pick(uSource * total) else { return }
        var radiant = source.radiant
        var speed = source.speed
        if source.index < 0 {
            radiant = Self.sporadicRadiant(height: uHeight, bearing: uBearing)
            speed = Self.sporadicSpeed(uSpeed)
        }
        let intrinsic = forceMagnitude ?? Self.magnitude(populationIndex: source.r, unit: uMagnitude)
        guard let path = Self.path(radiant: radiant, distance: uDistance, angle: uAngle, length: uLength,
                                   magnitude: intrinsic, speed: speed) else { return }
        let seen = intrinsic - 2.5 * log10(0.3 + 0.7 * path.sinHeight.squareRoot())
        let train: Float = speed >= 55 && seen < -1 ? Float(min(1, (-1 - seen) / 6)) : 0
        let meteor = Meteor(start: Self.float(path.start), end: Self.float(path.end), born: t, duration: Float(path.duration),
                            magnitude: Float(seen), colour: Self.colour(speed: speed, magnitude: seen), train: train,
                            shower: source.index, flare: seen <= 0 && uFlare < 0.1, radiant: Self.float(radiant))
        tally[source.index, default: 0] += 1
        live.append(meteor)
        keepSlots()
    }

    /// The source a draw lands on, by each source's share of the total rate.
    private func pick(_ x: Double) -> Source? {
        var left = x
        for s in sources {
            left -= s.perHour
            if left < 0 { return s }
        }
        return sources.last
    }

    /// At most six at once: the faintest train goes first, then the faintest head.
    private mutating func keepSlots() {
        while live.count > Self.slots {
            var worst = 0
            var lowest = Double.infinity
            for (i, m) in live.enumerated() {
                let score = Self.importance(m, at: time)
                if score < lowest { lowest = score; worst = i }
            }
            live.remove(at: worst)
        }
    }

    static func importance(_ m: Meteor, at t: Double) -> Double {
        if t < m.born + Double(m.duration) { return 1000 - Double(m.magnitude) }   // heads before trains, brighter first
        return Double(m.trainBrightness(at: t))
    }

    /// The fireballs' soft sky brightening now: 8% × (0.2 at −4 … 1 at −8) × the head's light curve, summed and capped
    /// at 8%.
    private func flash() -> Float {
        var sum: Float = 0
        for m in live where m.magnitude <= Self.fireball && m.isHead(at: time) {
            let strength = min(1, (-3 - m.magnitude) / 5)
            let shape = m.headBrightness(at: time) / max(1e-6, m.peakBrightness)
            sum += Self.maxFlash * strength * shape
        }
        return min(Self.maxFlash, max(0, sum))
    }

    // MARK: - The sky's factors and frames

    static func factors(_ s: SkyState) -> Factors {
        let sunAltitude = s.sun.altitude.isFinite ? s.sun.altitude : 90
        let twilight = smoothstep(-18, -6, sunAltitude)
        let lit = s.moonLit.isFinite ? min(1, max(0, s.moonLit)) : 0
        let moonAltitude = s.moon.altitude.isFinite ? s.moon.altitude : -90
        let moonGlow = moonAltitude > 0 ? lit * sin(moonAltitude * .pi / 180) : 0
        let lm = 6.5 - 2.5 * moonGlow - 3 * twilight
        let cloud = s.cloudCover.isFinite ? Double(min(1, max(0, s.cloudCover))) : 0
        let mist = s.mist.isFinite ? Double(min(1, max(0, s.mist))) : 0
        return Factors(dark: sunAltitude <= -6, lmExcess: lm - 6.5, weather: (1 - 0.95 * cloud) * (1 - 0.5 * mist))
    }

    /// A star's direction in the horizon frame (x east, y north, z up) from its right ascension and declination
    /// (degrees), by the sky's sidereal time and latitude: the same turn the shader gives the real stars.
    static func direction(alpha: Double, delta: Double, sky: SkyState) -> SIMD3<Double> {
        let a = alpha * .pi / 180, d = delta * .pi / 180
        let lst = sky.siderealDegrees * .pi / 180, lat = sky.latitude * .pi / 180
        let cd = cos(d)
        let vx = cd * cos(a), vy = cd * sin(a), vz = sin(d)
        let sl = sin(lst), cl = cos(lst), sp = sin(lat), cp = cos(lat)
        let along = vx * cl + vy * sl
        let east = vy * cl - vx * sl
        let north = cp * vz - sp * along
        let up = cp * along + sp * vz
        return SIMD3(east, north, up)
    }

    /// Altitude and azimuth (from north, clockwise) of a horizon-frame direction, degrees.
    static func horizontal(_ v: SIMD3<Double>) -> (altitude: Double, azimuth: Double) {
        let altitude = asin(min(1, max(-1, v.z))) * 180 / .pi
        var azimuth = atan2(v.x, v.y) * 180 / .pi
        if azimuth < 0 { azimuth += 360 }
        return (altitude, azimuth)
    }

    /// The local hour (0…<24) at which a radiant next climbs through `clearing` degrees, from the sky's sidereal time
    /// and clock; nil if it never crosses that height here.
    static func risingHour(alpha: Double, delta: Double, sky: SkyState, clearing: Double = 10) -> Double? {
        let lat = sky.latitude * .pi / 180, dec = delta * .pi / 180
        let across = cos(lat) * cos(dec)
        guard abs(across) > 1e-9 else { return nil }
        let c = (sin(clearing * .pi / 180) - sin(lat) * sin(dec)) / across
        guard c > -1, c < 1 else { return nil }
        let hourAngle = acos(c) * 180 / .pi
        let wait = SolarLongitude.norm(alpha - hourAngle - sky.siderealDegrees)   // sidereal degrees until it rises
        var at = (sky.hourOfDay + wait / 15 / 1.002_737_909).truncatingRemainder(dividingBy: 24)
        if at < 0 { at += 24 }
        return at.isFinite ? at : nil
    }

    /// The steady shower's radiant: 80° up, toward the pole (behind a world's default, equator-facing view), fixed in
    /// the horizon frame.
    static func alwaysRadiant(latitude: Double) -> SIMD3<Double> {
        let a = MeteorShowers.alwaysAltitude * .pi / 180
        let north = latitude >= 0 ? cos(a) : -cos(a)
        return SIMD3(0, north, sin(a))
    }

    static func alwaysNow(sky: SkyState) -> ShowerNow {
        let s = MeteorShowers.always
        let h = horizontal(alwaysRadiant(latitude: sky.latitude))
        return ShowerNow(code: s.code, name: s.name, zhr: s.zhr(at: 0), radiantAltitude: h.altitude,
                         radiantAzimuth: h.azimuth, daysToPeak: 0, radiantRises: nil, radiantHighest: h.altitude)
    }

    // MARK: - Drawing a meteor

    /// The magnitude for a uniform draw u (0…<1; small u is bright): P(brighter than m) ∝ r^m from +5.5 down to −8.
    static func magnitude(populationIndex r: Double, unit u: Double) -> Double {
        let base = r.isFinite && r > 1 ? r : 2.5
        let low = pow(base, -8), high = pow(base, 5.5)
        let x = low + min(1, max(0, u)) * (high - low)
        return min(5.5, max(-8, log(x) / log(base)))
    }

    /// A sporadic radiant: uniform over the celestial sphere above −20° altitude.
    static func sporadicRadiant(height: Double, bearing: Double) -> SIMD3<Double> {
        let lowest = sin(-20 * Double.pi / 180)
        let z = lowest + height * (1 - lowest)
        let az = 2 * Double.pi * bearing
        let ring = max(0, 1 - z * z).squareRoot()
        return SIMD3(ring * sin(az), ring * cos(az), z)
    }

    /// A sporadic meteor's V∞: a triangular spread over 20–70 km/s peaking at 30 (mean 40).
    static func sporadicSpeed(_ u: Double) -> Double {
        if u < 0.2 { return 20 + (u * 500).squareRoot() }
        return 70 - ((1 - u) * 2000).squareRoot()
    }

    /// Steps 3–6: its distance D from the radiant (15°–100°, weighted by sin D) at a position angle, its run away from
    /// the radiant along their great circle ((6° + 14°·u)·√(sin D), 15% longer per magnitude brighter than 2), and its
    /// duration from the angular speed (0.62·V∞ − 0.0018·V∞²)°/s × sin h × sin D, clamped to 0.08–2.5 s. Nil when it
    /// would start below 5°.
    static func path(radiant: SIMD3<Double>, distance: Double, angle: Double, length: Double, magnitude: Double,
                     speed: Double) -> (start: SIMD3<Double>, end: SIMD3<Double>, sinHeight: Double, duration: Double)? {
        let nearest = cos(15 * Double.pi / 180), farthest = cos(100 * Double.pi / 180)
        let cosD = nearest - distance * (nearest - farthest)
        let d = acos(min(1, max(-1, cosD)))
        let sinD = sin(d)
        let reference = abs(radiant.z) < 0.9 ? SIMD3<Double>(0, 0, 1) : SIMD3<Double>(0, 1, 0)
        let p = unit(cross(radiant, reference))
        let q = cross(radiant, p)
        let psi = 2 * Double.pi * angle
        let tangent = p * cos(psi) + q * sin(psi)
        let start = radiant * cosD + tangent * sinD
        let sinHeight = start.z
        guard sinHeight >= sin(lowestStart * .pi / 180) else { return nil }
        let degrees = 180 / Double.pi
        let brighter = pow(1.15, max(0, 2 - magnitude))
        let run = min(175 - d * degrees, (6 + 14 * length) * sinD.squareRoot() * brighter)
        let travel = d + run / degrees
        let end = radiant * cos(travel) + tangent * sin(travel)
        let omega = (0.62 * speed - 0.0018 * speed * speed) * sinHeight * sinD
        let duration = omega > 0 ? min(2.5, max(0.08, run / omega)) : 2.5
        return (start, end, sinHeight, duration)
    }

    /// Colour by speed (slow warm yellow-orange, medium white, fast blue-green-white), fading to white when faint.
    static func colour(speed: Double, magnitude: Double) -> SIMD3<Float> {
        let warm = SIMD3<Float>(1.0, 0.8, 0.55), white = SIMD3<Float>(1.0, 0.97, 0.9), fast = SIMD3<Float>(0.75, 1.0, 0.9)
        let slow = Float(1 - smoothstep(26, 34, speed))
        let quick = Float(smoothstep(51, 59, speed))
        let bySpeed = white + (warm - white) * slow + (fast - white) * quick
        let vivid = Float(smoothstep(3.5, 1.0, magnitude))
        return white + (bySpeed - white) * vivid
    }

    // MARK: - Helpers

    /// A uniform double in 0…<1 (53 bits).
    static func unit(_ r: inout SeededRandom) -> Double { Double(r.next() >> 11) * 0x1p-53 }

    /// An exponential gap (mean 1) in expected arrivals.
    static func gap(_ r: inout SeededRandom) -> Double { -log(1 - unit(&r)) }

    static func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = min(1, max(0, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    static func dot(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double { a.x * b.x + a.y * b.y + a.z * b.z }

    static func cross(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
    }

    static func unit(_ v: SIMD3<Double>) -> SIMD3<Double> {
        let n = dot(v, v).squareRoot()
        return n > 0 ? v / n : v
    }

    static func float(_ v: SIMD3<Double>) -> SIMD3<Float> { SIMD3<Float>(Float(v.x), Float(v.y), Float(v.z)) }
}
