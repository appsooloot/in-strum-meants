import XCTest
import AVFoundation
@testable import InStrumApp
@testable import InStrumCore
import InStrumDSP

/// Writes demo audio and spectrograms when DEMO_DIR is set (CI previews and releases).
@MainActor
final class DemoRenderTests: XCTestCase {
    nonisolated static let rate = 48_000.0

    /// Renders a phrase through the Sound Core (stereo, interleaving left then right).
    nonisolated static func render(_ engine: ISDEngine, _ phrase: [(time: Double, message: MIDIMessage)], tail: Double = 4) -> (l: [Float], r: [Float])? {
        guard let synth = isd_synth_create(engine, rate, 512) else { return nil }
        defer { isd_synth_destroy(synth) }
        let total = Int(((phrase.last?.time ?? 0) + tail) * rate), block = 256
        var l = [Float](repeating: 0, count: total), r = [Float](repeating: 0, count: total)
        var e = 0, i = 0
        while i < total {
            let n = min(block, total - i)
            while e < phrase.count, Int(phrase[e].time * rate) < i + n {
                let bytes = phrase[e].message.bytes
                bytes.withUnsafeBufferPointer { isd_synth_midi(synth, $0.baseAddress, Int32($0.count), Int32(max(0, Int(phrase[e].time * rate) - i))) }
                e += 1
            }
            l.withUnsafeMutableBufferPointer { lp in
                r.withUnsafeMutableBufferPointer { rp in isd_synth_render(synth, lp.baseAddress! + i, rp.baseAddress! + i, Int32(n)) }
            }
            i += n
        }
        return (l, r)
    }

