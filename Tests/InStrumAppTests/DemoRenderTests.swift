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
    nonisolated static func renderAmbience(_ levels: [(ISDAmbienceSource, Float)], seconds: Double, nightCool: Float = 0) -> (l: [Float], r: [Float]) {
        guard let a = isd_ambience_create(rate, 512, 7) else { return ([], []) }
        defer { isd_ambience_destroy(a) }
        for (source, level) in levels { isd_ambience_set_level(a, source, level) }
        isd_ambience_set_night_cool(a, nightCool)
        let total = Int(seconds * rate), block = 256
        var l = [Float](repeating: 0, count: total), r = [Float](repeating: 0, count: total)
        var i = 0
        while i < total {
            let n = min(block, total - i)
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
        let scenes: [(String, [(ISDAmbienceSource, Float)], Float)] = [
            ("moonlit-lake-ambience", [(ISD_AMB_WATER, 0.8), (ISD_AMB_CRICKETS, 0.7), (ISD_AMB_BREEZE, 0.4), (ISD_AMB_OWL, 0.3)], 0.3),
            ("spaceship-lounge-ambience", [(ISD_AMB_SHIP_HUM, 0.8), (ISD_AMB_AIR_FLOW, 0.5), (ISD_AMB_CHIME, 0.3), (ISD_AMB_HULL_TICKS, 0.3)], 0),
        ]
        for (name, levels, cool) in scenes {
            let audio = Self.renderAmbience(levels, seconds: 60, nightCool: cool)
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
