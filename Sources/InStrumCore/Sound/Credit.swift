/// The song that inspired a sound. Words and a link only: never artwork or lyrics.
public struct Credit: Codable, Equatable, Identifiable {
    public let id: String
    public let song, artist, album: String
    public let year: Int
    public let trackNumber: Int
    public let key: String
    public let tempoBPM: Double
    /// What inspired us, in one line.
    public let line: String

    public init(id: String, song: String, artist: String, album: String, year: Int, trackNumber: Int, key: String, tempoBPM: Double, line: String) {
        self.id = id; self.song = song; self.artist = artist; self.album = album; self.year = year
        self.trackNumber = trackNumber; self.key = key; self.tempoBPM = tempoBPM; self.line = line
    }
}

/// Facts from docs/superpowers/briefs (with sources there).
public enum CreditLibrary {
    public static let comeBackToEarth = Credit(id: "come-back-to-earth", song: "Come Back to Earth", artist: "Mac Miller",
                                               album: "Swimming", year: 2018, trackNumber: 1, key: "D", tempoBPM: 84,
                                               line: "The soft, floating keys that open Swimming.")
    public static let innerbloom = Credit(id: "innerbloom", song: "Innerbloom", artist: "RÜFÜS DU SOL",
                                          album: "Bloom", year: 2016, trackNumber: 11, key: "E♭ major", tempoBPM: 122,
                                          line: "The slow-blooming, hypnotic synth that opens Innerbloom.")
    public static let musicToWatchBoysTo = Credit(id: "music-to-watch-boys-to", song: "Music to Watch Boys To", artist: "Lana Del Rey",
                                                  album: "Honeymoon", year: 2015, trackNumber: 2, key: "C♯ minor", tempoBPM: 132,
                                                  line: "The hazy, flute-like synths that drift through it.")
    public static let all: [Credit] = [comeBackToEarth, innerbloom, musicToWatchBoysTo]

    public static func credit(id: String) -> Credit? { all.first { $0.id == id } }
}

public extension Patch {
    /// The preset name, carrying its credit: `Felt Glass · after "Come Back to Earth"`.
    var displayName: String {
        guard let id = creditID, let credit = CreditLibrary.credit(id: id) else { return name }
        return "\(name) · after \"\(credit.song)\""
    }

    var credit: Credit? { creditID.flatMap { CreditLibrary.credit(id: $0) } }
}
