import XCTest
@testable import InStrumCore

final class LivingSkyTests: XCTestCase {
    let melbourneZone = TimeZone(identifier: "Australia/Melbourne")!
    let start = Date(timeIntervalSince1970: 1_793_000_000)   // 2026-10-26

    private func luminance(_ c: SIMD3<Float>) -> Float { 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z }

    func testQuickCycleLengthAndMoon() {
        var s = SkySettings(); s.timeMode = .quick; s.dayMinutes = 12; s.cityID = "melbourne"
        let sky = LivingSky(settings: s, homeZone: melbourneZone)
        var now = start
        var state = sky.step(now: now, dt: 0)
        let phase0 = state.moonPhase
        var crossings = 0, prevAlt = state.sun.altitude
        for _ in 0..<720 {   // 12 simulated minutes in 1 s steps
            now = now.addingTimeInterval(1)
            state = sky.step(now: now, dt: 1)
            if (prevAlt < 0) != (state.sun.altitude < 0) { crossings += 1 }
            prevAlt = state.sun.altitude
        }
        XCTAssertEqual(crossings, 2, "one sunrise and one sunset per quick day")
        var advance = state.moonPhase - phase0
        if advance < 0 { advance += 1 }
        XCTAssertEqual(advance, 0.125, accuracy: 0.01)
    }

    func testNightIsDarkDayIsBright() throws {
        var s = SkySettings(); s.timeMode = .frozen; s.cityID = "melbourne"; s.weatherMode = .pick; s.weather = .clear
        s.frozenHour = 2
        let night = LivingSky(settings: s, homeZone: melbourneZone).step(now: start, dt: 0)
        s.frozenHour = 13
        let day = LivingSky(settings: s, homeZone: melbourneZone).step(now: start, dt: 0)
        XCTAssertLessThan(luminance(night.zenith), 0.05, "night \(night.zenith)")
        XCTAssertGreaterThan(luminance(day.zenith), 0.4, "day \(day.zenith)")
        XCTAssertGreaterThan(night.starVisibility, 0.5)
        XCTAssertLessThan(day.starVisibility, 0.05)
        // Golden hour: find the frozen hour where the sun sits near 3°.
        var golden: SkyState?
        for minutes in stride(from: 5 * 60, to: 9 * 60, by: 2) {
            s.frozenHour = Double(minutes) / 60
            let st = LivingSky(settings: s, homeZone: melbourneZone).step(now: start, dt: 0)
            if abs(st.sun.altitude - 3) < 0.6 { golden = st; break }
        }
        let g = try XCTUnwrap(golden)
        XCTAssertGreaterThan(g.horizon.x, g.horizon.z * 1.4, "warm horizon \(g.horizon)")
    }

    /// Golden hour holds the sun 5° up whatever the clock says: the light (and the warm horizon) stay put.
    func testGoldenHourHoldsWhateverTheClock() {
        var s = SkySettings(); s.timeMode = .frozen; s.cityID = "melbourne"; s.weatherMode = .pick; s.weather = .clear
        for hour in [2.0, 13.0] {
            s.frozenHour = hour
            let st = LivingSky(settings: s, homeZone: melbourneZone).step(now: start, dt: 0, hold: .goldenHour)
            XCTAssertEqual(st.sun.altitude, 5, accuracy: 1e-9, "at \(hour):00")
            XCTAssertGreaterThan(st.horizon.x, st.horizon.z * 1.4, "warm horizon at \(hour):00")
        }
    }

    func testBlueHourHolds() {
        var s = SkySettings(); s.timeMode = .frozen; s.cityID = "melbourne"; s.weatherMode = .pick; s.weather = .clear
        s.frozenHour = 13
        let blue = LivingSky(settings: s, homeZone: melbourneZone).step(now: start, dt: 0, hold: .blueHour)
        let day = LivingSky(settings: s, homeZone: melbourneZone).step(now: start, dt: 0)
        s.frozenHour = 2
        let night = LivingSky(settings: s, homeZone: melbourneZone).step(now: start, dt: 0)
        XCTAssertEqual(blue.sun.altitude, -6, accuracy: 1e-9)
        XCTAssertGreaterThan(luminance(blue.zenith), luminance(night.zenith))
        XCTAssertLessThan(luminance(blue.zenith), luminance(day.zenith))
    }

