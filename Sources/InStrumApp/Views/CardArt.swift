import SwiftUI
import InStrumCore

/// Original living art for each "Inspired by" card, drawn in code from the song's feeling (never artwork,
/// photos or logos). The song's tempo is hidden in the motion: everything breathes at `pulsePeriod`.
enum CardArt {
    case comeBackToEarth, innerbloom, musicToWatchBoysTo, highByTheBeach, stay, dunno, wings, happinessIsAButterfly

    /// The Stay card's six-armed frost stars (x, y as fractions of the card, radius in points at 600 × 360): round the
    /// edges, clear of the liner notes (top right), the title block (bottom left) and the Listen button.
    static let stayFrost: [(CGFloat, CGFloat, CGFloat)] = [(0.05, 0.10, 16), (0.13, 0.05, 9), (0.03, 0.24, 8),
                                                         (0.955, 0.22, 13), (0.90, 0.15, 7), (0.04, 0.55, 10),
                                                         (0.10, 0.60, 6), (0.955, 0.70, 13), (0.88, 0.76, 7)]

    /// The Wings card's six brighter stars (the track number): x, y as fractions of the card, arm length in points at
    /// 600 × 360. High in the sky, above the curtains and clear of the liner notes (top right).
    static let wingsStars: [(CGFloat, CGFloat, CGFloat)] = [(0.07, 0.11, 7), (0.25, 0.06, 5), (0.43, 0.16, 6),
                                                          (0.64, 0.21, 5), (0.80, 0.17, 7), (0.94, 0.30, 5)]

    /// The Happiness Is a Butterfly card's thirteen glow motes (the track number): x, y as fractions of the card, the
    /// outer radius of each mote's glow in points at 600 × 360. Strung along the glowing waterline and in the water at the
    /// right, clear of the liner notes (top right), the title block (bottom left) and the Listen button.
    static let butterflyMotes: [(CGFloat, CGFloat, CGFloat)] = [(0.06, 0.58, 9), (0.15, 0.62, 7), (0.24, 0.56, 10),
                                                              (0.33, 0.63, 8), (0.41, 0.58, 7), (0.50, 0.61, 11),
                                                              (0.58, 0.56, 7), (0.66, 0.62, 9), (0.74, 0.57, 8),
                                                              (0.80, 0.66, 10), (0.88, 0.60, 8), (0.95, 0.70, 9),
                                                              (0.86, 0.77, 7)]

    static func art(for creditID: String) -> CardArt? {
        switch creditID {
        case CreditLibrary.comeBackToEarth.id: return .comeBackToEarth
        case CreditLibrary.innerbloom.id: return .innerbloom
        case CreditLibrary.musicToWatchBoysTo.id: return .musicToWatchBoysTo
        case CreditLibrary.highByTheBeach.id: return .highByTheBeach
        case CreditLibrary.stay.id: return .stay
        case CreditLibrary.dunno.id: return .dunno
        case CreditLibrary.wings.id: return .wings
        case CreditLibrary.happinessIsAButterfly.id: return .happinessIsAButterfly
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
        case .dunno: return .system(size: 26, weight: .light, design: .rounded)
        case .wings: return .system(size: 28, weight: .light, design: .rounded)
        case .happinessIsAButterfly: return .system(size: 26, weight: .regular, design: .serif)
        }
    }

    var titleTracking: CGFloat {
        switch self {
        case .innerbloom: return 7
        case .musicToWatchBoysTo: return 1.5
        case .highByTheBeach: return 3
        case .comeBackToEarth: return 0.5
        case .stay: return 1
        case .dunno: return 2
        case .wings: return 2
        case .happinessIsAButterfly: return 1
        }
    }

    /// How long one breath of the card lasts: a beat of the song, except the two felt in half time: "Stay"
    /// (134 BPM played as 67), so its snow falls at 60/67 s, and "Wings" (119 BPM, felt as about 60), whose curtains
    /// ripple once a second (60/60 s, the half-time feel rounded, as its demo plays it).
    func pulse(for credit: Credit) -> Double {
        switch self {
        case .stay: return 2 * credit.pulsePeriod
        case .wings: return 60.0 / 60
        case .happinessIsAButterfly: return credit.pulsePeriod   // 68 BPM: the motes blink at 60/68 s
        default: return credit.pulsePeriod
        }
    }
    var titleCase: Bool { self == .innerbloom }

