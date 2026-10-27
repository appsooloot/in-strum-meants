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

    func testCombinedBudget() {
        var felt = [R.pedal(0, 127)]
        for n: UInt8 in [36, 43, 48, 52, 55, 60, 64, 67, 71, 72, 76, 79, 83, 84, 88, 91] { felt.append(R.noteOn(0, n, 90)) }
        let pad = [48, 55, 60, 63, 67, 70, 72, 75].map { R.noteOn(0, UInt8($0), 90) }
        let seconds = bestOfThree {
            _ = R.render(seconds: 10, events: felt)
            _ = R.render(ISD_ENGINE_ORBIT_PAD, seconds: 10, events: pad)
        }
        XCTAssertLessThan(seconds / 10, 0.08, "Felt Glass + Orbit Pad used \(String(format: "%.1f", seconds * 10))% of real time")
    }
}
