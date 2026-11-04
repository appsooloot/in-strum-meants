import XCTest
import Metal
import simd
@testable import InStrumApp
@testable import InStrumCore

/// A dark sea-blue view (or an outside drawn by `outside`), then a round porthole's glass, its brass ring, and
/// whatever `after` draws round it (a cabin wall).
@MainActor
final class PortholeHarness: ThemeRenderer {
    let glass: WindowGlassLayer
    var spec: WindowSpec
    var quality: QualityLevel = .high
    /// Off: only the view is drawn (the reference for "untouched").
    var drawsWindow = true
    /// Off: no view copy, so the glass draws unwarped over the outside.
    var warps = true
    var outside: (@MainActor (MTLRenderCommandEncoder) -> Void)?
    var after: (@MainActor (MTLRenderCommandEncoder) -> Void)?
    var post = PostSettings(bloom: 0, bloomThreshold: 10, dof: 0, focusDepth: 1, grade: 0, grain: 0, vignette: 0,
                            exposure: 1, warmth: 0, time: 0, quality: .high)

    init?(device: MTLDevice, spec: WindowSpec) {
        guard let g = WindowGlassLayer(device: device) else { return nil }
        glass = g
        self.spec = spec
    }

    func update(condensation: Float, cold: Float, wetDrips: Float = 0, cabin: SIMD3<Float> = SIMD3(1, 0.85, 0.7),
                reflection: SIMD4<Float> = .zero, dt: Double = 1.0 / 30) {
        post.quality = quality
        glass.updatePorthole(spec: spec, condensation: condensation, cold: cold, wetDrips: wetDrips, cabinLight: cabin,
                             reflection: reflection, outsideLight: SIMD3(0.5, 0.5, 0.5), quality: quality, dt: dt,
                             aspect: 16.0 / 9)
    }

    func render(stack: RenderStack, commandBuffer cb: MTLCommandBuffer) {
        guard let pass = stack.scenePass(clear: MTLClearColor(red: 0.08, green: 0.12, blue: 0.2, alpha: 1)),
              var e = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        outside?(e)
        guard drawsWindow else { e.endEncoding(); return }
        var view: MTLTexture?
        if warps, let hdr = stack.hdrTarget {
            e.endEncoding()
            view = glass.makeView(from: hdr, commandBuffer: cb)
            guard let again = stack.scenePassContinuing(), let next = cb.makeRenderCommandEncoder(descriptor: again) else { return }
            e = next
        }
        glass.drawPorthole(e, view: view)
        glass.drawFrame(e)
        after?(e)
        e.endEncoding()
    }
}

/// The porthole (spec §7.4): round glass in a brass ring.
@MainActor
extension WindowKitTests {
    private func portholeShot(_ spec: WindowSpec, condensation: Float, window: Bool = true, device: MTLDevice,
                              preview: PreviewRenderer) throws -> CGImage {
        let h = try XCTUnwrap(PortholeHarness(device: device, spec: spec))
        h.drawsWindow = window
        h.update(condensation: condensation, cold: 1)
        return try XCTUnwrap(preview.capture(h))
    }

    /// Round glass is one pane: condensation fogs its rim (deep at depth) and leaves the middle clear, and nothing
    /// outside the circle changes, though the same rect as a pane fogs its bottom corners. Drips stay on the circle,
    /// and it never frosts.
    func testRoundGlassMasksCondensation() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let preview = try XCTUnwrap(PreviewRenderer(width: 640, height: 360))
        let spec = WindowSpec.porthole(centre: .zero, height: 1.2, aspect: 16.0 / 9, frameWidth: 0.04)
        XCTAssertEqual(spec.shape, .round)
        XCTAssertEqual(spec.material, .brass)
        let bare = try portholeShot(spec, condensation: 0, window: false, device: device, preview: preview)
        let dry = try portholeShot(spec, condensation: 0, device: device, preview: preview)
        let wet = try portholeShot(spec, condensation: 1, device: device, preview: preview)
        // Low on the glass, just inside the rim (0.88–0.95 of the radius), it fogs; the middle stays clear (the CPU
        // reference render measured 0.18 and 0).
        XCTAssertGreaterThan(FramePatch.difference(wet, dry, x: -0.05...0.05, y: -0.565...(-0.53)), 0.05, "the rim fogs")
        XCTAssertLessThan(FramePatch.difference(wet, dry, x: -0.08...0.08, y: -0.08...0.08), 0.004, "the middle stays clear")
        // The rect's corners, outside the circle and its ring: the view exactly, wet or dry.
        let corners: [(ClosedRange<Double>, ClosedRange<Double>)] = [
            (0.29...0.325, -0.585...(-0.55)), (-0.325...(-0.29), -0.585...(-0.55)),
            (0.29...0.325, 0.55...0.585), (-0.325...(-0.29), 0.55...0.585),
        ]
        for (x, y) in corners {
            let a = FramePatch.meanRGB(wet, x: x, y: y), b = FramePatch.meanRGB(bare, x: x, y: y)
            XCTAssertEqual(a.x, b.x, accuracy: 1.0 / 255, "corner \(x) \(y)")
            XCTAssertEqual(a.y, b.y, accuracy: 1.0 / 255, "corner \(x) \(y)")
            XCTAssertEqual(a.z, b.z, accuracy: 1.0 / 255, "corner \(x) \(y)")
        }
        // The same rect as one pane: its condensation band runs into the bottom corners.
        let pane = try XCTUnwrap(GlassHarness(device: device, field: nil))
        pane.spec = WindowSpec(columns: 1, rows: 1, bar: 0, rect: spec.rect, material: .logWood, frameWidth: 0.04)
        pane.update(frost: 0, condensation: 1)
        let paneWet = try XCTUnwrap(preview.capture(pane))
        pane.drawsWindow = false
        let paneBare = try XCTUnwrap(preview.capture(pane))
        XCTAssertGreaterThan(FramePatch.difference(paneWet, paneBare, x: corners[0].0, y: corners[0].1), 0.03, "a pane fogs its corner")

