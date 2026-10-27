/// Position of one piano key in normalised (0...1) keyboard space.
public struct KeyRect: Equatable {
    public let note: UInt8
    public let isBlack: Bool
    public let x: Float
    public let width: Float
}

/// Geometry of an 88-key piano (A0...C8).
public enum KeyboardLayout {
    public static let lowestNote: UInt8 = 21
    public static let highestNote: UInt8 = 108
    static let blackWidthRatio: Float = 0.6

    public static func isBlack(_ note: UInt8) -> Bool {
        [1, 3, 6, 8, 10].contains(note % 12)
    }

    /// White keys first, then black keys (draw order).
    public static func keys(from low: UInt8 = lowestNote, to high: UInt8 = highestNote) -> [KeyRect] {
        guard low <= high else { return [] }
        let notes = Array(low...high)
        let whiteCount = notes.filter { !isBlack($0) }.count
        guard whiteCount > 0 else { return [] }
        let w = 1 / Float(whiteCount)
        var whites: [KeyRect] = [], blacks: [KeyRect] = []
        var whiteIndex = 0
        for note in notes {
            if isBlack(note) {
                let boundary = Float(whiteIndex) * w
                let bw = w * blackWidthRatio
                blacks.append(KeyRect(note: note, isBlack: true, x: boundary - bw / 2, width: bw))
            } else {
                whites.append(KeyRect(note: note, isBlack: false, x: Float(whiteIndex) * w, width: w))
                whiteIndex += 1
            }
        }
        return whites + blacks
    }

    private static let full: [UInt8: KeyRect] = Dictionary(uniqueKeysWithValues: keys().map { ($0.note, $0) })

    /// The key for a note on the full 88-key layout, or nil outside A0...C8.
    public static func key(for note: UInt8) -> KeyRect? { full[note] }
}
