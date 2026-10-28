import SwiftUI
import InStrumCore

/// Original living art for each "Inspired by" card, drawn in code from the song's feeling (never artwork,
/// photos or logos). The song's tempo is hidden in the motion: everything breathes at `pulsePeriod`.
enum CardArt {
    case comeBackToEarth, innerbloom

    static func art(for creditID: String) -> CardArt? {
        switch creditID {
        case CreditLibrary.comeBackToEarth.id: return .comeBackToEarth
        case CreditLibrary.innerbloom.id: return .innerbloom
        default: return nil
        }
    }

    /// How the card sets its title: an airy serif under water, a clean wide-tracked sans at dusk.
    var titleFont: Font {
        switch self {
        case .comeBackToEarth: return .system(size: 30, weight: .light, design: .serif)
        case .innerbloom: return .system(size: 24, weight: .medium, design: .default)
        }
    }

    var titleTracking: CGFloat { self == .innerbloom ? 7 : 0.5 }
    var titleCase: Bool { self == .innerbloom }

    func draw(in ctx: GraphicsContext, size: CGSize, t: Double, pulse: Double) {
        switch self {
        case .comeBackToEarth: Self.underwater(ctx, size, t, pulse)
        case .innerbloom: Self.bloom(ctx, size, t, pulse)
        }
    }

    // MARK: - Come Back to Earth: light under water, a ring rising to the surface

