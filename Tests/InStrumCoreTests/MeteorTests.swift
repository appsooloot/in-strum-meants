import XCTest
import simd
@testable import InStrumCore

/// The meteor calendar and machine (spec §6.3, Sets 11 & 12 Task 5). Every statistical bound here was measured on a
/// bit-exact Python mirror of the machine's seeded streams for the seeds used (the measured values are noted), and
/// holds at 4σ or better whatever the seed.
final class MeteorTests: XCTestCase {
    private func date(_ iso: String) throws -> Date { try XCTUnwrap(ISO8601DateFormatter().date(from: iso)) }

    /// A frozen sky over `city` at `hour` on the day of `now`: clear, and the moon new (frozen phase 0, so it never lights
    /// the sky).
    private func frozenSky(_ city: String, hour: Double, rate: Double = 2, seed: UInt64 = 1) -> LivingSky {
        var s = SkySettings(); s.timeMode = .frozen; s.frozenHour = hour; s.frozenPhase = 0; s.cityID = city
        s.weatherMode = .pick; s.weather = .clear; s.meteorRate = rate
        return LivingSky(settings: s, seed: seed)
    }

    /// The real sky over `city`, clear.
    private func realSky(_ city: String, rate: Double = 2) -> LivingSky {
        var s = SkySettings(); s.timeMode = .realTime; s.cityID = city; s.weatherMode = .pick; s.weather = .clear
        s.meteorRate = rate
        return LivingSky(settings: s)
    }

    private func spawned(_ sky: LivingSky) -> Int { sky.meteorSky.tally.values.reduce(0, +) }

    private func shower(_ code: String) throws -> MeteorShower { try XCTUnwrap(MeteorShowers.shower(code: code)) }

    // MARK: - The calendar

    func testSolarLongitude() throws {
        XCTAssertEqual(SolarLongitude.degrees(at: try date("2026-12-14T14:00:00Z")), 262.2, accuracy: 0.1)    // 262.210
        XCTAssertEqual(SolarLongitude.degrees(at: try date("2026-08-13T03:00:00Z")), 140.05, accuracy: 0.1)   // 140.036
        XCTAssertEqual(SolarLongitude.degrees(at: try date("2026-01-03T21:00:00Z")), 283.15, accuracy: 0.1)   // 283.137
        // In range all year, wrapping at the March equinox, and about a degree a day.
        let start = try date("2026-01-01T00:00:00Z")
        var previous = SolarLongitude.degrees(at: start), wraps = 0
        for day in 1...365 {
            let l = SolarLongitude.degrees(at: start.addingTimeInterval(Double(day) * 86_400))
            XCTAssertTrue(l >= 0 && l < 360, "\(l)")
            var step = l - previous
            if step < 0 { step += 360; wraps += 1 }
            XCTAssertTrue(step > 0.95 && step < 1.02, "day \(day): \(step)°")
            previous = l
        }
        XCTAssertEqual(wraps, 1, "once a year, at the March equinox")
    }