    func testFollowIsThePlainSky() {
        var s = SkySettings(); s.timeMode = .quick; s.cityID = "melbourne"
        let a = LivingSky(settings: s, seed: 4, homeZone: melbourneZone), b = LivingSky(settings: s, seed: 4, homeZone: melbourneZone)
        var now = start
        for _ in 0..<30 {
            now = now.addingTimeInterval(2)
            XCTAssertEqual(a.step(now: now, dt: 2, hold: .follow), b.step(now: now, dt: 2))
        }
    }

    func testCloudsGreyTheSky() {
        var s = SkySettings(); s.timeMode = .frozen; s.cityID = "melbourne"; s.frozenHour = 13; s.weatherMode = .pick
        s.weather = .clear
        let clear = LivingSky(settings: s, homeZone: melbourneZone).step(now: start, dt: 0)
        s.weather = .overcast
        let grey = LivingSky(settings: s, homeZone: melbourneZone).step(now: start, dt: 0)
        let sat = { (c: SIMD3<Float>) in (max(c.x, max(c.y, c.z)) - min(c.x, min(c.y, c.z))) / max(c.x, max(c.y, c.z)) }
        XCTAssertLessThan(sat(grey.zenith), sat(clear.zenith))
        XCTAssertEqual(grey.cloudCover, 0.85, accuracy: 1e-4)
        XCTAssertLessThan(grey.starVisibility, clear.starVisibility + 1e-6)
    }

    func testWeatherTransitionsAreSmooth() {
        var s = SkySettings(); s.timeMode = .frozen; s.weatherMode = .pick; s.weather = .clear
        let sky = LivingSky(settings: s, homeZone: melbourneZone)
        var now = start
        var prev = sky.step(now: now, dt: 0).rain
        XCTAssertEqual(prev, 0)
        s.weather = .rain
        sky.settings = s
        var maxStep: Float = 0, monotonic = true
        for _ in 0..<70 {
            now = now.addingTimeInterval(1)
            let r = sky.step(now: now, dt: 1).rain
            maxStep = max(maxStep, r - prev)
            if r < prev - 1e-6 { monotonic = false }
            prev = r
        }
        XCTAssertTrue(monotonic)
        XCTAssertLessThanOrEqual(maxStep, 0.05)
        XCTAssertEqual(prev, 0.75, accuracy: 1e-3)
        XCTAssertEqual(sky.step(now: now, dt: 0).weather, .rain)
    }

    /// Kind changes as (time, kind): each new kind starts its 60 s transition at `time`.
    private func weatherRun(seed: UInt64, hours: Double) -> [(Double, WeatherKind)] {
        var s = SkySettings(); s.timeMode = .frozen; s.weatherMode = .randomBeautiful
        let sky = LivingSky(settings: s, seed: seed, homeZone: melbourneZone)
        var now = start, t = 0.0, last: WeatherKind?
        var out: [(Double, WeatherKind)] = []
        while t < hours * 3600 {
            let st = sky.step(now: now, dt: 1)
            let target = st.nextWeather
            if target != last { out.append((t, target)); last = target }
            t += 1; now = now.addingTimeInterval(1)
        }
        return out
    }

    func testRandomBeautifulIsDeterministicAndVaried() {
        let a = weatherRun(seed: 7, hours: 6), b = weatherRun(seed: 7, hours: 6)
        XCTAssertEqual(a.map(\.1), b.map(\.1))
        XCTAssertEqual(a.map(\.0), b.map(\.0))
        XCTAssertGreaterThanOrEqual(a.count, 18, "6 h of 5–20 min spells")
        for i in 1..<a.count {
            XCTAssertNotEqual(a[i].1, a[i - 1].1, "no kind twice in a row")
            if i >= 2 {
                let minutes = (a[i].0 - a[i - 1].0) / 60
                XCTAssertTrue((5...20.02).contains(minutes), "spell of \(minutes) min")
            }
        }
        XCTAssertGreaterThanOrEqual(Set(a.map(\.1)).count, 4, "varied")
        XCTAssertNotEqual(weatherRun(seed: 8, hours: 2).map(\.1), weatherRun(seed: 7, hours: 2).map(\.1))
    }

