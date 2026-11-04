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
        XCTAssertEqual(SetLibrary.all.count, 10)
        let fallback = SetsGallery.tint(for: "no-such-set")
        var seen: [[Color]] = []
        for set in SetLibrary.all {
            let tint = SetsGallery.tint(for: set.id)
            XCTAssertNotEqual(tint, fallback, "\(set.id) falls back to grey")
            XCTAssertFalse(seen.contains(tint), "\(set.id) shares another set's colours")
            seen.append(tint)
        }
        // The still places (spec §11): the tea room's shadow to its lit paper; the moss's shade to the raked gravel.
        XCTAssertEqual(SetsGallery.tint(for: SetLibrary.teaHouseSnow.id),
                       [Color(red: 0.10, green: 0.09, blue: 0.11), Color(red: 0.86, green: 0.80, blue: 0.70)])
        XCTAssertEqual(SetsGallery.tint(for: SetLibrary.zenRockGarden.id),
                       [Color(red: 0.08, green: 0.10, blue: 0.08), Color(red: 0.78, green: 0.76, blue: 0.66)])
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
        render(InspiredByCard(credit: c, fixedTime: t))
    }

    /// Renders a set's place card at a fixed moment.
    static func render(place set: InStrumSet, at t: Double) -> CGImage? {
        render(InspiredByCard(place: set, fixedTime: t))
    }

    private static func render(_ card: InspiredByCard) -> CGImage? {
        let renderer = ImageRenderer(content: card.frame(width: 600, height: 360))
        renderer.scale = 1
        return renderer.cgImage
    }

    /// Every set shows one card: its song's, or (born from its place, no credit) its place card.
    func testEverySetHasACardOrPlaceArt() {
        for set in SetLibrary.all {
            if let credit = set.creditID {
                XCTAssertNotNil(CardArt.art(for: credit), "\(set.id) has no song card")
                XCTAssertNil(CardArt.place(for: set.id), "\(set.id) has a song card and a place card")
            } else {
                XCTAssertNotNil(CardArt.place(for: set.id), "\(set.id) has no credit and no place card")
            }
        }
        XCTAssertEqual(SetLibrary.all.compactMap { CardArt.place(for: $0.id) }, [.teaHouseSnow, .zenRockGarden])
        for c in CreditLibrary.all { XCTAssertFalse(CardArt.art(for: c.id)?.isPlace ?? true, c.id) }
    }

    /// The tea house is born from its place: its card (steam curling over a snow garden seen through a lattice, the koto's
    /// thirteen strings faint along the lower edge) breathes at a slow fixed 60/48 s whatever any song's tempo, names the
    /// set and its mood instead of a song, artist and album, has no liner notes or Listen button, and looks like none of
    /// the song cards.
    func testPlaceCardForTheTeaHouse() throws {
        let art = try XCTUnwrap(CardArt.place(for: "tea-house-snow"))
        XCTAssertTrue(art.isPlace)
        XCTAssertEqual(CardArt.placePulse, 60.0 / 48, accuracy: 1e-12)
        XCTAssertEqual(art.pulse(for: CreditLibrary.stay), 60.0 / 48, accuracy: 1e-12, "a place card follows no song")
        XCTAssertEqual(CardArt.teaHouseStrings.count, 13, "the koto's thirteen strings")
        XCTAssertTrue(CardArt.teaHouseStrings.allSatisfy { $0 > 0.85 && $0 < 1 }, "along the lower edge")
        XCTAssertNil(CardArt.place(for: SetLibrary.moonlitLake.id), "a song's set has no place card")
        XCTAssertNil(CardArt.place(for: "no-such-set"))
        for c in CreditLibrary.all { XCTAssertNotEqual(CardArt.art(for: c.id), art, c.id) }

        let card = InspiredByCard(place: SetLibrary.teaHouseSnow)
        XCTAssertEqual(card.subject, .place(SetLibrary.teaHouseSnow))
        XCTAssertEqual(card.art, .teaHouseSnow)
        XCTAssertEqual(card.pulse, 60.0 / 48, accuracy: 1e-12)
        XCTAssertEqual(card.words.title, "Tea House Snow")
        XCTAssertEqual(card.words.subtitle, "Delicate, hushed")
        XCTAssertNil(card.words.listen, "no Listen button")
        XCTAssertNil(card.words.linerNotes)
        XCTAssertNil(card.words.line)
        // A song card still names its song and links to it.
        let song = InspiredByCard(credit: CreditLibrary.dunno)
        XCTAssertEqual(song.words.title, "Dunno")
        XCTAssertEqual(song.words.subtitle, "Mac Miller · Swimming · 2018")
        XCTAssertEqual(song.words.listen, CreditLibrary.dunno)
        XCTAssertEqual(song.words.linerNotes, "C♯ major · TRACK 10 · 82 BPM")
        XCTAssertEqual(song.pulse, 60.0 / 82, accuracy: 1e-12)

        // The picture: it draws, it breathes, and it looks like no song card.
        let a = try XCTUnwrap(Self.render(place: SetLibrary.teaHouseSnow, at: 0.2))
        let s = PreviewRenderer.stats(a)
        XCTAssertGreaterThan(s.meanLuminance, 0.05)
        XCTAssertGreaterThan(s.variance, 0.001)
        let b = try XCTUnwrap(Self.render(place: SetLibrary.teaHouseSnow, at: 2.2))
        let moved = PreviewRenderer.difference(a, b)
        if moved <= 0.001 { XCTFail("the tea house card moved only \(moved)") }
        let place = try XCTUnwrap(Self.render(place: SetLibrary.teaHouseSnow, at: 1.0))
        for c in CreditLibrary.all {
            let other = try XCTUnwrap(Self.render(c, at: 1.0), c.id)
            let d = PreviewRenderer.difference(place, other)
            if d <= 0.02 { XCTFail("the tea house card and \(c.id) differ by only \(d)") }
        }
    }

    /// The garden is born from its place too: its card (raked circles round five stones in three groups on moss islands, and
    /// the eave's bamboo pole along the top with five rings, the shakuhachi's five holes) breathes at the same slow fixed
    /// 60/48 s, names the set and its mood instead of a song, artist and album, has no liner notes or Listen button, and
    /// looks like none of the song cards, nor like the tea house's.
    func testPlaceCardForTheGarden() throws {
        let art = try XCTUnwrap(CardArt.place(for: "zen-rock-garden"))
        XCTAssertTrue(art.isPlace)
        XCTAssertNotEqual(art, CardArt.place(for: "tea-house-snow"), "each place has its own card")
        XCTAssertEqual(art.pulse(for: CreditLibrary.stay), 60.0 / 48, accuracy: 1e-12, "a place card follows no song")
        XCTAssertEqual(art.pulse(for: CreditLibrary.dunno), 60.0 / 48, accuracy: 1e-12)
        XCTAssertEqual(CardArt.rockGardenRings.count, 5, "the shakuhachi's five holes")
        XCTAssertTrue(CardArt.rockGardenRings.allSatisfy { $0 > 0.05 && $0 < 0.95 }, "across the pole")
        XCTAssertLessThan(CardArt.rockGardenPole.upperBound, 0.1, "along the top")
        XCTAssertEqual(CardArt.rockGardenGroups.count, 3, "three groups")
        XCTAssertEqual(CardArt.rockGardenGroups.reduce(0) { $0 + $1.stones.count }, 5, "five stones")
        for c in CreditLibrary.all { XCTAssertNotEqual(CardArt.art(for: c.id), art, c.id) }

        let card = InspiredByCard(place: SetLibrary.zenRockGarden)
        XCTAssertEqual(card.subject, .place(SetLibrary.zenRockGarden))
        XCTAssertEqual(card.art, .zenRockGarden)
        XCTAssertEqual(card.pulse, 60.0 / 48, accuracy: 1e-12)
        XCTAssertEqual(card.words.kicker, "BORN FROM A PLACE")
        XCTAssertEqual(card.words.title, "Zen Rock Garden")
        XCTAssertEqual(card.words.subtitle, "Ordered calm")
        XCTAssertNil(card.words.listen, "no Listen button")
        XCTAssertNil(card.words.linerNotes)
        XCTAssertNil(card.words.line)

        // The picture: it draws, it breathes, and it looks like no song card, nor like the tea house's.
        let a = try XCTUnwrap(Self.render(place: SetLibrary.zenRockGarden, at: 0.2))
        let s = PreviewRenderer.stats(a)
        XCTAssertGreaterThan(s.meanLuminance, 0.05)
        XCTAssertGreaterThan(s.variance, 0.001)
        let b = try XCTUnwrap(Self.render(place: SetLibrary.zenRockGarden, at: 2.2))
        let moved = PreviewRenderer.difference(a, b)
        if moved <= 0.001 { XCTFail("the garden card moved only \(moved)") }
        let place = try XCTUnwrap(Self.render(place: SetLibrary.zenRockGarden, at: 1.0))
        for c in CreditLibrary.all {
            let other = try XCTUnwrap(Self.render(c, at: 1.0), c.id)
            let d = PreviewRenderer.difference(place, other)
            if d <= 0.02 { XCTFail("the garden card and \(c.id) differ by only \(d)") }
        }
        let teaHouse = try XCTUnwrap(Self.render(place: SetLibrary.teaHouseSnow, at: 1.0))
        let fromTea = PreviewRenderer.difference(place, teaHouse)
        if fromTea <= 0.02 { XCTFail("the garden card and the tea house's differ by only \(fromTea)") }
    }

    /// "Stay" is felt in half time, so its card breathes at 67, not 134.
    func testStayCardBreathesAtHalfTempo() throws {
        let art = try XCTUnwrap(CardArt.art(for: CreditLibrary.stay.id))
        XCTAssertEqual(art.pulse(for: CreditLibrary.stay), 60.0 / 67, accuracy: 1e-9)
        XCTAssertEqual(CardArt.highByTheBeach.pulse(for: CreditLibrary.highByTheBeach), 60.0 / 132, accuracy: 1e-9)
    }

    /// "Dunno"'s motes twinkle on its beat, 82 BPM.
    func testDunnoCardTwinklesAtTempo() throws {
        let art = try XCTUnwrap(CardArt.art(for: CreditLibrary.dunno.id))
        XCTAssertNotEqual(art, CardArt.art(for: CreditLibrary.stay.id))
        XCTAssertEqual(art.pulse(for: CreditLibrary.dunno), 60.0 / 82, accuracy: 1e-9)
    }

    /// "Wings" is felt in half time (119 BPM, about 60), so its curtains ripple once a second.
    func testWingsCardRipplesAtHalfTempo() throws {
        let art = try XCTUnwrap(CardArt.art(for: CreditLibrary.wings.id))
        XCTAssertNotEqual(art, CardArt.art(for: CreditLibrary.stay.id))
        XCTAssertNotEqual(art, CardArt.art(for: CreditLibrary.dunno.id))
        XCTAssertEqual(art.pulse(for: CreditLibrary.wings), 60.0 / 60, accuracy: 1e-9)
        XCTAssertEqual(CardArt.wingsStars.count, CreditLibrary.wings.trackNumber, "one bright star per track number")
    }

    /// The Wings card's bright stars keep off the liner notes (top right).
    func testWingsStarsKeepOffTheLinerNotes() {
        let w: CGFloat = 600, h: CGFloat = 360
        let notes = CGRect(x: 0.6 * w, y: 0, width: 0.4 * w, height: 0.1 * h)
        for (fx, fy, r) in CardArt.wingsStars {
            let star = CGRect(x: fx * w - r, y: fy * h - r, width: 2 * r, height: 2 * r)
            XCTAssertFalse(star.intersects(notes), "star at (\(fx), \(fy)) covers the liner notes")
        }
    }

    /// "Happiness Is a Butterfly"'s thirteen motes (the track number) blink on its beat, 68 BPM.
    func testButterflyCardBlinksAtTempo() throws {
        let art = try XCTUnwrap(CardArt.art(for: CreditLibrary.happinessIsAButterfly.id))
        XCTAssertNotEqual(art, CardArt.art(for: CreditLibrary.wings.id))
        XCTAssertNotEqual(art, CardArt.art(for: CreditLibrary.highByTheBeach.id))
        XCTAssertEqual(art.pulse(for: CreditLibrary.happinessIsAButterfly), 60.0 / 68, accuracy: 1e-9)
        XCTAssertEqual(CardArt.butterflyMotes.count, CreditLibrary.happinessIsAButterfly.trackNumber, "one mote per track number")
    }

    /// The Butterfly card's motes keep off its words: the liner notes (top right), the title block (bottom left) and the
    /// Listen button, as the Stay card's frost does.
    func testButterflyMotesKeepOffTheWords() {
        let w: CGFloat = 600, h: CGFloat = 360
        let words = [CGRect(x: 0.6 * w, y: 0, width: 0.4 * w, height: 0.1 * h),          // D major · TRACK 13 · 68 BPM
                     CGRect(x: 0, y: 0.68 * h, width: 0.72 * w, height: 0.32 * h),        // Inspired by, title, credit, line
                     CGRect(x: 0.82 * w, y: 0.86 * h, width: 0.18 * w, height: 0.14 * h)] // Listen
        for (fx, fy, r) in CardArt.butterflyMotes {
            let mote = CGRect(x: fx * w - r, y: fy * h - r, width: 2 * r, height: 2 * r)
            for rect in words { XCTAssertFalse(mote.intersects(rect), "mote at (\(fx), \(fy)) covers \(rect)") }
        }
    }

    /// The Stay card's frost stars keep off its words: the liner notes (top right), the title block (bottom left) and
    /// the Listen button (final review: a star sat on "TRACK 3").
    func testStayFrostKeepsOffTheWords() {
        let w: CGFloat = 600, h: CGFloat = 360
        let words = [CGRect(x: 0.6 * w, y: 0, width: 0.4 * w, height: 0.1 * h),          // F♯ major · TRACK 3 · 134 BPM
                     CGRect(x: 0, y: 0.68 * h, width: 0.72 * w, height: 0.32 * h),        // Inspired by, title, credit, line
                     CGRect(x: 0.82 * w, y: 0.86 * h, width: 0.18 * w, height: 0.14 * h)] // Listen
        for (fx, fy, r) in CardArt.stayFrost {
            let star = CGRect(x: fx * w - r, y: fy * h - r, width: 2 * r, height: 2 * r)
            for rect in words { XCTAssertFalse(star.intersects(rect), "star at (\(fx), \(fy)) covers \(rect)") }
        }
    }

    /// The Dunno card's beam is light falling through the room, not a white wedge (final review: plus-lighter clipped it
    /// to white and swallowed the motes).
    func testDunnoBeamIsNotClippedToWhite() throws {
        let image = try XCTUnwrap(Self.render(CreditLibrary.dunno, at: 1.0))
        let beam = FramePatch.meanRGB(image, x: -0.1...0.1, y: -0.11...0)
        XCTAssertLessThan(min(beam.x, beam.y, beam.z), 0.9, "\(beam)")
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