    func testShowerCurvesPeakAndFall() throws {
        XCTAssertEqual(MeteorShowers.all.map(\.code),
                       ["QUA", "ACE", "LYR", "ETA", "SDA", "PER", "DRA", "ORI", "STA", "NTA", "LEO", "PUV", "GEM", "URS"])
        let gem = try shower("GEM")
        XCTAssertEqual(gem.zhr(at: 262.2), 150, accuracy: 1.5, "150 ± 1% at the peak")
        let top = gem.components(at: 262.2).peak
        XCTAssertEqual(gem.components(at: 262.2 - 1 / 0.59).peak / top, 0.1, accuracy: 1e-9, "the rising side, B 0.59")
        XCTAssertEqual(gem.components(at: 262.2 + 1 / 0.81).peak / top, 0.1, accuracy: 1e-9, "and the steeper fall, B 0.81")
        XCTAssertGreaterThan(gem.zhr(at: 262.2 - 1 / 0.59), 0.1 * 150, "the broad base is still there")
        // The Perseids: 100 at the peak, the base (23 in Jenniskens' curve) rescaled along with the peak.
        let per = try shower("PER")
        XCTAssertEqual(per.zhr(at: 140), 100, accuracy: 1e-9)
        let parts = per.components(at: 140)
        XCTAssertEqual(parts.base / parts.peak, 23.0 / 100, accuracy: 1e-9)
        XCTAssertEqual(parts.peak, 100 * 100 / 123, accuracy: 1e-9)
        // Every shower: its IMO ZHR at its peak, and its peak component halved log10(2)/B either side (inside the window).
        for s in MeteorShowers.all {
            let imo: Double = s.zhr
            XCTAssertEqual(s.zhr(at: s.peak), imo, accuracy: 1e-9 * imo, s.code)
            let peak = s.components(at: s.peak).peak
            for (side, slope) in [(-1.0, s.peakSlope.bp), (1.0, s.peakSlope.bm)] {
                let at = s.peak + side * log10(2) / slope
                guard s.isActive(at: at) else { continue }
                XCTAssertEqual(s.components(at: at).peak / peak, 0.5, accuracy: 1e-9, "\(s.code) \(side)")
            }
            XCTAssertEqual(s.daysToPeak(from: s.peak), 0, accuracy: 1e-12, s.code)
            XCTAssertEqual(s.radiant(at: s.peak).alpha, s.alpha, accuracy: 1e-9, s.code)
        }
        // The radiant drifts linearly from its peak place: the Perseids' 1.35° a day in right ascension.
        let later = per.radiant(at: 140 + 5 * SolarLongitude.degreesPerDay)
        XCTAssertEqual(later.alpha, 48 + 5 * 1.35, accuracy: 1e-9)
        XCTAssertEqual(later.delta, 58 + 5 * 0.12, accuracy: 1e-9)
        XCTAssertEqual(per.daysToPeak(from: 130), 10 / SolarLongitude.degreesPerDay, accuracy: 1e-9)
        XCTAssertLessThan(per.daysToPeak(from: 141), 0, "negative after the peak")
    }

    func testOnlyInsideTheActivityWindow() throws {
        let gem = try shower("GEM")
        XCTAssertEqual(gem.zhr(at: SolarLongitude.degrees(at: try date("2026-11-30T12:00:00Z"))), 0, "before 4 December")
        XCTAssertGreaterThan(gem.zhr(at: SolarLongitude.degrees(at: try date("2026-12-10T12:00:00Z"))), 0)
        XCTAssertEqual(gem.zhr(at: SolarLongitude.degrees(at: try date("2026-12-21T12:00:00Z"))), 0, "after 20 December")
        for s in MeteorShowers.all {
            XCTAssertTrue(s.isActive(at: s.peak), s.code)
            XCTAssertEqual(s.zhr(at: s.activeFrom - 0.01), 0, s.code)
            XCTAssertEqual(s.zhr(at: s.activeTo + 0.01), 0, s.code)
            XCTAssertGreaterThan(s.zhr(at: s.activeFrom + 0.01), 0, s.code)
        }
        // A window may wrap through 360°.
        let wrapping = MeteorShower(code: "X", name: "X", activeFrom: 350, activeTo: 10, peak: 0, alpha: 0, delta: 0,
                                    driftAlpha: 0, driftDelta: 0, speed: 40, r: 2.5, zhr: 10, peakSlope: (0.1, 0.1))
        XCTAssertTrue(wrapping.isActive(at: 355) && wrapping.isActive(at: 5) && !wrapping.isActive(at: 20))
        XCTAssertEqual(wrapping.zhr(at: 0), 10, accuracy: 1e-9)
        // Late January, between every window: only sporadic meteors fall.
        let lull = SolarLongitude.degrees(at: try date("2027-01-20T12:00:00Z"))
        XCTAssertTrue(MeteorShowers.all.allSatisfy { $0.zhr(at: lull) == 0 })
        // Any year: the Geminids peak on their solar longitude in 2030 too.
        XCTAssertGreaterThan(gem.zhr(at: SolarLongitude.degrees(at: try date("2030-12-14T12:00:00Z"))), 100)
    }

    // MARK: - Where you are

