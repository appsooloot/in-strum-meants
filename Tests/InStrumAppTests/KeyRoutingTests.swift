import XCTest
@testable import InStrumApp

final class KeyRoutingTests: XCTestCase {
    private func play(plugin: Bool = false, sheet: Bool = false, mods: Bool = false, text: Bool = false) -> Bool {
        KeyRouting.shouldPlay(inPluginWindow: plugin, inSheet: sheet, hasCommandControlOrOption: mods, typingInTextField: text)
    }
    func testPlaysInMainWindow() { XCTAssertTrue(play()) }
    func testIgnoresPluginWindow() { XCTAssertFalse(play(plugin: true)) }
    func testIgnoresSheets() { XCTAssertFalse(play(sheet: true)) }
    func testIgnoresShortcuts() { XCTAssertFalse(play(mods: true)) }
    func testIgnoresTextFields() { XCTAssertFalse(play(text: true)) }
}
