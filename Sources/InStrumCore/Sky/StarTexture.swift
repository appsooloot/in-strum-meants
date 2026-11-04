import Foundation

/// The real stars and the constellation lines as an equirectangular RGBA8 image (CPU-built, deterministic):
/// x = RA 0…360° west to east (x = ra / 360 · width), row 0 = Dec +90°, row height−1 = Dec −90°.
///
/// RGB is the summed starlight, **stored as the square root of linear light** (a gamma-2 encoding, so stars down to
/// magnitude 4.5 survive 8 bits; the shader squares it back, no `pow`). Each star is a Gaussian footprint of radius
/// 1.0 + 0.2 · max(0, 2.5 − mag) px (round on the sky: wider in x toward the poles), with an amplitude ∝ 10^(−0.4·mag)
/// scaled so Sirius peaks at 255 in its brightest channel, coloured by its B−V index. A bright star shows its
/// brightness, not its size: even Sirius's core (where it is over half its peak) is about 0.4° across, a point whose glow
/// is the bloom's (the spec's 0.9 px a magnitude made it a soft ball well over a degree across).
/// Alpha is the constellation lines: 1-pixel anti-aliased great-circle segments, shortened 1.2° at each star
/// (30% of the side on sides shorter than 4°), split where they cross RA 0/360.
public enum StarTexture {
    public static let width = 2048, height = 1024

    /// The texel holding (ra, dec) in degrees.
    public static func pixel(ra: Float, dec: Float) -> (x: Int, y: Int) {
        let p = position(ra: ra, dec: dec)
        var x = Int(floor(p.x)) % width
        if x < 0 { x += width }
        return (x, min(height - 1, max(0, Int(floor(p.y)))))
    }

    /// Continuous texel coordinates (texel centres at +0.5).
    static func position(ra: Float, dec: Float) -> (x: Float, y: Float) {
        (ra / 360 * Float(width), (90 - dec) / 180 * Float(height))
    }

    /// A star's colour from its B−V index (brightest channel 1).
    static func colour(bv: Float) -> SIMD3<Float> {
        let blue = SIMD3<Float>(0.72, 0.8, 1.0), white = SIMD3<Float>(1, 0.98, 0.9), red = SIMD3<Float>(1, 0.78, 0.55)
        if bv <= -0.3 { return blue }
        if bv < 0.6 { return blue + (white - blue) * ((bv + 0.3) / 0.9) }
        if bv < 1.6 { return white + (red - white) * ((bv - 0.6) / 1.0) }
        return red
    }

    static func radius(mag: Float) -> Float { 1.0 + 0.2 * max(0, 2.5 - mag) }

    /// Builds the image (`width` × `height` × 4 bytes). `lines: false` leaves alpha at 0.
    public static func build(lines: Bool = true) -> [UInt8] {
        let w = width, h = height
        var light = [Float](repeating: 0, count: w * h * 3)
        // Sirius peaks at 1.0 (255) in its brightest channel.
        let sirius = StarCatalogue.star(hip: 32349) ?? Star(ra: 101.287, dec: -16.716, mag: -1.44, bv: 0.009, hip: 32349)
        let siriusColour = colour(bv: sirius.bv)
        let siriusFlux = Float(pow(10.0, Double(-0.4 * sirius.mag)))
        let siriusPeak: Float = max(siriusColour.x, siriusColour.y, siriusColour.z)
        let gain: Float = 1 / (siriusFlux * siriusPeak)

        light.withUnsafeMutableBufferPointer { buf in
            for star in StarCatalogue.stars {
                let flux = Float(pow(10.0, Double(-0.4 * star.mag)))
                let c = colour(bv: star.bv) * (gain * flux)
                let r = radius(mag: star.mag)
                let p = position(ra: star.ra, dec: star.dec)
                let squeeze = max(0.05, cos(star.dec * .pi / 180))   // x texels shrink by cos(dec) on the sky
                let reachY = Int(ceil(r * 1.5)), reachX = min(w / 2, Int(ceil(r * 1.5 / squeeze)))
                let cx = Int(floor(p.x)), cy = Int(floor(p.y))
                let inv = 2 / (r * r)
                for y in max(0, cy - reachY)...min(h - 1, cy + reachY) {
                    let dy = Float(y) + 0.5 - p.y
                    for xi in (cx - reachX)...(cx + reachX) {
                        let dx = (Float(xi) + 0.5 - p.x) * squeeze
                        let d2 = dx * dx + dy * dy
                        let k = exp(-d2 * inv)
                        if k < 0.002 { continue }
                        var x = xi % w
                        if x < 0 { x += w }
                        let i = (y * w + x) * 3
                        buf[i] += c.x * k; buf[i + 1] += c.y * k; buf[i + 2] += c.z * k
                    }
                }
            }
        }

        // Exactly 255 at Sirius's own texel (its centre seldom falls on a texel centre).
        let sp = pixel(ra: sirius.ra, dec: sirius.dec), si = (sp.y * w + sp.x) * 3
        let peak = max(light[si], light[si + 1], light[si + 2])
        let norm: Float = peak > 0 ? 1 / peak : 1

        var out = [UInt8](repeating: 0, count: w * h * 4)
        out.withUnsafeMutableBufferPointer { o in
            light.withUnsafeBufferPointer { l in
                for p in 0..<(w * h) {
                    let r = l[p * 3] * norm, g = l[p * 3 + 1] * norm, b = l[p * 3 + 2] * norm
                    if r == 0 && g == 0 && b == 0 { continue }
                    o[p * 4] = encode(r); o[p * 4 + 1] = encode(g); o[p * 4 + 2] = encode(b)
                }
            }
            if lines { drawLines(into: o) }
        }
        return out
    }

