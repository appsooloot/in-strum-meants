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
