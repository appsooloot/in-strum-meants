import XCTest
import InStrumDSP

/// Ambience generators through the C API.
final class AmbienceTests: XCTestCase {
    static let sr = DSPTestKit.sampleRate
    typealias Action = (time: Double, apply: (OpaquePointer) -> Void)

    /// Renders `seconds` of ambience; `actions` run at the start of the block containing their time.
    static func render(seconds: Double, seed: UInt64 = 1, block: Int = 256, actions: [Action]) -> (l: [Float], r: [Float]) {
        guard let a = isd_ambience_create(sr, Int32(block), seed) else { return ([], []) }
        defer { isd_ambience_destroy(a) }
        let total = Int(seconds * sr)
        var left = [Float](repeating: 0, count: total), right = [Float](repeating: 0, count: total)
        let pending = actions.sorted { $0.time < $1.time }
        var next = 0, i = 0
        while i < total {
            let n = min(block, total - i)
            while next < pending.count, Int(pending[next].time * sr) < i + n { pending[next].apply(a); next += 1 }
            left.withUnsafeMutableBufferPointer { lp in
                right.withUnsafeMutableBufferPointer { rp in isd_ambience_render(a, lp.baseAddress! + i, rp.baseAddress! + i, Int32(n)) }
            }
            i += n
        }
        return (left, right)
    }

    static func level(_ s: ISDAmbienceSource, _ v: Float, at t: Double = 0) -> Action { (t, { isd_ambience_set_level($0, s, v) }) }
    static func wave(_ strength: Float, at t: Double) -> Action { (t, { isd_ambience_trigger_wave($0, strength) }) }
    static func speed(_ v: Float, at t: Double = 0) -> Action { (t, { isd_ambience_set_speed($0, v) }) }
    static func surfDistance(_ d: Float) -> Action { (0, { isd_ambience_set_surf_distance($0, d) }) }
    static func density(_ d: Float) -> Action { (0, { isd_ambience_set_density($0, d) }) }

    /// Share of the energy between `lo` and `hi` (Welch average of 8192-sample segments).
    static func bandShare(_ x: [Float], _ lo: Double, _ hi: Double) -> Double {
        let n = 8192
        var power = [Double](repeating: 0, count: n / 2)
        var start = 0
        while start + n <= x.count {
            let p = DSPTestKit.powerSpectrum(Array(x[start..<(start + n)]), size: n)
            for i in 0..<min(power.count, p.count) { power[i] += p[i] }
            start += n / 2
        }
        let binHz = sr / Double(n)
        var inBand = 0.0, total = 0.0
        for i in 1..<power.count {
            total += power[i]
            let f = Double(i) * binHz
            if f >= lo && f <= hi { inBand += power[i] }
        }
        return total > 0 ? inBand / total : 0
    }

    /// RMS of each 0.5 s window, in dBFS.
    static func windows(_ x: [Float], seconds: Double = 0.5) -> [Double] {
        let n = Int(seconds * sr)
        return stride(from: 0, to: x.count - n + 1, by: n).map { DSPTestKit.dBFS(x[$0..<($0 + n)]) }
    }

    func testEachSourceInItsBand() {
        let bands: [(ISDAmbienceSource, String, ClosedRange<Double>, ClosedRange<Double>)] = [
            (ISD_AMB_WATER, "water", 150...1500, -30 ... -18),
            (ISD_AMB_CRICKETS, "crickets", 3500...6500, -36 ... -18),
            (ISD_AMB_BREEZE, "breeze", 200...2000, -30 ... -18),
            (ISD_AMB_RAIN_WATER, "rain on water", 800...4000, -30 ... -18),
            (ISD_AMB_RAIN_GLASS, "rain on glass", 1500...12000, -30 ... -18),
            (ISD_AMB_DAWN_CHORUS, "dawn chorus", 2000...6500, -36 ... -18),
            (ISD_AMB_SHIP_HUM, "ship hum", 20...250, -30 ... -18),
            (ISD_AMB_AIR_FLOW, "air flow", 300...3000, -30 ... -18),
            (ISD_AMB_WIND, "wind", 100...1500, -30 ... -18),
        ]
        for (source, name, band, loudness) in bands {
            let out = Self.render(seconds: 20, actions: [Self.level(source, 1)])
            let steady = SynthRender.slice(out.l, 3, 20)
            let centroid = DSPTestKit.averageCentroid(steady, sampleRate: Self.sr), db = DSPTestKit.dBFS(steady)
            XCTAssertTrue(band.contains(centroid), "\(name): centroid \(Int(centroid)) Hz")
            XCTAssertTrue(loudness.contains(db), "\(name): \(String(format: "%.1f", db)) dBFS")
            XCTAssertTrue(out.l.allSatisfy(\.isFinite) && out.r.allSatisfy(\.isFinite), name)
        }
    }