    func testResetStartsSettled() {
        var raining = SkySettings(); raining.weatherMode = .pick; raining.weather = .rain
        let sky = LivingSky(settings: raining, seed: 3, homeZone: melbourneZone)
        var s = SkySettings(); s.timeMode = .frozen; s.cityID = "melbourne"; s.weatherMode = .pick; s.weather = .clear
        sky.reset(settings: s)
        let state = sky.step(now: start, dt: 1.0 / 30)
        XCTAssertEqual(state.weather, .clear)
        XCTAssertEqual(state.weatherBlend, 0)
        XCTAssertEqual(state.rain, 0)
        XCTAssertEqual(sky.settings, s)
        // Changing the settings (not resetting) still blends.
        s.weather = .rain
        sky.settings = s
        let blending = sky.step(now: start.addingTimeInterval(1), dt: 1)
        XCTAssertLessThan(blending.rain, 0.2)
    }

    func testStormsFlashLightning() {
        var s = SkySettings(); s.timeMode = .frozen; s.weatherMode = .pick; s.weather = .storm
        let sky = LivingSky(settings: s, homeZone: melbourneZone)
        var now = start, flashes = 0, wasLit = false
        for _ in 0..<(120 * 30) {   // 120 s at 30 fps
            now = now.addingTimeInterval(1.0 / 30)
            let lit = sky.step(now: now, dt: 1.0 / 30).lightning > 0.5
            if lit && !wasLit { flashes += 1 }
            wasLit = lit
        }
        XCTAssertTrue((4...22).contains(flashes), "\(flashes) flashes in 2 min")
    }

    /// Review Focus 5: clocks change, the sky doesn't jump.
    func testDaylightSavingIsInvisible() {
        var s = SkySettings(); s.timeMode = .realTime; s.cityID = "melbourne"
        let sky = LivingSky(settings: s, homeZone: melbourneZone)
        var now = Date(timeIntervalSince1970: 1_791_043_200 - 120)   // DST starts 2026-10-03T16:00Z (2:00 → 3:00 on Sunday 4 Oct); − 2 min
        var prev = sky.step(now: now, dt: 0)
        var worst = 0.0, hourJump = 0.0
        for _ in 0..<240 {
            now = now.addingTimeInterval(1)
            let st = sky.step(now: now, dt: 1)
            worst = max(worst, abs(st.sun.altitude - prev.sun.altitude))
            hourJump = max(hourJump, abs(st.hourOfDay - prev.hourOfDay))
            prev = st
        }
        XCTAssertLessThan(worst, 0.01)
        XCTAssertGreaterThan(hourJump, 0.9, "the local clock itself did change")
    }

    func testRealTimeFollowsTheCity() {
        var s = SkySettings(); s.timeMode = .realTime; s.cityID = "melbourne"
        let sky = LivingSky(settings: s, homeZone: melbourneZone)
        let noon = sky.step(now: Date(timeIntervalSince1970: 1_793_152_800), dt: 0)   // 2026-10-28T02:00Z ≈ 13:00 AEDT
        XCTAssertEqual(noon.sun.altitude, Solar.direction(at: Date(timeIntervalSince1970: 1_793_152_800), from: sky.location).altitude, accuracy: 1e-9)
        XCTAssertEqual(noon.hourOfDay, 13, accuracy: 0.01)
        XCTAssertEqual(noon.latitude, -37.8136, accuracy: 1e-6)
    }

    func testUnknownCityFallsBack() {
        var s = SkySettings(); s.cityID = "nowhere"
        XCTAssertEqual(LivingSky(settings: s, homeZone: melbourneZone).location, Cities.city(id: "melbourne")!.point)
        XCTAssertEqual(LivingSky(settings: s, homeZone: TimeZone(identifier: "Etc/UTC")!).location, GeoPoint(latitude: 0, longitude: 0))
    }
}

// MARK: - Sets 5 & 6: blizzard, after the rain, frost, wetness, gusts, halos, pastel dawns

extension LivingSkyTests {
    private func sky(_ kind: WeatherKind, hour: Double = 13, city: String = "melbourne", seed: UInt64 = 1) -> LivingSky {
        var s = SkySettings(); s.timeMode = .frozen; s.frozenHour = hour; s.cityID = city; s.weatherMode = .pick; s.weather = kind
        return LivingSky(settings: s, seed: seed, homeZone: melbourneZone)
    }

