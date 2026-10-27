/// Picks the render quality.
/// - Auto starts at Smooth (lite), steps up to High after 10 s at 58 fps or better, and back
///   down after 1 s below 50 fps. It never goes above High.
/// - Safety net, for every setting: two frames in a row taking 0.25 s or more drop to Smooth
///   for the rest of the session (or until a quality is chosen again), so a slow Mac never locks up.
/// Pass the real time between frames (not a clamped value).
public struct AutoQuality {
    public static let slowFPS = 50.0, goodFPS = 58.0
    public static let slowFor = 1.0, goodFor = 10.0
    public static let stallFrame = 0.25

    public var setting: QualitySetting {
        didSet { if setting != oldValue { rescued = false; stalls = 0 } }
    }
    /// True once the safety net has stepped in.
    public private(set) var rescued = false
    private var level: QualityLevel = .lite
    private var slowTime = 0.0, goodTime = 0.0
    private var stalls = 0

    public init(setting: QualitySetting) { self.setting = setting }

    public mutating func record(frameTime: Double) -> QualityLevel {
        if frameTime >= Self.stallFrame { stalls += 1 } else { stalls = 0 }
        if stalls >= 2 { rescued = true; level = .lite }
        if rescued { return .lite }
        switch setting {
        case .lite: return .lite
        case .high: return .high
        case .ultra: return .ultra
        case .auto: break
        }
        guard frameTime > 0 else { return level }
        let fps = 1 / frameTime
        if fps < Self.slowFPS { slowTime += frameTime; goodTime = 0 } else { slowTime = 0 }
        if fps >= Self.goodFPS { goodTime += frameTime }
        if slowTime >= Self.slowFor, level != .lite {
            level = .lite
            slowTime = 0; goodTime = 0
        } else if goodTime >= Self.goodFor, level == .lite {
            level = .high
            goodTime = 0
        }
        return level
    }
}

/// How many pixels to draw for a window: Smooth draws far fewer and lets the screen scale up.
public enum RenderScale {
    /// Fraction of the screen's native pixels per side.
    public static let factor: [QualityLevel: Double] = [.lite: 0.5, .high: 0.75, .ultra: 1.0]
    /// Smooth never draws more than this many pixels, however big the window.
    public static let liteMaxPixels = 1_000_000.0

    public static func pixels(points: (Double, Double), backingScale: Double, quality: QualityLevel) -> (width: Int, height: Int) {
        let w = max(1, points.0), h = max(1, points.1)
        var s = max(1, backingScale) * (factor[quality] ?? 1)
        if quality == .lite { s = min(s, (liteMaxPixels / (w * h)).squareRoot()) }
        let round: (Double) -> Int = quality == .lite ? { Int($0.rounded(.down)) } : { Int($0.rounded()) }
        return (max(1, round(w * s)), max(1, round(h * s)))
    }
}
