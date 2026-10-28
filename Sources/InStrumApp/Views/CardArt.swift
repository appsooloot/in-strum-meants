import SwiftUI
import InStrumCore

/// Original living art for each "Inspired by" card, drawn in code from the song's feeling (never artwork,
/// photos or logos). The song's tempo is hidden in the motion: everything breathes at `pulsePeriod`.
enum CardArt {
    case comeBackToEarth, innerbloom, musicToWatchBoysTo, highByTheBeach, stay

    static func art(for creditID: String) -> CardArt? {
        switch creditID {
        case CreditLibrary.comeBackToEarth.id: return .comeBackToEarth
        case CreditLibrary.innerbloom.id: return .innerbloom
        case CreditLibrary.musicToWatchBoysTo.id: return .musicToWatchBoysTo
        case CreditLibrary.highByTheBeach.id: return .highByTheBeach
        case CreditLibrary.stay.id: return .stay
        default: return nil
        }
    }

    /// How the card sets its title: an airy serif under water, a clean wide-tracked sans at dusk, a lush
    /// high-contrast retro serif in the golden haze.
    var titleFont: Font {
        switch self {
        case .comeBackToEarth: return .system(size: 30, weight: .light, design: .serif)
        case .innerbloom: return .system(size: 24, weight: .medium, design: .default)
        case .musicToWatchBoysTo: return .custom("Didot", size: 30)
        case .highByTheBeach: return .custom("Futura-CondensedMedium", size: 28)
        case .stay: return .system(size: 30, weight: .regular, design: .serif)
        }
    }

    var titleTracking: CGFloat {
        switch self {
        case .innerbloom: return 7
        case .musicToWatchBoysTo: return 1.5
        case .highByTheBeach: return 3
        case .comeBackToEarth: return 0.5
        case .stay: return 1
        }
    }

    /// How long one breath of the card lasts: a beat of the song, except "Stay", which is felt in half time
    /// (134 BPM played as 67), so its snow falls at 60/67 s.
    func pulse(for credit: Credit) -> Double {
        self == .stay ? 2 * credit.pulsePeriod : credit.pulsePeriod
    }
    var titleCase: Bool { self == .innerbloom }