    private static func underwater(_ ctx: GraphicsContext, _ size: CGSize, _ t: Double, _ pulse: Double) {
        let rect = CGRect(origin: .zero, size: size)
        ctx.fill(Path(rect), with: .linearGradient(
            Gradient(colors: [Color(red: 0.55, green: 0.74, blue: 0.86), Color(red: 0.10, green: 0.30, blue: 0.48),
                              Color(red: 0.02, green: 0.07, blue: 0.16)]),
            startPoint: CGPoint(x: size.width * 0.5, y: 0), endPoint: CGPoint(x: size.width * 0.5, y: size.height)))

        // Light shafts from the surface.
        var shafts = ctx
        shafts.blendMode = .plusLighter
        for i in 0..<5 {
            let x = size.width * (0.12 + 0.2 * Double(i)) + 18 * sin(t * 0.21 + Double(i) * 1.7)
            var p = Path()
            p.move(to: CGPoint(x: x - 10, y: 0)); p.addLine(to: CGPoint(x: x + 14, y: 0))
            p.addLine(to: CGPoint(x: x + 70 + 20 * Double(i % 2), y: size.height)); p.addLine(to: CGPoint(x: x + 10, y: size.height))
            p.closeSubpath()
            shafts.fill(p, with: .linearGradient(Gradient(colors: [Color.white.opacity(0.16), Color.white.opacity(0)]),
                                                 startPoint: CGPoint(x: x, y: 0), endPoint: CGPoint(x: x + 40, y: size.height * 0.9)))
        }

        // Caustics: a net of bright lines where two octaves of noise cross a level.
        var caustic = ctx
        caustic.blendMode = .plusLighter
        caustic.addFilter(.blur(radius: 0.8))
        let rows = 16, steps = 72
        for r in 0..<rows {
            let depth = Double(r) / Double(rows - 1)
            var p = Path()
            for s in 0...steps {
                let x = size.width * Double(s) / Double(steps)
                let n = noise2(x * 0.012 + t * 0.12, depth * 3.1 + t * 0.05) * 0.65 + noise2(x * 0.03 - t * 0.2, depth * 7.3) * 0.35
                let y = size.height * (0.05 + 0.6 * depth) + (n - 0.5) * 34 * (1 - 0.6 * depth)
                if s == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
            }
            caustic.stroke(p, with: .color(Color(red: 0.8, green: 0.95, blue: 1.0).opacity(0.22 * (1 - depth) + 0.04)), lineWidth: 1.2)
        }

        // A slow ring rising and surfacing once every two beats.
        let cycle = 2 * pulse
        let k = (t.truncatingRemainder(dividingBy: cycle)) / cycle
        let cx = size.width * 0.72, cy = size.height * (0.92 - 0.8 * k)
        let radius = 14 + 40 * k
        var ring = ctx
        ring.blendMode = .plusLighter
        let ringRect = CGRect(x: cx - radius, y: cy - radius * 0.45, width: radius * 2, height: radius * 0.9)
        ring.stroke(Path(ellipseIn: ringRect), with: .color(.white.opacity(0.7 * (1 - k) * min(1, k * 6))), lineWidth: 2)
        // Surfacing: a brief brightening at the top.
        let surface = max(0, 1 - abs(k - 0.95) / 0.05)
        ring.fill(Path(rect), with: .linearGradient(Gradient(colors: [Color.white.opacity(0.12 * surface), .clear]),
                                                    startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height * 0.3)))
    }

    // MARK: - Innerbloom: petals of light opening from one point at dusk

    private static func bloom(_ ctx: GraphicsContext, _ size: CGSize, _ t: Double, _ pulse: Double) {
        let rect = CGRect(origin: .zero, size: size)
        ctx.fill(Path(rect), with: .linearGradient(
            Gradient(colors: [Color(red: 0.06, green: 0.03, blue: 0.14), Color(red: 0.24, green: 0.09, blue: 0.30),
                              Color(red: 0.62, green: 0.28, blue: 0.30)]),
            startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))

        let centre = CGPoint(x: size.width * 0.68, y: size.height * 0.46)
        // The bloom opens over eight beats and closes over the next eight; each beat lifts its light.
        let phase = t / (16 * pulse) * 2 * .pi
        let open = 0.35 + 0.65 * (0.5 - 0.5 * cos(phase))
        let beat = (t / pulse).truncatingRemainder(dividingBy: 1)
        let lift = 0.75 + 0.25 * exp(-beat * 4)

        var petals = ctx
        petals.blendMode = .plusLighter
        petals.addFilter(.blur(radius: 1.5))
        let count = 9
        for i in 0..<count {
            let a = Double(i) / Double(count) * 2 * .pi + t * 0.05
            let length = (36 + 70 * open) * (0.85 + 0.15 * sin(Double(i) * 2.3))
            let width = 10 + 16 * open
            var p = Path()
            p.move(to: .zero)
            p.addQuadCurve(to: CGPoint(x: length, y: 0), control: CGPoint(x: length * 0.5, y: -width))
            p.addQuadCurve(to: .zero, control: CGPoint(x: length * 0.5, y: width))
            let transform = CGAffineTransform(translationX: centre.x, y: centre.y).rotated(by: a)
            let hueShift = Double(i) / Double(count)
            let colour = Color(red: 0.95, green: 0.55 + 0.25 * hueShift, blue: 0.65 + 0.3 * (1 - hueShift))
            petals.fill(p.applying(transform), with: .color(colour.opacity(0.22 * lift)))
            petals.stroke(p.applying(transform), with: .color(colour.opacity(0.35 * lift)), lineWidth: 0.8)
        }
        var core = ctx
        core.blendMode = .plusLighter
        core.fill(Path(ellipseIn: CGRect(x: centre.x - 40, y: centre.y - 40, width: 80, height: 80)),
                  with: .radialGradient(Gradient(colors: [Color.white.opacity(0.7 * lift), Color(red: 1, green: 0.7, blue: 0.8).opacity(0)]),
                                        center: centre, startRadius: 0, endRadius: 40))
        // A low horizon of dusk light.
        core.fill(Path(CGRect(x: 0, y: size.height * 0.82, width: size.width, height: size.height * 0.18)),
                  with: .linearGradient(Gradient(colors: [Color(red: 1, green: 0.6, blue: 0.45).opacity(0), Color(red: 1, green: 0.6, blue: 0.45).opacity(0.18)]),
                                        startPoint: CGPoint(x: 0, y: size.height * 0.82), endPoint: CGPoint(x: 0, y: size.height)))
    }

    // MARK: - Noise

    private static func hash(_ x: Int, _ y: Int) -> Double {
        var h = UInt32(truncatingIfNeeded: x &* 374_761_393 &+ y &* 668_265_263)
        h = (h ^ (h >> 13)) &* 1_274_126_177
        return Double(h ^ (h >> 16)) / Double(UInt32.max)
    }

    /// Smooth value noise, 0…1.
    static func noise2(_ x: Double, _ y: Double) -> Double {
        let xi = Int(floor(x)), yi = Int(floor(y))
        let fx = x - floor(x), fy = y - floor(y)
        let u = fx * fx * (3 - 2 * fx), v = fy * fy * (3 - 2 * fy)
        let a = hash(xi, yi), b = hash(xi + 1, yi), c = hash(xi, yi + 1), d = hash(xi + 1, yi + 1)
        return (a + (b - a) * u) + ((c + (d - c) * u) - (a + (b - a) * u)) * v
    }
}
