import XCTest
@testable import InStrumCore

final class SetsTests: XCTestCase {
    func testSixSetsAreComplete() throws {
        XCTAssertEqual(SetLibrary.all.map(\.id), ["moonlit-lake", "spaceship-lounge", "golden-hour-beach", "coast-road",
                                                  "snowbound-cabin", "bedroom-dawn"])
        for s in SetLibrary.all {
            XCTAssertEqual(ThemeRegistry.resolve(s.worldID), s.worldID, s.id)
            let visual = try XCTUnwrap(ThemeRegistry.parameters(for: s.worldID).first { $0.id == "visual" }, s.id)
            guard case let .choice(options) = visual.kind else { return XCTFail("\(s.id): visual is not a choice") }
            XCTAssertTrue(options.contains(s.visual), s.id)
            XCTAssertNotNil(PatchLibrary.all.first { $0.id == s.patchID }, s.id)
            XCTAssertNotNil(CreditLibrary.credit(id: s.creditID), s.id)
            XCTAssertEqual(SetLibrary.set(id: s.id), s)
            XCTAssertFalse(s.name.isEmpty); XCTAssertFalse(s.moodName.isEmpty)
        }
        let lake = try XCTUnwrap(SetLibrary.set(id: "moonlit-lake"))
        XCTAssertEqual(lake.mood, .serene)
        XCTAssertEqual(lake.worldID, MoonlitLakeModel.id)
        XCTAssertEqual(lake.visual, "Lake Ripples")
        XCTAssertEqual(PatchLibrary.all.first { $0.id == lake.patchID }?.engine, .feltGlass)
        XCTAssertEqual(lake.creditID, CreditLibrary.comeBackToEarth.id)
        let lounge = try XCTUnwrap(SetLibrary.set(id: "spaceship-lounge"))
        XCTAssertEqual(lounge.mood, .dreamy)
        XCTAssertEqual(lounge.worldID, SpaceshipLoungeModel.id)
        XCTAssertEqual(lounge.visual, "Galaxy Warp")
        XCTAssertEqual(PatchLibrary.all.first { $0.id == lounge.patchID }?.engine, .orbitPad)
        XCTAssertEqual(lounge.creditID, CreditLibrary.innerbloom.id)
        let beach = try XCTUnwrap(SetLibrary.set(id: "golden-hour-beach"))
        XCTAssertEqual(beach.name, "Golden Hour Beach")
        XCTAssertEqual(beach.moodName, "Warm, hazy, nostalgic")
        XCTAssertEqual(beach.mood, .warmHaze)
        XCTAssertEqual(beach.worldID, GoldenHourBeachModel.id)
        XCTAssertEqual(beach.visual, "Tide Lines")
        XCTAssertEqual(PatchLibrary.all.first { $0.id == beach.patchID }?.engine, .honeyTape)
        XCTAssertEqual(beach.patchID, "honey-tape")
        XCTAssertEqual(beach.creditID, CreditLibrary.musicToWatchBoysTo.id)
        let road = try XCTUnwrap(SetLibrary.set(id: "coast-road"))
        XCTAssertEqual(road.name, "Coast Road")
        XCTAssertEqual(road.moodName, "Hazy, restless, free")
        XCTAssertEqual(road.mood, .restless)
        XCTAssertEqual(road.worldID, CoastRoadModel.id)
        XCTAssertEqual(road.visual, "Coast Lights")
        XCTAssertEqual(PatchLibrary.all.first { $0.id == road.patchID }?.engine, .hazeBells)
        XCTAssertEqual(road.patchID, "haze-bells")
        XCTAssertEqual(road.creditID, CreditLibrary.highByTheBeach.id)
        let cabin = try XCTUnwrap(SetLibrary.set(id: "snowbound-cabin"))
        XCTAssertEqual(cabin.name, "Snowbound Cabin Window")
        XCTAssertEqual(cabin.moodName, "Hushed, safe, warm")
        XCTAssertEqual(cabin.mood, .hushedWarm)
        XCTAssertEqual(cabin.worldID, SnowboundCabinModel.id)
        XCTAssertEqual(cabin.visual, "Frost Grow")
        XCTAssertEqual(PatchLibrary.all.first { $0.id == cabin.patchID }?.engine, .cabinFelt)
        XCTAssertEqual(cabin.patchID, "cabin-felt")
        XCTAssertEqual(cabin.creditID, CreditLibrary.stay.id)
        let bedroom = try XCTUnwrap(SetLibrary.set(id: "bedroom-dawn"))
        XCTAssertEqual(bedroom.name, "Bedroom Window at Dawn")
        XCTAssertEqual(bedroom.moodName, "Soft, waking")
        XCTAssertEqual(bedroom.mood, .softWaking)
        XCTAssertEqual(bedroom.worldID, BedroomDawnModel.id)
        XCTAssertEqual(bedroom.visual, "Curtain Light")
        XCTAssertEqual(PatchLibrary.all.first { $0.id == bedroom.patchID }?.engine, .morningBox)
        XCTAssertEqual(bedroom.patchID, "morning-box")
        XCTAssertEqual(bedroom.creditID, CreditLibrary.dunno.id)
        XCTAssertNil(SetLibrary.set(id: "nope"))
        // Each set's built-in preset carries the same credit as the set.
        for s in SetLibrary.all { XCTAssertEqual(PatchLibrary.all.first { $0.id == s.patchID }?.creditID, s.creditID) }
    }

