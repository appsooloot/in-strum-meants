import XCTest
@testable import InStrumCore

final class StarCatalogueTests: XCTestCase {
    func testCatalogueShape() {
        let stars = StarCatalogue.stars
        XCTAssertTrue((900...960).contains(stars.count), "\(stars.count) stars")
        XCTAssertEqual(Set(stars.map(\.hip)).count, stars.count, "one entry per HIP id")
        for s in stars {
            XCTAssertTrue(s.ra.isFinite && s.dec.isFinite && s.mag.isFinite && s.bv.isFinite, "HIP \(s.hip)")
            XCTAssertTrue((0..<360).contains(s.ra), "HIP \(s.hip) ra \(s.ra)")
            XCTAssertTrue((-90...90).contains(s.dec), "HIP \(s.hip) dec \(s.dec)")
            XCTAssertLessThanOrEqual(s.mag, 4.5)
            XCTAssertGreaterThan(s.hip, 0)
        }
        XCTAssertEqual(stars.map(\.mag), stars.map(\.mag).sorted(), "brightest first")
        XCTAssertEqual(StarCatalogue.star(hip: stars[10].hip), stars[10])
        XCTAssertNil(StarCatalogue.star(hip: 1))
    }

    func testBrightStarsArePresent() throws {
        let sirius = try XCTUnwrap(StarCatalogue.star(hip: 32349))
        XCTAssertLessThan(sirius.mag, -1)
        XCTAssertEqual(sirius.ra, 101.287, accuracy: 0.01)
        XCTAssertEqual(sirius.dec, -16.716, accuracy: 0.01)
        XCTAssertEqual(StarCatalogue.stars.first, sirius)
        XCTAssertEqual(StarCatalogue.names[32349], "Sirius")
        XCTAssertEqual(try XCTUnwrap(StarCatalogue.star(hip: 30438)).mag, -0.62, accuracy: 0.01)   // Canopus
        XCTAssertEqual(StarCatalogue.names[30438], "Canopus")
        for (hip, name, mag) in [(60718, "Acrux", 0.77), (61084, "Gacrux", 1.59), (62434, "Mimosa", 1.25), (71683, "Rigil Kentaurus", -0.01)] as [(Int32, String, Float)] {
            let s = try XCTUnwrap(StarCatalogue.star(hip: hip), name)
            XCTAssertEqual(s.mag, mag, accuracy: 0.01, name)
            XCTAssertEqual(StarCatalogue.names[hip], name)
            XCTAssertLessThan(s.dec, -55, "\(name) is a far-southern star")
        }
        XCTAssertNotNil(StarCatalogue.star(hip: 11767), "Polaris")
    }

    func testFiguresReferenceCatalogueStars() {
        let figures = ConstellationLines.figures
        XCTAssertGreaterThanOrEqual(figures.count, 26)
        for name in ["Crux", "Centaurus", "Orion", "Scorpius", "Sagittarius", "Ursa Major", "Cassiopeia", "Pegasus and Andromeda", "Pavo"] {
            XCTAssertTrue(figures.contains { $0.name == name }, name)
        }
        for f in figures {
            XCTAssertFalse(f.segments.isEmpty, f.name)
            XCTAssertNotNil(StarCatalogue.star(hip: f.labelHip), f.name)
            for (a, b) in f.segments {
                XCTAssertNotNil(StarCatalogue.star(hip: a), "\(f.name): HIP \(a)")
                XCTAssertNotNil(StarCatalogue.star(hip: b), "\(f.name): HIP \(b)")
                XCTAssertNotEqual(a, b, f.name)
            }
        }
        let crux = figures.first { $0.name == "Crux" }
        XCTAssertTrue(crux?.segments.contains { $0 == (60718, 61084) } ?? false, "Acrux–Gacrux")
        XCTAssertEqual(crux?.labelHip, 60718)
    }

