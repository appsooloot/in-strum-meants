import XCTest
@testable import InStrumCore

/// Excitement (Fire & Neon spec §5). The performances and bounds match Scripts/excitement-mirror.py, where they were
/// tuned first (its printed values are in the comments).
final class ExcitementTests: XCTestCase {
    private struct Note { let t: Double; let on: Bool; let note: Int; let velocity: Float }
    private struct Log { var t: [Double] = []; var energy: [Float] = []; var tension: [Float] = []; var moments: [(t: Double, m: BigMoment)] = []
        var surprises: [(t: Double, s: WorldSurprise)] = []
        func at(_ time: Double) -> Int { t.indices.min { abs(t[$0] - time) < abs(t[$1] - time) } ?? 0 } }

    /// Plays `notes` (each applied once the clock reaches it, then the step), at 60 steps a second, until `until`.
    private func run(_ ex: inout Excitement, _ notes: [Note], until: Double, surprises: Int = 0) -> Log {
        let sorted = notes.sorted { $0.t < $1.t }
        var i = 0, clock = 0.0, log = Log()
        let dt = 1.0 / 60
        while clock < until {
            while i < sorted.count, sorted[i].t <= clock + 1e-9 {
                if sorted[i].on { ex.noteOn(sorted[i].note, velocity: sorted[i].velocity) } else { ex.noteOff(sorted[i].note) }
                i += 1
            }
            let f = ex.step(dt: dt, surpriseCount: surprises)
            clock += dt
            log.t.append(clock); log.energy.append(f.energy); log.tension.append(f.tension)
            if let m = f.moment { log.moments.append((clock, m)) }
            if let s = f.surprise { log.surprises.append((clock, s)) }
        }
        return log
    }
    private func sixteenths(from t0: Double, count: Int, note: (Int) -> Int = { _ in 60 }, velocity: Float = 1) -> [Note] {
        (0..<count).flatMap { k -> [Note] in
            let t = t0 + Double(k) * 0.125
            return [Note(t: t, on: true, note: note(k), velocity: velocity), Note(t: t + 0.1, on: false, note: note(k), velocity: 0)]
        }
    }
    private func chord(at t: Double, _ notes: [Int], velocity: Float, spread: Double = 0.01) -> [Note] {
        notes.enumerated().map { Note(t: t + Double($0.offset) * spread, on: true, note: $0.element, velocity: velocity) }
    }

    /// Mirror: 0.594 at 0.6 s, 0.762 at 1.5 s, 0.784 at 2 s, 0.09 at 12 s.
    func testEnergyRisesFastFallsSlow() {
        var ex = Excitement()
        let log = run(&ex, sixteenths(from: 0, count: 16), until: 12)
        XCTAssertGreaterThanOrEqual(log.energy[log.at(0.6)], 0.5)
        XCTAssertGreaterThanOrEqual(log.energy[log.at(2.0)], 0.75)
        XCTAssertLessThanOrEqual(log.energy[log.at(12.0)], 0.2)
    }

    /// Mirror: one chord moment, strength 0.55, low.
    func testHardChordFiresAMoment() {
        var ex = Excitement()
        let log = run(&ex, chord(at: 0, [40, 45, 52, 36], velocity: 0.9), until: 1)
        XCTAssertEqual(log.moments.count, 1)
        let m = try? XCTUnwrap(log.moments.first?.m)
        XCTAssertEqual(m?.kind, .chord)
        XCTAssertGreaterThanOrEqual(m?.strength ?? 0, 0.5)
        XCTAssertEqual(m?.low, true)
        var high = Excitement()
        XCTAssertEqual(run(&high, chord(at: 0, [60, 64, 67], velocity: 0.95), until: 1).moments.first?.m.low, false)
        var soft = Excitement()
        XCTAssertTrue(run(&soft, chord(at: 0, [40, 45, 52], velocity: 0.6), until: 1).moments.isEmpty, "a soft chord")
        var slow = Excitement()
        XCTAssertTrue(run(&slow, chord(at: 0, [40, 45, 52], velocity: 0.95, spread: 0.05), until: 1).moments.isEmpty, "a rolled chord")
    }