    /// The beach's and the road's sources, each in its own band (density up so rare ones happen).
    func testNewSourcesInTheirBands() {
        let table: [(ISDAmbienceSource, String, ClosedRange<Double>, Float, Bool, Double)] = [
            (ISD_AMB_SURF, "surf", 60...6000, 0, true, 30),
            (ISD_AMB_PALMS, "palms", 1500...9000, 0, false, 30),
            (ISD_AMB_GULLS, "gulls", 500...3500, 0, false, 60),
            (ISD_AMB_ROAD, "road", 30...1200, 0.6, false, 30),
            (ISD_AMB_ENGINE, "engine", 25...250, 0.6, false, 30),
            (ISD_AMB_WINDOW_WIND, "window wind", 300...4000, 0.8, false, 30),
            (ISD_AMB_PASSING_CAR, "passing car", 80...3000, 0, false, 120),
        ]
        for (source, name, band, speed, waves, seconds) in table {
            var actions: [Action] = [Self.level(source, 1), Self.density(1.5), Self.speed(speed)]
            if waves { for t in stride(from: 1.0, to: seconds, by: 9) { actions.append(Self.wave(0.7, at: t)) } }
            let out = Self.render(seconds: seconds, actions: actions)
            let body = SynthRender.slice(out.l, 3, seconds)
            XCTAssertGreaterThan(Self.bandShare(body, band.lowerBound, band.upperBound), 0.5, name)
            XCTAssertTrue(out.l.allSatisfy(\.isFinite) && out.r.allSatisfy(\.isFinite), name)
            XCTAssertGreaterThan(Self.windows(body).max() ?? -200, -60, "\(name) is heard")
        }
        // The night skies: a far waterfall and lapping water at their levels; the ice's creak bed stays faint.
        let skies: [(ISDAmbienceSource, String, ClosedRange<Double>, ClosedRange<Double>)] = [
            (ISD_AMB_WATERFALL, "waterfall", 300...2500, -32 ... -18),
            (ISD_AMB_LAPPING, "lapping", 300...3000, -40 ... -22),
        ]
        for (source, name, band, loudness) in skies {
            let out = Self.render(seconds: 20, actions: [Self.level(source, 1)])
            let steady = SynthRender.slice(out.l, 3, 20)
            let centroid = DSPTestKit.averageCentroid(steady, sampleRate: Self.sr), db = DSPTestKit.dBFS(steady)
            XCTAssertTrue(band.contains(centroid), "\(name): centroid \(Int(centroid)) Hz")
            XCTAssertTrue(loudness.contains(db), "\(name): \(String(format: "%.1f", db)) dBFS")
            XCTAssertTrue(out.l.allSatisfy(\.isFinite) && out.r.allSatisfy(\.isFinite), name)
        }
        let ice = Self.render(seconds: 20, actions: [Self.level(ISD_AMB_ICE_GROAN, 1)])
        let bed = Self.windows(SynthRender.slice(ice.l, 3, 20)).sorted()
        XCTAssertLessThan(bed[bed.count / 2], -30, "the ice's creak bed")
        XCTAssertGreaterThan(bed[bed.count / 2], -60, "the ice's creak bed is heard")
        XCTAssertTrue(ice.l.allSatisfy(\.isFinite) && ice.r.allSatisfy(\.isFinite), "ice")
        XCTAssertLessThanOrEqual(max(ice.l.map(abs).max() ?? 0, ice.r.map(abs).max() ?? 0), 1, "ice")
    }

    /// A wave breaks: a low crash first, then the bright wash sliding up the sand.
    func testWaveMakesACrashThenAWash() {
        let out = Self.render(seconds: 6.5, actions: [Self.level(ISD_AMB_SURF, 1), Self.wave(1, at: 3.0)])
        let before = DSPTestKit.dBFS(SynthRender.slice(out.l, 2.6, 2.95)), after = DSPTestKit.dBFS(SynthRender.slice(out.l, 3.0, 3.6))
        XCTAssertGreaterThan(after, before + 6)
        var lowPeak = (time: 0.0, e: -1.0), highPeak = (time: 0.0, e: -1.0)
        for t in stride(from: 3.0, to: 6.0, by: 0.05) {
            let seg = SynthRender.slice(out.l, t, t + 0.05)
            let lo = DSPTestKit.bandEnergy(seg, sampleRate: Self.sr, from: 20, to: 300)
            let hi = DSPTestKit.bandEnergy(seg, sampleRate: Self.sr, from: 3000, to: 20000)
            if lo > lowPeak.e { lowPeak = (t, lo) }
            if hi > highPeak.e { highPeak = (t, hi) }
        }
        XCTAssertLessThan(lowPeak.time, highPeak.time, "crash at \(lowPeak.time) s, wash at \(highPeak.time) s")
    }

