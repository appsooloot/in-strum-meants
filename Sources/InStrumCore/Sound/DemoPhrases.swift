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

    /// F♯-major colours at the half-time pocket of 134 (67): F♯maj9, Bmaj9, D♯m9, C♯sus4 to C♯7, F♯6/9. Chords
    /// held under the pedal with a melody on top, so the horn takes the top line: it scoops into fresh phrases and
    /// slurs where the melody is legato (and is held over the chord changes so the chords never steal it).
    public static let cabinFelt: Phrase = {
        var m = Builder()
        let beat = 60.0 / 67
        func at(_ b: Double) -> Double { 0.2 + b * beat }
        /// Chord tones listed top first and pressed top first, a few ms apart.
        func chord(_ b: Double, _ notes: [UInt8], _ v: UInt8, _ beats: Double) {
            m.pedal(at(b) - 0.03, down: false); m.pedal(at(b) + 0.02, down: true)
            for (k, n) in notes.enumerated() { m.note(at(b) + Double(k) * 0.008, n, v, beats * beat) }
        }
        func tune(_ notes: [(b: Double, n: UInt8, beats: Double, v: UInt8)]) {
            for x in notes { m.note(at(x.b), x.n, x.v, x.beats * beat) }
        }
        chord(0, [68, 65, 61, 54, 42], 62, 3.95)                  // F♯maj9
        tune([(1.0, 70, 1.05, 76), (2.0, 73, 1.6, 84), (3.5, 75, 0.9, 80)])
        chord(4, [70, 66, 63, 59, 47], 60, 3.95)                  // Bmaj9, under the held D♯
        tune([(4.35, 78, 1.2, 88), (5.5, 77, 0.55, 78), (6.0, 75, 1.4, 80), (7.6, 73, 0.6, 72)])
        chord(8, [66, 65, 61, 58, 51, 39], 58, 3.95)              // D♯m9, under the held C♯
        tune([(8.15, 75, 0.9, 80), (9.0, 73, 1.05, 76), (10.0, 70, 1.6, 74), (11.75, 68, 0.4, 70)])
        chord(12, [66, 59, 56, 49, 37], 60, 1.95)                 // C♯sus4
        tune([(12.1, 73, 1.0, 84), (13.0, 75, 0.55, 86), (13.5, 77, 1.6, 90), (15.0, 78, 0.6, 80)])
        chord(14, [65, 59, 56, 49, 37], 60, 1.95)                 // C♯7, under the held E♯
        chord(16, [70, 68, 63, 61, 54, 42], 58, 4.5)              // F♯6/9: its top note starts a fresh horn phrase
        tune([(16.6, 73, 0.9, 70), (17.4, 78, 2.8, 66)])
        m.pedal(at(20.6), down: false)
        return m.sorted
    }()

    /// C♯-major colours at 82 BPM for 40 s, long enough to hear the wall build: held chords (C♯maj9, F♯maj9,
    /// A♯m9, G♯sus, C♯maj9, F♯maj9, then C♯6/9) under a ticking eighth-note celesta figure that keeps playing.
    public static let morningBox: Phrase = {
        var m = Builder()
        let eighth = 60.0 / 82 / 2
        let sections: [(chord: [UInt8], figure: [UInt8])] = [
            ([37, 49, 56, 60, 63], [73, 80, 75, 77, 84, 80, 75, 72]),
            ([42, 54, 58, 61, 65], [78, 82, 85, 77, 82, 78, 73, 77]),
            ([46, 58, 61, 65, 68], [77, 80, 84, 82, 77, 80, 73, 75]),
            ([44, 56, 61, 63], [75, 80, 85, 80, 73, 75, 80, 78]),
            ([37, 49, 56, 60, 63], [73, 77, 80, 84, 85, 84, 80, 77]),
            ([42, 54, 58, 61, 65], [82, 85, 89, 85, 82, 78, 77, 73]),
        ]
        let length = 16 * eighth
        for (i, section) in sections.enumerated() {
            let t = 0.2 + Double(i) * length
            m.pedal(t - 0.03, down: false); m.pedal(t + 0.02, down: true)
            for (k, n) in section.chord.enumerated() { m.note(t + Double(k) * 0.02, n, 64, length - 0.08) }
            for k in 0..<16 {
                let n = section.figure[k % 8]
                m.note(t + Double(k) * eighth, n, UInt8(k % 2 == 0 ? 80 : 64), eighth * 0.8)
            }
        }
        let end = 0.2 + 6 * length
        m.pedal(end - 0.03, down: false); m.pedal(end + 0.02, down: true)
        for (k, n) in [37, 49, 56, 63, 70].enumerated() { m.note(end + Double(k) * 0.02, UInt8(n), 60, 5) }
        for (k, n) in [73, 77, 80, 84, 85].enumerated() { m.note(end + 0.5 + Double(k) * 0.45, UInt8(n), 66, 3.5) }
        m.pedal(end + 5.4, down: false)
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
