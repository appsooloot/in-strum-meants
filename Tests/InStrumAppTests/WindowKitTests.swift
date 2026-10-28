import XCTest
import Metal
import simd
@testable import InStrumApp
@testable import InStrumCore

/// One frost field for every Window Kit test (it takes a moment to grow).
private let windowKitField = FrostField(seed: 3, columns: 3, rows: 2, bar: 0.02)

/// A mid-grey "view" (or a Living Sky, for previews), then a window's glass and frame over it.
@MainActor
final class GlassHarness: ThemeRenderer {
    static let spec = WindowSpec(columns: 3, rows: 2, bar: 0.02, rect: SIMD4(-0.7, -0.6, 0.7, 0.6), material: .logWood, frameWidth: 0.05)

    let glass: WindowGlassLayer
    var spec = GlassHarness.spec
    var quality: QualityLevel = .high
    /// Off: only the view is drawn (the reference for "untouched").
    var drawsWindow = true
    var sky: SkyLayer?
    var weather: WeatherLayer?
    private(set) var post = PostSettings(bloom: 0, bloomThreshold: 10, dof: 0, focusDepth: 1, grade: 0, grain: 0, vignette: 0,
                                         exposure: 1, warmth: 0, time: 0, quality: .high)

    init?(device: MTLDevice, field: FrostField? = windowKitField) {
        guard let g = WindowGlassLayer(device: device) else { return nil }
        glass = g
        if let field { glass.setField(field) }
    }

    func update(frost: Float, patches: [GlassPatch] = [], condensation: Float = 0, wetDrips: Float = 0, snow: Float = 0,
                reflection: SIMD4<Float> = .zero, glint: SIMD4<Float> = SIMD4(1, 0.72, 0.45, 0.3), dt: Double = 1.0 / 30) {
        post.quality = quality
        glass.update(spec: spec, frost: frost, patches: patches, condensation: condensation, wetDrips: wetDrips, snow: snow,
                     reflection: reflection, glint: glint, quality: quality, dt: dt,
                     outsideLight: SIMD3(0.8, 0.84, 0.9), aspect: 16.0 / 9)
    }

    func render(stack: RenderStack, commandBuffer cb: MTLCommandBuffer) {
        guard let pass = stack.scenePass(clear: MTLClearColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)),
              var e = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        sky?.draw(e)
        weather?.draw(e)
        guard drawsWindow else { e.endEncoding(); return }
        var blur: MTLTexture?
        if quality != .lite, let hdr = stack.hdrTarget {
            e.endEncoding()
            blur = glass.makeBlur(from: hdr, commandBuffer: cb)
            guard let again = stack.scenePassContinuing(), let next = cb.makeRenderCommandEncoder(descriptor: again) else { return }
            e = next
        }
        glass.drawGlass(e, blur: blur)
        glass.drawFrame(e)
        e.endEncoding()
    }
}

@MainActor
final class WindowKitTests: XCTestCase {
    private let glassX: ClosedRange<Double> = -0.7...0.7, glassY: ClosedRange<Double> = -0.6...0.6

