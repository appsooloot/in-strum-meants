import XCTest
@testable import InStrumCore

final class TouchCurveTests: XCTestCase {
    func testNormalIsUnchanged() {
        for v in [UInt8(1), 40, 64, 100, 127] { XCTAssertEqual(TouchCurve.normal.apply(v), v) }
    }
    func testHeavyKeepsSoftPlayingSoft() {
        XCTAssertLessThan(TouchCurve.heavy.apply(40), 25)
        XCTAssertEqual(TouchCurve.heavy.apply(127), 127)
        XCTAssertGreaterThanOrEqual(TouchCurve.heavy.apply(1), 1)
    }
    func testLightMakesLoudEasier() {
        XCTAssertGreaterThan(TouchCurve.light.apply(64), 80)
        XCTAssertEqual(TouchCurve.light.apply(127), 127)
    }
    func testCurvesAreMonotonic() {
        for c in TouchCurve.allCases {
            var last: UInt8 = 0
            for v in UInt8(1)...127 { let o = c.apply(v); XCTAssertGreaterThanOrEqual(o, last); last = o }
        }
    }
    func testTransformChangesOnlyNoteOnVelocity() {
        XCTAssertEqual(TouchCurve.heavy.transform([0x91, 60, 127]), [0x91, 60, 127])
        XCTAssertEqual(TouchCurve.heavy.transform([0x90, 60, 40]), [0x90, 60, TouchCurve.heavy.apply(40)])
        XCTAssertEqual(TouchCurve.heavy.transform([0x90, 60, 0]), [0x90, 60, 0])     // release stays a release
        XCTAssertEqual(TouchCurve.heavy.transform([0x80, 60, 40]), [0x80, 60, 40])
        XCTAssertEqual(TouchCurve.heavy.transform([0xB0, 64, 40]), [0xB0, 64, 40])
        XCTAssertEqual(TouchCurve.heavy.transform([0xF8]), [0xF8])
    }
    func testSettingsDefaults() {
        XCTAssertEqual(AppSettings.default.touchCurve, .normal)
        XCTAssertEqual(AppSettings.default.bufferFrames, 256)
    }
}