    func testStarTextureIsDeterministicAndPutsSiriusThere() throws {
        let w = StarTexture.width, h = StarTexture.height
        XCTAssertEqual([w, h], [2048, 1024])
        let a = StarTexture.build(), b = StarTexture.build()
        XCTAssertEqual(a.count, w * h * 4)
        XCTAssertTrue(a == b, "deterministic")
        func brightness(_ x: Int, _ y: Int) -> Int {
            let xx = (x % w + w) % w, i = (y * w + xx) * 4
            return Int(a[i]) + Int(a[i + 1]) + Int(a[i + 2])
        }
        let sirius = try XCTUnwrap(StarCatalogue.star(hip: 32349))
        let p = StarTexture.pixel(ra: sirius.ra, dec: sirius.dec)
        XCTAssertEqual(p.x, Int(101.287 / 360 * 2048))
        XCTAssertEqual(p.y, Int((90 + 16.716) / 180 * 1024))
        let centre = brightness(p.x, p.y)
        for dy in -8...8 { for dx in -8...8 where dx != 0 || dy != 0 {
            XCTAssertLessThanOrEqual(brightness(p.x + dx, p.y + dy), centre, "Sirius's texel is the brightest near it (\(dx), \(dy))")
        } }
        let i = (p.y * w + p.x) * 4
        XCTAssertEqual(max(a[i], a[i + 1], a[i + 2]), 255, "Sirius peaks at 255")
        // The line from Acrux to Gacrux: its midpoint is drawn.
        let acrux = try XCTUnwrap(StarCatalogue.star(hip: 60718)), gacrux = try XCTUnwrap(StarCatalogue.star(hip: 61084))
        let m = StarTexture.pixel(ra: (acrux.ra + gacrux.ra) / 2, dec: (acrux.dec + gacrux.dec) / 2)
        var alpha: UInt8 = 0
        for dy in -1...1 { for dx in -1...1 { alpha = max(alpha, a[((m.y + dy) * w + m.x + dx) * 4 + 3]) } }
        XCTAssertGreaterThan(alpha, 128, "the Acrux–Gacrux line")
        // Lines stop short of the stars, and a build without lines has no alpha anywhere.
        let ac = StarTexture.pixel(ra: acrux.ra, dec: acrux.dec)
        XCTAssertEqual(a[(ac.y * w + ac.x) * 4 + 3], 0, "the line is trimmed clear of Acrux")
        let plain = StarTexture.build(lines: false)
        XCTAssertFalse(stride(from: 3, to: plain.count, by: 4).contains { plain[$0] != 0 })
        XCTAssertGreaterThan(stride(from: 0, to: plain.count, by: 4).filter { plain[$0] > 0 }.count, 1500, "every star leaves light")
    }

    /// A bright star is a point with a glow, not a ball: Sirius's core (the texels holding at least half its peak light,
    /// about where the night's tone curve clips it) spans at most 0.6° along Dec and along RA (× cos Dec), the same
    /// angle at any screen size (it is drawn on the sky, not in pixels); and the faint stars are still there.
    func testBrightStarsArePointsNotBalls() throws {
        let w = StarTexture.width, h = StarTexture.height
        let image = StarTexture.build(lines: false)
        // Light (linear: the texture holds its square root) in Sirius's brightest channel.
        func light(_ x: Int, _ y: Int) -> Double {
            let xx = (x % w + w) % w, i = (min(h - 1, max(0, y)) * w + xx) * 4
            let v = Double(max(image[i], image[i + 1], image[i + 2])) / 255
            return v * v
        }
        let sirius = try XCTUnwrap(StarCatalogue.star(hip: 32349))
        let p = StarTexture.pixel(ra: sirius.ra, dec: sirius.dec)
        let peak = light(p.x, p.y)
        XCTAssertEqual(peak, 1, accuracy: 1e-9)
        var rows = Set<Int>(), cols = Set<Int>()
        for dy in -20...20 { for dx in -20...20 where light(p.x + dx, p.y + dy) >= 0.5 * peak { rows.insert(dy); cols.insert(dx) } }
        let texel = 180.0 / Double(h)   // degrees of Dec per texel (RA: 360 / w, the same)
        let across = Double(cols.count) * texel * cos(Double(sirius.dec) * .pi / 180), tall = Double(rows.count) * texel
        XCTAssertLessThanOrEqual(tall, 0.6, "Sirius's core is \(tall)° tall")
        XCTAssertLessThanOrEqual(across, 0.6, "and \(across)° across")
        // The faint stars keep their light: the 20 faintest still leave a texel of a thousandth of Sirius's peak or more
        // (about 8 of 255 in the stored square root; they sit near 12).
        let faint = StarCatalogue.stars.suffix(20)
        for s in faint {
            let q = StarTexture.pixel(ra: s.ra, dec: s.dec)
            var best = 0.0
            for dy in -1...1 { for dx in -1...1 { best = max(best, light(q.x + dx, q.y + dy)) } }
            XCTAssertGreaterThanOrEqual(best, 0.001, "HIP \(s.hip) (mag \(s.mag)) still shows")
        }
    }

    func testStarTextureBuildsQuickly() {
        _ = StarCatalogue.stars   // the catalogue is built once, outside the timing
        let t0 = Date()
        let image = StarTexture.build()
        let seconds = Date().timeIntervalSince(t0)
        XCTAssertEqual(image.count, StarTexture.width * StarTexture.height * 4)
        #if DEBUG
        XCTAssertLessThan(seconds, 3)
        #else
        XCTAssertLessThan(seconds, 0.3)
        #endif
    }
}
