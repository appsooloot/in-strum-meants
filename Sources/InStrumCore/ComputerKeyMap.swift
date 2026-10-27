/// Maps the Mac keyboard to piano notes for the on-screen keyboard.
/// A W S E D F T G Y H U J K play C4...C5; Z / X shift the octave.
public struct ComputerKeyMap {
    static let offsets: [Character: Int] = [
        "a": 0, "w": 1, "s": 2, "e": 3, "d": 4, "f": 5, "t": 6,
        "g": 7, "y": 8, "h": 9, "u": 10, "j": 11, "k": 12,
    ]
    static let baseNote = 60

    public var octaveShift: Int = 0

    public init() {}

    public func note(for character: Character) -> UInt8? {
        guard let offset = Self.offsets[Character(character.lowercased())] else { return nil }
        return UInt8(Self.baseNote + offset + 12 * octaveShift)
    }

    /// Handles Z (down) and X (up). Returns true if the key was an octave key.
    public mutating func handleOctaveKey(_ character: Character) -> Bool {
        switch Character(character.lowercased()) {
        case "z": octaveShift = max(-3, octaveShift - 1); return true
        case "x": octaveShift = min(3, octaveShift + 1); return true
        default: return false
        }
    }
}
