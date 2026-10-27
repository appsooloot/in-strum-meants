import Foundation

/// Detects whether the previous run ended without settling (e.g. a plugin crash),
/// so the app can offer Safe Mode.
public final class LaunchGuard {
    private let markerURL: URL

    public init(directory: URL) {
        markerURL = directory.appendingPathComponent("running.marker")
    }

    /// Returns true if the previous run ended uncleanly, then marks this run as in progress.
    public func beginLaunch() -> Bool {
        let fm = FileManager.default
        let unclean = fm.fileExists(atPath: markerURL.path)
        try? fm.createDirectory(at: markerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: markerURL.path, contents: Data())
        return unclean
    }

    /// Call once the app has been running stably.
    public func markStable() {
        try? FileManager.default.removeItem(at: markerURL)
    }
}
