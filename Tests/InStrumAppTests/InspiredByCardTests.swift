import XCTest
import SwiftUI
@testable import InStrumApp
@testable import InStrumCore

/// The living "Inspired by" cards.
@MainActor
final class InspiredByCardTests: XCTestCase {
    func testEveryCreditHasArt() {
        for c in CreditLibrary.all { XCTAssertNotNil(CardArt.art(for: c.id), c.id) }
        XCTAssertNil(CardArt.art(for: "not-a-credit"))
        XCTAssertNotEqual(CardArt.art(for: CreditLibrary.comeBackToEarth.id), CardArt.art(for: CreditLibrary.innerbloom.id))
    }

    /// Renders a card at a fixed moment (600×360, the card's 5:3).
    static func render(_ c: Credit, at t: Double) -> CGImage? {
        let renderer = ImageRenderer(content: InspiredByCard(credit: c, fixedTime: t).frame(width: 600, height: 360))
        renderer.scale = 1
        return renderer.cgImage
    }

    func testCardsDrawTheirArtAndBreatheWithTheTempo() throws {
        for c in CreditLibrary.all {
            let a = try XCTUnwrap(Self.render(c, at: 0.2), c.id)
            let s = PreviewRenderer.stats(a)
            XCTAssertGreaterThan(s.meanLuminance, 0.05, c.id)
            XCTAssertGreaterThan(s.variance, 0.001, c.id)
            // A beat later the art has moved (the rising ring is half way up; the bloom has opened further).
            let b = try XCTUnwrap(Self.render(c, at: 0.2 + c.pulsePeriod), c.id)
            XCTAssertGreaterThan(PreviewRenderer.difference(a, b), 0.001, c.id)
        }
    }
}
