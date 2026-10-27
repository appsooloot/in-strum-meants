import Foundation

/// How hard you have to play: reshapes key velocity before it reaches the instrument.
public enum TouchCurve: String, Codable, CaseIterable, Identifiable {
    /// Easier to play loud.
    case light
    /// Unchanged.
    case normal
    /// Soft playing stays soft.
    case heavy

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .light: return "Light"
        case .normal: return "Normal"
        case .heavy: return "Heavy"
        }
    }

    var exponent: Double {
        switch self {
        case .light: return 0.6
        case .normal: return 1.0
        case .heavy: return 1.6
        }
    }

    /// Maps a velocity 1...127 through the curve (0 stays 0).
    public func apply(_ velocity: UInt8) -> UInt8 {
        guard velocity > 0, self != .normal else { return velocity }
        let shaped = (127 * pow(Double(min(velocity, 127)) / 127, exponent)).rounded()
        return UInt8(max(1, min(127, shaped)))
    }

    /// Applies the curve to a complete MIDI message; only note-on velocities change.
    public func transform(_ bytes: [UInt8]) -> [UInt8] {
        guard self != .normal, bytes.count == 3, bytes[0] & 0xF0 == 0x90, bytes[2] > 0 else { return bytes }
        return [bytes[0], bytes[1], apply(bytes[2])]
    }
}
