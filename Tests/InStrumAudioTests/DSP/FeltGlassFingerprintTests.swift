import XCTest
import InStrumDSP

/// Felt Glass's sound, locked before its strings moved into the shared piano core (PianoStrings.hpp).
/// A characterisation test: the numbers are today's engine, measured with the local g++ mirror.
final class FeltGlassFingerprintTests: XCTestCase {
    typealias R = SynthRender

    /// Left-channel RMS (dBFS) of each 100 ms window of the phrase.
    static let rmsDB: [Double] = [
        -37.474, -37.661, -29.807, -30.577, -23.092, -23.908, -19.392, -21.147, -16.377, -18.382,
        -19.164, -20.953, -22.729, -24.250, -25.299, -26.223, -27.126, -28.220, -29.505, -30.569,
        -31.512, -32.168, -32.811, -33.426, -34.274, -35.716, -36.693, -37.592, -37.886, -38.930,
        -41.406, -43.079, -43.548, -44.258, -45.303, -45.928, -46.315, -46.413, -47.132, -47.771,
    ]
    /// Average spectral centroid (Hz) of each second.
    static let centroids: [Double] = [1469.5, 1227.7, 887.9, 698.4]

    /// Pedal down; seven notes rising 0.2 s apart at varied velocities; two released at 2 s; pedal up at 3 s.
    static func phrase() -> [Float] {
        let notes: [UInt8] = [36, 48, 60, 64, 67, 72, 84], velocities: [UInt8] = [40, 64, 90, 110, 127, 80, 60]
        var events = [R.pedal(0, 127)]
        for i in 0..<7 { events.append(R.noteOn(0.2 * Double(i), notes[i], velocities[i])) }
        events += [R.noteOff(2.0, 60), R.noteOff(2.0, 64), R.pedal(3.0, 0)]
        return R.render(ISD_ENGINE_FELT_GLASS, seconds: 4, params: [Int(ISD_P_SPACE): 0], events: events).l
    }

    func testSoundsExactlyAsBefore() {
        let out = Self.phrase()
        let rms = (0..<40).map { DSPTestKit.dBFS(R.slice(out, Double($0) * 0.1, Double($0 + 1) * 0.1)) }
        let cents = (0..<4).map { DSPTestKit.averageCentroid(R.slice(out, Double($0), Double($0 + 1)), sampleRate: R.sr) }
        var ok = true
        for (i, (got, want)) in zip(rms, Self.rmsDB).enumerated() where want > -80 && abs(got - want) > 0.1 {
            ok = false
            XCTFail("window \(i): \(String(format: "%.3f", got)) dB, locked \(want)")
        }
        for (i, (got, want)) in zip(cents, Self.centroids).enumerated() where abs(got / want - 1) > 0.01 {
            ok = false
            XCTFail("second \(i): centroid \(String(format: "%.1f", got)) Hz, locked \(want)")
        }
        if !ok {
            print("FINGERPRINT rms: " + rms.map { String(format: "%.3f", $0) }.joined(separator: ", "))
            print("FINGERPRINT centroids: " + cents.map { String(format: "%.1f", $0) }.joined(separator: ", "))
        }
    }
}
