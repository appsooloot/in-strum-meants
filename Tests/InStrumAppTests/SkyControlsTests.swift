import XCTest
@testable import InStrumApp
@testable import InStrumCore

final class SkyControlsTests: XCTestCase {
    func testCitySearchKeepsTheSelectedCity() throws {
        let tokyo = try XCTUnwrap(Cities.all.first { $0.id == "tokyo" })
        let melbourne = try XCTUnwrap(Cities.all.first { $0.id == "melbourne" })
        let hits = SkyControls.filtered(Cities.all, query: "tok", keeping: melbourne.id)
        XCTAssertTrue(hits.contains(tokyo))
        XCTAssertTrue(hits.contains(melbourne), "the picker's selection must stay in its list while you search")
        XCTAssertFalse(hits.contains { $0.id == "paris" })
        XCTAssertEqual(SkyControls.filtered(Cities.all, query: "", keeping: nil).count, Cities.all.count)
        XCTAssertEqual(SkyControls.filtered(Cities.all, query: "zzzz", keeping: melbourne.id), [melbourne])
        // Sorted by name, with the search matched on the country too.
        let names = SkyControls.filtered(Cities.all, query: "australia", keeping: nil).map(\.name)
        XCTAssertEqual(names, names.sorted())
        XCTAssertTrue(names.contains("Melbourne"))
    }

    func testWeatherNames() {
        let names = WeatherKind.allCases.map(SkyControls.weatherName)
        XCTAssertTrue(names.allSatisfy { !$0.isEmpty })
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertEqual(SkyControls.weatherName(.blizzard), "Blizzard")
        XCTAssertEqual(SkyControls.weatherName(.sunShower), "Sun-shower")
        XCTAssertEqual(SkyControls.weatherName(.fogBank), "Fog bank")
        XCTAssertEqual(SkyControls.weatherName(.sleet), "Sleet")
        XCTAssertEqual(SkyControls.weatherName(.hail), "Hail")
        XCTAssertEqual(SkyControls.weatherName(.iceFog), "Ice fog")
        XCTAssertEqual(SkyControls.weatherName(.thunderheads), "Thunderheads")
        XCTAssertEqual(SkyControls.weatherName(.dustStorm), "Dust storm")
        XCTAssertEqual(SkyControls.weatherName(.flurries), "Snow flurries")
        XCTAssertEqual(SkyControls.weatherName(.freezingDrizzle), "Freezing drizzle")
        XCTAssertEqual(SkyControls.weatherName(.squall), "Squall")
        XCTAssertEqual(SkyControls.weatherName(.dryLightning), "Dry lightning")
        XCTAssertEqual(SkyControls.weatherName(.smokeHaze), "Smoke haze")
        XCTAssertEqual(SkyControls.weatherName(.monsoon), "Monsoon")
        XCTAssertEqual(SkyControls.weatherName(.afterRain), "After the rain")
        XCTAssertEqual(SkyControls.weatherName(.humid), "Humid night")
        XCTAssertEqual(SkyControls.weatherName(.diamondDust), "Diamond dust")
        XCTAssertEqual(SkyControls.weatherName(.rime), "Rime frost")
        XCTAssertEqual(SkyControls.weatherName(.seaSmoke), "Sea smoke")
        XCTAssertEqual(names.last, "Sea smoke")
    }
}
