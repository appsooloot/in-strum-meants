import XCTest
@testable import InStrumCore

final class FrostFieldTests: XCTestCase {
    private let w = FrostField.width, h = FrostField.height

    func testDeterministic() {
        let a = FrostField(seed: 7, columns: 3, rows: 2, bar: 0.02)
        let b = FrostField(seed: 7, columns: 3, rows: 2, bar: 0.02)
        let c = FrostField(seed: 8, columns: 3, rows: 2, bar: 0.02)
        XCTAssertEqual(a.arrival.count, w * h)
        XCTAssertEqual(a.arrival, b.arrival)
        var differ = 0
        for i in 0..<a.arrival.count where abs(a.arrival[i] - c.arrival[i]) > 1e-6 { differ += 1 }
        XCTAssertGreaterThan(Double(differ) / Double(a.arrival.count), 0.2)
    }

    func testCornersFirstCentresLast() {
        for seed: UInt64 in [1, 2, 3] {
            let f = FrostField(seed: seed, columns: 3, rows: 2, bar: 0.02)
            for p in panes(columns: 3, rows: 2, bar: 0.02) {
                let corners = [(p.x0 + 2, p.y0 + 2), (p.x1 - 2, p.y0 + 2), (p.x0 + 2, p.y1 - 2), (p.x1 - 2, p.y1 - 2)]
                for (x, y) in corners {
                    XCTAssertLessThan(f.arrival[y * w + x], 0.05, "seed \(seed) corner \(x),\(y)")
                }
                let centre = f.arrival[((p.y0 + p.y1) / 2) * w + (p.x0 + p.x1) / 2]
                XCTAssertGreaterThan(centre, 0.6, "seed \(seed) pane at \(p.x0),\(p.y0)")
            }
        }
    }

    func testFrontsAreConnected() {
        let f = FrostField(seed: 5, columns: 3, rows: 2, bar: 0.02)
        let seeds = Set(f.seedCells)
        var lonely = 0
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                if seeds.contains(i) { continue }
                var ok = false
                for dy in -1...1 where !ok {
                    for dx in -1...1 where !(dx == 0 && dy == 0) {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, ny >= 0, nx < w, ny < h else { continue }
                        if f.arrival[ny * w + nx] <= f.arrival[i] { ok = true; break }
                    }
                }
                if !ok { lonely += 1 }
            }
        }
        XCTAssertEqual(lonely, 0, "cells the frost could not have grown into")
    }

    /// Arms along the seed's six axes arrive well before the directions halfway between them.
    func testSixFoldCrystals() {
        for seed: UInt64 in [1, 2, 3, 4] {
            let f = FrostField.single(seed: seed)
            let cx = Double(w / 2) + 0.5, cy = Double(h / 2) + 0.5
            // The frost reaching the neighbourhood of a point (needles are one cell wide).
            func near(_ angle: Double) -> Double {
                let px = Int((cx + 40 * cos(angle)).rounded(.down)), py = Int((cy + 40 * sin(angle)).rounded(.down))
                var m: Float = 9
                for dy in -1...1 { for dx in -1...1 { m = min(m, f.arrival[(py + dy) * w + px + dx]) } }
                return Double(m)
            }
            var best = 9.0
            for phase in 0..<60 {
                var on = 0.0, off = 0.0
                for k in 0..<6 {
                    let a = Double(phase + 60 * k) * .pi / 180
                    on += near(a)
                    off += near(a + .pi / 6)
                }
                best = min(best, on / off)
            }
            XCTAssertLessThan(best, 0.85, "seed \(seed)")
        }
    }

    func testBarsHaveNoFrost() {
        let f = FrostField(seed: 3, columns: 3, rows: 2, bar: 0.02)
        let p = panes(columns: 3, rows: 2, bar: 0.02)
        // The middle of the first vertical bar and of the horizontal bar.
        let barX = (Float(p[0].x1) + Float(p[1].x0) + 1) / 2 / Float(w)
        let barY = (Float(p[0].y1) + Float(p[3].y0) + 1) / 2 / Float(h)
        XCTAssertEqual(f.value(x: barX, y: 0.25), 0)
        XCTAssertEqual(f.value(x: 0.15, y: barY), 0)
        XCTAssertGreaterThan(f.value(x: 0.15, y: 0.25), 0.3, "a pane centre has frost to come")
    }

    func testValueIsBilinear() {
        let f = FrostField(seed: 4, columns: 1, rows: 1, bar: 0.02)
        let x = 100, y = 60
        let a = f.arrival[y * w + x], b = f.arrival[y * w + x + 1]
        // Halfway between two cell centres.
        let v = f.value(x: (Float(x) + 1.0) / Float(w), y: (Float(y) + 0.5) / Float(h))
        XCTAssertEqual(v, (a + b) / 2, accuracy: 1e-5)
        XCTAssertEqual(f.value(x: -1, y: 2), f.value(x: 0, y: 1), "outside clamps to the edge")
    }

    func testGeneratesQuickly() {
        let start = Date()
        _ = FrostField(seed: 11, columns: 3, rows: 2, bar: 0.02)
        let seconds = Date().timeIntervalSince(start)
        #if DEBUG
        XCTAssertLessThan(seconds, 1.5)
        #else
        XCTAssertLessThan(seconds, 0.15)
        #endif
    }

    // The panes' cell rectangles, as the field lays them out.
    private func panes(columns: Int, rows: Int, bar: Float) -> [(x0: Int, y0: Int, x1: Int, y1: Int)] {
        FrostField.paneRects(columns: columns, rows: rows, bar: bar).map { ($0.x0, $0.y0, $0.x1, $0.y1) }
    }
}
