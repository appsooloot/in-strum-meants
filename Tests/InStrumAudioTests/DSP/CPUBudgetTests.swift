import XCTest
import InStrumDSP

/// Real-time budgets (the DSP target is optimised even in debug builds).
final class CPUBudgetTests: XCTestCase {
    typealias R = SynthRender

    private func bestOfThree(_ work: () -> Void) -> Double {
        var best = Double.infinity
        for _ in 0..<3 {
            let start = CFAbsoluteTimeGetCurrent()
            work()
            best = min(best, CFAbsoluteTimeGetCurrent() - start)
        }
        return best
    }

    func testFeltGlassBudget() {
        var events = [R.pedal(0, 127)]
        for n: UInt8 in [36, 43, 48, 52, 55, 60, 64, 67, 71, 72, 76, 79, 83, 84, 88, 91] { events.append(R.noteOn(0, n, 90)) }
        for i in 0..<32 { events.append(R.noteOn(0.5 + Double(i) / 16, UInt8(60 + i), 90)) }
        let seconds = bestOfThree { _ = R.render(seconds: 10, events: events) }
        XCTAssertLessThan(seconds / 10, 0.05, "Felt Glass used \(String(format: "%.1f", seconds * 10))% of real time")
    }

    func testHoneyTapeBudget() {
        let chord = [36, 43, 48, 52, 55, 60, 64, 67, 71, 72, 76, 79].map { R.noteOn(0, UInt8($0), 90) }
        let seconds = bestOfThree { _ = R.render(ISD_ENGINE_HONEY_TAPE, seconds: 10, events: chord) }
        XCTAssertLessThan(seconds / 10, 0.05, "Honey Tape used \(String(format: "%.1f", seconds * 10))% of real time")
    }

    func testHazeBellsBudget() {
        var run = [R.pedal(0, 127)]
        for i in 0..<24 { run.append(R.noteOn(0.05 + Double(i) * 0.2, UInt8(48 + i * 2 % 36), 100)) }
        let p: [Int: Float] = [Int(ISD_P_ECHO): 1, Int(ISD_P_ORGAN): 0.5]
        let seconds = bestOfThree { _ = R.render(ISD_ENGINE_HAZE_BELLS, seconds: 10, params: p, events: run) }
        XCTAssertLessThan(seconds / 10, 0.04, "Haze Bells used \(String(format: "%.1f", seconds * 10))% of real time")
    }

    func testWorldAmbienceBudget() {
        typealias A = AmbienceTests
        var beach: [A.Action] = [ISD_AMB_SURF, ISD_AMB_PALMS, ISD_AMB_GULLS, ISD_AMB_CRICKETS, ISD_AMB_BREEZE, ISD_AMB_RAIN_WATER].map { A.level($0, 1) }
        for t in stride(from: 0.5, to: 10, by: 9) { beach.append(A.wave(0.9, at: t)) }
        var road: [A.Action] = [ISD_AMB_ROAD, ISD_AMB_ENGINE, ISD_AMB_WINDOW_WIND, ISD_AMB_SURF, ISD_AMB_PASSING_CAR, ISD_AMB_RAIN_GLASS].map { A.level($0, 1) }
        road += [A.speed(0.7), A.surfDistance(0.9), A.wave(0.8, at: 2)]
        for (name, actions) in [("beach", beach), ("road", road)] {
            let seconds = bestOfThree { _ = A.render(seconds: 10, actions: actions) }
            XCTAssertLessThan(seconds / 10, 0.02, "the \(name) ambience used \(String(format: "%.1f", seconds * 10))% of real time")
        }
    }

    func testCombinedBudget() {
        var felt = [R.pedal(0, 127)]
        for n: UInt8 in [36, 43, 48, 52, 55, 60, 64, 67, 71, 72, 76, 79, 83, 84, 88, 91] { felt.append(R.noteOn(0, n, 90)) }
        let pad = [48, 55, 60, 63, 67, 70, 72, 75].map { R.noteOn(0, UInt8($0), 90) }
        let ambience: [AmbienceTests.Action] = (0..<Int(ISD_AMB_COUNT.rawValue)).map { AmbienceTests.level(ISDAmbienceSource(UInt32($0)), 0.6) }
        let seconds = bestOfThree {
            _ = R.render(seconds: 10, events: felt)
            _ = R.render(ISD_ENGINE_ORBIT_PAD, seconds: 10, events: pad)
            _ = AmbienceTests.render(seconds: 10, actions: ambience)
        }
        XCTAssertLessThan(seconds / 10, 0.08, "Felt Glass + Orbit Pad + ambience used \(String(format: "%.1f", seconds * 10))% of real time")
    }
}