        // Drips, from the fog and after rain, stay on the circle; and there is never frost on it.
        let h = try XCTUnwrap(PortholeHarness(device: device, spec: spec))
        var seen = 0
        for _ in 0..<900 {
            h.update(condensation: 1, cold: 1, wetDrips: 1)
            for p in h.glass.dripPositions {
                seen += 1
                XCTAssertLessThanOrEqual(simd_length(p - SIMD2<Float>(0.5, 0.5)), 0.5, "a drip at \(p)")
            }
        }
        XCTAssertGreaterThan(seen, 0)
        XCTAssertEqual(h.glass.frostCoverage, 0)
        XCTAssertEqual(h.glass.stuckFlakeCount, 0)
    }

    /// The ring's 12 bolts, from its geometry: evenly round it 30° apart (the first at 12 o'clock), each head on its
    /// washer clear of the gasket and on the ring; the layer's ring uniforms carry the same count, angle and circle.
    /// Pane windows have none.
    func testBrassPortholeHasTwelveBolts() throws {
        let aspect: Float = 16.0 / 9
        let spec = WindowSpec.porthole(centre: SIMD2(-0.08, 0.02), height: 1.4, aspect: aspect, frameWidth: 0.06)
        let bolts = spec.bolts(aspect: aspect)
        XCTAssertEqual(bolts.count, 12)
        XCTAssertEqual(WindowSpec.portholeBolts, 12)
        let (centre, radius) = spec.circle
        let ring = spec.frameWidth * aspect, washer = 1.3 * WindowSpec.boltHead * ring
        var angles: [Float] = []
        for b in bolts {
            let q = (b - centre) * SIMD2<Float>(aspect, 1)
            let r = simd_length(q)
            XCTAssertGreaterThan(r - washer, radius + WindowSpec.gasket * ring, "clear of the gasket: \(b)")
            XCTAssertLessThan(r + washer, radius + ring, "on the ring: \(b)")
            angles.append(atan2(q.y, q.x))
        }
        XCTAssertEqual(angles[0], .pi / 2, accuracy: 1e-4, "the first at 12 o'clock")
        let sorted = angles.sorted()
        for i in 0..<sorted.count {
            let next = i + 1 < sorted.count ? sorted[i + 1] : sorted[0] + 2 * .pi
            XCTAssertEqual(next - sorted[i], .pi / 6, accuracy: 1e-4, "evenly spaced")
        }
        XCTAssertTrue(GlassHarness.spec.bolts(aspect: aspect).isEmpty, "pane windows have none")

        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let glass = try XCTUnwrap(WindowGlassLayer(device: device))
        glass.updatePorthole(spec: spec, condensation: 0, cold: 0, cabinLight: SIMD3(1, 0.8, 0.6), reflection: .zero,
                             outsideLight: SIMD3(0.1, 0.2, 0.4), quality: .lite, dt: 1.0 / 30, aspect: aspect)
        XCTAssertEqual(glass.portU[2].y, Float(WindowSpec.portholeBolts))
        XCTAssertEqual(glass.portU[2].z, WindowSpec.boltPhase)
        XCTAssertEqual(glass.portU[2].w, WindowSpec.boltCircle)
        XCTAssertEqual(glass.portU[3].x, WindowSpec.boltHead)
        XCTAssertEqual(glass.portU[3].y, WindowSpec.gasket)
        glass.update(spec: GlassHarness.spec, frost: 0, patches: [], condensation: 0, wetDrips: 0, snow: 0, reflection: .zero,
                     glint: .zero, quality: .lite, dt: 0)
        XCTAssertEqual(glass.portU[2].y, 0, "no bolts on panes")
    }

    /// The porthole over the underwater test view and a cabin wall, at both qualities: structured (not blank, not
    /// flat), a warm brass ring, and the view copy made once and kept.
    func testPortholePreviewIsStructured() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let preview = try XCTUnwrap(PreviewRenderer(width: 640, height: 360))
        for q in [QualityLevel.lite, .high] {
            let (h, _) = try PortholePreview.harness(device: device, quality: q, size: CGSize(width: 640, height: 360))
            let image = try XCTUnwrap(preview.capture(h))
            let s = PreviewRenderer.stats(image)
            XCTAssertGreaterThan(s.meanLuminance, 0.03, "\(q)")
            XCTAssertGreaterThan(s.variance, 0.001, "\(q)")
            // The ring's left side, halfway across it: brass (warm), not the sea or the wall.
            let c = h.spec.circle
            let ringX = Double(c.centre.x - (c.radius + 0.6 * h.spec.frameWidth * 16.0 / 9) / (16.0 / 9))
            let brass = FramePatch.meanRGB(image, x: (ringX - 0.004)...(ringX + 0.004), y: (Double(c.centre.y) - 0.05)...(Double(c.centre.y) + 0.05))
            XCTAssertGreaterThan(brass.x, brass.z + 0.05, "brass at the ring (\(q)): \(brass)")
            for _ in 0..<5 { _ = preview.capture(h) }
            XCTAssertEqual(h.glass.viewAllocations, 1, "the view copy is kept (\(q))")
        }
    }
}

