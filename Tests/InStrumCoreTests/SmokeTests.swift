import XCTest
@testable import InStrumCore

final class SmokeTests: XCTestCase {
    func testCoreModuleLoads() { XCTAssertEqual(InStrumCore.version, "0.1.0") }
}
