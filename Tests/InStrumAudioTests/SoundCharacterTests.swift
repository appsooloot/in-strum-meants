import XCTest
@testable import InStrumAudio

final class SoundCharacterTests: XCTestCase {
    let sr = 44_100.0

    private func feed(_ a: SoundCharacterAnalyzer, seconds: Double, _ f: (Double) -> (Float, Float)) {
        let n = Int(seconds * sr)
        var l = [Float](repeating: 0, count: 512), r = [Float](repeating: 0, count: 512)
        var i = 0
        while i < n {
            let count = min(512, n - i)
            for k in 0..<count { (l[k], r[k]) = f(Double(i + k) / sr) }
            a.process(left: l, right: r, frames: count)
            i += count
        }
    }
    private func mono(_ x: Float) -> (Float, Float) { (x, x) }
    private func sine(_ hz: Double, _ t: Double) -> Float { Float(sin(2 * .pi * hz * t)) * 0.5 }

    func testClickIsSharp() {
        let a = SoundCharacterAnalyzer(sampleRate: sr)
        a.noteOn()
        feed(a, seconds: 0.8) { t in self.mono(Float(exp(-t / 0.005)) * self.sine(440, t)) }
        XCTAssertGreaterThan(a.reading.attack, 0.8)
    }
    func testSwellIsSmooth() {
        let a = SoundCharacterAnalyzer(sampleRate: sr)
        a.noteOn()
        feed(a, seconds: 0.8) { t in self.mono(Float(min(1, t / 0.4)) * self.sine(440, t)) }
        XCTAssertLessThan(a.reading.attack, 0.3)
    }
    func testLowToneIsDark() {
        let a = SoundCharacterAnalyzer(sampleRate: sr)
        feed(a, seconds: 0.3) { t in self.mono(self.sine(200, t)) }
        XCTAssertLessThan(a.reading.brightness, 0.15)
    }
    func testHighToneIsBright() {
        let a = SoundCharacterAnalyzer(sampleRate: sr)
        feed(a, seconds: 0.3) { t in self.mono(self.sine(6000, t)) }
        XCTAssertGreaterThan(a.reading.brightness, 0.8)
    }
    func testNoiseIsTexturedSineIsPure() {
        let noisy = SoundCharacterAnalyzer(sampleRate: sr)
        var rng = SystemRandomNumberGenerator()
        feed(noisy, seconds: 0.3) { _ in self.mono(Float.random(in: -0.5...0.5, using: &rng)) }
        XCTAssertGreaterThan(noisy.reading.texture, 0.6)
        let pure = SoundCharacterAnalyzer(sampleRate: sr)
        feed(pure, seconds: 0.3) { t in self.mono(self.sine(440, t)) }
        XCTAssertLessThan(pure.reading.texture, 0.1)
    }
    func testLongDecayRingsLonger() {
        func ring(_ tau: Double) -> Double {
            let a = SoundCharacterAnalyzer(sampleRate: sr)
            a.noteOn()
            feed(a, seconds: 0.2) { t in self.mono(self.sine(440, t)) }
            a.noteOff()
            feed(a, seconds: 3.2) { t in self.mono(Float(exp(-t / tau)) * self.sine(440, t)) }
            return a.reading.ring
        }
        XCTAssertGreaterThan(ring(0.6), ring(0.03) + 0.2)
    }
    func testWidth() {
        let m = SoundCharacterAnalyzer(sampleRate: sr)
        feed(m, seconds: 0.2) { t in self.mono(self.sine(440, t)) }
        XCTAssertLessThan(m.reading.width, 0.05)
        let w = SoundCharacterAnalyzer(sampleRate: sr)
        feed(w, seconds: 0.2) { t in let s = self.sine(440, t); return (s, -s) }
        XCTAssertGreaterThan(w.reading.width, 0.9)
    }
    func testSilenceIsQuiet() {
        let a = SoundCharacterAnalyzer(sampleRate: sr)
        feed(a, seconds: 0.2) { _ in (0, 0) }
        XCTAssertEqual(a.reading.loudness, 0, accuracy: 0.01)
        let b = SoundCharacterAnalyzer(sampleRate: sr)
        feed(b, seconds: 0.3) { t in self.mono(self.sine(440, t) * 2) }
        XCTAssertGreaterThan(b.reading.loudness, 0.8)
    }
}
