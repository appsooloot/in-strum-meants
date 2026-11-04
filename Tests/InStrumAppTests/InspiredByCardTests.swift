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
        XCTAssertEqual(SetLibrary.all.count, 8)
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

    /// Tea House Snow as Sets 9 & 10 will add it to `SetLibrary` (spec §2, §8.1, §10): born from its place, so no credit.
    static var teaHouse: InStrumSet {
        InStrumSet(id: "tea-house-snow", name: "Tea House Snow", moodName: "Delicate, hushed",
                   mood: Mood(energy: 0.2, warmth: 0.55, brightness: 0.5, space: 0.3, motion: 0.2),
                   worldID: "tea-house-snow", visual: "Steam Lines", patchID: "tea-house-koto",
                   ambience: AmbienceSettings(), creditID: nil)
    }

    /// Every set shows one card: its song's, or (born from its place, no credit) its place card.
    func testEverySetHasACardOrPlaceArt() {
        for set in SetLibrary.all + [Self.teaHouse] {
            if let credit = set.creditID {
                XCTAssertNotNil(CardArt.art(for: credit), "\(set.id) has no song card")
                XCTAssertNil(CardArt.place(for: set.id), "\(set.id) has a song card and a place card")
            } else {
                XCTAssertNotNil(CardArt.place(for: set.id), "\(set.id) has no credit and no place card")
            }
        }
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

        let card = InspiredByCard(place: Self.teaHouse)
        XCTAssertEqual(card.subject, .place(Self.teaHouse))
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
        let a = try XCTUnwrap(Self.render(place: Self.teaHouse, at: 0.2))
        let s = PreviewRenderer.stats(a)
        XCTAssertGreaterThan(s.meanLuminance, 0.05)
        XCTAssertGreaterThan(s.variance, 0.001)
        let b = try XCTUnwrap(Self.render(place: Self.teaHouse, at: 2.2))
        let moved = PreviewRenderer.difference(a, b)
        if moved <= 0.001 { XCTFail("the tea house card moved only \(moved)") }
        let place = try XCTUnwrap(Self.render(place: Self.teaHouse, at: 1.0))
        for c in CreditLibrary.all {
            let other = try XCTUnwrap(Self.render(c, at: 1.0), c.id)
            let d = PreviewRenderer.difference(place, other)
            if d <= 0.02 { XCTFail("the tea house card and \(c.id) differ by only \(d)") }
        }
    }

    /// The credit for "Underwater" (spec §11), exactly: words and a link only.
    func testUnderwaterCredit() {
        let c = CreditLibrary.underwater
        XCTAssertEqual(c.id, "underwater")
        XCTAssertEqual(c.song, "Underwater")
        XCTAssertEqual(c.artist, "RÜFÜS DU SOL")
        XCTAssertEqual(c.album, "Solace")
        XCTAssertEqual(c.year, 2018)
        XCTAssertEqual(c.trackNumber, 7)
        XCTAssertEqual(c.key, "F♯ minor")
        XCTAssertEqual(c.tempoBPM, 118)
        XCTAssertEqual(c.line, "The blinking, echoing arp that starts it, murky as deep water.")
        XCTAssertEqual(CreditLibrary.credit(id: "underwater"), c)
        XCTAssertTrue(CreditLibrary.all.contains(c))
        XCTAssertEqual(c.artist, CreditLibrary.innerbloom.artist, "spelled as the band's other credit")
        // The card says it in words: the song, the band, the album and its year, and the liner notes.
        let card = InspiredByCard(credit: c)
        XCTAssertEqual(card.words.kicker, "INSPIRED BY")
        XCTAssertEqual(card.words.title, "Underwater")
        XCTAssertEqual(card.words.subtitle, "RÜFÜS DU SOL · Solace · 2018")
        XCTAssertEqual(card.words.linerNotes, "F♯ minor · TRACK 7 · 118 BPM")
        XCTAssertEqual(card.words.line, c.line)
        XCTAssertEqual(card.words.listen, c)
    }

    /// The "Underwater" card is original abstract art (nothing from the album art, the lyrics or the short film): a
    /// deep-blue field with three easter eggs. Sonar rings pulse on the song's beat (one leaves the centre every 60/118 s
    /// and the picture repeats exactly once a beat), seven bubbles rise (the track number), and a sweep rests at F♯
    /// (pitch class 6 of 12, opposite C at the top) on a faint twelve-tick dial (the key). The bubbles keep off the
    /// words, and the card looks like no other song card.
    func testUnderwaterCardEasterEggs() throws {
        let credit = CreditLibrary.underwater
        let art = try XCTUnwrap(CardArt.art(for: credit.id))
        XCTAssertEqual(art, .underwater)
        XCTAssertFalse(art.isPlace)
        XCTAssertFalse(art.titleCase)
        // The rings' pulse: 60/118 s, the card's breath.
        let beat = 60.0 / 118
        XCTAssertEqual(art.pulse(for: credit), beat, accuracy: 1e-12)
        XCTAssertEqual(InspiredByCard(credit: credit).pulse, beat, accuracy: 1e-12)
        for t in [0.13, 1.0, 2.4, 7.77] {
            let now = CardArt.sonarRings(at: t, pulse: beat)
            let next = CardArt.sonarRings(at: t + beat, pulse: beat)
            let half = CardArt.sonarRings(at: t + beat / 2, pulse: beat)
            XCTAssertEqual(now.count, 3)
            XCTAssertEqual(next.count, 3)
            XCTAssertEqual(half.count, 3)
            guard now.count == 3, next.count == 3, half.count == 3 else { continue }
            for j in 0..<3 {
                XCTAssertEqual(now[j].radius, next[j].radius, accuracy: 1e-9, "a beat later the rings are where they were (t \(t))")
                XCTAssertEqual(now[j].opacity, next[j].opacity, accuracy: 1e-9)
            }
            XCTAssertGreaterThan(abs(now[0].radius - half[0].radius), 0.1, "half a beat later they have moved on (t \(t))")
        }
        let leaving = CardArt.sonarRings(at: 3 * beat + 1e-6, pulse: beat)   // just after a beat
        XCTAssertLessThan(leaving.first?.radius ?? 1, 0.06, "a ring leaves the centre on the beat")
        XCTAssertGreaterThan(leaving.first?.opacity ?? 0, 0.5)
        XCTAssertTrue(leaving.allSatisfy { $0.radius < 1.5 && $0.opacity >= 0 }, "and fades out as it spreads past the dial")
        // Seven bubbles: the track number.
        XCTAssertEqual(CardArt.underwaterBubbles.count, 7)
        XCTAssertEqual(CardArt.underwaterBubbles.count, credit.trackNumber)
        // The sweep rests at F♯: pitch class 6 of the dial's 12 ticks, C at the top and round clockwise, so it points
        // straight down.
        XCTAssertEqual(CardArt.underwaterDialTicks, 12)
        XCTAssertEqual(CardArt.underwaterSweep, 6)
        XCTAssertTrue(credit.key.hasPrefix("F♯"), "the key's tonic")
        XCTAssertEqual(CardArt.dialAngle(0), -Double.pi / 2, accuracy: 1e-12, "C at the top")
        XCTAssertEqual(CardArt.dialAngle(3), 0, accuracy: 1e-12, "D♯ at the right")
        XCTAssertEqual(CardArt.dialAngle(CardArt.underwaterSweep), Double.pi / 2, accuracy: 1e-12, "F♯ at the bottom")

        // The bubbles keep off the words (the liner notes, the title block and the Listen button), wherever they are in
        // their rise; and the sonar's sweep keeps off them too.
        let w: CGFloat = 600, h: CGFloat = 360
        let words = [CGRect(x: 0.6 * w, y: 0, width: 0.4 * w, height: 0.1 * h),          // F♯ minor · TRACK 7 · 118 BPM
                     CGRect(x: 0, y: 0.68 * h, width: 0.72 * w, height: 0.32 * h),        // Inspired by, title, credit, line
                     CGRect(x: 0.82 * w, y: 0.86 * h, width: 0.18 * w, height: 0.14 * h)] // Listen
        for b in CardArt.underwaterBubbles {
            let r: CGFloat = 1.15 * b.radius   // at the top of its rise
            let span = CGRect(x: b.x * w - 5 - r, y: 0.06 * h - r, width: 10 + 2 * r, height: 0.58 * h + 2 * r)
            for rect in words { XCTAssertFalse(span.intersects(rect), "the bubble at x \(b.x) crosses \(rect)") }
        }
        let sonar = CardArt.underwaterSonar
        let sweep = CGRect(x: sonar.x * w - 1, y: sonar.y * h, width: 2, height: sonar.radius * h + 1)
        for rect in words { XCTAssertFalse(sweep.intersects(rect), "the sweep crosses \(rect)") }

        // The picture: it draws, it moves, and it looks like no other song card.
        let a = try XCTUnwrap(Self.render(credit, at: 0.2))
        let stats = PreviewRenderer.stats(a)
        XCTAssertGreaterThan(stats.meanLuminance, 0.05)
        XCTAssertGreaterThan(stats.variance, 0.001)
        let b = try XCTUnwrap(Self.render(credit, at: 2.2))
        let moved = PreviewRenderer.difference(a, b)
        if moved <= 0.001 { XCTFail("the Underwater card moved only \(moved)") }
        let mine = try XCTUnwrap(Self.render(credit, at: 1.0))
        for c in CreditLibrary.all where c.id != credit.id {
            let other = try XCTUnwrap(Self.render(c, at: 1.0), c.id)
            let d = PreviewRenderer.difference(mine, other)
            if d <= 0.02 { XCTFail("the Underwater card and \(c.id) differ by only \(d)") }
        }
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
