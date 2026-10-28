/// Short original demo phrases for the built-in instruments (rendered into the demo audio on each release).
/// Original material: no melodies from the inspiring songs.
public enum DemoPhrases {
    public typealias Phrase = [(time: Double, message: MIDIMessage)]

    /// Soft single notes, a pedalled Fmaj9 → Em7 → Dm9 → Cmaj9, a hard low note, a high glassy run, then silence.
    public static let feltGlass: Phrase = {
        var m = Builder()
        for (i, n) in [74, 78, 81, 76, 71, 74].enumerated() { m.note(0.2 + Double(i) * 0.5, UInt8(n), UInt8(38 + i * 3), 0.45) }
        let chords: [[UInt8]] = [[53, 57, 60, 64, 67], [52, 55, 59, 62, 67], [50, 53, 57, 60, 64], [48, 52, 55, 59, 62]]
        for (c, chord) in chords.enumerated() {
            let t = 3.5 + Double(c) * 2.2
            m.pedal(t - 0.03, down: false); m.pedal(t + 0.06, down: true)
            for (k, n) in chord.enumerated() { m.note(t + Double(k) * 0.02, n, UInt8(62 + k * 2), 2.0) }
        }
        m.pedal(12.4, down: false)
        m.note(12.6, 33, 118, 2.0)
        m.pedal(15.0, down: true)
        for (i, n) in [84, 86, 88, 91, 93, 96, 98, 100].enumerated() { m.note(15.1 + Double(i) * 0.11, UInt8(n), 56, 0.3) }
        m.pedal(19.5, down: false)
        return m.sorted
    }()

    /// Long, overlapping E♭ / B♭ / Cm / A♭maj7 chords, then one short chord to show the response.
    public static let orbitPad: Phrase = {
        var m = Builder()
        let chords: [[UInt8]] = [[51, 58, 63, 67, 70], [46, 58, 62, 65, 70], [48, 55, 60, 63, 67], [44, 56, 60, 63, 67]]
        for (c, chord) in chords.enumerated() {
            let t = 0.2 + Double(c) * 5.0
            for (k, n) in chord.enumerated() { m.note(t + Double(k) * 0.03, n, UInt8(78 + k * 4), 6.0) }
        }
        for (k, n) in [55, 58, 62].enumerated() { m.note(21.5 + Double(k) * 0.01, UInt8(n), 100, 0.4) }
        return m.sorted
    }()

    /// Slow C♯-minor colours (C♯m9, Amaj7, F♯m9, G♯sus) held under a drifting line of long flute notes,
    /// then a soft high phrase and a last held note running into the tape's haze.
    public static let honeyTape: Phrase = {
        var m = Builder()
        let chords: [[UInt8]] = [[49, 56, 61, 63, 64], [45, 52, 56, 61, 64], [42, 54, 57, 61, 64], [44, 51, 56, 61, 63]]
        for (c, chord) in chords.enumerated() {
            let t = 0.2 + Double(c) * 4.0
            for (k, n) in chord.enumerated() { m.note(t + Double(k) * 0.04, n, UInt8(58 + k * 3), 3.85) }
        }
        let line: [(Double, UInt8, Double)] = [(1.0, 76, 1.4), (2.6, 75, 0.9), (3.6, 73, 1.8), (5.8, 71, 1.0), (7.0, 73, 1.6),
                                               (9.0, 76, 0.8), (10.0, 78, 1.8), (12.2, 80, 1.2), (13.6, 76, 1.9)]
        for (t, n, length) in line { m.note(t, n, 84, length) }
        for (i, n) in [80, 83, 85, 83, 80].enumerated() { m.note(16.4 + Double(i) * 0.35, UInt8(n), UInt8(50 + i * 4), 0.4) }
        m.note(18.3, 73, 70, 3.0)
        return m.sorted
    }()

    /// B-minor colours (Bm, Gmaj7, Em9, F♯) at 132 BPM: low chords held under the pedal while eighth-note bell
    /// arpeggios ring and echo above them, then one soft chord left to drift.
    public static let hazeBells: Phrase = {
        var m = Builder()
        let eighth = 60.0 / 132 / 2
        let sections: [(low: [UInt8], arp: [UInt8])] = [
            ([47, 54, 62], [71, 74, 78, 85, 83, 78, 74, 69]),
            ([43, 50, 59], [67, 71, 74, 78, 81, 78, 74, 71]),
            ([40, 47, 55], [76, 79, 83, 86, 83, 79, 78, 76]),
            ([42, 49, 58], [78, 82, 85, 88, 85, 82, 78, 73]),
        ]
        for (i, section) in sections.enumerated() {
            let t = 0.2 + Double(i) * 4.5
            m.pedal(t - 0.03, down: false); m.pedal(t + 0.02, down: true)
            for (k, n) in section.low.enumerated() { m.note(t + Double(k) * 0.03, n, 70, 4.2) }
            for (k, n) in section.arp.enumerated() { m.note(t + 0.4 + Double(k) * eighth, n, UInt8(72 + (k % 3) * 10), eighth * 0.8) }
        }
        m.pedal(18.17, down: false); m.pedal(18.22, down: true)
        for (k, n) in [71, 74, 78].enumerated() { m.note(18.3 + Double(k) * 0.05, UInt8(n), 64, 2.5) }
        m.pedal(21.5, down: false)
        return m.sorted
    }()

    private struct Builder {
        var events: Phrase = []
        mutating func note(_ t: Double, _ n: UInt8, _ v: UInt8, _ length: Double) {
            events.append((t, .noteOn(channel: 0, note: n, velocity: v)))
            events.append((t + length, .noteOff(channel: 0, note: n, velocity: 64)))
        }
        mutating func pedal(_ t: Double, down: Bool) {
            events.append((t, .controlChange(channel: 0, controller: 64, value: down ? 127 : 0)))
        }
        var sorted: Phrase { events.enumerated().sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }.map(\.element) }
    }
}
