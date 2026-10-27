import Accelerate
import Foundation
import os

/// The character of the instrument's own sound, each 0...1.
public struct SoundReading: Equatable {
    /// 1 = sharp (plucks, stabs, struck piano) ... 0 = smooth swell (pads).
    public var attack: Double = 0
    /// Spectral centroid / 5 kHz.
    public var brightness: Double = 0
    /// How long the sound rings after release (to -30 dB) / 3 s.
    public var ring: Double = 0
    /// Spectral flatness: 0 pure tone ... 1 noise.
    public var texture: Double = 0
    /// Level, -60 dBFS → 0 ... 0 dBFS → 1.
    public var loudness: Double = 0
    /// Side vs mid energy: 0 mono ... 1 fully wide.
    public var width: Double = 0
    public init() {}
}

/// Analyses a copy of the instrument's output (never the live audio path).
/// `process` runs on the audio tap thread; `reading` can be read from any thread.
public final class SoundCharacterAnalyzer {
    static let fftLog2 = 11
    static let fftSize = 1 << 11
    static let attackWindow = 0.6
    static let ringLimit = 3.0

    private let sampleRate: Double
    private let shared = OSAllocatedUnfairLock(initialState: SoundReading())
    private let pending = OSAllocatedUnfairLock(initialState: (on: false, off: false))
    private var clock = 0
    private var ringBuffer = [Float](repeating: 0, count: SoundCharacterAnalyzer.fftSize)
    private var writeIndex = 0
    private var filled = 0
    private var sinceFFT = 0
    private var lastRMS: Float = 0
    // attack
    private var onset: Int?
    private var attackHistory: [(sample: Int, rms: Float)] = []
    // ring
    private var releaseAt: Int?
    private var releaseRMS: Float = 0
    // FFT
    private let setup: FFTSetup
    private let window: [Float]
    private var real = [Float](repeating: 0, count: SoundCharacterAnalyzer.fftSize / 2)
    private var imag = [Float](repeating: 0, count: SoundCharacterAnalyzer.fftSize / 2)

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
        setup = vDSP_create_fftsetup(vDSP_Length(Self.fftLog2), FFTRadix(kFFTRadix2))!
        var w = [Float](repeating: 0, count: Self.fftSize)
        vDSP_hann_window(&w, vDSP_Length(Self.fftSize), Int32(vDSP_HANN_NORM))
        window = w
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    public var reading: SoundReading { shared.withLock { $0 } }

    /// A note started (measures how quickly the sound arrives).
    public func noteOn() { pending.withLock { $0.on = true; $0.off = false } }

    /// All notes released (measures how long the sound rings).
    public func noteOff() { pending.withLock { $0.off = true } }

    public func process(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int) {
        guard frames > 0 else { return }
        let events = pending.withLock { p -> (on: Bool, off: Bool) in let e = p; p = (false, false); return e }
        if events.on {
            onset = clock
            attackHistory.removeAll(keepingCapacity: true)
            releaseAt = nil
        }
        if events.off {
            releaseAt = clock
            releaseRMS = lastRMS
        }
        let blockStart = clock
        var midEnergy: Float = 0, sideEnergy: Float = 0, sumSq: Float = 0
        for i in 0..<frames {
            let l = left[i], r = right[i]
            let m = (l + r) * 0.5, s = (l - r) * 0.5
            midEnergy += m * m
            sideEnergy += s * s
            sumSq += (l * l + r * r) * 0.5
            ringBuffer[writeIndex] = m
            writeIndex = (writeIndex + 1) & (Self.fftSize - 1)
        }
        clock += frames
        filled = min(Self.fftSize, filled + frames)
        sinceFFT += frames
        let rms = (sumSq / Float(frames)).squareRoot()
        lastRMS = rms

        var r = reading
        r.loudness = rms > 0 ? Double(max(0, min(1, (20 * log10(rms) + 60) / 60))) : 0
        let total = midEnergy + sideEnergy
        r.width = total > 1e-9 ? Double(sideEnergy / total) : 0

        if let start = onset {
            attackHistory.append((blockStart, rms))
            if Double(clock - start) / sampleRate >= Self.attackWindow {
                let peak = attackHistory.map { $0.rms }.max() ?? 0
                if peak > 1e-5, let first = attackHistory.first(where: { $0.rms >= 0.9 * peak }) {
                    let seconds = Double(first.sample - start) / sampleRate
                    r.attack = max(0, min(1, 1 - (seconds - 0.005) / 0.3))
                }
                onset = nil
            }
        }
        if let off = releaseAt {
            let elapsed = Double(clock - off) / sampleRate
            if releaseRMS <= 1e-6 {
                releaseAt = nil
            } else if rms < releaseRMS * 0.0316 {
                r.ring = min(1, elapsed / Self.ringLimit)
                releaseAt = nil
            } else if elapsed >= Self.ringLimit {
                r.ring = 1
                releaseAt = nil
            }
        }
        if filled == Self.fftSize, sinceFFT >= 512 {
            sinceFFT = 0
            spectrum(into: &r)
        }
        let out = r
        shared.withLock { $0 = out }
    }

    private func spectrum(into r: inout SoundReading) {
        let n = Self.fftSize
        var frame = [Float](repeating: 0, count: n)
        for i in 0..<n { frame[i] = ringBuffer[(writeIndex + i) & (n - 1)] * window[i] }
        var power = [Float](repeating: 0, count: n / 2)
        real.withUnsafeMutableBufferPointer { re in
            imag.withUnsafeMutableBufferPointer { im in
                var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                frame.withUnsafeBufferPointer { f in
                    f.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, vDSP_Length(Self.fftLog2), FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(n / 2))
            }
        }
        power[0] = 0   // DC / Nyquist packing
        var total: Float = 0
        vDSP_sve(power, 1, &total, vDSP_Length(n / 2))
        guard total > 1e-10 else { r.brightness = 0; r.texture = 0; return }
        let binHz = Float(sampleRate) / Float(n)
        var weighted: Float = 0
        for i in 1..<(n / 2) { weighted += Float(i) * binHz * power[i] }
        r.brightness = Double(min(1, (weighted / total) / 5000))
        // Flatness over 64 bands of 16 bins (smoother than per-bin).
        let bands = 64, per = (n / 2) / bands
        var logSum: Double = 0, linSum: Double = 0
        for b in 0..<bands {
            var e: Float = 0
            vDSP_meanv(Array(power[(b * per)..<((b + 1) * per)]), 1, &e, vDSP_Length(per))
            let v = Double(e) + 1e-12
            logSum += log(v)
            linSum += v
        }
        let geo = exp(logSum / Double(bands)), arith = linSum / Double(bands)
        r.texture = max(0, min(1, geo / arith))
    }
}