    /// Review focus 1. Mirror: 2 moments on Some (0, 6.13 s), 4 on Lots.
    func testCooldownHolds() {
        for (setting, most) in [(ExcitementSettings.Moments.some, 2), (.lots, 4)] {
            var ex = Excitement()
            ex.settings.moments = setting
            let hammer: [Note] = (0..<80).flatMap { (k: Int) -> [Note] in chord(at: Double(k) * 0.125, [48, 52, 55, 60], velocity: 1, spread: 0) }
            let log = run(&ex, hammer, until: 10)
            XCTAssertLessThanOrEqual(log.moments.count, most, "\(setting)")
            XCTAssertGreaterThanOrEqual(log.moments.count, 1)
            for k in 1..<log.moments.count {
                XCTAssertGreaterThanOrEqual(log.moments[k].t - log.moments[k - 1].t, Excitement.cooldown(setting) - 1e-6)
            }
        }
        var off = Excitement()
        off.settings.moments = .off
        XCTAssertTrue(run(&off, chord(at: 0, [40, 45, 52], velocity: 1), until: 1).moments.isEmpty)
    }

    /// Mirror: soft single notes for 4 s (energy 0.33), then fff sixteenths: one crescendo near 5.8 s.
    func testCrescendoFires() {
        var ex = Excitement()
        var notes = (0..<16).flatMap { k -> [Note] in
            let t = Double(k) * 0.25
            return [Note(t: t, on: true, note: 60 + k % 3, velocity: 0.3), Note(t: t + 0.2, on: false, note: 60 + k % 3, velocity: 0)]
        }
        notes += sixteenths(from: 4, count: 24, note: { 62 + $0 % 3 })
        let log = run(&ex, notes, until: 8)
        let crescendos = log.moments.filter { $0.m.kind == .crescendo }
        XCTAssertEqual(crescendos.count, 1)
        XCTAssertGreaterThan(crescendos.first?.t ?? 0, 4)
    }

    /// Mirror: climbing a semitone every sixteenth for 5 s takes tension to 1; the hard chord after it is a drop.
    func testDropNeedsTension() {
        var calm = Excitement()
        XCTAssertEqual(run(&calm, chord(at: 0, [60, 64, 67], velocity: 0.95), until: 1).moments.first?.m.isDrop, false)
        var ex = Excitement()
        var notes = sixteenths(from: 0, count: 40, note: { 48 + $0 }, velocity: 0.6)
        notes += chord(at: 5.2, [60, 64, 67], velocity: 0.95)
        let log = run(&ex, notes, until: 8)
        XCTAssertGreaterThan(log.tension[log.at(5.1)], 0.6)
        let drop = log.moments.first { $0.t > 5 }
        XCTAssertEqual(drop?.m.isDrop, true)
        XCTAssertLessThan(log.tension[log.at(5.5)], 0.1, "tension resets at the drop")
        var off = Excitement()
        off.settings.buildAndDrop = false
        let flat = run(&off, notes, until: 8)
        XCTAssertEqual(flat.tension.max() ?? 1, 0)
        XCTAssertFalse(flat.moments.contains { $0.m.isDrop })
    }

    /// Spec §5.3: rare surprises at least 90 s apart, often at least 30 s apart, never the same twice running, and only
    /// while you play.
    func testSurprisesAreSpacedAndNeverRepeat() {
        for (setting, gap) in [(ExcitementSettings.Surprises.rare, 90.0), (.often, 30.0)] {
            var ex = Excitement(seed: 7)
            ex.settings.surprises = setting
            // An hour of steady playing: a note every second.
            let notes: [Note] = (0..<3600).flatMap { (k: Int) -> [Note] in
                let n: Int = 60 + k % 12
                return [Note(t: Double(k), on: true, note: n, velocity: 0.6), Note(t: Double(k) + 0.3, on: false, note: n, velocity: 0)]
            }
            let log = run(&ex, notes, until: 3600, surprises: 4)
            XCTAssertGreaterThan(log.surprises.count, setting == .often ? 20 : 5, "\(setting)")
            for k in 1..<log.surprises.count {
                XCTAssertGreaterThanOrEqual(log.surprises[k].t - log.surprises[k - 1].t, gap - 1e-6)
                XCTAssertNotEqual(log.surprises[k].s.index, log.surprises[k - 1].s.index)
            }
            XCTAssertTrue(log.surprises.allSatisfy { (0..<4).contains($0.s.index) })
        }
    }