    /// Melbourne (−37.8°) never sees the Perseids' radiant (+58°): it culminates 5.8° below the horizon.
    func testPerseidsNeverRiseInMelbourne() throws {
        let sky = realSky("melbourne", rate: 10)
        let start = try date("2026-08-12T07:00:00Z")   // 17:00 on the 12th in Melbourne … 07:00 on the 13th
        var highest = -90.0, codes = Set<String>(), rises: [Double?] = [], culmination = 90.0
        _ = sky.step(now: start, dt: 0)
        for i in 1...(14 * 180) {
            let st = sky.step(now: start.addingTimeInterval(Double(i) * 20), dt: 1)
            guard let shower = st.shower else { codes.insert("none"); continue }
            codes.insert(shower.code)
            highest = max(highest, shower.radiantAltitude)
            culmination = min(culmination, shower.radiantHighest)
            if i % 180 == 0 { rises.append(shower.radiantRises) }
        }
        XCTAssertEqual(codes, ["PER"], "the Perseids are the strongest shower all night, though they never rise")
        XCTAssertLessThan(highest, 0)            // −5.78
        XCTAssertLessThan(culmination, 0)        // −5.81
        XCTAssertTrue(rises.allSatisfy { $0 == nil }, "it never clears 10°")
        let tally = sky.meteorSky.tally
        XCTAssertEqual(tally[5] ?? 0, 0, "no Perseids at all")
        XCTAssertGreaterThan(tally[-1] ?? 0, 0, "but sporadic meteors")   // mirror: 17 (P(none) ≈ 4e-8)
    }

    /// The Geminids' radiant stands 70° up over Tokyo at its best, 19° over Melbourne.
    func testGeminidsHigherFromTokyo() throws {
        let gem = try shower("GEM")
        let start = try date("2026-12-14T02:00:00Z")   // the peak (14:00 UT) ± 12 hours
        func best(_ city: String) -> Double {
            let sky = realSky(city)
            var top = 0.0
            for i in 0...(24 * 6) {
                var st = sky.step(now: start.addingTimeInterval(Double(i) * 600), dt: 0)
                st.moonLit = 0   // the geometry and the dark alone (the five-day moon has set by the best hours anyway)
                top = max(top, gem.visibleRate(at: st.solarLongitude, sky: st))
            }
            return top
        }
        let tokyo = best("tokyo"), melbourne = best("melbourne")   // mirror: 122.2 and 39.8 an hour
        XCTAssertGreaterThan(tokyo, 2 * melbourne)
        XCTAssertGreaterThan(melbourne, 0, "they do rise from Melbourne, low in the north")
    }

    /// Review focus 2: the calendar runs on UT solar longitude; the local date is only for show.
    func testTheCalendarRunsOnUniversalTime() throws {
        let instant = try date("2026-12-14T09:30:00Z")
        let apia = realSky("apia").step(now: instant, dt: 0)            // 22:30 on the 14th
        let avarua = realSky("rarotonga").step(now: instant, dt: 0)     // 23:30 on the 13th
        XCTAssertEqual(apia.dayOfYear, avarua.dayOfYear + 1, "a day apart across the date line")
        XCTAssertEqual(apia.solarLongitude, avarua.solarLongitude, "one calendar")
        XCTAssertEqual(apia.shower?.code, "GEM")
        XCTAssertEqual(apia.shower?.daysToPeak ?? 0, avarua.shower?.daysToPeak ?? 1, accuracy: 1e-12)
        XCTAssertEqual(apia.shower?.zhr ?? 0, avarua.shower?.zhr ?? 1, accuracy: 1e-12)
    }

    // MARK: - When

    func testNoMeteorsByDay() throws {
        let start = try date("2026-12-14T00:00:00Z")   // the Geminids' day in Tokyo
        let noon = frozenSky("tokyo", hour: 13, rate: 10)
        var highestRate: Float = 0, lowestSun = 90.0, any = false
        for i in 0..<3600 {
            let st = noon.step(now: start.addingTimeInterval(Double(i)), dt: 1, meteors: .always)
            highestRate = max(highestRate, st.meteorRate)
            lowestSun = min(lowestSun, st.sun.altitude)
            any = any || !st.meteors.isEmpty
        }
        XCTAssertGreaterThan(lowestSun, -6)
        XCTAssertEqual(spawned(noon), 0, "not even a steady shower at rate 10")
        XCTAssertEqual(highestRate, 0)
        XCTAssertFalse(any)
        // The day's shower is still named (the panel can say what tonight brings).
        XCTAssertEqual(frozenSky("tokyo", hour: 13).step(now: start, dt: 0).shower?.code, "GEM")
        // A held golden hour (the sun 5° up) has none; a held deep night does.
        let golden = frozenSky("tokyo", hour: 23, rate: 10)
        for i in 0..<600 { _ = golden.step(now: start.addingTimeInterval(Double(i)), dt: 1, hold: .goldenHour) }
        XCTAssertEqual(spawned(golden), 0)
        XCTAssertGreaterThan(frozenSky("tokyo", hour: 13).step(now: start, dt: 0, hold: .deepNight).meteorRate, 0)
    }

