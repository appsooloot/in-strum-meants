import AVFoundation
import Foundation
import InStrumCore
import InStrumAudio

/// What the app model needs from the sound engine (lets tests use a fake).
public protocol InstrumentEngine: AnyObject {
    func start() throws
    @MainActor func loadInstrument(_ choice: InstrumentChoice) async throws
    @MainActor func currentInstrumentState() -> Data?
    func send(_ bytes: [UInt8])
    func panic()
    var audioLevel: Float { get }
    var masterVolume: Float { get set }
    var bufferFrames: UInt32 { get set }
    var soundReading: SoundReading { get }
    var loadedAudioUnit: AUAudioUnit? { get }
    func setMood(_ mood: Mood)
    /// Built-in instruments only.
    func applyPatch(_ patch: Patch)
    var builtInPatchID: String? { get }
    /// Puts the ambience generator on its own bus (after `start`).
    func startAmbience() async
    func setAmbience(_ scene: AmbienceScene)
    var ambienceVolume: Float { get set }
    var ambienceEnabled: Bool { get set }
}

public extension InstrumentEngine {
    var soundReading: SoundReading { SoundReading() }
    var loadedAudioUnit: AUAudioUnit? { nil }
    func setMood(_ mood: Mood) {}
    func applyPatch(_ patch: Patch) {}
    var builtInPatchID: String? { nil }
    func startAmbience() async {}
    func setAmbience(_ scene: AmbienceScene) {}
}

extension AudioEngine: InstrumentEngine {
    public func applyPatch(_ patch: Patch) { loadedBuiltIn?.apply(patch) }
    public var builtInPatchID: String? { loadedBuiltIn?.patchID }
}
