import Metal
import CoreGraphics
import InStrumCore

enum SkyShaders { static let source = "" }
enum WeatherSurface { case water(horizonY: Float), ground(horizonY: Float), glass, none }
@MainActor final class SkyLayer {
    static func defaultViewAzimuth(latitude: Double) -> Double { 0 }
}
@MainActor final class WeatherLayer {
    init?(device: MTLDevice) { return nil }
    var particleCount = 0
    var exposureBoost: Float = 1
    func update(_ s: SkyState, quality: QualityLevel, size: CGSize, dt: Double, surface: WeatherSurface) {}
}
@MainActor final class SkyOnlyRenderer: ThemeRenderer {
    init?(device: MTLDevice) { return nil }
    func update(_ s: SkyState, quality: QualityLevel, size: CGSize, dt: Double, time: Float, surface: WeatherSurface) {}
    func render(stack: RenderStack, commandBuffer: MTLCommandBuffer) {}
    var post = PostSettings()
}