    /// A wave that arrives while the surf is fading out (the world is changing) makes no crash.
    func testWaveIgnoredWhileSurfFadesOut() {
        let base: [Action] = [Self.level(ISD_AMB_SURF, 1), Self.level(ISD_AMB_SURF, 0, at: 3.0)]
        let quiet = Self.render(seconds: 4.5, actions: base)
        let late = Self.render(seconds: 4.5, actions: base + [Self.wave(1, at: 3.1)])
        let a = DSPTestKit.dBFS(SynthRender.slice(quiet.l, 3.1, 4.5)), b = DSPTestKit.dBFS(SynthRender.slice(late.l, 3.1, 4.5))
        XCTAssertLessThan(b - a, 0.5, "fading bed \(a) dBFS, with the late wave \(b) dBFS")
    }

    /// The engine's purr and a passing car's tone keep their pitch however long the drive: their oscillator
    /// (shared helper) runs at exactly the frequency asked, at every sample rate, after 30 s and after 10 minutes.
    func testToneOscillatorsHoldPitch() {
        for sr: Float in [44_100, 48_000, 96_000] {
            for hz: Float in [35, 42, 60, 70, 95] {
                for seconds: Float in [30, 600] {
                    let measured = Double(isd_ambience_debug_tone_hz(hz, sr, seconds))
                    XCTAssertEqual(DSPTestKit.cents(measured, Double(hz)), 0, accuracy: 0.5, "\(hz) Hz at \(Int(sr)) Hz over \(Int(seconds)) s")
                }
            }
        }
    }

    func testRoadFollowsSpeed() {
        let car: [Action] = [Self.level(ISD_AMB_ROAD, 1), Self.level(ISD_AMB_ENGINE, 1), Self.level(ISD_AMB_WINDOW_WIND, 1)]
        let slow = SynthRender.slice(Self.render(seconds: 10, actions: car + [Self.speed(0.2)]).l, 3, 10)
        let fast = SynthRender.slice(Self.render(seconds: 10, actions: car + [Self.speed(1)]).l, 3, 10)
        XCTAssertGreaterThan(DSPTestKit.dBFS(fast), DSPTestKit.dBFS(slow) + 6)
        XCTAssertGreaterThan(DSPTestKit.averageCentroid(fast, sampleRate: Self.sr), DSPTestKit.averageCentroid(slow, sampleRate: Self.sr))
    }

    func testFarSurfIsDarker() {
        func surf(_ d: Float) -> [Float] {
            var actions: [Action] = [Self.level(ISD_AMB_SURF, 1), Self.surfDistance(d)]
            for t in stride(from: 1.0, to: 20, by: 9) { actions.append(Self.wave(0.8, at: t)) }
            return SynthRender.slice(Self.render(seconds: 20, actions: actions).l, 3, 20)
        }
        let near = DSPTestKit.averageCentroid(surf(0), sampleRate: Self.sr), far = DSPTestKit.averageCentroid(surf(1), sampleRate: Self.sr)
        XCTAssertLessThan(far, 0.6 * near, "near \(Int(near)) Hz, far \(Int(far)) Hz")
    }

    /// Owl, chime and hull ticks are rare: at least one event in 300 s, silent most of the time.
    func testRareEventsHappen() {
        for (source, name) in [(ISD_AMB_OWL, "owl"), (ISD_AMB_CHIME, "chime"), (ISD_AMB_HULL_TICKS, "hull ticks")] {
            let out = Self.render(seconds: 300, actions: [Self.level(source, 1)])
            let w = Self.windows(out.l)
            let loud = w.filter { $0 > -60 }.count
            XCTAssertGreaterThanOrEqual(loud, 1, "\(name): no event in 300 s")
            XCTAssertLessThan(Double(loud) / Double(w.count), 0.25, "\(name) is not rare")
            XCTAssertLessThanOrEqual(max(out.l.map(abs).max() ?? 0, out.r.map(abs).max() ?? 0), 1, name)
        }
    }

    func testLevelsCrossFade() {
        let out = Self.render(seconds: 12, actions: [Self.level(ISD_AMB_WATER, 1)])
        let early = DSPTestKit.dBFS(SynthRender.slice(out.l, 0.4, 0.5)), steady = DSPTestKit.dBFS(SynthRender.slice(out.l, 4, 12))
        XCTAssertLessThan(early, steady - 6, "early \(early) steady \(steady)")
        XCTAssertGreaterThan(steady, -40)
        // A level that stepped instead of gliding would click in the fade's first second. (Steady water at
        // −24 dBFS has natural sample steps up to about 0.06, so the whole render is checked for clicks only.)
        XCTAssertLessThan(DSPTestKit.maxJump(SynthRender.slice(out.l, 0, 1)), 0.05)
        XCTAssertLessThan(DSPTestKit.maxJump(SynthRender.slice(out.r, 0, 1)), 0.05)
        XCTAssertLessThan(DSPTestKit.maxJump(out.l), 0.15)
    }