/// The porthole over the underwater test view (25 m by day, Snell's window at the top), a little left of centre at
/// 70% of the view's height as the submarine has it, with the cabin wall around.
@MainActor
enum PortholePreview {
    static func harness(device: MTLDevice, quality: QualityLevel, size: CGSize, night: Bool = false) throws -> (PortholeHarness, UnderwaterTestView) {
        let aspect = Float(size.width / size.height)
        let spec = WindowSpec.porthole(centre: SIMD2(-0.08, 0.02), height: 1.4, aspect: aspect, frameWidth: 0.06)
        let h = try XCTUnwrap(PortholeHarness(device: device, spec: spec))
        let view = try XCTUnwrap(UnderwaterTestView(device: device))
        var s = SkySettings(); s.timeMode = .frozen; s.frozenHour = night ? 23 : 11; s.frozenPhase = 0.5; s.cityID = "melbourne"
        s.weatherMode = .pick; s.weather = .clear
        let state = LivingSky(settings: s, homeZone: TimeZone(identifier: "Australia/Melbourne")!)
            .step(now: Date(timeIntervalSince1970: 1_793_000_000), dt: 0)
        view.depth = night ? 60 : 25
        view.pitch = 18
        view.cabin = night ? SIMD3(0.75, 0.1, 0.05) : SIMD3(0.85, 0.8, 0.72)
        if night { view.light = SIMD3(0.05, 0.05, 0.06) }
        view.update(state, size: size, quality: quality)
        h.quality = quality
        h.outside = { view.drawOutside($0) }
        h.after = { view.drawWall($0, around: spec) }
        h.post = PostSettings(bloom: 0.45, bloomThreshold: 1, dof: 0, focusDepth: 1, grade: 0, grain: 0, vignette: 0.3,
                              exposure: 1, warmth: 0, time: 0, quality: quality)
        for _ in 0..<30 {
            h.glass.updatePorthole(spec: spec, condensation: night ? 0.9 : 0.6, cold: night ? 0.8 : 0.3, cabinLight: view.cabin,
                                   reflection: SIMD4(view.cabin, 0.05), outsideLight: SIMD3(0.05, 0.12, 0.3), quality: quality,
                                   dt: 1.0 / 30, aspect: aspect)
        }
        return (h, view)
    }
}

@MainActor
extension WorldPreviewTests {
    /// The brass porthole over the underwater test view: by day at 25 m (High and Smooth) and at night at 60 m.
    func testWritePortholePreviews() throws {
        guard let dir = ProcessInfo.processInfo.environment["PREVIEW_DIR"] else { throw XCTSkip("PREVIEW_DIR not set") }
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let preview = try XCTUnwrap(PreviewRenderer(width: 1280, height: 720))
        let size = CGSize(width: 1280, height: 720)
        for (name, quality, night) in [("porthole-brass", QualityLevel.high, false), ("porthole-brass-smooth", .lite, false),
                                       ("porthole-brass-night", .high, true)] {
            let (h, _) = try PortholePreview.harness(device: device, quality: quality, size: size, night: night)
            let image = try XCTUnwrap(preview.capture(h))
            try PreviewRenderer.writePNG(image, to: url.appendingPathComponent("\(name).png"))
        }
    }
}
