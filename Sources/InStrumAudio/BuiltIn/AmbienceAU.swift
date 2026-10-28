import AVFoundation
import AudioToolbox
import InStrumCore
import InStrumDSP
import os

/// The ambience generator the render block uses. Retired instances (after a sample-rate change) live until the
/// unit goes away, so the render thread never touches freed memory.
final class AmbienceBox {
    var ambience: OpaquePointer?
    var retired: [OpaquePointer] = []
    var scratchL: UnsafeMutablePointer<Float>?
    var scratchR: UnsafeMutablePointer<Float>?
    deinit {
        if let ambience { isd_ambience_destroy(ambience) }
        retired.forEach { isd_ambience_destroy($0) }
    }
}

/// The live ambience (spec §5) as an in-process generator Audio Unit. It plays on its own bus,
/// never through the instrument's, so panic and the sound-character tap leave it alone.
public final class AmbienceAU: AUAudioUnit {
    private let box = AmbienceBox()
    private var outputBus: AUAudioUnitBus!
    private var busArray: AUAudioUnitBusArray!
    private var scratch: AVAudioPCMBuffer?
    private var rate: Double = 0
    private struct State { var scene = AmbienceScene.silent; var enabled = true; var playing = false }
    private let state = OSAllocatedUnfairLock(uncheckedState: State())
    private static let seed = UInt64(Date().timeIntervalSince1970 * 1000) & 0xFFFF_FFFF

    public override init(componentDescription: AudioComponentDescription, options: AudioComponentInstantiationOptions = []) throws {
        try super.init(componentDescription: componentDescription, options: options)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        outputBus = try AUAudioUnitBus(format: format)
        outputBus.maximumChannelCount = 2
        busArray = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [outputBus])
        guard make(rate: 48_000) else { throw AudioEngineError.loadFailed("Ambience") }
        maximumFramesToRender = 4096
    }

    public override var outputBusses: AUAudioUnitBusArray { busArray }
    public override var canProcessInPlace: Bool { true }

    // MARK: - Control (any thread)

    public func setScene(_ scene: AmbienceScene) {
        state.withLockUnchecked { $0.scene = scene }
        apply(thunder: scene.thunder)
    }

    /// Off fades every source out (and stops the work); on brings the scene back.
    public var enabled: Bool {
        get { state.withLockUnchecked { $0.enabled } }
        set { state.withLockUnchecked { $0.enabled = newValue }; apply(thunder: nil) }
    }

    /// Notes held on the instrument: the ambience ducks under them.
    public func setPlaying(_ playing: Bool) {
        let changed = state.withLockUnchecked { s -> Bool in let c = s.playing != playing; s.playing = playing; return c }
        if changed { apply(thunder: nil) }
    }

    private func apply(thunder: Double?) {
        guard let a = box.ambience else { return }
        let s = state.withLockUnchecked { $0 }
        for source in AmbienceSource.allCases {
            let level = s.enabled ? s.scene.level(source) : 0
            isd_ambience_set_level(a, Self.cSource(source), Float(level))
        }
        isd_ambience_set_night_cool(a, Float(s.scene.nightCool))
        isd_ambience_set_closeness(a, Float(s.scene.closeness))
        isd_ambience_set_density(a, Float(s.scene.density))
        isd_ambience_set_activity(a, Float(max(s.scene.activity, s.playing ? 1 : 0)))
        if let distance = thunder, s.enabled { isd_ambience_trigger_thunder(a, Float(distance)) }
    }

    static func cSource(_ s: AmbienceSource) -> ISDAmbienceSource {
        switch s {
        case .water: return ISD_AMB_WATER
        case .crickets: return ISD_AMB_CRICKETS
        case .breeze: return ISD_AMB_BREEZE
        case .owl: return ISD_AMB_OWL
        case .rainOnWater: return ISD_AMB_RAIN_WATER
        case .rainOnGlass: return ISD_AMB_RAIN_GLASS
        case .dawnChorus: return ISD_AMB_DAWN_CHORUS
        case .shipHum: return ISD_AMB_SHIP_HUM
        case .airFlow: return ISD_AMB_AIR_FLOW
        case .chime: return ISD_AMB_CHIME
        case .hullTicks: return ISD_AMB_HULL_TICKS
        case .wind: return ISD_AMB_WIND
        }
    }

    // MARK: - Rendering

    private func make(rate newRate: Double) -> Bool {
        guard let fresh = isd_ambience_create(newRate, 4096, Self.seed) else { return false }
        if let old = box.ambience { box.retired.append(old) }
        box.ambience = fresh
        rate = newRate
        apply(thunder: nil)
        return true
    }

    public override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        let busRate = outputBus.format.sampleRate
        if busRate != rate, !make(rate: busRate) { throw AudioEngineError.loadFailed("Ambience") }
        scratch = AVAudioPCMBuffer(pcmFormat: outputBus.format, frameCapacity: max(maximumFramesToRender, 4096))
        box.scratchL = scratch?.floatChannelData?[0]
        box.scratchR = outputBus.format.channelCount > 1 ? scratch?.floatChannelData?[1] : nil
    }

    public override var internalRenderBlock: AUInternalRenderBlock {
        let box = self.box
        return { _, _, frameCount, _, outputData, _, _ in
            guard let ambience = box.ambience else { return kAudioUnitErr_Uninitialized }
            let buffers = UnsafeMutableAudioBufferListPointer(outputData)
            guard buffers.count >= 2 else { return kAudioUnitErr_FormatNotSupported }
            if buffers[0].mData == nil || buffers[1].mData == nil, let sl = box.scratchL, let sr = box.scratchR {
                buffers[0].mData = UnsafeMutableRawPointer(sl)
                buffers[1].mData = UnsafeMutableRawPointer(sr)
            }
            guard let l = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let r = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return kAudioUnitErr_InvalidParameter }
            isd_ambience_render(ambience, l, r, Int32(frameCount))
            buffers[0].mDataByteSize = frameCount * 4
            buffers[1].mDataByteSize = frameCount * 4
            return noErr
        }
    }
}
