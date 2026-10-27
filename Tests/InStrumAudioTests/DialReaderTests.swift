import XCTest
import AVFoundation
@testable import InStrumAudio

final class DialReaderTests: XCTestCase {
    private func unit(_ type: OSType, _ sub: OSType) throws -> AUAudioUnit {
        let d = AudioComponentDescription(componentType: type, componentSubType: sub,
                                          componentManufacturer: kAudioUnitManufacturer_Apple,
                                          componentFlags: 0, componentFlagsMask: 0)
        return try AUAudioUnit(componentDescription: d, options: [])
    }

    func testListsNamedDials() throws {
        let reader = DialReader(audioUnit: try unit(kAudioUnitType_Effect, kAudioUnitSubType_Delay))
        XCTAssertFalse(reader.dials.isEmpty)
        XCTAssertTrue(reader.dials.allSatisfy { !$0.name.isEmpty })
        XCTAssertEqual(reader.currentValues().count, reader.dials.count)
        XCTAssertTrue(reader.currentValues().values.allSatisfy { (0...1).contains($0) })
    }

    func testTurningADialReportsNormalisedValue() throws {
        let au = try unit(kAudioUnitType_Effect, kAudioUnitSubType_Delay)
        let reader = DialReader(audioUnit: au)
        let param = try XCTUnwrap(au.parameterTree?.allParameters.first)
        let changed = expectation(description: "dial change")
        changed.assertForOverFulfill = false
        var seen: Double?
        reader.onChange = { info, v in
            if info.address == param.address { seen = v; changed.fulfill() }
        }
        param.setValue(param.maxValue, originator: nil)
        wait(for: [changed], timeout: 2)
        XCTAssertEqual(seen ?? 0, 1, accuracy: 0.01)
        XCTAssertEqual(reader.currentValues()[param.address] ?? 0, 1, accuracy: 0.01)
    }

    func testInstrumentWithoutDialsIsFine() throws {
        let reader = DialReader(audioUnit: try unit(kAudioUnitType_MusicDevice, kAudioUnitSubType_Sampler))
        _ = reader.dials            // may be empty; must not crash
        _ = reader.currentValues()
    }
}
