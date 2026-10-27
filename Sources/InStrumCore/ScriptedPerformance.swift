/// An 18-second demo performance used for preview frames and tests:
/// soft melody, hard notes, a pedalled chord, a fast run, a crescendo, then silence.
public enum ScriptedPerformance {
    public static let duration = 18.0

    public static let demo: [(time: Double, message: MIDIMessage)] = {
        var m: [(Double, MIDIMessage)] = []
        func note(_ t: Double, _ n: UInt8, _ v: UInt8, _ len: Double) {
            m.append((t, .noteOn(channel: 0, note: n, velocity: v)))
            m.append((t + len, .noteOff(channel: 0, note: n, velocity: 50)))
        }
        // 0–2 s: soft melody
        for (i, n) in [72, 74, 76, 79, 76].enumerated() { note(Double(i) * 0.4, UInt8(n), 32, 0.35) }
        // 2–3.5 s: hard notes, low and high
        note(2.0, 36, 120, 1.2); note(2.4, 67, 115, 0.9); note(2.8, 96, 125, 0.6)
        // 3.5–6 s: pedal + held chord
        m.append((3.5, .controlChange(channel: 0, controller: 64, value: 127)))
        for n in [60, 64, 67, 72] { note(3.6, UInt8(n), 92, 2.0) }
        m.append((6.0, .controlChange(channel: 0, controller: 64, value: 0)))
        // 6–7.5 s: fast run
        let run: [UInt8] = [60, 62, 64, 65, 67, 69, 71, 72, 74, 76, 77, 79, 81, 83, 84, 86, 88, 89, 91, 93, 95, 96]
        for (i, n) in run.enumerated() { note(6.0 + Double(i) * 0.06, n, 82, 0.08) }
        // 7.5–9 s: crescendo
        for i in 0..<6 { note(7.6 + Double(i) * 0.25, UInt8(55 + i * 2), UInt8(50 + i * 14), 0.2) }
        // 9–18 s: silence (butterflies land after 4 s)
        return m.sorted { $0.0 < $1.0 }
    }()
}