    /// × 5 on the Advanced "Meteors" setting: 5× the spawns over 2 simulated hours (the same seed, so the runs share
    /// their arrivals: the bound is 4.2σ).
    func testRateScalesWithTheSetting() throws {
        let now = try date("2026-12-14T03:00:00Z")
        let tokyo = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let living = frozenSky("tokyo", hour: 21)
        let st = living.step(now: now, dt: 0)
        let calendar = SkyClock.calendar(day: LivingSky.localDay(now, zone: tokyo), hour: 21, zone: tokyo)
        XCTAssertEqual(SolarLongitude.degrees(at: calendar), st.solarLongitude, accuracy: 1e-9)
        func spawns(_ rate: Double) -> Int {
            var machine = MeteorSky(seed: 11)
            for _ in 0..<720 { _ = machine.step(dt: 10, date: calendar, sky: st, mode: .follow, rate: rate) }
            return machine.tally.values.reduce(0, +)
        }
        let low = spawns(2), high = spawns(10)   // mirror: 359 and 1843 (× 5.13)
        XCTAssertEqual(Double(high) / Double(low), 5, accuracy: 1, "5× ± 20%")
        // The expected rate scales exactly, and the setting is held to 0.5…10.
        var tuned = living.settings; tuned.meteorRate = 10; living.settings = tuned
        let ten = living.step(now: now, dt: 0)
        XCTAssertEqual(ten.meteorRate / st.meteorRate, 5, accuracy: 1e-4)
        tuned.meteorRate = 50; living.settings = tuned
        XCTAssertEqual(living.step(now: now, dt: 0).meteorRate, ten.meteorRate, accuracy: 1e-3, "at most 10")
        tuned.meteorRate = 0; living.settings = tuned
        XCTAssertEqual(living.step(now: now, dt: 0).meteorRate / st.meteorRate, 0.25, accuracy: 1e-4, "at least 0.5")
    }

    func testAlwaysAndNeverModes() throws {
        let lull = try date("2027-01-20T03:00:00Z")   // between every shower in the calendar
        let always = frozenSky("tokyo", hour: 21, rate: 10)
        var st = always.step(now: lull, dt: 0, meteors: .always)
        let steady = try XCTUnwrap(st.shower)
        XCTAssertEqual(steady.code, "ALW")
        XCTAssertEqual(steady.zhr, 60, accuracy: 1e-9)
        XCTAssertEqual(steady.radiantAltitude, 80, accuracy: 1e-6, "nearly overhead")
        XCTAssertEqual(steady.radiantAzimuth, 0, accuracy: 1e-6, "pole-ward, behind the equator-facing view")
        XCTAssertNil(steady.radiantRises)
        XCTAssertEqual(steady.daysToPeak, 0)
        for i in 1...300 { st = always.step(now: lull.addingTimeInterval(Double(i)), dt: 1, meteors: .always) }
        XCTAssertGreaterThan(always.meteorSky.tally[MeteorShowers.alwaysIndex] ?? 0, 0)   // mirror: 31 in 5 minutes
        // Follow on the same night: no shower, only the sporadic meteors.
        let follow = frozenSky("tokyo", hour: 21, rate: 10).step(now: lull, dt: 0)
        XCTAssertNil(follow.shower)
        XCTAssertGreaterThan(follow.meteorRate, 0)
        XCTAssertGreaterThan(st.meteorRate, 10 * follow.meteorRate)   // 601 against 39.7 an hour
        // Never: no meteors at all, sporadic ones included, and nothing left over from before.
        let never = frozenSky("tokyo", hour: 21, rate: 10)
        for i in 0...60 { _ = never.step(now: lull.addingTimeInterval(Double(i)), dt: 1, meteors: .always) }
        let before = spawned(never)
        for i in 61...360 { st = never.step(now: lull.addingTimeInterval(Double(i)), dt: 1, meteors: .never) }
        XCTAssertTrue(st.meteors.isEmpty)
        XCTAssertNil(st.shower)
        XCTAssertEqual(st.meteorRate, 0)
        XCTAssertEqual(st.meteorFlash, 0)
        XCTAssertEqual(spawned(never), before, "none spawned while Never")
        // In the south the steady radiant leans south.
        XCTAssertEqual(frozenSky("melbourne", hour: 23).step(now: lull, dt: 0, meteors: .always).shower?.radiantAzimuth ?? 0,
                       180, accuracy: 1e-6)
        // The world parameter.
        let spec = MeteorMode.spec(default: .follow)
        XCTAssertEqual([spec.id, spec.name, spec.group], ["meteors.mode", "Meteors", "Sky"])
        XCTAssertEqual(spec.kind, .choice(["Follow the calendar", "Always a shower", "Never"]))
        XCTAssertEqual(spec.defaultValue, .choice("Follow the calendar"))
        XCTAssertEqual(MeteorMode.spec(default: .never).defaultValue, .choice("Never"))
    }

