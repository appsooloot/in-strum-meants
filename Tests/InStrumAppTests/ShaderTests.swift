import XCTest
import Metal
@testable import InStrumApp

final class ShaderTests: XCTestCase {
    func testMidnightSteinwayShadersCompile() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device on this machine") }
        let library = try device.makeLibrary(source: MidnightSteinwayShaders.source, options: nil)
        for name in ["stage_vertex", "stage_fragment", "key_vertex", "key_fragment"] {
            XCTAssertNotNil(library.makeFunction(name: name), name)
        }
    }
}
