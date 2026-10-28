import XCTest
@testable import InStrumCore

final class SetsTests: XCTestCase {
    func testTwoSetsAreComplete() throws {
        XCTAssertEqual(SetLibrary.all.map(\.id), ["moonlit-lake", "spaceship-lounge"])
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
        XCTAssertNil(SetLibrary.set(id: "nope"))
        // Each set's built-in preset carries the same credit as the set.
        for s in SetLibrary.all { XCTAssertEqual(PatchLibrary.all.first { $0.id == s.patchID }?.creditID, s.creditID) }
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
    }

    func testPulseFollowsTempo() {
        for c in CreditLibrary.all { XCTAssertEqual(c.pulsePeriod, 60 / c.tempoBPM, accuracy: 1e-12) }
        XCTAssertEqual(CreditLibrary.comeBackToEarth.pulsePeriod, 60.0 / 84, accuracy: 1e-12)
    }
}