    func testWindowKitShadersCompile() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let lib = try device.makeLibrary(source: WindowKitShaders.source, options: nil)
        for name in ["glass_vertex", "glass_fragment", "frame_vertex", "frame_fragment", "glassdrop_vertex", "glassdrop_fragment",
                     "glass_fullscreen_vertex", "blur_down_fragment"] {
            XCTAssertNotNil(lib.makeFunction(name: name), name)
        }
        XCTAssertFalse(WindowKitShaders.source.contains("pow("), "squares and powers are written out (pow of a negative base is NaN)")
    }

    // MARK: - Rendering helpers

    private func harness(quality: QualityLevel = .high, field: FrostField? = windowKitField) throws -> (GlassHarness, PreviewRenderer) {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let h = try XCTUnwrap(GlassHarness(device: device, field: field))
        h.quality = quality
        return (h, try XCTUnwrap(PreviewRenderer(width: 640, height: 360)))
    }

    private func render(frost: Float, patches: [GlassPatch] = [], condensation: Float = 0, quality: QualityLevel = .high,
                        field: FrostField? = windowKitField, window: Bool = true) throws -> CGImage {
        let (h, preview) = try harness(quality: quality, field: field)
        h.drawsWindow = window
        h.update(frost: frost, patches: patches, condensation: condensation)
        return try XCTUnwrap(preview.capture(h))
    }

    private func luma(_ c: SIMD3<Double>) -> Double { 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z }

    /// The share of glass pixels in an NDC box that differ from the bare window by more than 0.08 in luminance.
    /// Glass pixels are those the bare window leaves at the view's grey (the frame and bars are left out).
    private func frostedShare(_ image: CGImage, bare: CGImage, view: Double, x: ClosedRange<Double>, y: ClosedRange<Double>) -> Double {
        let a = FramePatch.pixels(image, x: x, y: y), b = FramePatch.pixels(bare, x: x, y: y)
        var glass = 0, frosted = 0
        for i in 0..<min(a.count, b.count) where abs(luma(b[i]) - view) < 0.02 {
            glass += 1
            if abs(luma(a[i]) - luma(b[i])) > 0.08 { frosted += 1 }
        }
        return glass > 0 ? Double(frosted) / Double(glass) : 0
    }

    private func viewLuma() throws -> Double {
        luma(FramePatch.meanRGB(try render(frost: 0, window: false), x: -0.1...0.1, y: -0.1...0.1))
    }

    // MARK: - Frost

    func testFrostCoversMoreAsTheLevelRises() throws {
        let view = try viewLuma()
        let bare = try render(frost: 0)
        let shares = try [0.2, 0.5, 0.8].map { level -> Double in
            frostedShare(try render(frost: Float(level)), bare: bare, view: view, x: glassX, y: glassY)
        }
        XCTAssertGreaterThan(shares[0], 0.02, "a little frost at 0.2")
        XCTAssertLessThan(shares[0], shares[1])
        XCTAssertLessThan(shares[1], shares[2])
        XCTAssertGreaterThan(shares[2], 0.5)
    }

    func testFrostShowsBeforeTheFieldArrives() throws {
        let view = try viewLuma()
        let bare = try render(frost: 0, field: nil)
        let share = frostedShare(try render(frost: 0.6, field: nil), bare: bare, view: view, x: glassX, y: glassY)
        XCTAssertGreaterThan(share, 0.1, "the radial fallback draws frost until the field is ready")
    }

    /// Boxes inside a patch at the glass centre (radius 0.1 of the width) and just outside it, left and right.
    private func patchBoxes() -> (inside: (ClosedRange<Double>, ClosedRange<Double>), outside: [(ClosedRange<Double>, ClosedRange<Double>)]) {
        let rx: Double = 0.1 * 1.4
        let ry: Double = 0.1 * (384.0 / 216.0) * 1.2
        let insideX: ClosedRange<Double> = (-0.5 * rx)...(0.5 * rx)
        let insideY: ClosedRange<Double> = (-0.5 * ry)...(0.5 * ry)
        let band: ClosedRange<Double> = -0.15...0.15
        let right: ClosedRange<Double> = (1.25 * rx)...(1.7 * rx)
        let left: ClosedRange<Double> = (-1.7 * rx)...(-1.25 * rx)
        return ((insideX, insideY), [(right, band), (left, band)])
    }

    func testPatchesClearTheFrost() throws {
        let view = try viewLuma()
        let bare = try render(frost: 0)
        let image = try render(frost: 0.8, patches: [GlassPatch(x: 0.5, y: 0.5, radius: 0.1, warmth: 1)])
        let boxes = patchBoxes()
        XCTAssertLessThan(frostedShare(image, bare: bare, view: view, x: boxes.inside.0, y: boxes.inside.1), 0.1)
        for (x, y) in boxes.outside {
            XCTAssertGreaterThan(frostedShare(image, bare: bare, view: view, x: x, y: y), 0.5)
        }
    }

    func testWarmthLetsFrostBack() throws {
        let view = try viewLuma()
        let bare = try render(frost: 0)
        let image = try render(frost: 0.8, patches: [GlassPatch(x: 0.5, y: 0.5, radius: 0.1, warmth: 0.2)])
        let boxes = patchBoxes()
        XCTAssertGreaterThan(frostedShare(image, bare: bare, view: view, x: boxes.inside.0, y: boxes.inside.1), 0.4)
    }

    func testPatchesAreCapped() throws {
        let (h, preview) = try harness(quality: .lite)
        let many = (0..<100).map { GlassPatch(x: Float($0 % 10) / 10, y: Float($0 / 10) / 10, radius: 0.05, warmth: 1) }
        h.update(frost: 0.5, patches: many)
        XCTAssertEqual(h.glass.patchCount, WindowGlassLayer.patchCap(.lite))
        h.quality = .ultra
        h.update(frost: 0.5, patches: many)
        XCTAssertEqual(h.glass.patchCount, WindowGlassLayer.patchCap(.ultra))
        XCTAssertNotNil(preview.capture(h))
    }

    func testCoverageEstimateFollowsTheLevel() throws {
        let (h, _) = try harness()
        h.update(frost: 0.2)
        let low = h.glass.frostCoverage
        h.update(frost: 0.8)
        let high = h.glass.frostCoverage
        h.update(frost: 0.8, patches: [GlassPatch(x: 0.5, y: 0.5, radius: 0.2, warmth: 1)])
        XCTAssertLessThan(low, high)
        XCTAssertLessThan(h.glass.frostCoverage, high, "a warm patch clears some")
    }

    // MARK: - Condensation, frame, blur

    func testCondensationSitsLow() throws {
        let image = try render(frost: 0, condensation: 1)
        for p in GlassHarness.spec.panes() {
            let lo = GlassHarness.spec.ndc(SIMD2(p.x, p.y)), hi = GlassHarness.spec.ndc(SIMD2(p.z, p.w))
            let w = Double(hi.x - lo.x), ht = Double(hi.y - lo.y)
            let xs = (Double(lo.x) + 0.1 * w)...(Double(hi.x) - 0.1 * w)
            let bottom = luma(FramePatch.meanRGB(image, x: xs, y: (Double(lo.y) + 0.02 * ht)...(Double(lo.y) + 0.15 * ht)))
            let middle = luma(FramePatch.meanRGB(image, x: xs, y: (Double(lo.y) + 0.4 * ht)...(Double(lo.y) + 0.6 * ht)))
            XCTAssertGreaterThan(bottom, middle + 0.02, "pane at \(p)")
        }
    }

    func testFramesStayOutsideTheGlass() throws {
        let view = try render(frost: 0, window: false)
        let bare = try render(frost: 0)
        let spec = GlassHarness.spec
        func wood(_ x: Double, _ y: Double, _ label: String) {
            let c = FramePatch.meanRGB(bare, x: (x - 0.004)...(x + 0.004), y: (y - 0.006)...(y + 0.006))
            XCTAssertGreaterThan(c.x, c.z + 0.03, "\(label) is warm wood: \(c)")
            XCTAssertLessThan(luma(c), 0.5, "\(label) is dark: \(c)")
        }
        wood(Double(spec.rect.x) - 0.025, 0.3, "left frame")
        wood(Double(spec.rect.z) + 0.025, -0.3, "right frame")
        wood(0.2, Double(spec.rect.w) + 0.025 * 16 / 9, "top frame")
        for b in spec.bars() {
            let mid: Float = (b.x + b.y) / 2
            if b.z < 0.5 {
                wood(Double(spec.ndc(SIMD2<Float>(mid, 0)).x), 0.3, "vertical bar")
            } else {
                wood(-0.47, Double(spec.ndc(SIMD2<Float>(0, mid)).y), "horizontal bar")
            }
        }
        // Glass at frost 0 leaves the view exactly as it was.
        for (x, y) in [(-0.47, 0.3), (0.0, -0.3), (0.47, 0.3)] {
            let a = FramePatch.meanRGB(bare, x: (x - 0.05)...(x + 0.05), y: (y - 0.05)...(y + 0.05))
            let b = FramePatch.meanRGB(view, x: (x - 0.05)...(x + 0.05), y: (y - 0.05)...(y + 0.05))
            XCTAssertEqual(a.x, b.x, accuracy: 1.0 / 255); XCTAssertEqual(a.y, b.y, accuracy: 1.0 / 255); XCTAssertEqual(a.z, b.z, accuracy: 1.0 / 255)
        }
    }

    func testSashIsPaintedLight() throws {
        let (h, preview) = try harness()
        h.spec.material = .paintedSash
        h.update(frost: 0)
        let image = try XCTUnwrap(preview.capture(h))
        let c = FramePatch.meanRGB(image, x: (Double(h.spec.rect.x) - 0.029)...(Double(h.spec.rect.x) - 0.021), y: 0.25...0.35)
        XCTAssertGreaterThan(luma(c), 0.45, "a painted sash is pale: \(c)")
    }

    func testBlurOnlyOnHighAndUltra() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw XCTSkip("No Metal device") }
        let (h, _) = try harness(quality: .lite)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: RenderStack.sceneFormat, width: 640, height: 360, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]; d.storageMode = .private
        let source = try XCTUnwrap(device.makeTexture(descriptor: d))
        h.update(frost: 0.5)
        XCTAssertNil(h.glass.makeBlur(from: source, commandBuffer: try XCTUnwrap(queue.makeCommandBuffer())))
        h.quality = .high
        h.update(frost: 0.5)
        let cb = try XCTUnwrap(queue.makeCommandBuffer())
        let blur = try XCTUnwrap(h.glass.makeBlur(from: source, commandBuffer: cb))
        cb.commit(); cb.waitUntilCompleted()
        XCTAssertEqual(blur.width, 320); XCTAssertEqual(blur.height, 180); XCTAssertEqual(blur.mipmapLevelCount, 4)
        let cb2 = try XCTUnwrap(queue.makeCommandBuffer())
        let again = h.glass.makeBlur(from: source, commandBuffer: cb2)
        cb2.commit()
        XCTAssertTrue(again === blur, "kept and reused")
    }

    // MARK: - Flakes, drips, buffers

    func testStuckFlakesMelt() throws {
        let (h, _) = try harness()
        for _ in 0..<90 { h.update(frost: 0.3, snow: 1) }
        XCTAssertGreaterThan(h.glass.stuckFlakeCount, 0)
        XCTAssertLessThanOrEqual(h.glass.stuckFlakeCount, WindowGlassLayer.maxFlakes)
        for _ in 0..<360 { h.update(frost: 0.3, snow: 0) }
        XCTAssertEqual(h.glass.stuckFlakeCount, 0)
    }

    func testDripsRunWhileWet() throws {
        let (h, _) = try harness()
        var most = 0
        for _ in 0..<300 { h.update(frost: 0, wetDrips: 1); most = max(most, h.glass.dripCount) }
        XCTAssertGreaterThan(most, 0)
        XCTAssertLessThanOrEqual(most, WindowGlassLayer.maxDrips)
        for _ in 0..<900 { h.update(frost: 0, wetDrips: 0) }
        XCTAssertEqual(h.glass.dripCount, 0, "drips run off and none start when dry")
    }

    func testNoBuffersPerFrame() throws {
        let (h, preview) = try harness()
        for i in 0..<300 {
            h.update(frost: 0.4, condensation: 1, wetDrips: 1, snow: 1)
            if i % 50 == 0 { XCTAssertNotNil(preview.capture(h)) }
        }
        XCTAssertLessThanOrEqual(h.glass.bufferAllocations, 3)
    }

    func testHugeAndOddInputsStayFinite() throws {
        let (h, preview) = try harness()
        h.update(frost: .nan, patches: [GlassPatch(x: .infinity, y: -3, radius: -1, warmth: .nan)], condensation: 9, wetDrips: -2,
                 snow: .infinity, reflection: SIMD4(repeating: .nan), dt: 50)
        XCTAssertTrue(h.glass.frostCoverage.isFinite)
        XCTAssertNotNil(preview.capture(h))
    }
}

