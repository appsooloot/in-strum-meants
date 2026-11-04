import XCTest
import InStrumDSP

/// Pitch bend and aftertouch reach every engine (Sets 9 & 10); the engines made before then ignore them.
final class BendAndPressureTests: XCTestCase {
    typealias R = SynthRender

    /// The engines that existed before pitch bend and pressure reached the Sound Core.
    static let olderEngines: [ISDEngine] = [
        ISD_ENGINE_FELT_GLASS, ISD_ENGINE_ORBIT_PAD, ISD_ENGINE_HONEY_TAPE, ISD_ENGINE_HAZE_BELLS,
        ISD_ENGINE_CABIN_FELT, ISD_ENGINE_MORNING_BOX, ISD_ENGINE_POLAR_CHOIR, ISD_ENGINE_PLANKTON_KEYS,
    ]

    func testBendAndPressureLeaveOlderEnginesAlone() {
        let notes: [R.Event] = [
            R.noteOn(0.05, 60, 90), R.noteOn(0.06, 64, 80), R.noteOn(0.07, 67, 70),
            R.noteOff(1.0, 60), R.noteOff(1.0, 64), R.noteOff(1.0, 67),
        ]
        let touches: [R.Event] = [
            R.Event(time: 0.2, bytes: [0xE0, 0x7F, 0x7F]),   // the wheel full up
            R.Event(time: 0.3, bytes: [0xD0, 100]),           // channel pressure
            R.Event(time: 0.4, bytes: [0xA0, 64, 90]),        // poly pressure on E4
            R.Event(time: 0.5, bytes: [0xE0, 0x00, 0x00]),   // the wheel full down
            R.Event(time: 0.7, bytes: [0xE0, 0x00, 0x40]),   // back to the centre
        ]
        for engine in Self.olderEngines {
            let plain = R.render(engine, seconds: 1.5, events: notes)
            let touched = R.render(engine, seconds: 1.5, events: notes + touches)
            XCTAssertFalse(plain.l.isEmpty, "engine \(engine.rawValue) renders")
            XCTAssertLessThan(R.maxAbsDifference(plain.l, touched.l), 1e-6, "engine \(engine.rawValue) ignores bend and pressure (left)")
            XCTAssertLessThan(R.maxAbsDifference(plain.r, touched.r), 1e-6, "engine \(engine.rawValue) ignores bend and pressure (right)")
        }
    }
}
