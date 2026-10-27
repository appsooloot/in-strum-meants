import XCTest
import Metal
@testable import InStrumApp

@MainActor
final class RenderStackTests: XCTestCase {
    private func makeStack() throws -> RenderStack {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        guard let stack = RenderStack(device: device, pixelFormat: .bgra8Unorm) else { return XCTFail("stack") as! RenderStack }
        return stack
    }
    func testPostShadersCompile() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let lib = try device.makeLibrary(source: PostShaders.source, options: nil)
        for name in ["fullscreen_vertex", "bright_pass", "downsample", "upsample", "dof_gather", "composite"] {
            XCTAssertNotNil(lib.makeFunction(name: name), name)
        }
    }
    func testResizeAllocatesTargets() throws {
        let s = try makeStack()
        s.resize(width: 640, height: 360)
        XCTAssertEqual(s.hdrTarget?.width, 640)
        XCTAssertEqual(s.hdrTarget?.pixelFormat, .rgba16Float)
        XCTAssertEqual(s.depthTarget?.height, 360)
    }
    func testResizeToZeroIsHarmless() throws {
        let s = try makeStack()
        s.resize(width: 640, height: 360)
        s.resize(width: 0, height: 0)
        XCTAssertEqual(s.hdrTarget?.width, 640)
        s.resize(width: 1920, height: 1080)
        XCTAssertEqual(s.hdrTarget?.width, 1920)
    }
}