    func testDucking() {
        let out = Self.render(seconds: 12, actions: [Self.level(ISD_AMB_AIR_FLOW, 1),
                                                     (5, { isd_ambience_set_activity($0, 1) }),
                                                     (8, { isd_ambience_set_activity($0, 0) })])
        let before = DSPTestKit.dBFS(SynthRender.slice(out.l, 4, 5))
        let ducked = DSPTestKit.dBFS(SynthRender.slice(out.l, 5.5, 6))
        let back = DSPTestKit.dBFS(SynthRender.slice(out.l, 11, 12))
        XCTAssertGreaterThan(before - ducked, 3, "ducked \(before - ducked) dB")
        XCTAssertLessThan(before - ducked, 5, "ducked \(before - ducked) dB")
        XCTAssertEqual(back, before, accuracy: 1)
    }

    func testThunderFollowsLightning() {
        let bed: [Action] = [Self.level(ISD_AMB_RAIN_WATER, 0.5)]
        let quiet = Self.render(seconds: 12, actions: bed)
        let storm = Self.render(seconds: 12, actions: bed + [(3, { isd_ambience_trigger_thunder($0, 0.5) })])
        let low = { (x: [Float]) in DSPTestKit.bandEnergy(SynthRender.slice(x, 4, 11), sampleRate: Self.sr, from: 20, to: 200) }
        XCTAssertGreaterThan(10 * log10(low(storm.l) / max(low(quiet.l), 1e-12)), 6)
        let beforeStrike = DSPTestKit.dBFS(SynthRender.slice(storm.l, 3, 3.4)) - DSPTestKit.dBFS(SynthRender.slice(quiet.l, 3, 3.4))
        XCTAssertEqual(beforeStrike, 0, accuracy: 1, "thunder waits for the distance delay")
        // A clap is a rumble under the beds, never a full-scale slab: peak well under the limiter, and the
        // first second of the roll between −32 and −12 dBFS (bed at this rain level ≈ −32 dBFS).
        let strike = 3 + 0.5 + 5.5 * 0.5
        XCTAssertLessThan(storm.l.map(abs).max() ?? 1, 0.7, "thunder must not pin the limiter")
        let roll = DSPTestKit.dBFS(SynthRender.slice(storm.l, strike, strike + 1))
        XCTAssertGreaterThan(roll, -32); XCTAssertLessThan(roll, -12)
        // Distance is audible: a near clap is clearly louder than a far one.
        let near = Self.render(seconds: 12, actions: bed + [(3, { isd_ambience_trigger_thunder($0, 0.1) })])
        let far = Self.render(seconds: 12, actions: bed + [(3, { isd_ambience_trigger_thunder($0, 0.9) })])
        let nearDb = DSPTestKit.dBFS(SynthRender.slice(near.l, 3 + 0.5 + 0.55, 3 + 0.5 + 0.55 + 1))
        let farDb = DSPTestKit.dBFS(SynthRender.slice(far.l, 3 + 0.5 + 4.95, 3 + 0.5 + 4.95 + 1))
        XCTAssertGreaterThan(nearDb - farDb, 5, "near \(nearDb) dBFS vs far \(farDb) dBFS")
    }

    func testClosenessChangesTheRoom() {
        let near = Self.render(seconds: 10, actions: [Self.level(ISD_AMB_WATER, 1), (0, { isd_ambience_set_closeness($0, 1) })])
        let far = Self.render(seconds: 10, actions: [Self.level(ISD_AMB_WATER, 1), (0, { isd_ambience_set_closeness($0, 0) })])
        let c = { (x: [Float]) in DSPTestKit.averageCentroid(SynthRender.slice(x, 3, 10), sampleRate: Self.sr) }
        XCTAssertGreaterThan(c(near.l), c(far.l), "distant ambience loses its top")
        XCTAssertTrue(far.l.allSatisfy(\.isFinite))
    }

    func testSilentByDefault() {
        let out = Self.render(seconds: 1, actions: [])
        XCTAssertLessThan(DSPTestKit.dBFS(out.l), -150)
    }
}

// MARK: - Window worlds: fire, kettle, street, drips, clock; through the glass; wet roads; snow ticks

extension AmbienceTests {
    static func indoors(_ v: Float, at t: Double = 0) -> Action { (t, { isd_ambience_set_indoors($0, v) }) }
    static func wetness(_ v: Float, at t: Double = 0) -> Action { (t, { isd_ambience_set_wetness($0, v) }) }
    static func snowOnGlass(_ v: Float, at t: Double = 0) -> Action { (t, { isd_ambience_set_snow_on_glass($0, v) }) }
    static func startKettle(at t: Double) -> Action { (t, { isd_ambience_debug_start_kettle($0) }) }

    static func mid(_ out: (l: [Float], r: [Float])) -> [Float] { zip(out.l, out.r).map { 0.5 * ($0 + $1) } }

