/// A decoded MIDI 1.0 channel message.
public enum MIDIMessage: Equatable {
    /// Velocity is always 1...127; a velocity-0 note-on is reported as `.noteOff`.
    case noteOn(channel: UInt8, note: UInt8, velocity: UInt8)
    /// Release velocity is kept (64 when the keyboard sends none, e.g. velocity-0 note-on).
    case noteOff(channel: UInt8, note: UInt8, velocity: UInt8 = 64)
    case controlChange(channel: UInt8, controller: UInt8, value: UInt8)
    /// 0...16383, centre 8192.
    case pitchBend(channel: UInt8, value: UInt16)
    case channelPressure(channel: UInt8, value: UInt8)
    case polyPressure(channel: UInt8, note: UInt8, value: UInt8)
    /// Recognised but unused here (program change).
    case other
}

/// Turns a raw MIDI byte stream into messages. Stateful across calls, so
/// running status and messages split between packets both work.
public struct MIDIParser {
    private var runningStatus: UInt8?
    private var data: [UInt8] = []
    private var inSysEx = false

    public init() {}

    public mutating func parse(_ bytes: [UInt8]) -> [MIDIMessage] {
        var out: [MIDIMessage] = []
        for byte in bytes {
            if byte >= 0xF8 { continue }                 // real-time: never disturbs state
            if inSysEx {
                if byte == 0xF7 { inSysEx = false }
                else if byte >= 0x80 { inSysEx = false; startStatus(byte) }
                continue
            }
            if byte == 0xF0 { inSysEx = true; runningStatus = nil; data.removeAll(); continue }
            if byte >= 0xF0 { runningStatus = nil; data.removeAll(); continue } // system common
            if byte >= 0x80 { startStatus(byte); continue }
            guard let status = runningStatus else { continue }   // stray data byte
            data.append(byte)
            if data.count == Self.dataLength(status) {
                out.append(Self.decode(status, data))
                data.removeAll()
            }
        }
        return out
    }

    private mutating func startStatus(_ status: UInt8) {
        runningStatus = status
        data.removeAll()
    }

    private static func dataLength(_ status: UInt8) -> Int {
        switch status & 0xF0 {
        case 0xC0, 0xD0: return 1
        default: return 2
        }
    }

    private static func decode(_ status: UInt8, _ d: [UInt8]) -> MIDIMessage {
        let ch = status & 0x0F
        switch status & 0xF0 {
        case 0x90:
            return d[1] == 0 ? .noteOff(channel: ch, note: d[0])
                             : .noteOn(channel: ch, note: d[0], velocity: d[1])
        case 0x80: return .noteOff(channel: ch, note: d[0], velocity: d[1])
        case 0xA0: return .polyPressure(channel: ch, note: d[0], value: d[1])
        case 0xD0: return .channelPressure(channel: ch, value: d[0])
        case 0xB0: return .controlChange(channel: ch, controller: d[0], value: d[1])
        case 0xE0: return .pitchBend(channel: ch, value: UInt16(d[0]) | (UInt16(d[1]) << 7))
        default: return .other
        }
    }
}