    func draw(in ctx: GraphicsContext, size: CGSize, t: Double, pulse: Double) {
        switch self {
        case .comeBackToEarth: Self.underwater(ctx, size, t, pulse)
        case .innerbloom: Self.bloom(ctx, size, t, pulse)
        case .musicToWatchBoysTo: Self.goldenHaze(ctx, size, t, pulse)
        case .highByTheBeach: Self.coastLine(ctx, size, t, pulse)
        case .stay: Self.cabinWindow(ctx, size, t, pulse)
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

    // MARK: - Music to Watch Boys To: a golden heat-shimmer over a soft horizon, wobbling like old tape

    private static func goldenHaze(_ ctx: GraphicsContext, _ size: CGSize, _ t: Double, _ pulse: Double) {
        let rect = CGRect(origin: .zero, size: size)
        // The whole picture sways a little, like a tape replaying slightly unevenly: once every two beats.
        let wobble = 2.2 * sin(2 * .pi * t / (2 * pulse)) + 0.8 * sin(2 * .pi * t / 7.3)
        let horizon = size.height * 0.6 + wobble
        ctx.fill(Path(rect), with: .linearGradient(
            Gradient(stops: [.init(color: Color(red: 0.96, green: 0.78, blue: 0.74), location: 0),
                             .init(color: Color(red: 0.99, green: 0.74, blue: 0.47), location: 0.5),
                             .init(color: Color(red: 1.0, green: 0.83, blue: 0.52), location: 0.6),
                             .init(color: Color(red: 0.62, green: 0.34, blue: 0.33), location: 0.62),
                             .init(color: Color(red: 0.22, green: 0.10, blue: 0.15), location: 1)]),
            startPoint: CGPoint(x: 0, y: wobble), endPoint: CGPoint(x: 0, y: size.height + wobble)))

        // A low sun, softened by the haze.
        let sun = CGPoint(x: size.width * 0.3, y: horizon - size.height * 0.07)
        var glow = ctx
        glow.blendMode = .plusLighter
        glow.fill(Path(ellipseIn: CGRect(x: sun.x - 120, y: sun.y - 70, width: 240, height: 140)),
                  with: .radialGradient(Gradient(colors: [Color(red: 1, green: 0.85, blue: 0.6).opacity(0.55), .clear]),
                                        center: sun, startRadius: 0, endRadius: 120))
        glow.fill(Path(ellipseIn: CGRect(x: sun.x - 22, y: sun.y - 20, width: 44, height: 40)),
                  with: .color(Color(red: 1, green: 0.93, blue: 0.78).opacity(0.85)))

        // Heat shimmer: thin bands above the horizon whose edges ripple slowly.
        var shimmer = ctx
        shimmer.blendMode = .plusLighter
        for i in 0..<14 {
            let y0 = horizon - 6 - Double(i) * size.height * 0.035
            var p = Path()
            let steps = 60
            for s in 0...steps {
                let x = size.width * Double(s) / Double(steps)
                let n = noise2(x * 0.02 + t * 0.35, Double(i) * 1.7 + t * 0.15) - 0.5
                let y = y0 + 3.5 * n + 1.2 * sin(x * 0.05 + t * 1.3 + Double(i))
                if s == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
            }
            let fade = 1 - Double(i) / 14
            shimmer.stroke(p, with: .color(Color(red: 1, green: 0.9, blue: 0.75).opacity(0.10 * fade)), lineWidth: 1.4)
        }

        // Honey and rose bands drifting across the water.
        var bands = ctx
        bands.blendMode = .plusLighter
        bands.addFilter(.blur(radius: 2))
        for i in 0..<9 {
            let depth = Double(i) / 8
            let y = horizon + 6 + depth * depth * (size.height - horizon - 10)
            let speed = 6 + 18 * depth
            let span = size.width * (0.25 + 0.2 * noise2(Double(i) * 3.1, 0.5))
            let x = (Double(i) * 97 + t * speed).truncatingRemainder(dividingBy: size.width + span) - span
            let rose = i % 3 == 1
            let colour = rose ? Color(red: 1, green: 0.62, blue: 0.66) : Color(red: 1, green: 0.8, blue: 0.45)
            bands.fill(Path(roundedRect: CGRect(x: x, y: y, width: span, height: 2 + 5 * depth), cornerRadius: 3),
                       with: .color(colour.opacity(0.28 * (1 - 0.5 * depth))))
        }
        // The sun's path on the water, breaking up as it nears.
        var path = ctx
        path.blendMode = .plusLighter
        for k in 0..<22 {
            let d = Double(k) / 21
            let y = horizon + 3 + d * d * (size.height - horizon - 6)
            let w = 10 + 70 * d
            let jitter = 9 * (noise2(Double(k) * 0.7, t * 0.6) - 0.5) * (0.3 + d)
            path.fill(Path(CGRect(x: sun.x - w / 2 + jitter, y: y, width: w, height: 1.5 + 2.5 * d)),
                      with: .color(Color(red: 1, green: 0.9, blue: 0.7).opacity(0.35 * (1 - 0.6 * d))))
        }
    }

    // MARK: - High by the Beach: one road curving along a dark coast, one light travelling it at the pulse

    private static func coastLine(_ ctx: GraphicsContext, _ size: CGSize, _ t: Double, _ pulse: Double) {
        let rect = CGRect(origin: .zero, size: size)
        let w = size.width, h = size.height
        ctx.fill(Path(rect), with: .linearGradient(
            Gradient(stops: [.init(color: Color(red: 0.02, green: 0.03, blue: 0.10), location: 0),
                             .init(color: Color(red: 0.07, green: 0.12, blue: 0.27), location: 0.52),
                             .init(color: Color(red: 0.16, green: 0.20, blue: 0.36), location: 0.55),
                             .init(color: Color(red: 0.02, green: 0.05, blue: 0.12), location: 1)]),
            startPoint: .zero, endPoint: CGPoint(x: 0, y: h)))
        // A few faint stars.
        for i in 0..<26 {
            let x = w * noise2(Double(i) * 7.1, 0.3), y = h * 0.48 * noise2(Double(i) * 3.3, 9.1)
            let twinkle = 0.5 + 0.5 * sin(t * 1.3 + Double(i))
            ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1.6, height: 1.6)), with: .color(.white.opacity(0.15 + 0.25 * twinkle)))
        }
        // The coast: a dark headland sweeping in from the left and out to a point on the right.
        let a = CGPoint(x: -10, y: h * 0.98), c1 = CGPoint(x: w * 0.25, y: h * 0.55), c2 = CGPoint(x: w * 0.55, y: h * 0.82)
        let b = CGPoint(x: w * 0.98, y: h * 0.58)
        var land = Path()
        land.move(to: CGPoint(x: -10, y: h + 10)); land.addLine(to: CGPoint(x: -10, y: a.y - 40))
        land.addCurve(to: CGPoint(x: b.x + 20, y: b.y - 22), control1: CGPoint(x: c1.x, y: c1.y - 40), control2: CGPoint(x: c2.x, y: c2.y - 30))
        land.addLine(to: CGPoint(x: w + 10, y: h + 10)); land.closeSubpath()
        ctx.fill(land, with: .color(Color(red: 0.01, green: 0.02, blue: 0.05)))
        // The road along it.
        var road = Path()
        road.move(to: a); road.addCurve(to: b, control1: c1, control2: c2)
        ctx.stroke(road, with: .color(Color(red: 0.75, green: 0.82, blue: 1).opacity(0.35)), style: StrokeStyle(lineWidth: 1.4, dash: [7, 6]))
        // One light travels the road every eight beats, brightening on each beat.
        let u = (t / (8 * pulse)).truncatingRemainder(dividingBy: 1)
        func bezier(_ s: Double) -> CGPoint {
            let m = 1 - s
            return CGPoint(x: m * m * m * a.x + 3 * m * m * s * c1.x + 3 * m * s * s * c2.x + s * s * s * b.x,
                           y: m * m * m * a.y + 3 * m * m * s * c1.y + 3 * m * s * s * c2.y + s * s * s * b.y)
        }
        let p = bezier(u)
        let beat = (t / pulse).truncatingRemainder(dividingBy: 1)
        let glow = 0.6 + 0.4 * exp(-beat * 5)
        var light = ctx
        light.blendMode = .plusLighter
        light.fill(Path(ellipseIn: CGRect(x: p.x - 26, y: p.y - 26, width: 52, height: 52)),
                   with: .radialGradient(Gradient(colors: [Color(red: 1, green: 0.85, blue: 0.6).opacity(0.5 * glow), .clear]),
                                         center: p, startRadius: 0, endRadius: 26))
        light.fill(Path(ellipseIn: CGRect(x: p.x - 2.5, y: p.y - 2.5, width: 5, height: 5)), with: .color(.white.opacity(glow)))
        // Its reflection, broken up on the sea.
        let q = CGPoint(x: p.x, y: h * 0.55 + (h * 0.55 - p.y) * -0.35 + 4)
        for k in 0..<5 {
            light.fill(Path(CGRect(x: q.x - 6 + 3 * sin(t * 2 + Double(k)), y: q.y + Double(k) * 5, width: 12 - Double(k) * 2, height: 1.2)),
                       with: .color(Color(red: 1, green: 0.85, blue: 0.6).opacity(0.25 * glow * (1 - Double(k) / 5))))
        }
        // Lo-fi grain and faint scan lines.
        let frame = Int(t * 12)
        for i in 0..<140 {
            let x = w * hash(i, frame), y = h * hash(frame, i + 999)
            ctx.fill(Path(CGRect(x: x, y: y, width: 1, height: 1)), with: .color(.white.opacity(0.06)))
        }
        for row in stride(from: 0.0, to: h, by: 3) {
            ctx.fill(Path(CGRect(x: 0, y: row, width: w, height: 0.6)), with: .color(.black.opacity(0.12)))
        }
    }

    // MARK: - Stay: a warm window in the snow, one golden horn line curling across it

    private static func cabinWindow(_ ctx: GraphicsContext, _ size: CGSize, _ t: Double, _ pulse: Double) {
        let rect = CGRect(origin: .zero, size: size)
        let w = size.width, h = size.height
        let amber = Color(red: 1, green: 0.66, blue: 0.30)
        // Snowy night outside.
        ctx.fill(Path(rect), with: .linearGradient(
            Gradient(colors: [Color(red: 0.03, green: 0.04, blue: 0.10), Color(red: 0.08, green: 0.09, blue: 0.17)]),
            startPoint: .zero, endPoint: CGPoint(x: 0, y: h)))
        let beat = (t / pulse).truncatingRemainder(dividingBy: 1)
        let breath = 0.85 + 0.15 * exp(-beat * 3)
        // The window and its glow on the snow.
        let win = CGRect(x: w * 0.30, y: h * 0.17, width: w * 0.40, height: h * 0.56)
        var glow = ctx
        glow.blendMode = .plusLighter
        let centre = CGPoint(x: win.midX, y: win.midY)
        glow.fill(Path(rect), with: .radialGradient(Gradient(colors: [amber.opacity(0.32 * breath), amber.opacity(0.08), .clear]),
                                                    center: centre, startRadius: win.width * 0.3, endRadius: w * 0.62))
        ctx.fill(Path(win.insetBy(dx: -6, dy: -6)), with: .color(Color(red: 0.16, green: 0.09, blue: 0.05)))
        // Four panes: three lit, one dim.
        let gap: CGFloat = 5
        let pw = (win.width - gap) / 2, ph = (win.height - gap) / 2
        for row in 0..<2 {
            for col in 0..<2 {
                let pane = CGRect(x: win.minX + CGFloat(col) * (pw + gap), y: win.minY + CGFloat(row) * (ph + gap), width: pw, height: ph)
                let lit = !(row == 0 && col == 1)
                let top = lit ? Color(red: 1, green: 0.78, blue: 0.45) : Color(red: 0.30, green: 0.20, blue: 0.14)
                let bottom = lit ? Color(red: 0.88, green: 0.46, blue: 0.16) : Color(red: 0.18, green: 0.11, blue: 0.08)
                ctx.fill(Path(pane), with: .linearGradient(Gradient(colors: [top.opacity(lit ? breath : 1), bottom]),
                                                           startPoint: CGPoint(x: pane.midX, y: pane.minY),
                                                           endPoint: CGPoint(x: pane.midX, y: pane.maxY)))
            }
        }
        // Snow on the sill.
        var sill = Path()
        sill.move(to: CGPoint(x: win.minX - 14, y: win.maxY + 8))
        sill.addQuadCurve(to: CGPoint(x: win.maxX + 14, y: win.maxY + 8), control: CGPoint(x: win.midX, y: win.maxY - 2))
        sill.addLine(to: CGPoint(x: win.maxX + 14, y: win.maxY + 13)); sill.addLine(to: CGPoint(x: win.minX - 14, y: win.maxY + 13))
        sill.closeSubpath()
        ctx.fill(sill, with: .color(Color(red: 0.86, green: 0.88, blue: 0.95).opacity(0.85)))
        // One golden line curling across, like a horn phrase: it flows along at the pulse and glows on each beat.
        var line = Path()
        line.move(to: CGPoint(x: -10, y: h * 0.62))
        line.addCurve(to: CGPoint(x: w * 0.47, y: h * 0.40), control1: CGPoint(x: w * 0.18, y: h * 0.70), control2: CGPoint(x: w * 0.30, y: h * 0.30))
        line.addCurve(to: CGPoint(x: w * 0.56, y: h * 0.52), control1: CGPoint(x: w * 0.62, y: h * 0.48), control2: CGPoint(x: w * 0.60, y: h * 0.62))
        line.addCurve(to: CGPoint(x: w + 10, y: h * 0.34), control1: CGPoint(x: w * 0.50, y: h * 0.40), control2: CGPoint(x: w * 0.80, y: h * 0.26))
        let gold = Color(red: 1, green: 0.83, blue: 0.42)
        glow.stroke(line, with: .color(gold.opacity(0.18 * breath)), style: StrokeStyle(lineWidth: 9, lineCap: .round))
        ctx.stroke(line, with: .color(gold.opacity(0.9)),
                   style: StrokeStyle(lineWidth: 1.8, lineCap: .round, dash: [26, 5], dashPhase: -t / pulse * 8))
        // Six-armed frost in the corners.
        let frost: [(CGFloat, CGFloat, CGFloat)] = [(0.05, 0.10, 16), (0.13, 0.05, 9), (0.03, 0.24, 8), (0.95, 0.10, 14),
                                                    (0.87, 0.05, 8), (0.06, 0.90, 12), (0.15, 0.95, 7), (0.94, 0.88, 15), (0.84, 0.95, 8)]
        for (fx, fy, r) in frost {
            let c = CGPoint(x: w * fx, y: h * fy)
            var star = Path()
            for k in 0..<6 {
                let a = Double(k) * .pi / 3 + 0.2
                let tip = CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
                star.move(to: c); star.addLine(to: tip)
                for s in [0.45, 0.7] {
                    let p = CGPoint(x: c.x + r * s * cos(a), y: c.y + r * s * sin(a))
                    let len = r * 0.28 * (1.1 - s)
                    for side in [-1.0, 1.0] {
                        star.move(to: p)
                        star.addLine(to: CGPoint(x: p.x + len * cos(a + side * .pi / 3), y: p.y + len * sin(a + side * .pi / 3)))
                    }
                }
            }
            ctx.stroke(star, with: .color(Color(red: 0.85, green: 0.92, blue: 1).opacity(0.45)), lineWidth: 0.8)
        }
        // Snow falling at the pulse: each flake crosses the card in eight beats.
        for i in 0..<70 {
            let speed = 0.8 + 0.4 * hash(i, 7)
            let u = (t / (8 * pulse) * speed + hash(i, 3)).truncatingRemainder(dividingBy: 1)
            let x = w * hash(i, 1) + 10 * sin(t * 0.9 + Double(i))
            let y = -6 + u * (h + 12)
            let r = 0.8 + 1.4 * hash(i, 5)
            ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)),
                     with: .color(.white.opacity(0.35 + 0.4 * hash(i, 9))))
        }
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
