import XCTest
import Metal
@testable import InStrumApp
@testable import InStrumCore

@MainActor
final class ButterflyRendererTests: XCTestCase {
    func testButterflyShadersCompile() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let lib = try device.makeLibrary(source: ButterflyShaders.source, options: nil)
        for name in ["sky_vertex", "sky_fragment", "sprite_vertex", "butterfly_fragment", "bloom_fragment",
                     "particle_vertex", "particle_fragment", "keys_vertex", "keys_fragment"] {
            XCTAssertNotNil(lib.makeFunction(name: name), name)
        }
    }

    func testRendersNonBlackStructuredFrame() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        let preview = try XCTUnwrap(PreviewRenderer(width: 640, height: 360))
        let image = try XCTUnwrap(preview.renderButterflyGarden(at: [3]).first)
        let s = PreviewRenderer.stats(image)
        XCTAssertGreaterThan(s.meanLuminance, 0.05)
        XCTAssertGreaterThan(s.variance, 0.002)
    }

    func testButterfliesChangeTheImage() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        let preview = try XCTUnwrap(PreviewRenderer(width: 320, height: 180))
        let quiet = try XCTUnwrap(preview.renderButterflyGarden(at: [0.01]).first)
        let busy = try XCTUnwrap(preview.renderButterflyGarden(at: [5]).first)
        XCTAssertGreaterThan(PreviewRenderer.difference(quiet, busy), 0.01)
    }
}

@MainActor
final class PreviewRenderTests: XCTestCase {
    /// Writes preview frames when PREVIEW_DIR is set (CI previews job).
    func testWritePreviewFrames() throws {
        guard let dir = ProcessInfo.processInfo.environment["PREVIEW_DIR"] else { throw XCTSkip("PREVIEW_DIR not set") }
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let preview = try XCTUnwrap(PreviewRenderer(width: 1280, height: 720))
        let times: [Double] = [1, 3, 5, 7, 17]
        let images = preview.renderButterflyGarden(at: times)
        XCTAssertEqual(images.count, times.count)
        for (t, image) in zip(times, images) {
            try PreviewRenderer.writePNG(image, to: url.appendingPathComponent("butterfly-t\(Int(t)).png"))
        }
        if let image = preview.render(themeID: MidnightSteinwayModel.id, at: [5]).first {
            try PreviewRenderer.writePNG(image, to: url.appendingPathComponent("steinway-t5.png"))
        }
        for tod in ["Dawn", "Moonlight"] {
            var p = ParameterSet(specs: ButterflyGardenModel.parameters, macroTargets: ButterflyGardenModel.macroTargets)
            p.set("time", .choice(tod))
            if let image = preview.renderButterflyGarden(at: [5], params: p).first {
                try PreviewRenderer.writePNG(image, to: url.appendingPathComponent("butterfly-\(tod.lowercased())-t5.png"))
            }
        }
    }
}