    private func pick(_ sky: LivingSky, _ kind: WeatherKind) {
        var s = sky.settings; s.weather = kind; sky.settings = s
    }

    /// Steps `seconds` of sky in `dt` steps from `now` (or the test's start), calling `each` after every step.
    @discardableResult
    private func run(_ sky: LivingSky, seconds: Double, dt: Double = 1, now: Date? = nil, hold: SkyHold = .follow,
                     each: (SkyState) -> Void = { _ in }) -> SkyState {
        let t0 = now ?? start
        var state = sky.step(now: t0, dt: 0, hold: hold)
        let steps = Int((seconds / dt).rounded())
        for i in 1...max(1, steps) {
            state = sky.step(now: t0.addingTimeInterval(Double(i) * dt), dt: dt, hold: hold)
            each(state)
        }
        return state
    }

    func testNewWeatherValues() {
        XCTAssertEqual(WeatherKind.allCases, [.clear, .lightCloud, .overcast, .mist, .drizzle, .rain, .storm, .snow, .blizzard, .afterRain, .sunShower, .fogBank, .sleet, .monsoon, .hail, .smokeHaze])
        // cloud, rain, snow, mist, wind, halo, frost, gust (spec §6.1)
        let table: [WeatherKind: [Float]] = [
            .clear: [0, 0, 0, 0.1, 0.1, 0, 0.15, 0],
            .lightCloud: [0.35, 0, 0, 0.15, 0.2, 0.7, 0.1, 0.1],
            .overcast: [0.85, 0, 0, 0.25, 0.3, 0, 0.1, 0.1],
            .mist: [0.4, 0, 0, 0.9, 0.05, 0.15, 0.2, 0],
            .drizzle: [0.8, 0.3, 0, 0.4, 0.2, 0, 0, 0.1],
            .rain: [0.9, 0.75, 0, 0.3, 0.4, 0, 0, 0.2],
            .storm: [1, 1, 0, 0.2, 0.9, 0, 0, 0.6],
            .snow: [0.85, 0, 0.8, 0.3, 0.25, 0.2, 0.6, 0.2],
            .blizzard: [1, 0, 1, 0.6, 1, 0, 0.9, 1],
            .afterRain: [0.45, 0, 0, 0.55, 0.1, 0, 0, 0],
            .sunShower: [0.5, 0.3, 0, 0.25, 0.2, 0, 0, 0.1],
            .fogBank: [0.6, 0, 0, 1, 0.05, 0, 0.1, 0],
            .sleet: [0.95, 0.5, 0.5, 0.4, 0.35, 0, 0.2, 0.2],
            .monsoon: [1, 1, 0, 0.45, 0.6, 0, 0, 0.4],
            .hail: [1, 0.7, 0.25, 0.2, 0.5, 0, 0, 0.4],
            .smokeHaze: [0.3, 0, 0, 0.8, 0.1, 0, 0, 0],
        ]
        for k in WeatherKind.allCases {
            let v = k.values
            XCTAssertEqual([v.cloud, v.rain, v.snow, v.mist, v.wind, v.halo, v.frost, v.gust], table[k], "\(k)")
        }
        XCTAssertEqual(WeatherKind.blizzard.beautyWeight, 0.3)
        XCTAssertEqual(WeatherKind.afterRain.beautyWeight, 1.5)
    }

    func testFrostOnlyAtNightForClearSkies() {
        XCTAssertEqual(sky(.clear, hour: 13).step(now: start, dt: 0).frost, 0, accuracy: 1e-6)
        XCTAssertEqual(sky(.clear, hour: 2).step(now: start, dt: 0).frost, 0.15, accuracy: 0.01)
        XCTAssertEqual(sky(.snow, hour: 13).step(now: start, dt: 0).frost, 0.6, accuracy: 0.01)
    }

