import Accelerate
import CoreGraphics
import Foundation

/// Renders audio as a log-frequency spectrogram (30 Hz–16 kHz), so sounds can be checked by eye.
enum Spectrogram {
    static func image(left x: [Float], sampleRate: Double, width: Int, height: Int) -> CGImage {
        let log2n = 12, n = 1 << log2n, half = n / 2
        let setup = vDSP_create_fftsetup(vDSP_Length(log2n), FFTRadix(kFFTRadix2))!
        defer { vDSP_destroy_fftsetup(setup) }
        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        let hop = max(1, (x.count - n) / max(1, width))
        let binHz = sampleRate / Double(n)
        // Row y → FFT bin (top row is 16 kHz).
        let rows: [Int] = (0..<height).map { y in
            let f = 30.0 * pow(16_000.0 / 30.0, 1.0 - Double(y) / Double(max(1, height - 1)))
            return min(half - 1, max(1, Int(f / binHz)))
        }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        var frame = [Float](repeating: 0, count: n), re = [Float](repeating: 0, count: half), im = [Float](repeating: 0, count: half)
        var mags = [Float](repeating: 0, count: half)
        for col in 0..<width {
            let start = col * hop
            for i in 0..<n { frame[i] = start + i < x.count ? x[start + i] * window[i] : 0 }
            re.withUnsafeMutableBufferPointer { rp in
                im.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    frame.withUnsafeBufferPointer { f in
                        f.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half)) }
                    }
                    vDSP_fft_zrip(setup, &split, 1, vDSP_Length(log2n), FFTDirection(FFT_FORWARD))
                    vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(half))
                }
            }
            for (y, bin) in rows.enumerated() {
                let db = 20 * log10(Double(mags[bin]) / Double(n) + 1e-12)
                let t = max(0, min(1, (db + 120) / 100))
                let (r, g, b) = color(t)
                let p = (y * width + col) * 4
                pixels[p] = r; pixels[p + 1] = g; pixels[p + 2] = b; pixels[p + 3] = 255
            }
        }
        let ctx = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }

    /// Dark → violet → orange → pale yellow.
    private static func color(_ t: Double) -> (UInt8, UInt8, UInt8) {
        let stops: [(Double, Double, Double, Double)] = [(0, 0, 0, 4), (0.3, 60, 15, 110), (0.55, 180, 50, 100), (0.8, 250, 140, 60), (1, 252, 250, 190)]
        for i in 1..<stops.count where t <= stops[i].0 {
            let a = stops[i - 1], b = stops[i], u = (t - a.0) / (b.0 - a.0)
            return (UInt8(a.1 + (b.1 - a.1) * u), UInt8(a.2 + (b.2 - a.2) * u), UInt8(a.3 + (b.3 - a.3) * u))
        }
        return (252, 250, 190)
    }
}
