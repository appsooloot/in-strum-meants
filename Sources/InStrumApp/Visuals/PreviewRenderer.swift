import Metal
import CoreGraphics
import ImageIO
import Foundation
import InStrumCore

/// Renders themes off-screen from the scripted demo performance, so frames can be
/// checked (and saved as PNGs) without a window.
@MainActor
final class PreviewRenderer {
    let width: Int, height: Int
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let stack: RenderStack
    private let target: MTLTexture

    init?(width: Int, height: Int) {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let stack = RenderStack(device: device, pixelFormat: .bgra8Unorm) else { return nil }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        guard let target = device.makeTexture(descriptor: d) else { return nil }
        stack.resize(width: width, height: height)
        self.width = width; self.height = height
        self.device = device; self.queue = queue; self.stack = stack; self.target = target
    }

    /// Simulates the demo performance at 60 fps through the app's SceneDirector and captures
    /// a frame of `themeID` at each time (seconds).
    func render(themeID: String, at times: [Double], state: ThemeState = ThemeState(), quality: QualityLevel = .high) -> [CGImage] {
        let director = SceneDirector(themeID: themeID, state: state, reaction: ReactionPresets.expressivePianist)
        var perf = PerformanceState()
        let script = ScriptedPerformance.demo
        var next = 0, time = 0.0
        let dt = 1.0 / 60
        var garden: ButterflyRenderer?, steinway: SteinwayRenderer?
        var images: [CGImage] = []
        for t in times.sorted() {
            var current: ThemeRenderer?
            while time + dt <= t || current == nil {
                time += dt
                var events: [PerformanceEvent] = []
                while next < script.count, script[next].time <= time {
                    events += perf.apply(script[next].message, at: script[next].time)
                    next += 1
                }
                director.handle(events, at: time)
                let frame = director.step(dt: dt, t: time, quality: quality)
                let size = CGSize(width: width, height: height)
                if let g = frame as? GardenFrame {
                    if garden == nil { garden = ButterflyRenderer(device: device) }
                    garden?.update(g, params: director.parameters, quality: quality, gentle: false, dt: dt, size: size)
                    current = garden
                } else if let f = frame as? SteinwayFrame {
                    if steinway == nil { steinway = SteinwayRenderer(device: device) }
                    steinway?.update(f, quality: quality, gentle: false, dt: dt)
                    current = steinway
                }
                if time + dt > t { break }
            }
            if let r = current, let image = capture(r) { images.append(image) }
        }
        return images
    }

    func renderButterflyGarden(at times: [Double], params: ParameterSet? = nil) -> [CGImage] {
        render(themeID: ButterflyGardenModel.id, at: times, state: ThemeState(values: params?.saved ?? [:]))
    }

    private func capture(_ renderer: ThemeRenderer) -> CGImage? {
        guard let cb = queue.makeCommandBuffer() else { return nil }
        renderer.render(stack: stack, commandBuffer: cb)
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        stack.post(into: pass, commandBuffer: cb, settings: renderer.post)
        let bytesPerRow = width * 4
        guard let out = device.makeBuffer(length: bytesPerRow * height, options: .storageModeShared),
              let blit = cb.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: target, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: width, height: height, depth: 1),
                  to: out, destinationOffset: 0, destinationBytesPerRow: bytesPerRow, destinationBytesPerImage: bytesPerRow * height)
        blit.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        let data = Data(bytes: out.contents(), count: bytesPerRow * height)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info, provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }

    private static func luminances(_ image: CGImage) -> [Double] {
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        ctx?.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var out = [Double](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            let r = Double(pixels[i * 4]), g = Double(pixels[i * 4 + 1]), b = Double(pixels[i * 4 + 2])
            let y: Double = 0.2126 * r + 0.7152 * g + 0.0722 * b
            out[i] = y / 255
        }
        return out
    }

    static func stats(_ image: CGImage) -> (meanLuminance: Double, variance: Double) {
        let l = luminances(image)
        let mean = l.reduce(0, +) / Double(l.count)
        let variance = l.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(l.count)
        return (mean, variance)
    }

    /// Mean absolute luminance difference (images must be the same size).
    static func difference(_ a: CGImage, _ b: CGImage) -> Double {
        let la = luminances(a), lb = luminances(b)
        return zip(la, lb).reduce(0) { $0 + abs($1.0 - $1.1) } / Double(la.count)
    }
}