    func draw(in ctx: GraphicsContext, size: CGSize, t: Double, pulse: Double) {
        switch self {
        case .comeBackToEarth: Self.underwater(ctx, size, t, pulse)
        case .innerbloom: Self.bloom(ctx, size, t, pulse)
        case .musicToWatchBoysTo: Self.goldenHaze(ctx, size, t, pulse)
        case .highByTheBeach: Self.coastLine(ctx, size, t, pulse)
        case .stay: Self.cabinWindow(ctx, size, t, pulse)
        case .dunno: Self.dawnBedroom(ctx, size, t, pulse)
        case .wings: Self.auroraWater(ctx, size, t, pulse)
        case .happinessIsAButterfly: Self.moonlitCove(ctx, size, t, pulse)
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
        // Six-armed frost round the edges, clear of the words.
        for (fx, fy, r) in Self.stayFrost {
            let c = CGPoint(x: w * fx, y: h * fy)
            var star = Path()
            for k in 0..<6 {
                let a: CGFloat = CGFloat(k) * CGFloat.pi / 3 + 0.2
                let ca: CGFloat = cos(a), sa: CGFloat = sin(a)
                star.move(to: c); star.addLine(to: CGPoint(x: c.x + r * ca, y: c.y + r * sa))
                for s: CGFloat in [0.45, 0.7] {
                    let p = CGPoint(x: c.x + r * s * ca, y: c.y + r * s * sa)
                    let len: CGFloat = r * 0.28 * (1.1 - s)
                    for side: CGFloat in [-1, 1] {
                        let b: CGFloat = a + side * CGFloat.pi / 3
                        let cb: CGFloat = cos(b), sb: CGFloat = sin(b)
                        star.move(to: p)
                        star.addLine(to: CGPoint(x: p.x + len * cb, y: p.y + len * sb))
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

    // MARK: - Dunno: a pastel dawn through a ten-pane window, a sheer curtain, one beam full of motes

    private static func dawnBedroom(_ ctx: GraphicsContext, _ size: CGSize, _ t: Double, _ pulse: Double) {
        let rect = CGRect(origin: .zero, size: size)
        let w = size.width, h = size.height
        ctx.fill(Path(rect), with: .linearGradient(
            Gradient(stops: [.init(color: Color(red: 0.96, green: 0.74, blue: 0.80), location: 0),
                             .init(color: Color(red: 0.78, green: 0.72, blue: 0.93), location: 0.5),
                             .init(color: Color(red: 0.99, green: 0.82, blue: 0.68), location: 1)]),
            startPoint: .zero, endPoint: CGPoint(x: w, y: h)))
        // The window: two columns of five panes, glowing with the dawn.
        let win = CGRect(x: w * 0.60, y: h * 0.10, width: w * 0.28, height: h * 0.62)
        ctx.fill(Path(win.insetBy(dx: -5, dy: -5)), with: .color(Color(red: 0.97, green: 0.93, blue: 0.95).opacity(0.9)))
        let gap: CGFloat = 4
        let pw = (win.width - gap) / 2, ph = (win.height - 4 * gap) / 5
        for row in 0..<5 {
            for col in 0..<2 {
                let pane = CGRect(x: win.minX + CGFloat(col) * (pw + gap), y: win.minY + CGFloat(row) * (ph + gap), width: pw, height: ph)
                let warmth = Double(row) / 4
                ctx.fill(Path(pane), with: .linearGradient(
                    Gradient(colors: [Color(red: 1, green: 0.90 - 0.06 * warmth, blue: 0.86 - 0.12 * warmth),
                                      Color(red: 1, green: 0.84 - 0.05 * warmth, blue: 0.74 - 0.10 * warmth)]),
                    startPoint: CGPoint(x: pane.minX, y: pane.minY), endPoint: CGPoint(x: pane.maxX, y: pane.maxY)))
            }
        }
        // One diagonal beam from the window down across the room: warm light over the room, never clipped to white.
        var light = ctx
        var beam = Path()
        beam.move(to: CGPoint(x: win.minX, y: win.minY + 10))
        beam.addLine(to: CGPoint(x: win.minX + 4, y: win.maxY))
        beam.addLine(to: CGPoint(x: w * 0.12, y: h + 10))
        beam.addLine(to: CGPoint(x: -w * 0.12, y: h + 10))
        beam.closeSubpath()
        let beatNow = (t / pulse).truncatingRemainder(dividingBy: 1)
        let beamGlow = 0.80 + 0.20 * exp(-beatNow * 3)   // the light breathes on the beat
        light.fill(beam, with: .linearGradient(Gradient(colors: [Color(red: 1, green: 0.86, blue: 0.70).opacity(0.3 * beamGlow), .clear]),
                                               startPoint: CGPoint(x: win.minX, y: win.midY), endPoint: CGPoint(x: 0, y: h)))
        // The sheer curtain over the left of the window: soft folds that sway.
        for k in 0..<6 {
            let x0 = win.minX - 10 + CGFloat(k) * win.width * 0.11
            let sway = CGFloat(7 * sin(t * 0.8 + Double(k) * 0.9))
            var fold = Path()
            fold.move(to: CGPoint(x: x0, y: win.minY - 8))
            fold.addCurve(to: CGPoint(x: x0 + sway, y: win.maxY + 10),
                          control1: CGPoint(x: x0 + 6 + sway * 0.5, y: win.minY + win.height * 0.35),
                          control2: CGPoint(x: x0 - 6 + sway, y: win.minY + win.height * 0.7))
            ctx.stroke(fold, with: .color(.white.opacity(0.22)), lineWidth: win.width * 0.09)
        }
        // Motes drifting in the beam; seven brighter ones twinkle on the beat.
        let beat = (t / pulse).truncatingRemainder(dividingBy: 1)
        for i in 0..<48 {
            let u = CGFloat((hash(i, 11) + t * 0.035 * (0.5 + hash(i, 12))).truncatingRemainder(dividingBy: 1))
            let v = CGFloat(hash(i, 13))
            // A point inside the beam: u runs from the window to the floor, v across it.
            let top = CGPoint(x: win.minX + 2, y: win.minY + 10 + v * win.height * 0.9)
            let bottom = CGPoint(x: -w * 0.12 + v * w * 0.24, y: h + 10)
            let wobbleX = CGFloat(3 * sin(t * 0.7 + Double(i))), wobbleY = CGFloat(2 * cos(t * 0.5 + Double(i) * 1.3))
            let x: CGFloat = top.x + (bottom.x - top.x) * u + wobbleX
            let y: CGFloat = top.y + (bottom.y - top.y) * u + wobbleY
            let bright = i < 7
            let phase: Double = (beat + Double(i) / 7).truncatingRemainder(dividingBy: 1)
            let flash: Double = bright ? 0.45 + 0.55 * exp(-phase * 5) : 0.35
            let r: CGFloat = bright ? 2.2 : 1.1
            light.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)), with: .color(.white.opacity(flash)))
        }
    }

    // MARK: - Wings: two aurora curtains over black water that mirrors them, under six bright stars

    private static func auroraWater(_ ctx: GraphicsContext, _ size: CGSize, _ t: Double, _ pulse: Double) {
        let w = size.width, h = size.height
        let horizon: CGFloat = h * 0.64
        let green = Color(red: 0.30, green: 0.95, blue: 0.62)
        let teal = Color(red: 0.18, green: 0.72, blue: 0.70)
        let violet = Color(red: 0.55, green: 0.35, blue: 0.85)
        // A deep teal-black sky, a little lighter towards the horizon, over still black water.
        ctx.fill(Path(CGRect(x: 0, y: 0, width: w, height: horizon)), with: .linearGradient(
            Gradient(colors: [Color(red: 0.01, green: 0.03, blue: 0.05), Color(red: 0.02, green: 0.09, blue: 0.11),
                              Color(red: 0.04, green: 0.15, blue: 0.16)]),
            startPoint: .zero, endPoint: CGPoint(x: 0, y: horizon)))
        ctx.fill(Path(CGRect(x: 0, y: horizon, width: w, height: h - horizon)), with: .linearGradient(
            Gradient(colors: [Color(red: 0.01, green: 0.04, blue: 0.05), Color(red: 0, green: 0.01, blue: 0.02)]),
            startPoint: CGPoint(x: 0, y: horizon), endPoint: CGPoint(x: 0, y: h)))

        // A field of faint stars, clear of the liner notes.
        for i in 0..<60 {
            let x: CGFloat = w * CGFloat(hash(i, 21)), y: CGFloat = horizon * 0.85 * CGFloat(hash(i, 22))
            if x > w * 0.6 && y < h * 0.1 { continue }
            let twinkle: Double = 0.5 + 0.5 * sin(t * (0.9 + hash(i, 23)) + Double(i))
            let r: CGFloat = 0.5 + 0.6 * CGFloat(hash(i, 24))
            ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)),
                     with: .color(.white.opacity(0.12 + 0.3 * twinkle)))
        }
        // Six brighter six-pointed stars.
        for (k, star) in Self.wingsStars.enumerated() {
            let (fx, fy, arm) = star
            let c = CGPoint(x: w * fx, y: h * fy)
            let glint: Double = 0.7 + 0.3 * sin(t * 0.8 + Double(k) * 1.9)
            var spikes = Path()
            for j in 0..<3 {
                let a: CGFloat = CGFloat(j) * CGFloat.pi / 3 + 0.26
                let dx: CGFloat = arm * cos(a), dy: CGFloat = arm * sin(a)
                spikes.move(to: CGPoint(x: c.x - dx, y: c.y - dy))
                spikes.addLine(to: CGPoint(x: c.x + dx, y: c.y + dy))
            }
            ctx.stroke(spikes, with: .color(Color(red: 0.85, green: 0.95, blue: 1).opacity(0.55 * glint)), lineWidth: 0.8)
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - 1.6, y: c.y - 1.6, width: 3.2, height: 3.2)), with: .color(.white.opacity(0.9 * glint)))
        }

        // Two curtains of rays, shaped by noise that drifts slowly; a fold travels along each once a pulse.
        let wave: Double = 2 * Double.pi * t / pulse
        let steps = 96
        let strip: CGFloat = w / CGFloat(steps) * 1.6
        let curtains: [(base: Double, sweep: Double, height: Double, glow: Double, seed: Double)] = [
            (0.50, 0.05, 0.30, 0.55, 0), (0.575, 0.035, 0.20, 0.40, 7.3)]
        var rays: [(x: CGFloat, base: CGFloat, tall: CGFloat, bright: Double, sway: CGFloat)] = []
        rays.reserveCapacity(curtains.count * steps)
        for c in curtains {
            for s in 0..<steps {
                let u: Double = Double(s) / Double(steps - 1)
                let fold: Double = sin(u * 9 - wave + c.seed)
                let n: Double = noise2(u * 6 + t * 0.06 + c.seed, c.seed + t * 0.03)
                let baseFraction: Double = c.base + c.sweep * sin(u * 3.4 + c.seed + t * 0.05) + 0.012 * fold
                let bright: Double = c.glow * (0.35 + 0.65 * n) * (0.8 + 0.2 * fold)
                let sway: CGFloat = CGFloat(3 * sin(Double(s) * 0.7 + t * 1.1))
                let x: CGFloat = w * CGFloat(u) - strip * 0.3
                let tall: CGFloat = h * CGFloat(c.height * (0.55 + 0.6 * n))
                rays.append((x: x, base: h * CGFloat(baseFraction), tall: tall, bright: bright, sway: sway))
            }
        }
        var sky = ctx
        sky.blendMode = .plusLighter
        sky.addFilter(.blur(radius: 2))
        sky.drawLayer { layer in
            for r in rays {
                let top: CGFloat = r.base - r.tall
                layer.fill(Path(CGRect(x: r.x, y: top, width: strip, height: r.tall)), with: .linearGradient(
                    Gradient(colors: [violet.opacity(0), teal.opacity(0.45 * r.bright), green.opacity(r.bright)]),
                    startPoint: CGPoint(x: r.x, y: top), endPoint: CGPoint(x: r.x, y: r.base)))
            }
        }
        // The water mirrors them: flipped about the horizon, dimmer, swaying a little.
        var mirror = ctx
        mirror.blendMode = .plusLighter
        mirror.clip(to: Path(CGRect(x: 0, y: horizon, width: w, height: h - horizon)))
        mirror.addFilter(.blur(radius: 3))
        mirror.drawLayer { layer in
            for r in rays {
                let top: CGFloat = 2 * horizon - r.base
                layer.fill(Path(CGRect(x: r.x + r.sway, y: top, width: strip, height: r.tall)), with: .linearGradient(
                    Gradient(colors: [green.opacity(0.35 * r.bright), teal.opacity(0.15 * r.bright), violet.opacity(0)]),
                    startPoint: CGPoint(x: r.x, y: top), endPoint: CGPoint(x: r.x, y: top + r.tall)))
            }
        }

        // A low dark shore along the horizon.
        var shore = Path()
        shore.move(to: CGPoint(x: 0, y: horizon))
        for s in 0...48 {
            let u: Double = Double(s) / 48
            let rise: CGFloat = h * CGFloat(0.012 + 0.05 * noise2(u * 5 + 3.1, 0.7) * (0.4 + 0.6 * abs(u - 0.55)))
            shore.addLine(to: CGPoint(x: w * CGFloat(u), y: horizon - rise))
        }
        shore.addLine(to: CGPoint(x: w, y: horizon + 1)); shore.addLine(to: CGPoint(x: 0, y: horizon + 1))
        shore.closeSubpath()
        ctx.fill(shore, with: .color(Color(red: 0.0, green: 0.02, blue: 0.03)))
        // Faint ripples breaking up the reflection.
        for k in 0..<14 {
            let d: Double = Double(k) / 13
            let y0: CGFloat = horizon + 4 + CGFloat(d * d) * (h - horizon - 6)
            var p = Path()
            for s in 0...40 {
                let x: CGFloat = w * CGFloat(s) / 40
                let y: CGFloat = y0 + CGFloat(1.2 * sin(Double(s) * 0.9 + t * 0.7 + Double(k) * 1.3))
                if s == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
            }
            ctx.stroke(p, with: .color(.black.opacity(0.5)), lineWidth: CGFloat(1 + 2 * d))
        }
    }

    // MARK: - Happiness Is a Butterfly: a midnight cove, a glowing cyan waterline, thirteen motes and a pale moon

    private static func moonlitCove(_ ctx: GraphicsContext, _ size: CGSize, _ t: Double, _ pulse: Double) {
        let w = size.width, h = size.height
        let waterline: CGFloat = h * 0.52
        let cyan = Color(red: 0.30, green: 0.95, blue: 0.95)
        // A midnight-blue sky, lighter towards the water, over dark water.
        ctx.fill(Path(CGRect(x: 0, y: 0, width: w, height: waterline)), with: .linearGradient(
            Gradient(colors: [Color(red: 0.03, green: 0.06, blue: 0.17), Color(red: 0.07, green: 0.13, blue: 0.30),
                              Color(red: 0.12, green: 0.22, blue: 0.40)]),
            startPoint: .zero, endPoint: CGPoint(x: 0, y: waterline)))
        ctx.fill(Path(CGRect(x: 0, y: waterline, width: w, height: h - waterline)), with: .linearGradient(
            Gradient(colors: [Color(red: 0.04, green: 0.12, blue: 0.22), Color(red: 0.01, green: 0.04, blue: 0.10)]),
            startPoint: CGPoint(x: 0, y: waterline), endPoint: CGPoint(x: 0, y: h)))

        // Faint stars, clear of the liner notes and of the moon.
        let moon = CGPoint(x: w * 0.17, y: h * 0.20)
        for i in 0..<45 {
            let x: CGFloat = w * CGFloat(hash(i, 31)), y: CGFloat = waterline * 0.9 * CGFloat(hash(i, 32))
            if x > w * 0.6 && y < h * 0.12 { continue }
            let dx: CGFloat = x - moon.x, dy: CGFloat = y - moon.y
            if dx * dx + dy * dy < 900 { continue }
            let twinkle: Double = 0.5 + 0.5 * sin(t * (0.7 + hash(i, 33)) + Double(i) * 2.1)
            let r: CGFloat = 0.5 + 0.5 * CGFloat(hash(i, 34))
            ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)),
                     with: .color(.white.opacity(0.10 + 0.25 * twinkle)))
        }

        // The pale moon in a soft halo.
        var sky = ctx
        sky.blendMode = .plusLighter
        sky.fill(Path(ellipseIn: CGRect(x: moon.x - 64, y: moon.y - 64, width: 128, height: 128)),
                 with: .radialGradient(Gradient(colors: [Color(red: 0.75, green: 0.82, blue: 0.95).opacity(0.30), .clear]),
                                       center: moon, startRadius: 0, endRadius: 64))
        ctx.fill(Path(ellipseIn: CGRect(x: moon.x - 15, y: moon.y - 15, width: 30, height: 30)),
                 with: .color(Color(red: 0.93, green: 0.95, blue: 0.98)))
        ctx.fill(Path(ellipseIn: CGRect(x: moon.x - 9, y: moon.y - 7, width: 7, height: 6)),
                 with: .color(Color(red: 0.80, green: 0.84, blue: 0.90).opacity(0.6)))

        // The cove's two dark headlands, low against the sky.
        let rock = Color(red: 0.01, green: 0.02, blue: 0.06)
        var left = Path()
        left.move(to: CGPoint(x: 0, y: waterline + 1))
        for s in 0...20 {
            let u: Double = Double(s) / 20
            let rise: CGFloat = h * CGFloat(0.12 * (1 - u * u) + 0.015 * noise2(u * 6 + 1.3, 0.4))
            left.addLine(to: CGPoint(x: w * 0.16 * CGFloat(u), y: waterline - rise))
        }
        left.addLine(to: CGPoint(x: w * 0.16, y: waterline + 1)); left.closeSubpath()
        ctx.fill(left, with: .color(rock))
        var right = Path()
        right.move(to: CGPoint(x: w, y: waterline + 1))
        for s in 0...24 {
            let u: Double = Double(s) / 24
            let rise: CGFloat = h * CGFloat(0.09 * (1 - u * u) + 0.012 * noise2(u * 7 + 4.1, 0.9))
            right.addLine(to: CGPoint(x: w - w * 0.24 * CGFloat(u), y: waterline - rise))
        }
        right.addLine(to: CGPoint(x: w * 0.76, y: waterline + 1)); right.closeSubpath()
        ctx.fill(right, with: .color(rock))

        // The moon's broken path on the water, fading before the title.
        var glints = ctx
        glints.blendMode = .plusLighter
        for k in 0..<10 {
            let d: Double = Double(k) / 9
            let y: CGFloat = waterline + 4 + CGFloat(d) * h * 0.12
            let half: CGFloat = CGFloat(10 + 14 * d) * CGFloat(0.6 + 0.4 * noise2(Double(k) * 1.7, t * 0.4))
            let x: CGFloat = moon.x + CGFloat(3 * sin(t * 0.6 + Double(k) * 1.1))
            glints.fill(Path(CGRect(x: x - half, y: y, width: 2 * half, height: 1.2)),
                        with: .color(Color(red: 0.85, green: 0.90, blue: 1).opacity(0.30 * (1 - 0.7 * d))))
        }

        // The glowing cyan waterline, lapping slowly (once every four beats), with a sheen spilling into the water.
        let lap: Double = 0.85 + 0.15 * sin(2 * Double.pi * t / (4 * pulse))
        var line = Path()
        for s in 0...80 {
            let u: Double = Double(s) / 80
            let ripple: Double = 1.5 * sin(u * 23 + t * 0.9)
            let drift: Double = 1.2 * (noise2(u * 9 + t * 0.15, 2.7) - 0.5)
            let y: CGFloat = waterline + CGFloat(ripple + drift)
            if s == 0 { line.move(to: CGPoint(x: 0, y: y)) } else { line.addLine(to: CGPoint(x: w * CGFloat(u), y: y)) }
        }
        var glow = ctx
        glow.blendMode = .plusLighter
        glow.fill(Path(CGRect(x: 0, y: waterline, width: w, height: h * 0.10)), with: .linearGradient(
            Gradient(colors: [cyan.opacity(0.28 * lap), cyan.opacity(0)]),
            startPoint: CGPoint(x: 0, y: waterline), endPoint: CGPoint(x: 0, y: waterline + h * 0.10)))
        var halo = glow
        halo.addFilter(.blur(radius: 4))
        halo.stroke(line, with: .color(cyan.opacity(0.55 * lap)), lineWidth: 5)
        glow.stroke(line, with: .color(Color(red: 0.75, green: 1, blue: 1).opacity(0.85 * lap)), lineWidth: 1.2)

        // Thirteen glow motes, each blinking on the beat (68 BPM), out of step with its neighbours.
        let beat: Double = t / pulse
        for (i, mote) in Self.butterflyMotes.enumerated() {
            let (fx, fy, r) = mote
            let c = CGPoint(x: w * fx, y: h * fy + CGFloat(1.5 * sin(t * 0.8 + Double(i) * 1.3)))
            let phase: Double = (beat + Double(i) * 0.382).truncatingRemainder(dividingBy: 1)
            let blink: Double = 0.25 + 0.75 * exp(-phase * 4)
            let glowR: CGFloat = r - 1.5   // the drift above stays inside the mote's radius
            glow.fill(Path(ellipseIn: CGRect(x: c.x - glowR, y: c.y - glowR, width: 2 * glowR, height: 2 * glowR)),
                      with: .radialGradient(Gradient(colors: [cyan.opacity(0.6 * blink), cyan.opacity(0)]),
                                            center: c, startRadius: 0, endRadius: glowR))
            let core: CGFloat = 1.2 + 0.8 * CGFloat(blink)
            glow.fill(Path(ellipseIn: CGRect(x: c.x - core, y: c.y - core, width: 2 * core, height: 2 * core)),
                      with: .color(Color(red: 0.85, green: 1, blue: 1).opacity(0.9 * blink)))
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