    /// An RBJ band-pass, run twice (−24 dB/octave skirts).
    static func bandpass(_ x: [Float], _ lo: Double, _ hi: Double) -> [Float] {
        let f0 = (lo * hi).squareRoot(), bw = log2(hi / lo), w0 = 2 * Double.pi * f0 / sr
        let alpha = sin(w0) * sinh(log(2) / 2 * bw * w0 / sin(w0)), a0 = 1 + alpha
        let b0 = alpha / a0, b2 = -alpha / a0, a1 = -2 * cos(w0) / a0, a2 = (1 - alpha) / a0
        var y = x
        for _ in 0..<2 {
            var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
            for i in y.indices {
                let xi = Double(y[i])
                let yi = b0 * xi + b2 * x2 - a1 * y1 - a2 * y2
                x2 = x1; x1 = xi; y2 = y1; y1 = yi
                y[i] = Float(yi)
            }
        }
        return y
    }

    /// RMS (dBFS) of consecutive frames of `ms` milliseconds.
    static func frameDB(_ x: [Float], ms: Double) -> [Double] {
        let n = Int(ms / 1000 * sr)
        return stride(from: 0, to: x.count - n + 1, by: n).map { DSPTestKit.dBFS(x[$0..<($0 + n)]) }
    }

    /// How many times the frames rise `db` above the median of the `window` frames around them.
    static func events(_ frames: [Double], above db: Double, window: Int) -> Int {
        var count = 0, on = false
        for i in frames.indices {
            let lo = max(0, i - window / 2), hi = min(frames.count, i + window / 2)
            let sorted = frames[lo..<hi].sorted()
            let hit = frames[i] - sorted[sorted.count / 2] >= db
            if hit && !on { count += 1 }
            on = hit
        }
        return count
    }

    static func bandDB(_ x: [Float], _ lo: Double, _ hi: Double) -> Double { DSPTestKit.dBFS(bandpass(x, lo, hi)) }

    func testWindowSourcesInTheirBands() {
        let bands: [(ISDAmbienceSource, String, ClosedRange<Double>, ClosedRange<Double>)] = [
            (ISD_AMB_FIRE, "fire", 300...4000, -36 ... -18),
            (ISD_AMB_STREET, "street", 100...1500, -42 ... -22),
            (ISD_AMB_DRIPS, "drips", 800...4000, -45 ... -20),
        ]
        for (source, name, band, loudness) in bands {
            let out = Self.render(seconds: 23, actions: [Self.level(source, 1)])
            let steady = SynthRender.slice(out.l, 3, 23)
            let centroid = DSPTestKit.averageCentroid(steady, sampleRate: Self.sr), db = DSPTestKit.dBFS(steady)
            XCTAssertTrue(band.contains(centroid), "\(name): centroid \(Int(centroid)) Hz")
            XCTAssertTrue(loudness.contains(db), "\(name): \(String(format: "%.1f", db)) dBFS")
            XCTAssertTrue(out.l.allSatisfy(\.isFinite) && out.r.allSatisfy(\.isFinite), name)
            XCTAssertLessThanOrEqual(max(out.l.map(abs).max() ?? 0, out.r.map(abs).max() ?? 0), 1, name)
        }
    }

    func testFireCracklesAndPops() {
        let fire = SynthRender.slice(Self.mid(Self.render(seconds: 33, actions: [Self.level(ISD_AMB_FIRE, 1)])), 3, 33)
        let crackles = Double(Self.events(Self.frameDB(fire, ms: 5), above: 12, window: 40)) / 30
        XCTAssertTrue((1...12).contains(crackles), "\(crackles) crackles a second")
        let thumps = Double(Self.events(Self.frameDB(Self.bandpass(fire, 60, 150), ms: 20), above: 10, window: 100)) / 30
        XCTAssertTrue((0.05...1).contains(thumps), "\(thumps) low thumps a second")
    }

    func testKettleCycle() {
        let out = Self.render(seconds: 150, actions: [Self.level(ISD_AMB_KETTLE, 1), Self.startKettle(at: 0)]).l
        let cold = Self.bandDB(SynthRender.slice(out, 0, 10), 60, 400), hot = Self.bandDB(SynthRender.slice(out, 80, 90), 60, 400)
        XCTAssertGreaterThanOrEqual(hot, cold + 6, "the rumble rises: \(cold) → \(hot) dB")
        // The click: a broadband transient (high band, 10 dB over the 200 ms before it) within 100–125 s.
        let high = Self.frameDB(Self.bandpass(SynthRender.slice(out, 99, 126), 2000, 16000), ms: 5)
        var click: Double?
        for i in 40..<high.count {
            let before = high[(i - 40)..<i].sorted()
            if high[i] - before[20] >= 10 { click = 99 + Double(i) * 0.005; break }
        }
        let clickAt = try? XCTUnwrap(click, "no click")
        XCTAssertTrue((100...125).contains(clickAt ?? 0), "click at \(clickAt ?? -1) s")
        // Then the clink: a 2.5–7 kHz ping more than 2 s later, far above that band before the click.
        let from = (clickAt ?? 100) + 2
        let ping = Self.frameDB(Self.bandpass(SynthRender.slice(out, from, 125), 2500, 7000), ms: 20)
        let peak = ping.max() ?? -200, quiet = Self.bandDB(SynthRender.slice(out, 99, 99.9), 2500, 7000)
        XCTAssertGreaterThanOrEqual(peak, quiet + 20, "clink \(peak) dB against \(quiet) dB")
        XCTAssertGreaterThan(peak, -60)
        // And back to quiet.
        XCTAssertLessThanOrEqual(DSPTestKit.dBFS(SynthRender.slice(out, 140, 150)), DSPTestKit.dBFS(SynthRender.slice(out, 0, 10)) + 3)
    }

