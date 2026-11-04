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

    /// Spectral centroid of the average spectrum (Welch: 8192-sample Hann segments, 50% overlap), for long or sparse signals.
    static func averageCentroid(_ x: [Float], sampleRate: Double) -> Double {
        let log2n = 13, n = 1 << log2n
        guard x.count >= n else { return centroid(x, sampleRate: sampleRate) }
        var w = [Float](repeating: 0, count: n)
        vDSP_hann_window(&w, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        var power = [Double](repeating: 0, count: n / 2)
        var start = 0
        while start + n <= x.count {
            var seg = Array(x[start..<(start + n)])
            vDSP_vmul(seg, 1, w, 1, &seg, 1, vDSP_Length(n))
            let mags = magnitudes(seg, log2n: log2n)
            for i in 1..<mags.count { power[i] += Double(mags[i]) * Double(mags[i]) }
            start += n / 2
        }
        let binHz = sampleRate / Double(n)
        var num = 0.0, den = 0.0
        for i in 1..<power.count { num += Double(i) * binHz * power[i]; den += power[i] }
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

    /// The largest |sample|.
    static func peak(_ x: [Float]) -> Float {
        var m: Float = 0
        vDSP_maxmgv(x, 1, &m, vDSP_Length(x.count))
        return m
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

    /// Power spectrum of `x` zero-padded to `size` (a power of two), 4-term Blackman–Harris window:
    /// sidelobes below −92 dB, so a sinusoid's leakage beyond ±5 bins stays near −87 dB (Hann leaks −40 dB past ±3).
    static func powerSpectrum(_ x: [Float], size: Int) -> [Double] {
        var log2n = 0
        while (1 << log2n) < size { log2n += 1 }
        let n = 1 << log2n
        var buf = [Float](repeating: 0, count: n)
        let m = min(x.count, n)
        for i in 0..<m {
            let t = 2 * Double.pi * Double(i) / Double(max(1, m - 1))
            let w = 0.35875 - 0.48829 * cos(t) + 0.14128 * cos(2 * t) - 0.01168 * cos(3 * t)
            buf[i] = x[i] * Float(w)
        }
        return magnitudes(buf, log2n: log2n).map { Double($0) * Double($0) }
    }

    /// Power-weighted mean frequency within ±`cents` of `hz` (Hann window, zero-padded to 2^18): the centre of a
    /// detuned unison cluster, which a single-peak search cannot find while the voices beat.
    static func clusterCentre(_ x: [Float], sampleRate: Double, near hz: Double, cents: Double = 30) -> Double {
        let log2n = 18, n = 1 << log2n
        let count = min(x.count, n)
        var buf = [Float](repeating: 0, count: n)
        var w = [Float](repeating: 0, count: count)
        vDSP_hann_window(&w, vDSP_Length(count), Int32(vDSP_HANN_NORM))
        for i in 0..<count { buf[i] = x[i] * w[i] }
        let mags = magnitudes(buf, log2n: log2n)
        let binHz = sampleRate / Double(n), lo = hz * pow(2, -cents / 1200), hi = hz * pow(2, cents / 1200)
        var num = 0.0, den = 0.0
        for (i, m) in mags.enumerated() {
            let f = Double(i) * binHz
            guard f >= lo, f <= hi else { continue }
            let p = Double(m) * Double(m)
            num += f * p; den += p
        }
        return den > 0 ? num / den : 0
    }

    static func cents(_ f: Double, _ ref: Double) -> Double { 1200 * log2(f / ref) }

    /// An RBJ high-pass biquad in Double (transposed direct form II).
    struct HighPass {
        var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0, z1 = 0.0, z2 = 0.0

        init(_ hz: Double, q: Double, sampleRate: Double) {
            let w: Double = 2 * Double.pi * hz / sampleRate
            let al: Double = sin(w) / (2 * q), c: Double = cos(w), a0: Double = 1 + al
            b0 = (1 + c) / 2 / a0; b1 = -(1 + c) / a0; b2 = b0; a1 = -2 * c / a0; a2 = (1 - al) / a0
        }

        mutating func run(_ x: Double) -> Double {
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            return y
        }
    }

    /// The loudest millisecond above 10 kHz (dBFS) between two times, on the louder side: 1 ms windows every 0.5 ms
    /// through an 8th-order Butterworth high-pass (four biquads) settled over the 5 ms before. A click spreads into
    /// this band, where the instruments have little of their own, and a pan step that cancels in a mono mix still
    /// shows on one side.
    static func loudestHigh(_ l: [Float], _ r: [Float], from t0: Double, to t1: Double, sampleRate sr: Double = sampleRate) -> Double {
        max(loudestHigh(side: l, from: t0, to: t1, sampleRate: sr), loudestHigh(side: r, from: t0, to: t1, sampleRate: sr))
    }

    private static func loudestHigh(side x: [Float], from t0: Double, to t1: Double, sampleRate sr: Double) -> Double {
        var filters = [0.5098, 0.6013, 0.9000, 2.5629].map { HighPass(10_000, q: $0, sampleRate: sr) }
        let start = Int(t0 * sr), end = min(x.count, Int(t1 * sr)), warm = max(0, start - Int(0.005 * sr))
        guard end > start else { return -200 }
        var y = [Double](repeating: 0, count: end - warm)
        for i in warm..<end {
            var v = Double(x[i])
            for k in 0..<filters.count { v = filters[k].run(v) }
            y[i - warm] = v
        }
        let w = Int(0.001 * sr), hop = w / 2
        var loudest = -200.0, i = start - warm
        while i + w <= y.count {
            var s = 0.0
            for k in i..<(i + w) { s += y[k] * y[k] }
            loudest = max(loudest, 10 * log10(s / Double(w) + 1e-30))
            i += hop
        }
        return loudest
    }

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