    func testSporadicsPeakBeforeDawn() throws {
        let winter = try date("2027-01-20T12:00:00Z")   // no shower in the calendar
        func rate(_ hour: Double) -> Float {
            frozenSky("milan", hour: hour).step(now: winter, dt: 0, hold: .deepNight).meteorRate   // the dark held alike
        }
        XCTAssertNil(frozenSky("milan", hour: 6).step(now: winter, dt: 0, hold: .deepNight).shower)
        let dawn = rate(6), dusk = rate(18)   // mirror: 21.21 and 5.39 an hour (solar 05:29 and 17:29)
        XCTAssertEqual(Double(dawn / dusk), 4, accuracy: 1)
    }

    // MARK: - The meteors themselves

    func testMeteorsRunAwayFromTheirRadiant() throws {
        let sky = frozenSky("tokyo", hour: 21, rate: 10)
        let start = try date("2026-12-14T03:00:00Z")
        var seen = Set<Double>(), worst: Float = 0, inward = 0, low = 0, fromGeminids = 0
        _ = sky.step(now: start, dt: 0)
        let gem = try XCTUnwrap(sky.step(now: start, dt: 0).shower)
        let gemRadiant = SkyLayerFrame.enu(azimuth: gem.radiantAzimuth, altitude: gem.radiantAltitude)
        for i in 1...900 {
            let st = sky.step(now: start.addingTimeInterval(Double(i)), dt: 1, meteors: i < 450 ? .follow : .always)
            for m in st.meteors where !seen.contains(m.born) {
                seen.insert(m.born)
                let n = simd_normalize(simd_cross(m.radiant, m.start))
                worst = max(worst, abs(simd_dot(n, m.end)))
                if simd_dot(m.radiant, m.end) >= simd_dot(m.radiant, m.start) { inward += 1 }
                if m.start.z < sin(5 * Float.pi / 180) - 1e-5 { low += 1 }
                if m.shower == 12 {
                    fromGeminids += 1
                    XCTAssertLessThan(simd_distance(m.radiant, gemRadiant), 1e-4, "a Geminid comes from the Geminids' radiant")
                }
                XCTAssertTrue(m.duration >= 0.08 && m.duration <= 2.5, "\(m.duration)")
                XCTAssertEqual(simd_length(m.start), 1, accuracy: 1e-5)
                XCTAssertEqual(simd_length(m.end), 1, accuracy: 1e-5)
            }
        }
        XCTAssertGreaterThan(seen.count, 50)   // mirror: 164
        XCTAssertGreaterThan(fromGeminids, 20)
        XCTAssertLessThan(worst, sin(0.5 * Float.pi / 180), "start, end and radiant on one great circle within 0.5°")
        XCTAssertEqual(inward, 0, "every end is farther from its radiant than its start")
        XCTAssertEqual(low, 0, "none starts below 5°")
    }

    func testMagnitudesFollowThePopulationIndex() {
        var rng = SeededRandom(seed: 0x4D_4147)
        var brighter = 0, lowest = 99.0, highest = -99.0
        for _ in 0..<20_000 {
            let m = MeteorSky.magnitude(populationIndex: 2.6, unit: MeteorSky.unit(&rng))
            if m < 0 { brighter += 1 }
            lowest = min(lowest, m); highest = max(highest, m)
        }
        let expected = (1 - pow(2.6, -8)) / (pow(2.6, 5.5) - pow(2.6, -8))   // r^−5.5, normalised over +5.5…−8
        XCTAssertEqual(Double(brighter) / 20_000, expected, accuracy: 0.5 * expected)   // mirror: 105 against 104.3
        XCTAssertTrue(lowest >= -8 && highest <= 5.5)
        XCTAssertEqual(MeteorSky.magnitude(populationIndex: 2.6, unit: 0), -8, accuracy: 1e-9)
        XCTAssertEqual(MeteorSky.magnitude(populationIndex: 2.6, unit: 1), 5.5, accuracy: 1e-9)
        XCTAssertLessThan(MeteorSky.magnitude(populationIndex: 2.0, unit: 0.01), MeteorSky.magnitude(populationIndex: 3.0, unit: 0.01),
                          "a lower population index is richer in bright meteors")
    }

