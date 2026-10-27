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
    /// The instrument plays into its own bus; the level and sound-character tap listen here, so ambience never counts.
    private let instrumentBus = AVAudioMixerNode()
    /// Ambience plays on its own bus straight into the main mixer.
    private let ambienceBus = AVAudioMixerNode()
    private var ambienceUnit: AVAudioUnit?
    private var ambienceScene = AmbienceScene.silent
    private let manualRendering: Bool
    private let manualSampleRate: Double
    private var instrument: AVAudioUnit?
    private struct Shared {
        var midiBlock: AUScheduleMIDIEventBlock?
        var level: Float = 0
        var analyzer: SoundCharacterAnalyzer?
        var held = Set<UInt16>()   // channel << 8 | note
        var ambience: AmbienceAU?
    }
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
        instrumentBus.removeTap(onBus: 0)
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
            if configObserver == nil { configObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
            ) { [weak self] _ in self?.restartAfterConfigurationChange() } }
        }
        _ = engine.mainMixerNode   // make sure the graph has an output path
        if instrumentBus.engine == nil {
            engine.attach(instrumentBus)
            engine.connect(instrumentBus, to: engine.mainMixerNode, format: renderFormat())
        }
        if !manualRendering { installLevelTap() }   // taps don't run in offline manual rendering
        engine.prepare()
        try engine.start()
    }

    /// Graph changes and plugin state happen on the main thread.
    @MainActor
    public func loadInstrument(_ choice: InstrumentChoice) async throws {
        let description: AudioComponentDescription
        if BuiltInCatalog.engine(for: choice) != nil {
            BuiltInCatalog.registerAll()
            description = AudioComponentDescription(componentType: choice.componentType, componentSubType: choice.componentSubType,
                                                    componentManufacturer: choice.componentManufacturer,
                                                    componentFlags: 0, componentFlagsMask: 0)
        } else {
            guard let component = PluginCatalog.component(for: choice) else {
                throw AudioEngineError.pluginNotFound(choice.name)
            }
            description = component.audioComponentDescription
        }
        let unit: AVAudioUnit
        do {
            unit = try await AVAudioUnit.instantiate(with: description, options: [])
        } catch {
            throw AudioEngineError.loadFailed(choice.name)
        }
        if let data = choice.stateData,
           let state = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            unit.auAudioUnit.fullState = state
        }
        let ambience = shared.withLockUnchecked { s -> AmbienceAU? in s.midiBlock = nil; s.held.removeAll(); return s.ambience }
        ambience?.setPlaying(false)
        if let old = instrument { engine.detach(old) }
        engine.attach(unit)
        engine.connect(unit, to: instrumentBus, format: renderFormat())
        instrument = unit
        let block = unit.auAudioUnit.scheduleMIDIEventBlock
        shared.withLockUnchecked { $0.midiBlock = block }
        if !engine.isRunning { try engine.start() }
    }

    /// The loaded instrument when it's one of the app's own.
    public var loadedBuiltIn: BuiltInInstrumentAU? { instrument?.auAudioUnit as? BuiltInInstrumentAU }

    /// Tells a built-in instrument the set's mood (plugins ignore it).
    public func setMood(_ mood: Mood) { loadedBuiltIn?.setMood(mood) }

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
        trackNotes(bytes)
    }

    /// What the instrument currently sounds like (sharp/smooth, bright/dark, ...).
    public var soundReading: SoundReading {
        shared.withLockUnchecked { $0.analyzer }?.reading ?? SoundReading()
    }

    /// Tells the sound analyser when notes start and when everything is released.
    private func trackNotes(_ bytes: [UInt8]) {
        guard bytes.count >= 3 else { return }
        let status = bytes[0] & 0xF0, key = UInt16(bytes[0] & 0x0F) << 8 | UInt16(bytes[1])
        let isOn = status == 0x90 && bytes[2] > 0
        let isOff = status == 0x80 || (status == 0x90 && bytes[2] == 0)
        guard isOn || isOff else { return }
        let (analyzer, released, ambience) = shared.withLockUnchecked { s -> (SoundCharacterAnalyzer?, Bool, AmbienceAU?) in
            let had = !s.held.isEmpty
            if isOn { s.held.insert(key) } else { s.held.remove(key) }
            return (s.analyzer, had && s.held.isEmpty, s.ambience)
        }
        if isOn { analyzer?.noteOn() } else if released { analyzer?.noteOff() }
        if isOn || released { ambience?.setPlaying(isOn) }
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

    // MARK: - Ambience

    /// Attaches the ambience generator on its own bus. Safe to call more than once.
    @MainActor
    public func startAmbience() async {
        guard ambienceUnit == nil else { return }
        BuiltInCatalog.registerAll()
        guard let unit = try? await AVAudioUnit.instantiate(with: BuiltInCatalog.ambienceDescription, options: []),
              let au = unit.auAudioUnit as? AmbienceAU else { return }
        if ambienceBus.engine == nil {
            engine.attach(ambienceBus)
            engine.connect(ambienceBus, to: engine.mainMixerNode, format: renderFormat())
        }
        engine.attach(unit)
        engine.connect(unit, to: ambienceBus, format: renderFormat())
        ambienceUnit = unit
        au.enabled = ambienceEnabled
        au.setScene(ambienceScene)
        let playing = shared.withLockUnchecked { s -> Bool in s.ambience = au; return !s.held.isEmpty }
        au.setPlaying(playing)
        updateAmbienceBus()
        if !engine.isRunning { try? engine.start() }
    }

    /// What the world wants to hear; every change glides over at least 2 s.
    public func setAmbience(_ scene: AmbienceScene) {
        ambienceScene = scene
        ambienceUnit.flatMap { $0.auAudioUnit as? AmbienceAU }?.setScene(scene)
    }

    /// 0…1 (default 25%).
    public var ambienceVolume: Float = 0.25 { didSet { updateAmbienceBus() } }

    public var ambienceEnabled = true {
        didSet {
            ambienceUnit.flatMap { $0.auAudioUnit as? AmbienceAU }?.enabled = ambienceEnabled
            updateAmbienceBus()
        }
    }

    /// Routing checks (tests): ambience goes straight to the main mixer, never through the instrument bus,
    /// where the level and sound-character tap listens.
    var ambienceFeedsMainMixer: Bool {
        ambienceUnit != nil && engine.outputConnectionPoints(for: ambienceBus, outputBus: 0).contains { $0.node === engine.mainMixerNode }
    }
    var ambienceFeedsInstrumentBus: Bool {
        guard let unit = ambienceUnit else { return false }
        return [unit, ambienceBus].contains { node in engine.outputConnectionPoints(for: node, outputBus: 0).contains { $0.node === instrumentBus } }
    }

    private func updateAmbienceBus() {
        ambienceBus.outputVolume = ambienceEnabled ? max(0, min(1, ambienceVolume)) : 0
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
        let mixer = instrumentBus
        mixer.removeTap(onBus: 0)
        let rate = mixer.outputFormat(forBus: 0).sampleRate
        let analyzer = SoundCharacterAnalyzer(sampleRate: rate > 0 ? rate : 44_100)
        shared.withLockUnchecked { $0.analyzer = analyzer }
        mixer.installTap(onBus: 0, bufferSize: 512, format: nil) { [weak self] buffer, _ in
            guard let self, let data = buffer.floatChannelData else { return }
            let n = Int(buffer.frameLength)
            guard n > 0 else { return }
            var sum: Float = 0
            for i in 0..<n { sum += data[0][i] * data[0][i] }
            let rms = min(1, sqrtf(sum / Float(n)) * 2)
            self.shared.withLockUnchecked { $0.level = rms }
            let right = buffer.format.channelCount > 1 ? data[1] : data[0]
            analyzer.process(left: data[0], right: right, frames: n)
        }
    }

    private func restartAfterConfigurationChange() {
        engine.disconnectNodeOutput(instrumentBus)
        engine.connect(instrumentBus, to: engine.mainMixerNode, format: renderFormat())
        if let unit = instrument {
            engine.disconnectNodeOutput(unit)
            engine.connect(unit, to: instrumentBus, format: renderFormat())
        }
        if let unit = ambienceUnit {
            engine.disconnectNodeOutput(ambienceBus)
            engine.connect(ambienceBus, to: engine.mainMixerNode, format: renderFormat())
            engine.disconnectNodeOutput(unit)
            engine.connect(unit, to: ambienceBus, format: renderFormat())
        }
        setOutputBufferSize()
        installLevelTap()
        engine.prepare()
        try? engine.start()
    }
}
