/// A Set (RED stub).
public struct InStrumSet: Codable, Equatable, Identifiable {
    public let id, name, moodName: String
    public let mood: Mood
    public let worldID: String
    public let visual: String
    public let patchID: String
    public let ambience: AmbienceSettings
    public let creditID: String
}

public enum SetLibrary {
    public static let all: [InStrumSet] = []
    public static func set(id: String) -> InStrumSet? { nil }
}
