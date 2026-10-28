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

    func testEverySetHasItsOwnCardColours() {
        let fallback = SetsGallery.tint(for: "no-such-set")
        var seen: [[Color]] = []
        for set in SetLibrary.all {
            let tint = SetsGallery.tint(for: set.id)
            XCTAssertNotEqual(tint, fallback, "\(set.id) falls back to grey")
            XCTAssertFalse(seen.contains(tint), "\(set.id) shares another set's colours")
            seen.append(tint)
        }
    }

    /// No two cards look alike.
    func testCardsAreDistinct() throws {
        let images = try CreditLibrary.all.map { try XCTUnwrap(Self.render($0, at: 1.0), $0.id) }
        for i in 0..<images.count {
            for j in (i + 1)..<images.count {
                let d = PreviewRenderer.difference(images[i], images[j])
                if d <= 0.02 { XCTFail("\(CreditLibrary.all[i].id) and \(CreditLibrary.all[j].id) differ by only \(d)") }
            }
        }
    }

    /// Renders a card at a fixed moment (600×360, the card's 5:3).
    static func render(_ c: Credit, at t: Double) -> CGImage? {
        let renderer = ImageRenderer(content: InspiredByCard(credit: c, fixedTime: t).frame(width: 600, height: 360))
        renderer.scale = 1
        return renderer.cgImage
    }

    /// "Stay" is felt in half time, so its card breathes at 67, not 134.
    func testStayCardBreathesAtHalfTempo() throws {
        let art = try XCTUnwrap(CardArt.art(for: CreditLibrary.stay.id))
        XCTAssertEqual(art.pulse(for: CreditLibrary.stay), 60.0 / 67, accuracy: 1e-9)
        XCTAssertEqual(CardArt.highByTheBeach.pulse(for: CreditLibrary.highByTheBeach), 60.0 / 132, accuracy: 1e-9)
    }

    func testCardsDrawTheirArtAndBreatheWithTheTempo() throws {
        for c in CreditLibrary.all {
            let a = try XCTUnwrap(Self.render(c, at: 0.2), c.id)
            let s = PreviewRenderer.stats(a)
            XCTAssertGreaterThan(s.meanLuminance, 0.05, c.id)
            XCTAssertGreaterThan(s.variance, 0.001, c.id)
            // Two seconds later the art has moved on (ring and caustics; the bloom opening).
            let b = try XCTUnwrap(Self.render(c, at: 2.2), c.id)
            let moved = PreviewRenderer.difference(a, b)
            if moved <= 0.001 { XCTFail("\(c.id) moved only \(moved)") }
        }
    }
}