    func testNewMoods() {
        XCTAssertEqual(Mood.warmHaze, Mood(energy: 0.25, warmth: 0.85, brightness: 0.55, space: 0.75, motion: 0.35))
        XCTAssertEqual(Mood.restless, Mood(energy: 0.5, warmth: 0.35, brightness: 0.4, space: 0.85, motion: 0.75))
        XCTAssertNotEqual(Mood.warmHaze, Mood.serene); XCTAssertNotEqual(Mood.restless, Mood.dreamy)
        XCTAssertEqual(Mood.hushedWarm, Mood(energy: 0.2, warmth: 0.85, brightness: 0.3, space: 0.35, motion: 0.2))
        XCTAssertEqual(Mood.softWaking, Mood(energy: 0.25, warmth: 0.6, brightness: 0.65, space: 0.55, motion: 0.3))
        let moods = [Mood.serene, .dreamy, .warmHaze, .restless, .hushedWarm, .softWaking]
        for i in 0..<moods.count { for j in (i + 1)..<moods.count { XCTAssertNotEqual(moods[i], moods[j]) } }
    }

    // MARK: - Inspired-by cards

    func testListenLinks() throws {
        let c = CreditLibrary.comeBackToEarth
        let app = ListenLink.spotifyApp(for: c)
        XCTAssertEqual(app.scheme, "spotify")
        XCTAssertTrue(app.absoluteString.contains("Mac%20Miller"), app.absoluteString)
        XCTAssertTrue(app.absoluteString.contains("Come%20Back%20to%20Earth"), app.absoluteString)
        let web = ListenLink.spotifyWeb(for: c)
        XCTAssertEqual(web.host, "open.spotify.com")
        XCTAssertEqual(web.scheme, "https")
        XCTAssertTrue(web.path.hasPrefix("/search/"))
        // Accented names survive the trip.
        let bloom = ListenLink.spotifyWeb(for: CreditLibrary.innerbloom)
        XCTAssertEqual(bloom.path, "/search/RÜFÜS DU SOL Innerbloom")
        XCTAssertEqual(ListenLink.spotifyWeb(for: CreditLibrary.stay).path, "/search/Mac Miller Stay")
        XCTAssertEqual(ListenLink.spotifyWeb(for: CreditLibrary.dunno).path, "/search/Mac Miller Dunno")
        XCTAssertTrue(ListenLink.spotifyApp(for: CreditLibrary.dunno).absoluteString.contains("Dunno"))
    }

    func testPulseFollowsTempo() {
        for c in CreditLibrary.all { XCTAssertEqual(c.pulsePeriod, 60 / c.tempoBPM, accuracy: 1e-12) }
        XCTAssertEqual(CreditLibrary.comeBackToEarth.pulsePeriod, 60.0 / 84, accuracy: 1e-12)
    }
}