    private static func encode(_ v: Float) -> UInt8 { UInt8(min(255, (min(1, max(0, v)).squareRoot() * 255).rounded())) }

    /// A unit vector for (ra, dec) in degrees.
    private static func unit(ra: Float, dec: Float) -> SIMD3<Double> {
        let a = Double(ra) * .pi / 180, d = Double(dec) * .pi / 180
        return SIMD3(cos(d) * cos(a), cos(d) * sin(a), sin(d))
    }

    /// Texel coordinates of a unit vector.
    private static func texel(_ v: SIMD3<Double>) -> (x: Float, y: Float) {
        var ra = atan2(v.y, v.x) * 180 / .pi
        if ra < 0 { ra += 360 }
        let dec = asin(min(1, max(-1, v.z))) * 180 / .pi
        return position(ra: Float(ra), dec: Float(dec))
    }

    private static func drawLines(into o: UnsafeMutableBufferPointer<UInt8>) {
        let step = 0.25 * Double.pi / 180
        for figure in ConstellationLines.figures {
            for (ha, hb) in figure.segments {
                guard let a = StarCatalogue.star(hip: ha), let b = StarCatalogue.star(hip: hb) else { continue }
                let u = unit(ra: a.ra, dec: a.dec), v = unit(ra: b.ra, dec: b.dec)
                let angle = acos(min(1, max(-1, (u * v).sum())))
                // 1.2° clear of each star (less on the shortest sides, such as Vega's to ζ Lyrae, so they still show).
                let trim = min(1.2 * Double.pi / 180, 0.3 * angle)
                guard angle > 2 * trim, sin(angle) > 1e-9 else { continue }
                // Walk the great circle from one trimmed end to the other in ~0.25° pieces.
                let n = max(1, Int(ceil((angle - 2 * trim) / step)))
                func at(_ theta: Double) -> SIMD3<Double> {
                    (u * sin(angle - theta) + v * sin(theta)) / sin(angle)
                }
                var prev = texel(at(trim))
                for i in 1...n {
                    let next = texel(at(trim + (angle - 2 * trim) * Double(i) / Double(n)))
                    var nx = next.x
                    // Split across RA 0/360: draw unwrapped, written modulo the width.
                    if nx - prev.x > Float(width) / 2 { nx -= Float(width) } else if prev.x - nx > Float(width) / 2 { nx += Float(width) }
                    segment(prev.x, prev.y, nx, next.y, into: o)
                    prev = next
                }
            }
        }
    }

    /// An anti-aliased 1-pixel line in texel space (alpha = 1 − distance), keeping the brightest coverage.
    private static func segment(_ x0: Float, _ y0: Float, _ x1: Float, _ y1: Float, into o: UnsafeMutableBufferPointer<UInt8>) {
        let minX = Int(floor(min(x0, x1) - 1.5)), maxX = Int(ceil(max(x0, x1) + 1.5))
        let minY = max(0, Int(floor(min(y0, y1) - 1.5))), maxY = min(height - 1, Int(ceil(max(y0, y1) + 1.5)))
        guard minY <= maxY else { return }
        let ex = x1 - x0, ey = y1 - y0, len2 = max(1e-6, ex * ex + ey * ey)
        for y in minY...maxY {
            let py = Float(y) + 0.5
            for xi in minX...maxX {
                let px = Float(xi) + 0.5
                let t = min(1, max(0, ((px - x0) * ex + (py - y0) * ey) / len2))
                let dx = px - (x0 + ex * t), dy = py - (y0 + ey * t)
                let cover = 1 - (dx * dx + dy * dy).squareRoot()
                if cover <= 0 { continue }
                var x = xi % width
                if x < 0 { x += width }
                let i = (y * width + x) * 4 + 3
                let a = UInt8((min(1, cover) * 255).rounded())
                if a > o[i] { o[i] = a }
            }
        }
    }
}
