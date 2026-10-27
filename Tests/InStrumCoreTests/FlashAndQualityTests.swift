import XCTest
@testable import InStrumCore

final class FlashLimiterTests: XCTestCase {
    /// Counts rises of more than 0.25 within 0.1 s inside each 1 s window.
    private func maxFlashesPerSecond(_ series: [Float], dt: Double) -> Int {
        var flashTimes: [Double] = []
        var lastFlash = -1.0
        for i in 1..<series.count {
            let back = max(0, i - Int(0.1 / dt))
            if series[i] - series[back] > 0.25, Double(i) * dt - lastFlash > 0.1 {
                flashTimes.append(Double(i) * dt); lastFlash = Double(i) * dt
            }
        }
        var best = 0
        for t in flashTimes { best = max(best, flashTimes.filter { $0 >= t && $0 < t + 1 }.count) }
        return best
    }

    func testStrobeLimitedToThreeFlashesPerSecond() {
        var f = FlashLimiter()
        let dt = 1.0 / 60
        var out: [Float] = []
        for i in 0..<180 {
            let strobe: Float = (i / 3) % 2 == 0 ? 0 : 1          // 10 Hz
            out.append(f.limit(exposure: strobe, sparkle: 0, dt: dt).exposure)
        }
        XCTAssertLessThanOrEqual(maxFlashesPerSecond(out, dt: dt), 3)
    }
    func testSmoothSwellUnaffected() {
        var f = FlashLimiter()
        for i in 0..<120 {
            let v = Float(i) / 120
            XCTAssertEqual(f.limit(exposure: v, sparkle: 0, dt: 1.0 / 60).exposure, v, accuracy: 0.001)
        }
    }
    func testFallsAreNeverLimited() {
        var f = FlashLimiter()
        _ = f.limit(exposure: 1, sparkle: 0, dt: 1.0 / 60)
        XCTAssertEqual(f.limit(exposure: 0, sparkle: 0, dt: 1.0 / 60).exposure, 0, accuracy: 0.001)
    }
    func testGentleHalvesSparkle() {
        var f = FlashLimiter(gentle: true)
        XCTAssertEqual(f.limit(exposure: 0.5, sparkle: 0.8, dt: 1.0 / 60).sparkle, 0.4, accuracy: 0.001)
    }
}

final class AutoQualityTests: XCTestCase {
    func testAutoStartsHigh() {
        var q = AutoQuality(setting: .auto)
        XCTAssertEqual(q.record(frameTime: 1.0 / 60), .high)
    }
    func testAutoStepsDownAfterTwoSlowSeconds() {
        var q = AutoQuality(setting: .auto)
        var level = QualityLevel.high
        for _ in 0..<(2 * 40 + 2) { level = q.record(frameTime: 1.0 / 40) }
        XCTAssertEqual(level, .lite)
    }
    func testOneSlowSecondIsTolerated() {
        var q = AutoQuality(setting: .auto)
        var level = QualityLevel.high
        for _ in 0..<40 { level = q.record(frameTime: 1.0 / 40) }
        for _ in 0..<60 { level = q.record(frameTime: 1.0 / 60) }
        XCTAssertEqual(level, .high)
    }
    func testAutoStepsUpAfterTenGoodSeconds() {
        var q = AutoQuality(setting: .auto)
        for _ in 0..<(2 * 40 + 2) { _ = q.record(frameTime: 1.0 / 40) }
        var level = QualityLevel.lite
        for _ in 0..<(10 * 60 + 2) { level = q.record(frameTime: 1.0 / 60) }
        XCTAssertEqual(level, .high)
    }
    func testFixedSettingNeverChanges() {
        var q = AutoQuality(setting: .ultra)
        var level = QualityLevel.lite
        for _ in 0..<300 { level = q.record(frameTime: 1.0 / 20) }
        XCTAssertEqual(level, .ultra)
    }
}