    func testRainbowsNeedSunAndShowerLight() {
        func window(_ alt: Double) -> Float {
            func ss(_ a: Float, _ b: Float, _ x: Float) -> Float { let t = min(1, max(0, (x - a) / (b - a))); return t * t * (3 - 2 * t) }
            return ss(1, 6, Float(alt)) * (1 - ss(32, 42, Float(alt)))
        }
        var sawFull = false, sawNone = false
        for hour in [7.0, 9, 11, 13, 15, 17, 19] {
            let st = sky(.sunShower, hour: hour).step(now: start, dt: 0)
            XCTAssertEqual(st.rainbow, window(st.sun.altitude), accuracy: 1e-4, "hour \(hour), sun \(st.sun.altitude)°")
            if st.rainbow > 0.99 { sawFull = true }
            if st.rainbow == 0 { sawNone = true }
        }
        XCTAssertTrue(sawFull, "a sun-shower with a mid-height sun shows the full bow at some hour of the day")
        XCTAssertTrue(sawNone, "and none with the sun too high or down")
        XCTAssertEqual(sky(.sunShower, hour: 2).step(now: start, dt: 0).rainbow, 0, "no bow at night")
        for hour in [9.0, 16] {
            let st = sky(.afterRain, hour: hour).step(now: start, dt: 0)
            XCTAssertEqual(st.rainbow, 0.75 * window(st.sun.altitude), accuracy: 1e-4, "after the rain a fainter bow")
            XCTAssertEqual(sky(.rain, hour: hour).step(now: start, dt: 0).rainbow, 0, "heavy rain under thick cloud: no bow")
            XCTAssertEqual(sky(.clear, hour: hour).step(now: start, dt: 0).rainbow, 0)
        }
    }

    func testRainMeltsFrost() {
        let s = sky(.snow)
        XCTAssertEqual(s.step(now: start, dt: 0).frost, 0.6, accuracy: 0.01)
        pick(s, .rain)
        var biggestDrop: Float = 0, last: Float = 0.6
        let after = run(s, seconds: 65) { st in biggestDrop = max(biggestDrop, last - st.frost); last = st.frost }
        XCTAssertLessThanOrEqual(after.frost, 0.01)
        XCTAssertLessThan(biggestDrop, 0.15, "the frost melts over seconds, never vanishing in one frame")
    }

    func testWetnessRisesInRainAndDriesSlowly() {
        let s = sky(.rain)
        let wet = run(s, seconds: 300)
        XCTAssertGreaterThan(wet.wetness, 0.9)
        pick(s, .clear)
        let dry = run(s, seconds: 540)
        XCTAssertGreaterThan(dry.wetness, 0.30 * wet.wetness, "\(dry.wetness)")
        XCTAssertLessThan(dry.wetness, 0.45 * wet.wetness, "\(dry.wetness)")
        pick(s, .afterRain)
        run(s, seconds: 60)
        var lowest: Float = 1
        run(s, seconds: 600) { lowest = min(lowest, $0.wetness) }
        XCTAssertGreaterThanOrEqual(lowest, 0.85)
    }

    func testSnowDoesNotWet() {
        XCTAssertEqual(run(sky(.snow), seconds: 600).wetness, 0)
    }

    func testGustsComeAndGo() {
        func rises(seed: UInt64) -> [Int] {
            var prev: Float = 0, i = 0, out: [Int] = []
            run(sky(.blizzard, seed: seed), seconds: 120, dt: 1.0 / 30) { st in
                if prev < 0.5 && st.gust >= 0.5 { out.append(i) }
                prev = st.gust; i += 1
            }
            return out
        }
        let a = rises(seed: 7)
        XCTAssertTrue((15...40).contains(a.count), "\(a.count) gusts in 2 minutes")
        XCTAssertEqual(rises(seed: 7), a, "the same seed gives the same gusts")
        XCTAssertEqual(run(sky(.clear), seconds: 30).gust, 0)
    }

    func testBlizzardMistRisesWithGust() {
        var peak: Float = 0, quiet: Float = 1
        run(sky(.blizzard), seconds: 30, dt: 1.0 / 30) { st in
            if st.gust > 0.95 { peak = max(peak, st.mist) }
            if st.gust < 0.01 { quiet = min(quiet, st.mist) }
        }
        XCTAssertGreaterThanOrEqual(peak, 0.85)
        XCTAssertEqual(quiet, 0.6, accuracy: 0.02)
    }