    func testKettleComesEveryFewMinutes() {
        let out = Self.render(seconds: 600, actions: [Self.level(ISD_AMB_KETTLE, 1), Self.density(1.5)]).l
        let windows = stride(from: 0.0, to: 600, by: 10).map { Self.bandDB(SynthRender.slice(out, $0, $0 + 10), 60, 400) }
        let median = windows.sorted()[windows.count / 2]
        var cycles = 0, on = false
        for w in windows {
            let hit = w > median + 10
            if hit && !on { cycles += 1 }
            on = hit
        }
        XCTAssertTrue((2...4).contains(cycles), "\(cycles) kettle cycles in 10 minutes")
    }

    func testClockTicksAtOneHertz() {
        let out = SynthRender.slice(Self.render(seconds: 22, actions: [Self.level(ISD_AMB_CLOCK, 1)]).l, 2, 20)
        let env = Self.frameDB(out, ms: 10).map { pow(10, $0 / 20) }
        var best = -1.0, bestLag = 0
        for lag in 50...150 {
            var s = 0.0
            for i in 0..<(env.count - lag) { s += env[i] * env[i + lag] }
            if s > best { best = s; bestLag = lag }
        }
        XCTAssertEqual(Double(bestLag) * 0.01, 1.0, accuracy: 0.02)
    }

    func testIndoorsMufflesOnlyOutdoorSources() {
        let open = SynthRender.slice(Self.render(seconds: 14, actions: [Self.level(ISD_AMB_STREET, 1)]).l, 4, 14)
        let closed = SynthRender.slice(Self.render(seconds: 14, actions: [Self.level(ISD_AMB_STREET, 1), Self.indoors(1)]).l, 4, 14)
        XCTAssertGreaterThanOrEqual(Self.bandDB(open, 3000, 8000) - Self.bandDB(closed, 3000, 8000), 12)
        XCTAssertGreaterThanOrEqual(DSPTestKit.dBFS(open) - DSPTestKit.dBFS(closed), 6)
        let fire = DSPTestKit.dBFS(SynthRender.slice(Self.render(seconds: 14, actions: [Self.level(ISD_AMB_FIRE, 1)]).l, 4, 14))
        let fireInside = DSPTestKit.dBFS(SynthRender.slice(Self.render(seconds: 14, actions: [Self.level(ISD_AMB_FIRE, 1), Self.indoors(1)]).l, 4, 14))
        XCTAssertEqual(fire, fireInside, accuracy: 0.5, "the fire is inside with you")
    }

