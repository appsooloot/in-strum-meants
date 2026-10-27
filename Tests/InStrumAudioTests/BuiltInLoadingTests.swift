import XCTest
import AVFoundation
@testable import InStrumAudio
@testable import InStrumCore

/// Synchronous loading paths for the built-in Audio Unit.
final class BuiltInLoadingTests: XCTestCase {
    func testA_RegisterIsIdempotent() {
        BuiltInCatalog.registerAll()
        BuiltInCatalog.registerAll()
    }

    func testB_DirectInstantiation() throws {
        let au = try BuiltInInstrumentAU(componentDescription: BuiltInCatalog.description(for: .feltGlass), options: [])
        let count = au.parameterTree?.allParameters.count ?? 0
        XCTAssertEqual(count, 13)
    }

    func testC_CallbackInstantiation() {
        BuiltInCatalog.registerAll()
        let done = expectation(description: "instantiated")
        var ok = false
        AVAudioUnit.instantiate(with: BuiltInCatalog.description(for: .feltGlass), options: []) { unit, error in
            ok = unit?.auAudioUnit is BuiltInInstrumentAU && error == nil
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertTrue(ok)
    }
}