    func testAfterRainFollowsRain() {
        var s = SkySettings(); s.weatherMode = .randomBeautiful
        var m = WeatherMachine(settings: s, seed: 11)
        var prev = m.current, wet = 0, after = 0
        for _ in 0..<2000 {
            m.step(dt: 1300, settings: s)   // one whole spell change per step
            if [.drizzle, .rain, .storm].contains(prev) {
                wet += 1
                if m.current == .afterRain { after += 1 }
            }
            XCTAssertNotEqual(m.current, prev, "never the same weather twice in a row")
            prev = m.current
        }
        XCTAssertGreaterThan(wet, 150)
        let share = Double(after) / Double(wet)
        XCTAssertTrue(share > 0.5 && share < 0.7, "after the rain followed \(share) of wet spells")
    }

    func testHaloFromLightCloud() {
        XCTAssertEqual(sky(.lightCloud).step(now: start, dt: 0).halo, 0.7, accuracy: 1e-4)
        XCTAssertEqual(sky(.clear).step(now: start, dt: 0).halo, 0)
        var s = SkySettings(); s.weatherMode = .randomBeautiful
        var m = WeatherMachine(settings: s, seed: 3)
        var halos: [Float] = []
        for _ in 0..<400 {
            m.step(dt: 1300, settings: s)
            if m.current == .lightCloud { halos.append(LivingSky.halo(m)) }
        }
        XCTAssertGreaterThan(halos.count, 20)
        XCTAssertTrue(halos.allSatisfy { $0 >= 0.5 - 1e-4 && $0 <= 1 + 1e-4 }, "\(halos)")
        XCTAssertGreaterThan(Set(halos).count, 5, "each light-cloud spell rolls its own ice")
        XCTAssertGreaterThan(halos.max() ?? 0, 0.85, "icy spells go past 0.7, where the 46° ring shows (spec §6.3)")
    }

    func testPastelMorningsAboutOneInThree() {
        let melbourne = (0..<300).map { LivingSky.dawnIsPastel(day: $0, cityID: "melbourne") }
        let count = melbourne.filter { $0 }.count
        XCTAssertTrue((80...120).contains(count), "\(count) pastel mornings in 300")
        XCTAssertEqual((0..<300).map { LivingSky.dawnIsPastel(day: $0, cityID: "melbourne") }, melbourne)
        XCTAssertNotEqual((0..<300).map { LivingSky.dawnIsPastel(day: $0, cityID: "tokyo") }, melbourne)
    }

    private func pastelDay(zone: TimeZone, city: String) throws -> Date {
        try XCTUnwrap((0..<40).map { start.addingTimeInterval(Double($0) * 86_400) }
            .first { LivingSky.dawnIsPastel(day: LivingSky.localDay($0, zone: zone), cityID: city) })
    }

    func testPastelOnlyInTheMorning() throws {
        let day = try pastelDay(zone: melbourneZone, city: "melbourne")
        XCTAssertGreaterThan(run(sky(.clear, hour: 6.2), seconds: 120, now: day).dawnPastel, 0.99)
        XCTAssertLessThan(run(sky(.clear, hour: 19.8), seconds: 120, now: day).dawnPastel, 0.01)
    }

    func testPastelDawnHold() {
        XCTAssertEqual(SkyHold.pastelDawn.rawValue, "Pastel dawn")
        XCTAssertTrue(SkyHold.pastelDawn.forcesPastel)
        XCTAssertFalse(SkyHold.goldenHour.forcesPastel)
        for hour in [2.0, 13.0, 20.0] {
            let st = run(sky(.clear, hour: hour), seconds: 1, hold: .pastelDawn)
            XCTAssertEqual(st.sun.altitude, 1.5, accuracy: 1e-9)
            XCTAssertEqual(st.dawnPastel, 1)
        }
    }

