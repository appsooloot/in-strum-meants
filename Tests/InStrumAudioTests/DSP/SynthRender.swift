import Foundation
import InStrumDSP

/// Offline renders of a built-in engine through the C API, with sample-accurate events.
enum SynthRender {
    static let sr = DSPTestKit.sampleRate

    struct Event { let time: Double; let bytes: [UInt8] }
    struct ParamChange { let time: Double; let address: Int; let value: Float }

    static func noteOn(_ t: Double, _ note: UInt8, _ velocity: UInt8) -> Event { Event(time: t, bytes: [0x90, note, velocity]) }
    static func noteOff(_ t: Double, _ note: UInt8) -> Event { Event(time: t, bytes: [0x80, note, 0]) }
    static func pedal(_ t: Double, _ value: UInt8) -> Event { Event(time: t, bytes: [0xB0, 64, value]) }

    static func render(_ engine: ISDEngine = ISD_ENGINE_FELT_GLASS, seconds: Double, params: [Int: Float] = [:],
                       events: [Event], changes: [ParamChange] = [], block: Int = 256,
                       sampleRate: Double = sr) -> (l: [Float], r: [Float]) {
        guard let synth = isd_synth_create(engine, sampleRate, Int32(block)) else { return ([], []) }
        defer { isd_synth_destroy(synth) }
        for (address, value) in params { isd_synth_set_param(synth, Int32(address), value) }
        let total = Int(seconds * sampleRate)
        var left = [Float](repeating: 0, count: total), right = [Float](repeating: 0, count: total)
        let sorted = events.sorted { $0.time < $1.time }, pending = changes.sorted { $0.time < $1.time }
        var e = 0, c = 0, i = 0
        while i < total {
            let n = min(block, total - i)
            while c < pending.count, Int(pending[c].time * sampleRate) < i + n {
                isd_synth_set_param(synth, Int32(pending[c].address), pending[c].value); c += 1
            }
            while e < sorted.count, Int(sorted[e].time * sampleRate) < i + n {
                let offset = max(0, Int(sorted[e].time * sampleRate) - i)
                sorted[e].bytes.withUnsafeBufferPointer { isd_synth_midi(synth, $0.baseAddress, Int32($0.count), Int32(offset)) }
                e += 1
            }
            left.withUnsafeMutableBufferPointer { lp in
                right.withUnsafeMutableBufferPointer { rp in
                    isd_synth_render(synth, lp.baseAddress! + i, rp.baseAddress! + i, Int32(n))
                }
            }
            i += n
        }
        return (left, right)
    }

    static func slice(_ x: [Float], _ a: Double, _ b: Double, sampleRate: Double = sr) -> [Float] {
        Array(x[min(x.count, Int(a * sampleRate))..<min(x.count, Int(b * sampleRate))])
    }

    static func maxAbsDifference(_ a: [Float], _ b: [Float]) -> Float {
        zip(a, b).reduce(0) { max($0, abs($1.0 - $1.1)) }
    }
}
