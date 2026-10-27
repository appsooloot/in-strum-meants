import XCTest
@testable import InStrumCore

final class KeyboardLayoutTests: XCTestCase {
    func testFullRangeHas52WhiteAnd36BlackKeys() {
        let keys = KeyboardLayout.keys()
        XCTAssertEqual(keys.filter { !$0.isBlack }.count, 52)
        XCTAssertEqual(keys.filter { $0.isBlack }.count, 36)
    }
    func testWhiteKeysDrawBeforeBlackKeys() {
        let keys = KeyboardLayout.keys()
        XCTAssertFalse(keys.prefix(52).contains { $0.isBlack })
    }
    func testWhiteKeysTileWithoutGaps() {
        let whites = KeyboardLayout.keys().filter { !$0.isBlack }
        XCTAssertEqual(whites.reduce(0) { $0 + $1.width }, 1, accuracy: 1e-5)
        XCTAssertEqual(whites.first!.x, 0, accuracy: 1e-6)
        for (a, b) in zip(whites, whites.dropFirst()) { XCTAssertEqual(a.x + a.width, b.x, accuracy: 1e-5) }
    }
    func testIsBlack() {
        XCTAssertTrue(KeyboardLayout.isBlack(61))
        XCTAssertFalse(KeyboardLayout.isBlack(60))
        XCTAssertTrue(KeyboardLayout.isBlack(22))   // A#0
    }
    func testBlackKeyIsNarrowerAndCentredOnBoundary() {
        let cSharp = KeyboardLayout.key(for: 61)!, c = KeyboardLayout.key(for: 60)!, d = KeyboardLayout.key(for: 62)!
        XCTAssertEqual(cSharp.width, c.width * 0.6, accuracy: 1e-6)
        XCTAssertEqual(cSharp.x + cSharp.width / 2, d.x, accuracy: 1e-6)
    }
    func testOutOfRangeHasNoKey() {
        XCTAssertNil(KeyboardLayout.key(for: 20))
        XCTAssertNil(KeyboardLayout.key(for: 109))
        XCTAssertNotNil(KeyboardLayout.key(for: 21))
        XCTAssertNotNil(KeyboardLayout.key(for: 108))
    }
}

final class ComputerKeyMapTests: XCTestCase {
    func testHomeRowMapsToMiddleOctave() {
        let m = ComputerKeyMap()
        XCTAssertEqual(m.note(for: "a"), 60)
        XCTAssertEqual(m.note(for: "w"), 61)
        XCTAssertEqual(m.note(for: "k"), 72)
        XCTAssertNil(m.note(for: "q"))
    }
    func testUppercaseMapsLikeLowercase() {
        XCTAssertEqual(ComputerKeyMap().note(for: "A"), 60)
    }
    func testOctaveKeysShiftAndClamp() {
        var m = ComputerKeyMap()
        for _ in 0..<4 { XCTAssertTrue(m.handleOctaveKey("x")) }
        XCTAssertEqual(m.octaveShift, 3)
        XCTAssertEqual(m.note(for: "a"), 96)
        for _ in 0..<7 { _ = m.handleOctaveKey("z") }
        XCTAssertEqual(m.octaveShift, -3)
        XCTAssertFalse(m.handleOctaveKey("a"))
    }
}
