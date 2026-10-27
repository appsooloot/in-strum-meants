import Foundation

/// What the visuals need to know about playing, derived from MIDI.
public enum PerformanceEvent: Equatable {
    /// velocity 0...1 (raw / 127)
    case noteOn(note: UInt8, velocity: Float)
    case noteOff(note: UInt8)
    /// Sustain pedal (CC64): down when value >= 64; amount = value / 127.
    case pedal(down: Bool, amount: Float)
    /// Three or more notes struck within `chordWindow`, sorted ascending.
    case chord(notes: [UInt8])
    case allNotesOff
}

/// Tracks held notes, pedal, chords and playing intensity.
public struct PerformanceState {
    public static let chordWindow: Double = 0.03
    public static let intensityHalfLife: Double = 1.0
    static let intensityPerNote: Float = 0.15

    public private(set) var heldNotes: [UInt8: Float] = [:]
    public private(set) var pedalDown = false
    public private(set) var intensity: Float = 0

    private var strikeTimes: [UInt8: Double] = [:]
    private var lastChord: Set<UInt8> = []
    private var lastTime: Double?

    public init() {}

    /// Applies a message at time `t` (seconds, monotonic) and returns events for the visuals.
    public mutating func apply(_ message: MIDIMessage, at t: Double) -> [PerformanceEvent] {
        decay(to: t)
        switch message {
        case let .noteOn(_, note, raw):
            let velocity = Float(raw) / 127
            heldNotes[note] = velocity
            strikeTimes[note] = t
            intensity = min(1, intensity + velocity * Self.intensityPerNote)
            var events: [PerformanceEvent] = [.noteOn(note: note, velocity: velocity)]
            if let chord = detectChord(at: t) { events.append(.chord(notes: chord)) }
            return events
        case let .noteOff(_, note):
            heldNotes[note] = nil
            strikeTimes[note] = nil
            return [.noteOff(note: note)]
        case let .controlChange(_, controller, value):
            switch controller {
            case 64:
                pedalDown = value >= 64
                return [.pedal(down: pedalDown, amount: Float(value) / 127)]
            case 120, 123:
                return reset()
            default:
                return []
            }
        case .pitchBend, .other:
            return []
        }
    }

    /// Clears all notes and the pedal (e.g. keyboard unplugged, panic).
    public mutating func reset() -> [PerformanceEvent] {
        heldNotes.removeAll()
        strikeTimes.removeAll()
        lastChord.removeAll()
        pedalDown = false
        return [.allNotesOff]
    }

    /// Lets intensity fade with time.
    public mutating func decay(to t: Double) {
        if let last = lastTime, t > last {
            intensity *= Float(pow(0.5, (t - last) / Self.intensityHalfLife))
        }
        if lastTime == nil || t > lastTime! { lastTime = t }
    }

    private mutating func detectChord(at t: Double) -> [UInt8]? {
        let recent = Set(strikeTimes.filter { abs(t - $0.value) <= Self.chordWindow }.keys)
        guard recent.count >= 3, recent != lastChord else { return nil }
        lastChord = recent
        return recent.sorted()
    }
}
