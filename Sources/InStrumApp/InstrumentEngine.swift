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
}

public extension InstrumentEngine {
    var soundReading: SoundReading { SoundReading() }
}

extension AudioEngine: InstrumentEngine {}
