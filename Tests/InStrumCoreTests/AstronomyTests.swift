import XCTest
@testable import InStrumCore

/// Ground truth: sunrise-sunset.org and USNO (sun), eclipse records (phases), USNO (Melbourne moon times),
/// and Meeus' worked examples (ephemeris digits).
final class AstronomyTests: XCTestCase {
    let melbourne = GeoPoint(latitude: -37.8136, longitude: 144.9631)
    let tromso = GeoPoint(latitude: 69.6496, longitude: 18.9560)
    let melbourneZone = TimeZone(identifier: "Australia/Melbourne")!

    private func utc(_ s: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)!
    }

    /// Noon on a local calendar day.
    private func localDay(_ y: Int, _ m: Int, _ d: Int, _ zone: TimeZone) -> Date {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = zone
        return c.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    private func assertNear(_ a: Date?, _ b: Date, minutes: Double, _ what: String, line: UInt = #line) {
        guard let a else { return XCTFail("\(what): none", line: line) }
        XCTAssertEqual(a.timeIntervalSince(b) / 60, 0, accuracy: minutes, what, line: line)
    }

    func testMelbourneSunriseSunset() {
        let d1 = localDay(2026, 10, 28, melbourneZone), d2 = localDay(2026, 10, 1, melbourneZone)
        assertNear(Solar.sunrise(on: d1, at: melbourne, timeZone: melbourneZone), utc("2026-10-27T19:18:19Z"), minutes: 2, "sunrise 28 Oct")
        assertNear(Solar.sunset(on: d1, at: melbourne, timeZone: melbourneZone), utc("2026-10-28T08:50:10Z"), minutes: 2, "sunset 28 Oct")
        assertNear(Solar.sunrise(on: d2, at: melbourne, timeZone: melbourneZone), utc("2026-09-30T19:56:21Z"), minutes: 2, "sunrise 1 Oct")
        assertNear(Solar.sunset(on: d2, at: melbourne, timeZone: melbourneZone), utc("2026-10-01T08:24:11Z"), minutes: 2, "sunset 1 Oct")
    }

    func testMoonPhases() {
        let cases: [(MoonPhaseEvent, String)] = [(.full, "2026-03-03T11:38:00Z"), (.full, "2026-10-26T04:13:00Z"),
                                                 (.new, "2026-02-17T12:01:00Z"), (.new, "2026-08-12T17:37:00Z")]
        for (phase, s) in cases {
            let truth = utc(s)
            assertNear(Lunar.next(phase, after: truth.addingTimeInterval(-3 * 86_400)), truth, minutes: 360, "\(phase) \(s)")
            let lit = Lunar.illuminatedFraction(at: truth)
            if phase == .full { XCTAssertGreaterThan(lit, 0.99, s) } else { XCTAssertLessThan(lit, 0.01, s) }
        }
        let fullAngle = Lunar.phaseAngle(at: utc("2026-10-26T04:13:00Z")), newAngle = Lunar.phaseAngle(at: utc("2026-08-12T17:37:00Z"))
        XCTAssertEqual(fullAngle, 180, accuracy: 1)
        XCTAssertEqual(min(newAngle, 360 - newAngle), 0, accuracy: 1)
        let q1 = Lunar.next(.firstQuarter, after: utc("2026-10-26T04:13:00Z")), q3 = Lunar.next(.lastQuarter, after: utc("2026-10-26T04:13:00Z"))
        XCTAssertEqual(Lunar.phaseAngle(at: q1), 90, accuracy: 0.5)
        XCTAssertEqual(Lunar.phaseAngle(at: q3), 270, accuracy: 0.5)
        XCTAssertLessThan(q3, q1, "after a full moon the last quarter comes first")
    }

    /// USNO for 28 Oct 2026 (AEDT): moonset 07:06, moonrise 22:39.
    func testMelbourneMoonriseMoonset() {
        let d = localDay(2026, 10, 28, melbourneZone)
        assertNear(Lunar.moonrise(on: d, at: melbourne, timeZone: melbourneZone), utc("2026-10-28T11:39:00Z"), minutes: 3, "moonrise")
        assertNear(Lunar.moonset(on: d, at: melbourne, timeZone: melbourneZone), utc("2026-10-27T20:06:00Z"), minutes: 3, "moonset")
    }

    func testSubsolarPoint() {
        let p = Solar.subsolarPoint(at: utc("2026-10-28T12:00:00Z"))
        XCTAssertEqual(p.longitude, -4, accuracy: 1.5)
        XCTAssertEqual(p.latitude, -13, accuracy: 1.5)
    }

    /// Review Focus 5: polar night and midnight sun.
    func testPolarNightAndMidnightSun() {
        let oslo = TimeZone(identifier: "Europe/Oslo")!
        XCTAssertNil(Solar.sunrise(on: localDay(2026, 12, 21, oslo), at: tromso, timeZone: oslo))
        XCTAssertNil(Solar.sunset(on: localDay(2026, 12, 21, oslo), at: tromso, timeZone: oslo))
        XCTAssertNil(Solar.sunset(on: localDay(2026, 6, 21, oslo), at: tromso, timeZone: oslo))
        XCTAssertNil(Solar.sunrise(on: localDay(2026, 6, 21, oslo), at: tromso, timeZone: oslo))
        for h in 0..<24 {
            let winter = utc(String(format: "2026-12-21T%02d:00:00Z", h)), summer = utc(String(format: "2026-06-21T%02d:00:00Z", h))
            XCTAssertLessThan(Solar.direction(at: winter, from: tromso).altitude, 0, "Dec \(h)h")
            XCTAssertGreaterThan(Solar.direction(at: summer, from: tromso).altitude, 0, "Jun \(h)h")
        }
    }

    func testSunDirectionIsSane() {
        // Melbourne, 28 Oct 2026 at USNO's upper transit (13:04 AEDT): due north, 90 − 37.8 + 13 (declination) ≈ 65° up.
        let noon = utc("2026-10-28T02:04:00Z")
        let s = Solar.direction(at: noon, from: melbourne)
        XCTAssertLessThan(min(s.azimuth, 360 - s.azimuth), 3, "north")
        XCTAssertEqual(s.altitude, 90 - 37.8136 + 13.0, accuracy: 1)
        XCTAssertLessThan(Solar.direction(at: utc("2026-10-28T14:00:00Z"), from: melbourne).altitude, -30, "1 am")
    }

    /// Meeus Example 47.a (1992 April 12, 0h TD): α 134.688470°, δ 13.768368°, Δ 368 409.7 km.
    func testMoonMatchesMeeusExample() {
        let t = Date(timeIntervalSince1970: (2_448_724.5 - 2_440_587.5) * 86_400)
        let m = Lunar.equatorial(at: t)
        XCTAssertEqual(m.rightAscension, 134.688470, accuracy: 0.01)
        XCTAssertEqual(m.declination, 13.768368, accuracy: 0.01)
        XCTAssertEqual(m.distanceKm, 368_409.7, accuracy: 30)
    }

    /// Meeus Example 12.a: 1987 April 10, 0h UT → GMST 13h10m46.3668s = 197.693195°.
    func testSiderealTime() {
        let t = Date(timeIntervalSince1970: 545_011_200)   // 1987-04-10T00:00:00Z
        XCTAssertEqual(Sidereal.localSiderealDegrees(at: t, longitude: 0), 197.693195, accuracy: 1e-4)
        XCTAssertEqual(Sidereal.localSiderealDegrees(at: t, longitude: 90), 287.693195, accuracy: 1e-4)
    }

    func testMoonDirectionMovesAcrossTheSky() {
        // Two hours after USNO's moonrise the moon is up in the north-east.
        let m = Lunar.direction(at: utc("2026-10-28T13:39:00Z"), from: melbourne)
        XCTAssertGreaterThan(m.altitude, 10)
        XCTAssertTrue((20...90).contains(m.azimuth), "azimuth \(m.azimuth)")
    }

    func testDefaultCityFromTimeZone() {
        XCTAssertEqual(Cities.defaultCity(for: TimeZone(identifier: "Australia/Melbourne")!)?.id, "melbourne")
        XCTAssertEqual(Cities.defaultCity(for: TimeZone(identifier: "Europe/London")!)?.id, "london")
        XCTAssertNil(Cities.defaultCity(for: TimeZone(identifier: "Etc/UTC")!))
    }

    func testCityListIsSane() {
        let all = Cities.all
        XCTAssertGreaterThanOrEqual(all.count, 180)
        XCTAssertEqual(Set(all.map(\.id)).count, all.count, "unique ids")
        for c in all {
            XCTAssertTrue((-90...90).contains(c.point.latitude) && (-180...180).contains(c.point.longitude), c.id)
            XCTAssertNotNil(TimeZone(identifier: c.timeZoneID), "\(c.id): \(c.timeZoneID)")
            XCTAssertFalse(c.name.isEmpty || c.country.isEmpty, c.id)
        }
        for id in ["melbourne", "sydney", "perth", "auckland", "tokyo", "london", "new-york", "los-angeles", "reykjavik", "tromso", "ushuaia"] {
            XCTAssertNotNil(Cities.city(id: id), id)
        }
        XCTAssertEqual(Cities.city(id: "tromso")?.point, GeoPoint(latitude: 69.6496, longitude: 18.9560))
        XCTAssertEqual(Cities.city(id: "melbourne")?.timeZoneID, "Australia/Melbourne")
    }
}
