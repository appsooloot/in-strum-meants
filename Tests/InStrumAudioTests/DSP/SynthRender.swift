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

    /// Chord `c` of a run of two-hand chords: eight notes in fourths up from C2, each chord a whole tone above the last
    /// (a semitone more after five), struck at `t` and let go `gap` later, as the next one comes.
    static func handChord(_ c: Int, at t: Double, gap: Double, velocity: UInt8) -> [Event] {
        let root: Int = 36 + 2 * (c % 5) + c / 5
        var events: [Event] = []
        for k in 0..<8 {
            let note = UInt8(root + 5 * k)
            events.append(noteOn(t, note, velocity))
            events.append(noteOff(t + gap, note))
        }
        return events
    }

    /// Two-hand chords `gap` s apart under the pedal on one synth, against the same chords each on a synth of its own,
    /// summed, where nothing is stolen. For each chord from `first` on (once the voices are full, each steals eight at
    /// once): how far (dB) the loudest millisecond above 10 kHz, from 2 ms before it to 25 ms after, rises over the
    /// reference, taken as no quieter than −80 dBFS. With the stealing render, for its own checks.
    static func stealClicks(_ engine: ISDEngine, params: [Int: Float], velocities: [UInt8], gap: Double, from first: Int)
        -> (clicks: [Double], out: (l: [Float], r: [Float])) {
        let seconds = Double(velocities.count - 1) * gap + 0.03
        var all = [pedal(0, 127)]
        for (c, v) in velocities.enumerated() { all += handChord(c, at: Double(c) * gap, gap: gap, velocity: v) }
        let out = render(engine, seconds: seconds, params: params, events: all)
        var refL = [Float](repeating: 0, count: out.l.count), refR = refL
        for (c, v) in velocities.enumerated() {
            let t = Double(c) * gap
            let solo = render(engine, seconds: seconds - t, params: params, events: [pedal(0, 127)] + handChord(c, at: 0, gap: gap, velocity: v))
            let at = Int(t * sr)
            for i in 0..<min(solo.l.count, refL.count - at) {
                refL[at + i] += solo.l[i]
                refR[at + i] += solo.r[i]
            }
        }
        let clicks = (first..<velocities.count).map { c -> Double in
            let t = Double(c) * gap
            let heard = DSPTestKit.loudestHigh(out.l, out.r, from: t - 0.002, to: t + 0.025)
            let reference = DSPTestKit.loudestHigh(refL, refR, from: t - 0.002, to: t + 0.025)
            return heard - max(reference, -80)
        }
        return (clicks, out)
    }

    /// `dial` jumps from 0 to 1 at `t`: how far (dB) the loudest millisecond above 10 kHz, from 2 ms before to 25 ms
    /// after, rises over the same notes with the dial held at 0 and at 1 (taken as no quieter than −80 dBFS).
    static func jumpClick(_ engine: ISDEngine, params: [Int: Float], dial: Int, at t: Double, events: [Event]) -> Double {
        var low = params, high = params
        low[dial] = 0
        high[dial] = 1
        let seconds = t + 0.1
        let jump = render(engine, seconds: seconds, params: low, events: events, changes: [ParamChange(time: t, address: dial, value: 1)])
        let still0 = render(engine, seconds: seconds, params: low, events: events)
        let still1 = render(engine, seconds: seconds, params: high, events: events)
        let heard = DSPTestKit.loudestHigh(jump.l, jump.r, from: t - 0.002, to: t + 0.025)
        let held0 = DSPTestKit.loudestHigh(still0.l, still0.r, from: t - 0.002, to: t + 0.025)
        let held1 = DSPTestKit.loudestHigh(still1.l, still1.r, from: t - 0.002, to: t + 0.025)
        return heard - max(held0, held1, -80)
    }
}