    nonisolated static func writeWAV(_ audio: (l: [Float], r: [Float]), to url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
                                       AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(audio.l.count))!
        buffer.frameLength = AVAudioFrameCount(audio.l.count)
        audio.l.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: audio.l.count) }
        audio.r.withUnsafeBufferPointer { buffer.floatChannelData![1].update(from: $0.baseAddress!, count: audio.r.count) }
        try file.write(from: buffer)
    }

    func testWriteDemoAudio() throws {
        guard let dir = ProcessInfo.processInfo.environment["DEMO_DIR"] else { throw XCTSkip("DEMO_DIR not set") }
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let demos: [(String, ISDEngine, [(time: Double, message: MIDIMessage)])] = [
            ("felt-glass", ISD_ENGINE_FELT_GLASS, DemoPhrases.feltGlass),
            ("orbit-pad", ISD_ENGINE_ORBIT_PAD, DemoPhrases.orbitPad),
            ("honey-tape", ISD_ENGINE_HONEY_TAPE, DemoPhrases.honeyTape),
            ("haze-bells", ISD_ENGINE_HAZE_BELLS, DemoPhrases.hazeBells),
            ("cabin-felt", ISD_ENGINE_CABIN_FELT, DemoPhrases.cabinFelt),
            ("morning-box", ISD_ENGINE_MORNING_BOX, DemoPhrases.morningBox),
            ("polar-choir", ISD_ENGINE_POLAR_CHOIR, DemoPhrases.polarChoir),
            ("plankton-keys", ISD_ENGINE_PLANKTON_KEYS, DemoPhrases.planktonKeys),
            ("tea-house-koto", ISD_ENGINE_TEA_HOUSE_KOTO, DemoPhrases.teaHouseKoto),
            ("zen-shakuhachi", ISD_ENGINE_ZEN_SHAKUHACHI, DemoPhrases.zenShakuhachi),
        ]
        var written = 0
        for (name, engine, phrase) in demos {
            guard let audio = Self.render(engine, phrase, tail: 6) else { continue }   // engine not built yet
            let peak = max(audio.l.map(abs).max() ?? 0, audio.r.map(abs).max() ?? 0)
            XCTAssertLessThanOrEqual(peak, 1.0, name)
            let wav = url.appendingPathComponent("\(name)-demo.wav")
            try Self.writeWAV(audio, to: wav)
            let png = url.appendingPathComponent("\(name)-spectrogram.png")
            try PreviewRenderer.writePNG(Spectrogram.image(left: audio.l, sampleRate: Self.rate, width: 1400, height: 500), to: png)
            XCTAssertTrue(FileManager.default.fileExists(atPath: wav.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: png.path))
            written += 1
        }
        XCTAssertGreaterThanOrEqual(written, 1)
    }

    /// Renders the ambience alone (levels glide in over 2.5 s, as in the app).
    nonisolated static func renderAmbience(_ levels: [(ISDAmbienceSource, Float)], seconds: Double, nightCool: Float = 0,
                                           waves: [Wave] = [], speed: Float = 0, surfDistance: Float = 0, indoors: Float = 0,
                                           snowOnGlass: Float = 0, kettleAt: Double? = nil,
                                           boatAt: Double? = nil, bellAt: Double? = nil,
                                           knockerAt: Double? = nil) -> (l: [Float], r: [Float]) {
        guard let a = isd_ambience_create(rate, 512, 7) else { return ([], []) }
        defer { isd_ambience_destroy(a) }
        for (source, level) in levels { isd_ambience_set_level(a, source, level) }
        isd_ambience_set_night_cool(a, nightCool)
        isd_ambience_set_speed(a, speed)
        isd_ambience_set_surf_distance(a, surfDistance)
        isd_ambience_set_indoors(a, indoors)
        isd_ambience_set_snow_on_glass(a, snowOnGlass)
        var kettlePending = kettleAt, boatPending = boatAt, bellPending = bellAt, knockerPending = knockerAt
        let total = Int(seconds * rate), block = 256
        var l = [Float](repeating: 0, count: total), r = [Float](repeating: 0, count: total)
        var i = 0, nextWave = 0
        while i < total {
            let n = min(block, total - i)
            while nextWave < waves.count, Int(waves[nextWave].breakTime * rate) < i + n {
                isd_ambience_trigger_wave(a, waves[nextWave].strength); nextWave += 1
            }
            if let k = kettlePending, Int(k * rate) < i + n { isd_ambience_debug_start_kettle(a); kettlePending = nil }
            if let b = boatPending, Int(b * rate) < i + n { isd_ambience_debug_start_boat(a); boatPending = nil }
            if let b = bellPending, Int(b * rate) < i + n { isd_ambience_debug_strike_bell(a); bellPending = nil }
            if let k = knockerPending, Int(k * rate) < i + n { isd_ambience_debug_start_knocker(a); knockerPending = nil }
            l.withUnsafeMutableBufferPointer { lp in
                r.withUnsafeMutableBufferPointer { rp in isd_ambience_render(a, lp.baseAddress! + i, rp.baseAddress! + i, Int32(n)) }
            }
            i += n
        }
        return (l, r)
    }

    func testWriteAmbienceDemos() throws {
        guard let dir = ProcessInfo.processInfo.environment["DEMO_DIR"] else { throw XCTSkip("DEMO_DIR not set") }
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var swell = OceanSwell(seed: 5)
        var waves: [Wave] = []
        for _ in 0..<(60 * 60) { waves += swell.step(dt: 1.0 / 60) }
        let scenes: [(String, [(ISDAmbienceSource, Float)], Float, [Wave], Float, Float)] = [
            ("moonlit-lake-ambience", [(ISD_AMB_WATER, 0.8), (ISD_AMB_CRICKETS, 0.7), (ISD_AMB_BREEZE, 0.4), (ISD_AMB_OWL, 0.3)], 0.3, [], 0, 0),
            ("spaceship-lounge-ambience", [(ISD_AMB_SHIP_HUM, 0.8), (ISD_AMB_AIR_FLOW, 0.5), (ISD_AMB_CHIME, 0.3), (ISD_AMB_HULL_TICKS, 0.3)], 0, [], 0, 0),
            ("golden-hour-beach-ambience", [(ISD_AMB_SURF, 0.9), (ISD_AMB_PALMS, 0.45), (ISD_AMB_BREEZE, 0.35), (ISD_AMB_CRICKETS, 0.25)], 0.1, waves, 0, 0.15),
            ("coast-road-ambience", [(ISD_AMB_ROAD, 0.8), (ISD_AMB_ENGINE, 0.6), (ISD_AMB_WINDOW_WIND, 0.5), (ISD_AMB_SURF, 0.5), (ISD_AMB_PASSING_CAR, 0.3)], 0, waves, 0.5, 0.9),
        ]
        // The window worlds: heard indoors through the glass.
        let indoorScenes: [(String, [(ISDAmbienceSource, Float)], Float, Double?)] = [
            ("snowbound-cabin-ambience", [(ISD_AMB_FIRE, 0.7), (ISD_AMB_WIND, 0.4), (ISD_AMB_RAIN_GLASS, 0.3)], 1, nil),
            ("bedroom-dawn-ambience", [(ISD_AMB_DAWN_CHORUS, 0.6), (ISD_AMB_KETTLE, 0.5), (ISD_AMB_STREET, 0.5), (ISD_AMB_BREEZE, 0.35),
                                       (ISD_AMB_DRIPS, 0.4), (ISD_AMB_CLOCK, 0.15)], 0, 2),
        ]
        for (name, levels, snow, kettle) in indoorScenes {
            let audio = Self.renderAmbience(levels, seconds: 60, indoors: 1, snowOnGlass: snow, kettleAt: kettle)
            let peak = max(audio.l.map(abs).max() ?? 0, audio.r.map(abs).max() ?? 0)
            XCTAssertLessThanOrEqual(peak, 1.0, name)
            let rms = (audio.l.reduce(0) { $0 + Double($1) * Double($1) } / Double(max(1, audio.l.count))).squareRoot()
            XCTAssertGreaterThan(20 * log10(max(rms, 1e-10)), -60, name)
            try Self.writeWAV(audio, to: url.appendingPathComponent("\(name).wav"))
            try PreviewRenderer.writePNG(Spectrogram.image(left: audio.l, sampleRate: Self.rate, width: 1400, height: 500),
                                         to: url.appendingPathComponent("\(name)-spectrogram.png"))
        }
        // The night waters (outdoors): the fjord's ice and far waterfall; the bay's lapping, with a boat passing at 2 s.
        let nightScenes: [(String, [(ISDAmbienceSource, Float)], Double?)] = [
            ("aurora-fjord-ambience", [(ISD_AMB_ICE_GROAN, 0.6), (ISD_AMB_WATERFALL, 0.35), (ISD_AMB_WATER, 0.5), (ISD_AMB_WIND, 0.3),
                                       (ISD_AMB_LAPPING, 0.3)], nil),
            ("bioluminescent-bay-ambience", [(ISD_AMB_LAPPING, 0.7), (ISD_AMB_WATER, 0.3), (ISD_AMB_CRICKETS, 0.5), (ISD_AMB_BOAT, 0.4),
                                             (ISD_AMB_BREEZE, 0.3), (ISD_AMB_OWL, 0.15)], 2),
        ]
        for (name, levels, boat) in nightScenes {
            let audio = Self.renderAmbience(levels, seconds: 60, indoors: 0, boatAt: boat)
            let peak = max(audio.l.map(abs).max() ?? 0, audio.r.map(abs).max() ?? 0)
            XCTAssertLessThanOrEqual(peak, 1.0, name)
            let rms = (audio.l.reduce(0) { $0 + Double($1) * Double($1) } / Double(max(1, audio.l.count))).squareRoot()
            XCTAssertGreaterThan(20 * log10(max(rms, 1e-10)), -60, name)
            try Self.writeWAV(audio, to: url.appendingPathComponent("\(name).wav"))
            try PreviewRenderer.writePNG(Spectrogram.image(left: audio.l, sampleRate: Self.rate, width: 1400, height: 500),
                                         to: url.appendingPathComponent("\(name)-spectrogram.png"))
        }
        // The still places. The tea house at a snowy dusk (the Snow weather) with its screens half open, heard through the
        // paper (indoors 0.8 − 0.5 × 0.5): the draught's rustle (0.4 × (0.4 + wind 0.25)), snow ticking on the paper
        // (0.8 × the paper's 0.55), the iron kettle warming from 2 s, and the temple bell struck at 3 s, once its level has
        // glided in, on E (the ambience's key until one is played, and the koto demo's). The garden on a spring morning,
        // outdoors: the water-knocker, starting empty at 2 s, fills, tips and clacks on its stone, then fills again (one
        // whole cycle inside the minute); the warbler calls on its own.
        let stillScenes: [(String, [(ISDAmbienceSource, Float)], Float, Float, Double?, Double?, Double?)] = [
            ("tea-house-snow-ambience", [(ISD_AMB_KETTLE, 0.35), (ISD_AMB_PAPER_SCREENS, 0.26), (ISD_AMB_TEMPLE_BELL, 0.5),
                                         (ISD_AMB_WIND, 0.3), (ISD_AMB_RAIN_GLASS, 0.44)], 0.55, 0.8, 2, 3, nil),
            ("zen-rock-garden-ambience", [(ISD_AMB_WATER_KNOCKER, 0.6), (ISD_AMB_WARBLER, 0.5), (ISD_AMB_BREEZE, 0.35),
                                          (ISD_AMB_DAWN_CHORUS, 0.3), (ISD_AMB_TEMPLE_BELL, 0.3)], 0, 0, nil, nil, 2),
        ]
        for (name, levels, indoors, snow, kettle, bell, knocker) in stillScenes {
            let audio = Self.renderAmbience(levels, seconds: 60, indoors: indoors, snowOnGlass: snow, kettleAt: kettle,
                                            bellAt: bell, knockerAt: knocker)
            let peak = max(audio.l.map(abs).max() ?? 0, audio.r.map(abs).max() ?? 0)
            XCTAssertLessThanOrEqual(peak, 1.0, name)
            let rms = (audio.l.reduce(0) { $0 + Double($1) * Double($1) } / Double(max(1, audio.l.count))).squareRoot()
            XCTAssertGreaterThan(20 * log10(max(rms, 1e-10)), -60, name)
            try Self.writeWAV(audio, to: url.appendingPathComponent("\(name).wav"))
            try PreviewRenderer.writePNG(Spectrogram.image(left: audio.l, sampleRate: Self.rate, width: 1400, height: 500),
                                         to: url.appendingPathComponent("\(name)-spectrogram.png"))
        }
        for (name, levels, cool, waves, speed, distance) in scenes {
            let audio = Self.renderAmbience(levels, seconds: 60, nightCool: cool, waves: waves, speed: speed, surfDistance: distance)
            let peak = max(audio.l.map(abs).max() ?? 0, audio.r.map(abs).max() ?? 0)
            XCTAssertLessThanOrEqual(peak, 1.0, name)
            let rms = (audio.l.reduce(0) { $0 + Double($1) * Double($1) } / Double(max(1, audio.l.count))).squareRoot()
            XCTAssertGreaterThan(20 * log10(max(rms, 1e-10)), -60, name)
            try Self.writeWAV(audio, to: url.appendingPathComponent("\(name).wav"))
            try PreviewRenderer.writePNG(Spectrogram.image(left: audio.l, sampleRate: Self.rate, width: 1400, height: 500),
                                         to: url.appendingPathComponent("\(name)-spectrogram.png"))
        }
    }

    func testSpectrogramShowsATone() {
        let tone = (0..<48_000).map { Float(sin(2 * Double.pi * 1000 * Double($0) / Self.rate)) * 0.5 }
        let image = Spectrogram.image(left: tone, sampleRate: Self.rate, width: 200, height: 100)
        XCTAssertEqual(image.width, 200)
        XCTAssertEqual(image.height, 100)
        XCTAssertGreaterThan(PreviewRenderer.stats(image).variance, 0.0005)
    }
}