    func testPastelPaletteIsPastel() {
        let p = SkyPalette.colours(sunAltitude: -2, cloud: 0, mist: 0, moonlight: 0, pastel: 1)
        XCTAssertGreaterThan(p.horizon.x, 0.85, "\(p.horizon)")
        XCTAssertTrue(p.horizon.y > 0.5 && p.horizon.y < 0.72, "\(p.horizon)")
        XCTAssertGreaterThan(p.horizon.z, 0.55, "\(p.horizon)")
        XCTAssertGreaterThan(p.zenith.z, p.zenith.x, "lavender-blue zenith \(p.zenith)")
        XCTAssertGreaterThan(p.zenith.x, p.zenith.y * 0.95, "lavender-blue zenith \(p.zenith)")
        // Outside the dawn window, and at pastel 0, the colours are exactly today's.
        for alt in [-20.0, -12, -6, -2, 0, 3, 6, 12, 25] {
            let today = SkyPalette.colours(sunAltitude: alt, cloud: 0.3, mist: 0.2, moonlight: 0.1)
            let zero = SkyPalette.colours(sunAltitude: alt, cloud: 0.3, mist: 0.2, moonlight: 0.1, pastel: 0)
            XCTAssertEqual(today.zenith, zero.zenith); XCTAssertEqual(today.horizon, zero.horizon)
        }
        for alt in [-20.0, -12, 10, 25] {
            let today = SkyPalette.colours(sunAltitude: alt, cloud: 0, mist: 0, moonlight: 0)
            let pastel = SkyPalette.colours(sunAltitude: alt, cloud: 0, mist: 0, moonlight: 0, pastel: 1)
            XCTAssertEqual(today.zenith, pastel.zenith, "at \(alt)°"); XCTAssertEqual(today.horizon, pastel.horizon, "at \(alt)°")
        }
    }

    /// Dhaka is UTC+6, so UTC's date changes at 06:00 there, in the middle of its dawn. A sky that picked its dawn by
    /// the UTC date would change its mind mid-dawn; the city's own date holds all morning. The Mac is on UTC here, so
    /// the Mac's date can't stand in for the city's either.
    func testPastelChoiceHoldsAllMorning() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "Asia/Dhaka"))
        var cal = Calendar(identifier: .gregorian); cal.timeZone = zone
        var day = cal.startOfDay(for: start)
        // A pastel day after a plain one, so the UTC date (still the day before until 06:00) would say no.
        while !(LivingSky.dawnIsPastel(day: LivingSky.localDay(day, zone: zone), cityID: "dhaka")
                && !LivingSky.dawnIsPastel(day: LivingSky.localDay(day.addingTimeInterval(-86_400), zone: zone), cityID: "dhaka")) {
            day = day.addingTimeInterval(86_400)
        }
        var s = SkySettings(); s.timeMode = .realTime; s.cityID = "dhaka"; s.weatherMode = .pick; s.weather = .clear
        let sky = LivingSky(settings: s, homeZone: try XCTUnwrap(TimeZone(identifier: "UTC")))
        var now = day.addingTimeInterval(4 * 3600)
        _ = sky.step(now: now, dt: 0)
        var lowest: Float = 1, inWindow = 0, beforeSix = 0
        while now < day.addingTimeInterval(8 * 3600) {
            now = now.addingTimeInterval(10)
            let st = sky.step(now: now, dt: 10)
            if st.sun.altitude > -10 && st.sun.altitude < 8 {
                lowest = min(lowest, st.dawnPastel); inWindow += 1
                if now < day.addingTimeInterval(6 * 3600) { beforeSix += 1 }
            }
        }
        XCTAssertGreaterThan(inWindow, 50)
        XCTAssertGreaterThan(beforeSix, 10, "part of the dawn falls before UTC's midnight")
        XCTAssertGreaterThanOrEqual(lowest, 0.95)
    }

    func testOldSettingsStillLoad() throws {
        let blizzard = try JSONDecoder().decode(SkySettings.self, from: Data(#"{"weather":"blizzard","weatherMode":"pick"}"#.utf8))
        XCTAssertEqual(blizzard.weather, .blizzard)
        let unknown = try JSONDecoder().decode(SkySettings.self, from: Data(#"{"weather":"aurora","cityID":"tokyo"}"#.utf8))
        XCTAssertEqual(unknown.weather, .clear)
        XCTAssertEqual(unknown.cityID, "tokyo")
    }

    func testTheLoungeHasNoWeather() {
        var st = SkyState(); st.halo = 0.7; st.frost = 0.6; st.wetness = 0.9; st.gust = 1
        let lounge = SpaceshipLoungeModel.weatherless(st)
        XCTAssertEqual([lounge.halo, lounge.frost, lounge.wetness, lounge.gust], [0, 0, 0, 0])
    }
}