    /// Review focus 3: five minutes of silence leaves no energy, no tension and no surprises.
    func testQuietKeyboardStopsEverything() {
        var ex = Excitement()
        ex.settings.surprises = .often
        let log = run(&ex, sixteenths(from: 0, count: 16, note: { 48 + $0 }), until: 320, surprises: 3)
        XCTAssertEqual(log.energy[log.at(319)], 0)
        XCTAssertEqual(log.tension[log.at(319)], 0)
        XCTAssertFalse(log.surprises.contains { $0.t > 25 }, "no surprises once the keys are quiet")
    }

    func testHoldFreezesExcitement() {
        var ex = Excitement()
        _ = run(&ex, sixteenths(from: 0, count: 8), until: 1)
        let before = ex.frame
        ex.holding = true
        let log = run(&ex, chord(at: 0, [40, 45, 52], velocity: 1), until: 2)
        XCTAssertTrue(log.moments.isEmpty)
        XCTAssertEqual(ex.frame.energy, before.energy)
        XCTAssertEqual(ex.frame.tension, before.tension)
    }

    /// Review focus 5.
    func testGentleAndReduceMotionCaps() {
        var ex = Excitement()
        ex.settings.moments = .lots
        ex.settings.surprises = .often
        ex.gentle = true
        let hammer: [Note] = (0..<80).flatMap { (k: Int) -> [Note] in chord(at: Double(k) * 0.125, [48, 52, 55, 60], velocity: 1, spread: 0) }
        XCTAssertLessThanOrEqual(run(&ex, hammer, until: 10).moments.count, 2, "gentle holds Lots to Some")
        var rm = Excitement()
        rm.reduceMotion = true
        let log = run(&rm, sixteenths(from: 0, count: 16), until: 2)
        XCTAssertGreaterThan(log.energy.max() ?? 0, 0.7)
        XCTAssertEqual(rm.frame.visualEnergy, min(rm.frame.energy, 0.5))
        var asleep = Excitement()
        asleep.sleeping = true
        XCTAssertTrue(run(&asleep, chord(at: 0, [40, 45, 52], velocity: 1), until: 1).moments.isEmpty, "Sleep Fade")
    }

    func testManualEnergy() {
        var ex = Excitement()
        ex.settings.autoEnergy = false
        ex.settings.manualEnergy = 0.8
        XCTAssertEqual(run(&ex, [], until: 0.5).energy.last, 0.8)
    }

    /// Review focus 4: settings saved before Excitement existed load with the defaults.
    func testOldSavesLoad() throws {
        let empty = try JSONDecoder().decode(ExcitementSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(empty, ExcitementSettings())
        let partial = try JSONDecoder().decode(ExcitementSettings.self, from: Data(#"{"moments":"lots","surprises":"nonsense"}"#.utf8))
        XCTAssertEqual(partial.moments, .lots)
        XCTAssertEqual(partial.surprises, .rare)
        let round = try JSONDecoder().decode(ExcitementSettings.self, from: JSONEncoder().encode(ExcitementSettings(autoEnergy: false, manualEnergy: 0.3, moments: .off, surprises: .often, buildAndDrop: false)))
        XCTAssertEqual(round, ExcitementSettings(autoEnergy: false, manualEnergy: 0.3, moments: .off, surprises: .often, buildAndDrop: false))
    }

    func testDeterministic() {
        func play() -> [Double] {
            var ex = Excitement(seed: 42)
            ex.settings.surprises = .often
            var notes: [Note] = []
            for k in 0..<600 {
                let root: Int = 40 + k % 7
                let velocity: Float = k % 9 == 0 ? 1 : 0.5
                notes += chord(at: Double(k) * 0.5, [root, 47, 52], velocity: velocity)
            }
            let log = run(&ex, notes, until: 300, surprises: 5)
            let moments: [Double] = log.moments.map { (entry: (t: Double, m: BigMoment)) -> Double in entry.t }
            let surprises: [Double] = log.surprises.map { (entry: (t: Double, s: WorldSurprise)) -> Double in Double(entry.s.index) + entry.t }
            return moments + surprises
        }
        XCTAssertEqual(play(), play())
    }
}