    /// The waking street: the later the morning (the higher its level), the more often a car goes by (final review:
    /// only the loudness followed the level).
    func testStreetCarsComeMoreOftenLater() {
        func cars(_ level: Float) -> Int32 {
            guard let a = isd_ambience_create(Self.sr, 512, 7) else { return -1 }
            defer { isd_ambience_destroy(a) }
            isd_ambience_set_level(a, ISD_AMB_STREET, level)
            var l = [Float](repeating: 0, count: 512), r = l
            for _ in 0..<Int(300 * Self.sr / 512) {
                l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in isd_ambience_render(a, lp.baseAddress!, rp.baseAddress!, 512) } }
            }
            return isd_ambience_debug_events(a, ISD_AMB_STREET)
        }
        let early = cars(0.15), late = cars(0.6)
        XCTAssertGreaterThanOrEqual(late, 2 * early, "\(early) cars early, \(late) later")
        XCTAssertGreaterThanOrEqual(late, 15)
    }

    /// The bedroom's old sash window (indoors 0.7) lets the dawn chorus through, softened (final review: behind the
    /// fully closed window the birds were 26 dB down).
    func testDawnChorusCarriesThroughTheSash() {
        let open = DSPTestKit.dBFS(SynthRender.slice(Self.render(seconds: 20, actions: [Self.level(ISD_AMB_DAWN_CHORUS, 0.6)]).l, 4, 20))
        let sash = DSPTestKit.dBFS(SynthRender.slice(Self.render(seconds: 20, actions: [Self.level(ISD_AMB_DAWN_CHORUS, 0.6), Self.indoors(0.7)]).l, 4, 20))
        XCTAssertGreaterThan(sash, open - 15)
        XCTAssertLessThan(sash, open - 4, "still through glass")
    }

    func testWetRoadHisses() {
        let dry = SynthRender.slice(Self.render(seconds: 10, actions: [Self.level(ISD_AMB_ROAD, 1), Self.speed(0.6)]).l, 3, 10)
        let wet = SynthRender.slice(Self.render(seconds: 10, actions: [Self.level(ISD_AMB_ROAD, 1), Self.speed(0.6), Self.wetness(1)]).l, 3, 10)
        XCTAssertGreaterThanOrEqual(Self.bandDB(wet, 4000, 10000) - Self.bandDB(dry, 4000, 10000), 6)
    }

    func testSnowTicksAreSofterThanRain() {
        let rain = SynthRender.slice(Self.render(seconds: 10, actions: [Self.level(ISD_AMB_RAIN_GLASS, 1)]).l, 3, 10)
        let snow = SynthRender.slice(Self.render(seconds: 10, actions: [Self.level(ISD_AMB_RAIN_GLASS, 1), Self.snowOnGlass(1)]).l, 3, 10)
        XCTAssertGreaterThanOrEqual(DSPTestKit.dBFS(rain) - DSPTestKit.dBFS(snow), 6)
        XCTAssertLessThan(DSPTestKit.averageCentroid(snow, sampleRate: Self.sr), DSPTestKit.averageCentroid(rain, sampleRate: Self.sr))
    }

    func testDripsFollowTheirLevel() {
        func drips(_ level: Float) -> Int {
            let x = SynthRender.slice(Self.mid(Self.render(seconds: 43, actions: [Self.level(ISD_AMB_DRIPS, level)])), 3, 43)
            return Self.events(Self.frameDB(x, ms: 5), above: 12, window: 40)
        }
        let few = drips(0.3), many = drips(1)
        XCTAssertGreaterThanOrEqual(Double(many), 2 * Double(few), "\(few) drips at 0.3, \(many) at 1")
        XCTAssertGreaterThan(few, 0)
    }
}

// MARK: - Night skies: ice, a waterfall, lapping water, a boat

extension AmbienceTests {
    static func startBoat(at t: Double) -> Action { (t, { isd_ambience_debug_start_boat($0) }) }

    /// The runs of frames that rise `db` above the median of the `window` frames around them: (first frame, length).
    static func swells(_ frames: [Double], above db: Double, window: Int) -> [(start: Int, length: Int)] {
        var runs: [(start: Int, length: Int)] = [], start = -1
        for i in frames.indices {
            let lo = max(0, i - window / 2), hi = min(frames.count, i + window / 2)
            let sorted = frames[lo..<hi].sorted()
            let hit = frames[i] - sorted[sorted.count / 2] >= db
            if hit && start < 0 { start = i }
            if !hit && start >= 0 { runs.append((start, i - start)); start = -1 }
        }
        if start >= 0 { runs.append((start, frames.count - start)) }
        return runs
    }

    /// Every 8th-sample average (a cheap 6 kHz copy for the low bands).
    static func decimate8(_ x: [Float]) -> [Float] {
        var y = [Float](repeating: 0, count: x.count / 8)
        for i in y.indices {
            var s: Float = 0
            for k in 0..<8 { s += x[i * 8 + k] }
            y[i] = s / 8
        }
        return y
    }

