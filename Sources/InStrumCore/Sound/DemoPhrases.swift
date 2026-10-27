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
