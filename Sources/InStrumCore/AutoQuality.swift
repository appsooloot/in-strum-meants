/// Picks the render quality. Auto starts at High, steps down one level after 2 s
/// below 55 fps, and back up (to High at most) after 10 s at 58 fps or better.
public struct AutoQuality {
    public static let slowFPS = 55.0, goodFPS = 58.0
    public static let slowFor = 2.0, goodFor = 10.0

    public var setting: QualitySetting
    private var level: QualityLevel = .high
    private var slowTime = 0.0, goodTime = 0.0

    public init(setting: QualitySetting) { self.setting = setting }

    public mutating func record(frameTime: Double) -> QualityLevel {
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
            level = level == .ultra ? .high : .lite
            slowTime = 0; goodTime = 0
        } else if goodTime >= Self.goodFor, level == .lite {
            level = .high
            goodTime = 0
        }
        return level
    }
}