    /// Over two minutes at density 1.5 the ice groans (40–120 Hz swells of 1–4 s, 8 dB over their surroundings) and
    /// cracks (5 ms broadband transients, 12 dB over the 200 ms around them).
    func testIceGroansAndCracks() throws {
        guard let a = isd_ambience_create(Self.sr, 512, 1) else { return XCTFail("no ambience") }
        defer { isd_ambience_destroy(a) }
        isd_ambience_set_density(a, 1.5)
        isd_ambience_set_level(a, ISD_AMB_ICE_GROAN, 1)
        let total = Int(120 * Self.sr)
        var l = [Float](repeating: 0, count: total), r = l
        for i in stride(from: 0, to: total, by: 512) {
            l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in isd_ambience_render(a, lp.baseAddress! + i, rp.baseAddress! + i, Int32(min(512, total - i))) } }
        }
        let started = isd_ambience_debug_events(a, ISD_AMB_ICE_GROAN)
        XCTAssertGreaterThanOrEqual(started, 5, "\(started) groans and cracks started")
        let mid = Self.mid((l, r))
        // Cracks: the sample-to-sample difference keeps the click and drops the groans and the bed.
        var diff = [Float](repeating: 0, count: mid.count)
        for i in 1..<mid.count { diff[i] = mid[i] - mid[i - 1] }
        let cracks = Self.events(Self.frameDB(diff, ms: 5), above: 12, window: 40)
        XCTAssertGreaterThanOrEqual(cracks, 3, "\(cracks) cracks in 120 s")
        // Groans: the 40–120 Hz band (on a 6 kHz copy) in 250 ms frames, against the 20 s around them.
        let low = Self.decimate8(mid), lowSR = Self.sr / 8
        let f0 = (40.0 * 120).squareRoot(), w0 = 2 * Double.pi * f0 / lowSR
        let alpha = sin(w0) * sinh(log(2) / 2 * log2(120.0 / 40) * w0 / sin(w0)), a0 = 1 + alpha
        var band = low.map(Double.init)
        for _ in 0..<2 {
            var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
            for i in band.indices {
                let xi = band[i], yi = (alpha * xi - alpha * x2 + 2 * cos(w0) * y1 - (1 - alpha) * y2) / a0
                x2 = x1; x1 = xi; y2 = y1; y1 = yi; band[i] = yi
            }
        }
        let n = Int(0.25 * lowSR)
        let frames = stride(from: 0, to: band.count - n + 1, by: n).map { s -> Double in
            let e = band[s..<(s + n)].reduce(0) { $0 + $1 * $1 } / Double(n)
            return e > 0 ? 10 * log10(e) : -200
        }
        let groans = Self.swells(frames, above: 8, window: 80).filter { (2...18).contains($0.length) }   // 0.5–4.5 s
        XCTAssertGreaterThanOrEqual(groans.count, 2, "\(groans.count) groans in 120 s: \(groans.map { Double($0.length) * 0.25 }) s")
    }

    /// A boat passes: the 60–120 Hz band swells by more than 10 dB over 12–20 s while it crosses from one side to the other.
    func testBoatPasses() {
        let out = Self.render(seconds: 26, actions: [Self.level(ISD_AMB_BOAT, 1), Self.startBoat(at: 2)])
        let left = Self.frameDB(Self.bandpass(out.l, 60, 120), ms: 500), right = Self.frameDB(Self.bandpass(out.r, 60, 120), ms: 500)
        let both = zip(left, right).map { 10 * log10(0.5 * (pow(10, $0 / 10) + pow(10, $1 / 10))) }
        let peak = both.max() ?? -200
        XCTAssertGreaterThan(peak, -50, "the boat is heard (\(peak) dB)")
        XCTAssertGreaterThanOrEqual(peak - both[5], 10, "the engine swells in: \(both[5]) → \(peak) dB")
        let heard = both.indices.filter { both[$0] >= peak - 20 }
        let span = Double((heard.last ?? 0) - (heard.first ?? 0) + 1) * 0.5
        XCTAssertTrue((12...20).contains(span), "the pass lasts \(span) s")
        let loud = both.indices.filter { both[$0] >= peak - 10 }
        guard let first = loud.first, let last = loud.last else { return XCTFail("no swell") }
        let from = left[first] - right[first], to = left[last] - right[last]
        XCTAssertGreaterThanOrEqual(abs(from), 3, "starts to one side (\(from) dB)")
        XCTAssertGreaterThanOrEqual(abs(to), 3, "ends to the other (\(to) dB)")
        XCTAssertLessThan(from * to, 0, "the boat crosses: \(from) dB → \(to) dB")
        XCTAssertTrue(out.l.allSatisfy(\.isFinite) && out.r.allSatisfy(\.isFinite))
    }

    /// Lapping water: soft 300–2000 Hz swells of 0.3–0.8 s, 6–40 a minute.
    func testLappingSloshes() {
        guard let a = isd_ambience_create(Self.sr, 512, 1) else { return XCTFail("no ambience") }
        defer { isd_ambience_destroy(a) }
        isd_ambience_set_level(a, ISD_AMB_LAPPING, 1)
        let total = Int(63 * Self.sr)
        var l = [Float](repeating: 0, count: total), r = l
        for i in stride(from: 0, to: total, by: 512) {
            l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in isd_ambience_render(a, lp.baseAddress! + i, rp.baseAddress! + i, Int32(min(512, total - i))) } }
        }
        let body = SynthRender.slice(Self.mid((l, r)), 3, 63)
        let runs = Self.swells(Self.frameDB(Self.bandpass(body, 300, 2000), ms: 50), above: 6, window: 60)
        let sloshes = runs.filter { (4...20).contains($0.length) }   // 0.2–1.0 s in 50 ms frames
        XCTAssertTrue((6...40).contains(sloshes.count), "\(sloshes.count) sloshes a minute (of \(runs.count) swells)")
        XCTAssertGreaterThanOrEqual(2 * sloshes.count, runs.count, "most swells are slosh-length")
        let started = isd_ambience_debug_events(a, ISD_AMB_LAPPING)
        XCTAssertTrue((6...45).contains(started), "\(started) sloshes started in 63 s")
    }
}