    /// The head's light curve, brightness scale, terminal flares, trains and colours (what Task 6 draws from).
    func testMeteorLightCurveAndTrain() {
        let m = Meteor(start: SIMD3(0, 1, 0), end: SIMD3(0, 0, 1), born: 10, duration: 1, magnitude: Meteor.siriusMagnitude)
        XCTAssertEqual(m.progress(at: 9), 0); XCTAssertEqual(m.progress(at: 10.5), 0.5, accuracy: 1e-6)
        XCTAssertEqual(m.progress(at: 12), 1)
        XCTAssertEqual(m.peakBrightness, 1, accuracy: 1e-6, "Sirius's brightness is 1")
        XCTAssertEqual(m.headBrightness(at: 10.5), 1, accuracy: 1e-5, "sin(π/2)^0.7 at the middle")
        XCTAssertEqual(m.headBrightness(at: 10.25), pow(sin(Float.pi / 4), 0.7), accuracy: 1e-5)
        XCTAssertEqual(m.headBrightness(at: 9.99), 0)
        XCTAssertEqual(m.headBrightness(at: 11), 0, "the run is over")
        for k in 0...100 { XCTAssertTrue(m.headBrightness(at: 10 + Double(k) / 100).isFinite, "never NaN: the base is never negative") }
        var bright = m; bright.magnitude = Meteor.siriusMagnitude - 2.5
        XCTAssertEqual(bright.peakBrightness, 10, accuracy: 1e-4, "2.5 magnitudes is ×10")
        var flaring = m; flaring.flare = true
        XCTAssertEqual(flaring.headBrightness(at: 10.9) / m.headBrightness(at: 10.9), 3.5, accuracy: 1e-4, "a terminal flare")
        XCTAssertEqual(flaring.headBrightness(at: 10.5), m.headBrightness(at: 10.5), "only near the end")
        XCTAssertNil(m.trainAge(at: 11.5)); XCTAssertEqual(m.trainBrightness(at: 11.5), 0); XCTAssertEqual(m.ends, 11)
        var trained = m; trained.train = 1
        XCTAssertEqual(trained.trainSeconds, 8); XCTAssertEqual(trained.trainShare, 0.1, accuracy: 1e-6)
        XCTAssertEqual(trained.trainDrift, 1, accuracy: 1e-6); XCTAssertEqual(trained.ends, 19)
        XCTAssertNil(trained.trainAge(at: 10.5), "no train while the head runs")
        XCTAssertEqual(trained.trainAge(at: 15) ?? -1, 0.5, accuracy: 1e-6)
        XCTAssertEqual(trained.trainBrightness(at: 11), 0.1, accuracy: 1e-6)
        XCTAssertEqual(trained.trainBrightness(at: 15), 0.1 * 0.25, accuracy: 1e-6)
        XCTAssertEqual(trained.trainWidening(at: 19), 3, accuracy: 1e-6)
        // Colour by speed, white when faint.
        func near(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Bool { simd_distance(a, b) < 1e-5 }
        XCTAssertTrue(near(MeteorSky.colour(speed: 20, magnitude: -2), SIMD3(1.0, 0.8, 0.55)), "slow: warm")
        XCTAssertTrue(near(MeteorSky.colour(speed: 45, magnitude: -2), SIMD3(1.0, 0.97, 0.9)), "medium: white")
        XCTAssertTrue(near(MeteorSky.colour(speed: 66, magnitude: -2), SIMD3(0.75, 1.0, 0.9)), "fast and bright: blue-green")
        XCTAssertTrue(near(MeteorSky.colour(speed: 66, magnitude: 4), SIMD3(1.0, 0.97, 0.9)), "faint: white")
    }

    // MARK: - Review focus 2 and 3

    func testNoMeteorsInTheMidnightSun() throws {
        let midnight = try date("2026-06-20T22:00:00Z")   // midnight in Tromsø, 21 June
        for mode in [MeteorMode.follow, .always] {
            let sky = realSky("tromso", rate: 10)
            var lowest = 90.0, any = false
            for i in 0...(24 * 60) {
                let st = sky.step(now: midnight.addingTimeInterval(Double(i) * 60), dt: 1, meteors: mode)
                lowest = min(lowest, st.sun.altitude)
                any = any || !st.meteors.isEmpty || st.meteorRate > 0
            }
            XCTAssertGreaterThan(lowest, 0, "the sun never sets")   // 3.3°
            XCTAssertFalse(any, "\(mode)")
            XCTAssertEqual(spawned(sky), 0, "\(mode)")
        }
    }

    func testCircumpolarRadiantAlwaysUp() throws {
        let ursids = try shower("URS")
        let sky = realSky("oslo")
        let start = try date("2026-12-22T14:00:00Z")   // 15:00 in Oslo, the Ursids' peak night
        var lowest = 90.0, codes = Set<String>(), rises: [Double?] = [], darkSteps = 0, faintest = Double.infinity
        for i in 0...(20 * 120) {
            let st = sky.step(now: start.addingTimeInterval(Double(i) * 30), dt: 1)
            guard let shower = st.shower else { codes.insert("none"); continue }
            codes.insert(shower.code)
            lowest = min(lowest, shower.radiantAltitude)
            if i % 120 == 0 { rises.append(shower.radiantRises) }
            if st.sun.altitude <= -6 {
                darkSteps += 1
                faintest = min(faintest, ursids.visibleRate(at: st.solarLongitude, sky: st))
            }
        }
        XCTAssertEqual(codes, ["URS"])
        XCTAssertGreaterThan(lowest, 40, "above 40° all night")   // 45.96°
        XCTAssertTrue(rises.allSatisfy { $0 == nil }, "it never sinks below 10°, so it never rises through it")
        XCTAssertGreaterThan(darkSteps, 1000, "a long winter night")
        XCTAssertGreaterThan(faintest, 0, "so its meteors can come all night, from dusk to dawn")
    }

    func testFrozenPeakNightKeepsShowering() throws {
        let sky = frozenSky("tokyo", hour: 21, rate: 10)
        let start = try date("2026-12-14T03:00:00Z")
        var st = sky.step(now: start, dt: 0)
        var perMinute: [Int] = [], last = 0
        for minute in 0..<30 {
            for s in 1...60 { st = sky.step(now: start.addingTimeInterval(Double(minute * 60 + s)), dt: 1) }
            let total = spawned(sky)
            perMinute.append(total - last)
            last = total
        }
        XCTAssertEqual(st.shower?.code, "GEM")
        XCTAssertTrue(perMinute.allSatisfy { $0 >= 1 }, "\(perMinute)")   // mirror: 9…24 a minute, mean 16.2
        XCTAssertEqual(st.solarLongitude, SolarLongitude.degrees(at: try date("2026-12-14T12:00:00Z")), accuracy: 1e-9,
                       "frozen at 21:00 on today's date in Tokyo")
    }

    func testQuickModeWalksTheCalendar() throws {
        var q = SkySettings(); q.timeMode = .quick; q.dayMinutes = 2; q.cityID = "melbourne"
        let sky = LivingSky(settings: q)
        let noon = try date("2026-10-05T01:00:00Z")   // noon in Melbourne, where the Sun moves about its mean pace
        let first = sky.step(now: noon, dt: 0)
        var last = first
        for i in 1...360 { last = sky.step(now: noon.addingTimeInterval(Double(i)), dt: 1) }   // three quick days
        XCTAssertEqual(last.dayOfYear - first.dayOfYear, 3)
        XCTAssertEqual((last.solarLongitude - first.solarLongitude) / 3, 0.986, accuracy: 0.01)   // 0.98597
    }

    /// Review focus 5: "Always a shower" at rate 10 with every magnitude forced to −8 for 60 s.
    func testFireballsStayInsideTheFlashLimiter() throws {
        let start = try date("2026-12-14T03:00:00Z")
        let dt = 1.0 / 60
        func flashes(force: Double, step: Double) -> (flash: [Float], spawned: Int) {
            let sky = frozenSky("tokyo", hour: 21, rate: 10)
            sky.meteorSky.forceMagnitude = force
            var out: [Float] = []
            _ = sky.step(now: start, dt: 0, meteors: .always)
            for i in 1...Int((60 / step).rounded()) {
                out.append(sky.step(now: start.addingTimeInterval(Double(i) * step), dt: step, meteors: .always).meteorFlash)
            }
            return (out, spawned(sky))
        }
        let run = flashes(force: -8, step: dt)   // mirror: 8 fireballs, the flash reaching its 8% cap
        XCTAssertGreaterThan(run.spawned, 0)
        XCTAssertGreaterThan(run.flash.max() ?? 0, 0.04, "the forced fireballs do brighten the sky")
        XCTAssertLessThanOrEqual(run.flash.max() ?? 1, MeteorSky.maxFlash)
        XCTAssertGreaterThanOrEqual(run.flash.min() ?? -1, 0)
        // FlashLimiter's rules on the exposure the flash causes (1 + meteorFlash), checked independently.
        let window = Int((FlashLimiter.window / dt).rounded())
        var flashTimes: [Double] = [], tooMany = false, tooSteep = false, biggestJump: Float = 0
        for i in run.flash.indices {
            let t = Double(i) * dt
            let lowest = run.flash[max(0, i - window)...i].min() ?? 0
            let rise = run.flash[i] - lowest
            biggestJump = max(biggestJump, rise)
            if rise > FlashLimiter.flashRise, flashTimes.last.map({ t - $0 > FlashLimiter.window }) ?? true { flashTimes.append(t) }
            let recent = flashTimes.filter { t - $0 < 1 }.count
            if recent > FlashLimiter.maxFlashesPerSecond { tooMany = true }
            if recent >= FlashLimiter.maxFlashesPerSecond, i > 0,
               run.flash[i] - run.flash[i - 1] > FlashLimiter.limitedRiseRate * Float(dt) + 1e-6 { tooSteep = true }
        }
        XCTAssertFalse(tooMany, "at most \(FlashLimiter.maxFlashesPerSecond) large jumps a second")
        XCTAssertFalse(tooSteep, "and only the limited rise once there have been that many")
        XCTAssertLessThan(biggestJump, FlashLimiter.flashRise, "no large jump at all within any 0.1 s")   // 0.031
        // Only fireballs (−4 or brighter) flash: the same arrivals forced to −3.9 never do.
        let dim = flashes(force: -3.9, step: 0.1)
        XCTAssertEqual(dim.spawned, run.spawned, "the same seed: the same meteors, only dimmer")
        XCTAssertEqual(dim.flash.max() ?? 1, 0)
    }

    /// The arrivals are the same whatever the step (the exponential gaps are solved within each step), so tests may step
    /// at a second or more and the app at 1/60 s.
    func testStepSizeDoesNotChangeTheShower() throws {
        let now = try date("2026-12-14T03:00:00Z")
        let st = frozenSky("tokyo", hour: 21).step(now: now, dt: 0)
        let calendar = try date("2026-12-14T12:00:00Z")
        func run(_ dt: Double) -> (tally: [Int8: Int], births: [Double]) {
            var machine = MeteorSky(seed: 7)
            var births: [Double] = []
            for _ in 0..<Int((120 / dt).rounded()) {
                let m = machine.step(dt: dt, date: calendar, sky: st, mode: .follow, rate: 10)
                for meteor in m.meteors where !births.contains(meteor.born) { births.append(meteor.born) }
            }
            return (machine.tally, births)
        }
        let fine = run(1.0 / 60), second = run(1), ten = run(10)
        XCTAssertGreaterThan(fine.tally.values.reduce(0, +), 10)
        XCTAssertEqual(fine.tally, second.tally)
        XCTAssertEqual(fine.tally, ten.tally)
        XCTAssertFalse(second.births.isEmpty)
        let shared = second.births.filter { b in fine.births.contains { abs($0 - b) < 1e-6 } }
        XCTAssertEqual(shared.count, second.births.count, "every meteor a 1 s step shows was born at the same instant at 1/60 s")
    }
}

/// The horizon frame's unit vector for an azimuth and altitude (degrees), as `SkyLayer.enu` makes it.
private enum SkyLayerFrame {
    static func enu(azimuth: Double, altitude: Double) -> SIMD3<Float> {
        let az = azimuth * .pi / 180, alt = altitude * .pi / 180
        return SIMD3<Float>(Float(sin(az) * cos(alt)), Float(cos(az) * cos(alt)), Float(sin(alt)))
    }
}
