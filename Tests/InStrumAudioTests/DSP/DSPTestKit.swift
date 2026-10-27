import Accelerate
import Foundation

/// Measurement helpers for offline DSP renders.
enum DSPTestKit {
    static let sampleRate = 48_000.0

    /// Frequency of the strongest peak within ±60 cents of `hz` (Hann window, zero-padded to 2^18, parabolic interpolation).
    static func fundamental(_ x: [Float], sampleRate: Double, near hz: Double) -> Double {
        let log2n = 18, n = 1 << log2n
        let count = min(x.count, n)
        var buf = [Float](repeating: 0, count: n)
        var w = [Float](repeating: 0, count: count)
        vDSP_hann_window(&w, vDSP_Length(count), Int32(vDSP_HANN_NORM))
        for i in 0..<count { buf[i] = x[i] * w[i] }
        let mags = magnitudes(buf, log2n: log2n)
        let binHz = sampleRate / Double(n)
        let lo = max(1, Int(hz * pow(2, -60.0 / 1200) / binHz)), hi = min(mags.count - 2, Int(hz * pow(2, 60.0 / 1200) / binHz) + 1)
        guard lo < hi else { return 0 }
        var best = lo
        for i in lo...hi where mags[i] > mags[best] { best = i }
        let a = log(Double(mags[best - 1]) + 1e-30), b = log(Double(mags[best]) + 1e-30), c = log(Double(mags[best + 1]) + 1e-30)
        let d = a - 2 * b + c
        let offset = d != 0 ? 0.5 * (a - c) / d : 0
        return (Double(best) + offset) * binHz
    }

    /// Spectral centroid in Hz of the whole slice.
    static func centroid(_ x: [Float], sampleRate: Double) -> Double {
        var log2n = 10
        while (1 << (log2n + 1)) <= x.count && log2n < 18 { log2n += 1 }
        let n = 1 << log2n
        var buf = Array(x.prefix(n))
        if buf.count < n { buf += [Float](repeating: 0, count: n - buf.count) }
        var w = [Float](repeating: 0, count: n)
        vDSP_hann_window(&w, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        vDSP_vmul(buf, 1, w, 1, &buf, 1, vDSP_Length(n))
        let mags = magnitudes(buf, log2n: log2n)
        let binHz = sampleRate / Double(n)
        var num = 0.0, den = 0.0
        for i in 1..<mags.count { let p = Double(mags[i]) * Double(mags[i]); num += Double(i) * binHz * p; den += p }
        return den > 0 ? num / den : 0
    }

    /// Energy (sum of squared magnitudes) between two frequencies, from an FFT of the slice.
    static func bandEnergy(_ x: [Float], sampleRate: Double, from f0: Double, to f1: Double) -> Double {
        var log2n = 10
        while (1 << (log2n + 1)) <= x.count && log2n < 18 { log2n += 1 }
        let n = 1 << log2n
        var buf = Array(x.prefix(n))
        if buf.count < n { buf += [Float](repeating: 0, count: n - buf.count) }
        let mags = magnitudes(buf, log2n: log2n)
        let binHz = sampleRate / Double(n)
        var e = 0.0
        for i in 1..<mags.count where Double(i) * binHz >= f0 && Double(i) * binHz <= f1 { e += Double(mags[i]) * Double(mags[i]) }
        return e
    }

    /// RMS level in dBFS (silence gives -200).
    static func dBFS<C: Collection>(_ x: C) -> Double where C.Element == Float {
        guard !x.isEmpty else { return -200 }
        var sum = 0.0
        for v in x { sum += Double(v) * Double(v) }
        let rms = (sum / Double(x.count)).squareRoot()
        return rms > 0 ? 20 * log10(rms) : -200
    }

    static func maxJump(_ x: [Float]) -> Float {
        var m: Float = 0
        for i in 1..<max(1, x.count) { m = max(m, abs(x[i] - x[i - 1])) }
        return m
    }

    static func correlation(_ a: ArraySlice<Float>, _ b: ArraySlice<Float>) -> Double {
        let n = min(a.count, b.count)
        guard n > 1 else { return 0 }
        let aa = Array(a.prefix(n)).map(Double.init), bb = Array(b.prefix(n)).map(Double.init)
        let ma = aa.reduce(0, +) / Double(n), mb = bb.reduce(0, +) / Double(n)
        var sab = 0.0, saa = 0.0, sbb = 0.0
        for i in 0..<n { let x = aa[i] - ma, y = bb[i] - mb; sab += x * y; saa += x * x; sbb += y * y }
        return saa > 0 && sbb > 0 ? sab / (saa * sbb).squareRoot() : 0
    }

    static func cents(_ f: Double, _ ref: Double) -> Double { 1200 * log2(f / ref) }

    /// Seconds → sample index at the kit's sample rate.
    static func at(_ seconds: Double, _ sr: Double = sampleRate) -> Int { Int(seconds * sr) }

    private static func magnitudes(_ input: [Float], log2n: Int) -> [Float] {
        let n = 1 << log2n
        guard let setup = vDSP_create_fftsetup(vDSP_Length(log2n), FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(setup) }
        var re = [Float](repeating: 0, count: n / 2), im = [Float](repeating: 0, count: n / 2)
        var out = [Float](repeating: 0, count: n / 2)
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                input.withUnsafeBufferPointer { p in
                    p.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, vDSP_Length(log2n), FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &out, 1, vDSP_Length(n / 2))
            }
        }
        out[0] = 0
        return out
    }
}
