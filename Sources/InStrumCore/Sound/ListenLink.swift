import Foundation

/// Where to listen to a credited song: a Spotify search for the artist and title (words only, nothing hosted here).
public enum ListenLink {
    /// Letters, digits and `-._~` stay; everything else (spaces, accents, punctuation) is percent-encoded.
    private static let allowed = CharacterSet.alphanumerics.intersection(CharacterSet(charactersIn: Unicode.Scalar(0)...Unicode.Scalar(127)))
        .union(CharacterSet(charactersIn: "-._~"))

    static func query(for c: Credit) -> String {
        "\(c.artist) \(c.song)".addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    /// Opens the Spotify app's search: `spotify:search:<artist song>`.
    public static func spotifyApp(for c: Credit) -> URL {
        URL(string: "spotify:search:\(query(for: c))")!
    }

    /// The same search on the web, for when the app isn't installed.
    public static func spotifyWeb(for c: Credit) -> URL {
        URL(string: "https://open.spotify.com/search/\(query(for: c))")!
    }
}

public extension Credit {
    /// One beat at the song's tempo (seconds): the card art breathes with it.
    var pulsePeriod: Double { 60 / tempoBPM }
}