extension WorldPreviewTests {
    /// The Window Kit over a Living Sky with snow: frost at three levels, Smooth, a warm patch, and condensation.
    func testWriteWindowKitPreviews() throws {
        guard let dir = ProcessInfo.processInfo.environment["PREVIEW_DIR"] else { throw XCTSkip("PREVIEW_DIR not set") }
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let preview = try XCTUnwrap(PreviewRenderer(width: 1280, height: 720))
        let field = FrostField(seed: 0xCAB1, columns: 3, rows: 2, bar: 0.018)
        func state(hour: Double, weather: WeatherKind) -> SkyState {
            var s = SkySettings(); s.timeMode = .frozen; s.frozenHour = hour; s.frozenPhase = 0.5; s.cityID = "melbourne"
            s.weatherMode = .pick; s.weather = weather
            return LivingSky(settings: s, homeZone: TimeZone(identifier: "Australia/Melbourne")!).step(now: Date(timeIntervalSince1970: 1_793_000_000), dt: 0)
        }
        let cases: [(String, Double, WeatherKind, Float, QualityLevel, [GlassPatch], Float, SIMD4<Float>)] = [
            ("windowkit-frost-0.3-day", 12.5, .lightCloud, 0.3, .high, [], 0.2, .zero),
            ("windowkit-frost-0.6-golden", 18.9, .clear, 0.6, .high, [], 0.4, .zero),
            ("windowkit-frost-0.85-night", 23.0, .snow, 0.85, .high, [], 0.4, SIMD4(1, 0.55, 0.25, 0.06)),
            ("windowkit-frost-0.6-smooth", 12.5, .lightCloud, 0.6, .lite, [], 0.4, .zero),
            ("windowkit-patches", 23.0, .clear, 0.8, .high,
             [GlassPatch(x: 0.3, y: 0.45, radius: 0.06, warmth: 1), GlassPatch(x: 0.62, y: 0.6, radius: 0.08, warmth: 0.5)], 0.3,
             SIMD4(1, 0.55, 0.25, 0.06)),
        ]
        for (name, hour, weather, frost, quality, patches, condensation, reflection) in cases {
            let h = try XCTUnwrap(GlassHarness(device: device, field: field))
            h.quality = quality
            h.spec = WindowSpec(columns: 3, rows: 2, bar: 0.018, rect: SIMD4(-0.82, -0.62, 0.82, 0.8), material: .logWood, frameWidth: 0.05)
            h.sky = SkyLayer(device: device); h.weather = WeatherLayer(device: device)
            let st = state(hour: hour, weather: weather)
            h.sky?.horizonY = -0.4
            let night = st.sun.altitude < -4
            let glint = night ? SIMD4<Float>(1, 0.6, 0.3, 0.2) : SIMD4<Float>(0.9, 0.75, 0.6, 1)
            for i in 0..<120 {
                h.sky?.update(st, quality: quality, size: CGSize(width: 1280, height: 720), time: Float(i) / 30)
                h.weather?.update(st, quality: quality, size: CGSize(width: 1280, height: 720), dt: 1.0 / 30, surface: .ground(horizonY: -0.4))
                h.glass.update(spec: h.spec, frost: frost, patches: patches, condensation: condensation, wetDrips: 0, snow: st.snow,
                               reflection: reflection, glint: glint, quality: quality, dt: 1.0 / 30,
                               outsideLight: (st.horizon + st.zenith) * 0.5, aspect: 16.0 / 9)
            }
            let image = try XCTUnwrap(preview.capture(h))
            try PreviewRenderer.writePNG(image, to: url.appendingPathComponent("\(name).png"))
        }
    }
}
