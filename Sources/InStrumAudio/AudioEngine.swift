import AVFoundation
import AudioToolbox
import InStrumCore
import os

public enum AudioEngineError: Error, Equatable {
    case pluginNotFound(String)
    case loadFailed(String)
}

/// Hosts one instrument plugin and plays it to the speakers.
/// `send` is safe to call from the CoreMIDI thread.
public final class AudioEngine {

    private let engine = AVAudioEngine()
    private let manualRendering: Bool
    private let manualSampleRate: Double
    private var instrument: AVAudioUnit?
    private struct Shared { var midiBlock: AUScheduleMIDIEventBlock?; var level: Float = 0 }
    private let shared = OSAllocatedUnfairLock(uncheckedState: Shared())
    private var configObserver: NSObjectProtocol?

    /// Output buffer size in frames (smaller = lower latency, larger = fewer glitches).
    public var bufferFrames: UInt32 = 256 {
        didSet { if !manualRendering && engine.isRunning { setOutputBufferSize() } }
    }

    public init(manualRendering: Bool = false, manualSampleRate: Double = 44_100) {
        self.manualRendering = manualRendering
        self.manualSampleRate = manualSampleRate
    }

    deinit {
        if let o = configObserver { NotificationCenter.default.removeObserver(o) }
        engine.mainMixerNode.removeTap(onBus: 0)
        engine.stop()
    }

    /// Safe to call more than once.
    public func start() throws {
        if engine.isRunning { return }
        if manualRendering {
            if !engine.isInManualRenderingMode {
                let format = AVAudioFormat(standardFormatWithSampleRate: manualSampleRate, channels: 2)!
                try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
            }
        } else {
            setOutputBufferSize()
            installLevelTap()
            if configObserver == nil { configObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
            ) { [weak self] _ in self?.restartAfterConfigurationChange() } }
        }
        _ = engine.mainMixerNode   // make sure the graph has an output path
        engine.prepare()
        try engine.start()
    }

    /// Graph changes and plugin state happen on the main thread.
    @MainActor
    public func loadInstrument(_ choice: InstrumentChoice) async throws {
        guard let component = PluginCatalog.component(for: choice) else {
            throw AudioEngineError.pluginNotFound(choice.name)
        }
        let unit: AVAudioUnit
        do {
            unit = try await AVAudioUnit.instantiate(with: component.audioComponentDescription, options: [])
        } catch {
            throw AudioEngineError.loadFailed(choice.name)
        }
        if let data = choice.stateData,
           let state = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            unit.auAudioUnit.fullState = state
        }
        shared.withLockUnchecked { $0.midiBlock = nil }
        if let old = instrument { engine.detach(old) }
        engine.attach(unit)
        engine.connect(unit, to: engine.mainMixerNode, format: renderFormat())
        instrument = unit
        let block = unit.auAudioUnit.scheduleMIDIEventBlock
        shared.withLockUnchecked { $0.midiBlock = block }
        if !engine.isRunning { try engine.start() }
    }

    @MainActor
    public func currentInstrumentState() -> Data? {
        guard let state = instrument?.auAudioUnit.fullState else { return nil }
        return try? PropertyListSerialization.data(fromPropertyList: state, format: .binary, options: 0)
    }

    public func send(_ bytes: [UInt8]) {
        let block = shared.withLockUnchecked { $0.midiBlock }
        guard let block, !bytes.isEmpty else { return }
        bytes.withUnsafeBufferPointer { p in
            block(AUEventSampleTimeImmediate, 0, p.count, p.baseAddress!)
        }
    }

    /// Silences everything: pedal up, all notes off, all sound off.
    public func panic() {
        for ch: UInt8 in 0..<16 {
            send([0xB0 | ch, 64, 0])
            send([0xB0 | ch, 123, 0])
            send([0xB0 | ch, 120, 0])
        }
        for note: UInt8 in 0...127 { send([0x80, note, 0]) }
    }

    public var audioLevel: Float {
        shared.withLockUnchecked { $0.level }
    }

    public var loadedAudioUnit: AUAudioUnit? { instrument?.auAudioUnit }

    public var masterVolume: Float {
        get { engine.mainMixerNode.outputVolume }
        set { engine.mainMixerNode.outputVolume = max(0, min(1, newValue)) }
    }

    /// Offline rendering, for tests only.
    public func renderOffline(frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: frames)!
        _ = try engine.renderOffline(frames, to: buffer)
        return buffer
    }

    // MARK: - Private

    /// Render the instrument at the output device's rate so nothing is resampled.
    private func renderFormat() -> AVAudioFormat {
        var rate = manualRendering ? engine.manualRenderingFormat.sampleRate
                                   : engine.outputNode.outputFormat(forBus: 0).sampleRate
        if rate <= 0 { rate = 44_100 }
        return AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
    }

    private func setOutputBufferSize() {
        guard let unit = engine.outputNode.audioUnit else { return }
        var frames = bufferFrames
        AudioUnitSetProperty(unit, kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0,
                             &frames, UInt32(MemoryLayout<UInt32>.size))
    }

    private func installLevelTap() {
        let mixer = engine.mainMixerNode
        mixer.removeTap(onBus: 0)
        mixer.installTap(onBus: 0, bufferSize: 512, format: nil) { [weak self] buffer, _ in
            guard let self, let data = buffer.floatChannelData else { return }
            let n = Int(buffer.frameLength)
            guard n > 0 else { return }
            var sum: Float = 0
            for i in 0..<n { sum += data[0][i] * data[0][i] }
            let rms = min(1, sqrtf(sum / Float(n)) * 2)
            self.shared.withLockUnchecked { $0.level = rms }
        }
    }

    private func restartAfterConfigurationChange() {
        if let unit = instrument {
            engine.disconnectNodeOutput(unit)
            engine.connect(unit, to: engine.mainMixerNode, format: renderFormat())
        }
        setOutputBufferSize()
        installLevelTap()
        engine.prepare()
        try? engine.start()
    }
}
