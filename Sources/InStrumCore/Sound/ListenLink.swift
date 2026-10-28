import Foundation

/// Listen links (RED stub).
public enum ListenLink {
    public static func spotifyApp(for c: Credit) -> URL { URL(string: "about:blank")! }
    public static func spotifyWeb(for c: Credit) -> URL { URL(string: "about:blank")! }
}

public extension Credit {
    var pulsePeriod: Double { 0 }
}
