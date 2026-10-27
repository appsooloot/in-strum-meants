import Foundation
import AppKit
import os
import InStrumCore
import InStrumAudio

/// Wires keyboard → sound → visuals, and keeps settings safe.
@MainActor
public final class AppModel: ObservableObject {
    public enum Status: Equatable {
        case starting
        case safeMode
        case needsInstrument(message: String?)
        case playing(instrumentName: String)
    }

    public static let screenVelocity: UInt8 = 90
    static let autosaveInterval: TimeInterval = 30
    static let stableAfter: UInt64 = 10_000_000_000   // ns

    @Published public private(set) var status: Status = .starting
    @Published public private(set) var midiSourceNames: [String] = []
    /// True while a plugin is being loaded; new choices are ignored until it finishes.
    @Published public private(set) var isLoading = false
    @Published public private(set) var touchCurve: TouchCurve
    /// The active visual theme.
    @Published public private(set) var themeID: String
    /// Bumped whenever any visual setting changes (the canvas re-reads them).
    @Published public private(set) var visualsVersion = 0
    @Published public private(set) var quality: QualitySetting
    @Published public private(set) var gentleVisuals: Bool
    /// Name of the active reaction style ("Custom" after editing the mapping).
    @Published public private(set) var reactionName: String
    public private(set) var reaction: ReactionMap
    public let presets: PresetStore
    /// Called just before the instrument changes (e.g. to close the old plugin's window).
    public var willChangeInstrument: (@MainActor () -> Void)?
    /// True when the previous run ended without settling (offer Safe Mode before launching).
    public let offersSafeMode: Bool

    public var showsOnScreenKeyboard: Bool { midiSourceNames.isEmpty }
    public var volume: Float { engine.masterVolume }

    // nonisolated: touched from the CoreMIDI and render threads.
    nonisolated let engine: InstrumentEngine
    private struct Live {
        var parser = MIDIParser()
        var state = PerformanceState()
        var events: [PerformanceEvent] = []
        var touch: TouchCurve = .normal
    }
    nonisolated private let live = OSAllocatedUnfairLock(uncheckedState: Live())

    private let store: SettingsStore
    private let launchGuard: LaunchGuard
    private var settings: AppSettings
    private var launched = false
    private var autosaveTimer: Timer?
    private var terminateObserver: NSObjectProtocol?

    public init(engine: InstrumentEngine, store: SettingsStore, launchGuard: LaunchGuard, presets: PresetStore) {
        self.presets = presets
        self.engine = engine
        self.store = store
        self.launchGuard = launchGuard
        let loaded = store.load()
        self.settings = loaded
        self.touchCurve = loaded.touchCurve
        self.themeID = ThemeRegistry.resolve(loaded.themeID)
        self.quality = loaded.quality
        self.gentleVisuals = loaded.gentleVisuals
        self.reactionName = loaded.reactionName
        self.reaction = loaded.reaction
            ?? ReactionPresets.all.first { $0.name == loaded.reactionName }?.map
            ?? ReactionPresets.expressivePianist
        self.offersSafeMode = launchGuard.beginLaunch()
        live.withLockUnchecked { $0.touch = loaded.touchCurve }
    }

    // MARK: - Launch and instruments

    /// Runs once; later calls do nothing.
    public func launch(skipPluginInSafeMode: Bool) async {
        guard !launched else { return }
        launched = true
        engine.masterVolume = settings.masterVolume
        engine.bufferFrames = settings.bufferFrames
        do { try engine.start() } catch {
            status = .needsInstrument(message: "Sound output couldn't start. Check your speakers or headphones, then reopen the app.")
            return
        }
        startAutosave()
        if offersSafeMode && skipPluginInSafeMode {
            status = .safeMode
            launchGuard.markStable()
            return
        }
        guard let choice = settings.instrument else {
            status = .needsInstrument(message: nil)
            return
        }
        await load(choice)
    }

    public func choose(_ plugin: PluginInfo) async {
        guard !isLoading else { return }
        await load(plugin.choice())
    }

    private func load(_ choice: InstrumentChoice) async {
        isLoading = true
        defer { isLoading = false }
        willChangeInstrument?()
        do {
            try await engine.loadInstrument(choice)
        } catch let AudioEngineError.pluginNotFound(name) {
            status = .needsInstrument(message: "“\(name)” couldn't be found. It may have been uninstalled or moved. Choose an instrument below.")
            return
        } catch {
            status = .needsInstrument(message: "“\(choice.name)” couldn't be loaded. If it needs you to sign in, open its own app first, then choose it again.")
            return
        }
        settings.instrument = choice
        status = .playing(instrumentName: choice.name)
        autosave()
        let launchGuard = self.launchGuard
        Task { try? await Task.sleep(nanoseconds: Self.stableAfter); launchGuard.markStable() }
    }

    // MARK: - Playing (any thread)

    /// Called on the CoreMIDI thread. Sound first, visuals second.
    public nonisolated func handleMIDI(bytes raw: [UInt8], time: Double) {
        let bytes = live.withLockUnchecked { $0.touch }.transform(raw)
        engine.send(bytes)
        live.withLockUnchecked { l in
            for message in l.parser.parse(bytes) {
                l.events += l.state.apply(message, at: time)
            }
        }
    }

    public func playFromScreen(note: UInt8, down: Bool) {
        let bytes: [UInt8] = down ? [0x90, note, Self.screenVelocity] : [0x80, note, 0]
        handleMIDI(bytes: bytes, time: ProcessInfo.processInfo.systemUptime)
    }

    public func midiSourcesChanged(names: [String], removed: Bool) {
        midiSourceNames = names
        if removed { panic() }
    }

    public func panic() {
        engine.panic()
        live.withLockUnchecked { l in l.events += l.state.reset() }
    }

    /// Called by the renderer each frame.
    public nonisolated func drainEvents() -> [PerformanceEvent] {
        live.withLockUnchecked { l in
            let out = l.events
            l.events.removeAll(keepingCapacity: true)
            return out
        }
    }

    public nonisolated var intensity: Float {
        live.withLockUnchecked { l in
            l.state.decay(to: ProcessInfo.processInfo.systemUptime)
            return l.state.intensity
        }
    }

    public nonisolated var audioLevel: Float { engine.audioLevel }

    // MARK: - Settings

    public func setVolume(_ v: Float) {
        engine.masterVolume = v
        settings.masterVolume = engine.masterVolume
        autosave()
    }

    public var bufferFrames: UInt32 { engine.bufferFrames }

    public func setTouchCurve(_ curve: TouchCurve) {
        touchCurve = curve
        live.withLockUnchecked { $0.touch = curve }
        settings.touchCurve = curve
        autosave()
    }

    public func setBufferFrames(_ frames: UInt32) {
        engine.bufferFrames = frames
        settings.bufferFrames = frames
        autosave()
    }

    // MARK: - Visuals

    public func setTheme(_ id: String) {
        let resolved = ThemeRegistry.resolve(id)
        guard resolved != themeID else { return }
        themeID = resolved
        settings.themeID = resolved
        visualsVersion += 1
        autosave()
    }

    public func themeState(for id: String) -> ThemeState {
        settings.themeStates[ThemeRegistry.resolve(id)] ?? ThemeState()
    }

    public func saveThemeState(_ state: ThemeState, for id: String) {
        settings.themeStates[ThemeRegistry.resolve(id)] = state
        visualsVersion += 1
        scheduleSave()
    }

    public func setQuality(_ q: QualitySetting) {
        quality = q; settings.quality = q; visualsVersion += 1; autosave()
    }

    public func setGentleVisuals(_ on: Bool) {
        gentleVisuals = on; settings.gentleVisuals = on; visualsVersion += 1; autosave()
    }

    // MARK: - Presets

    public func allReactions() -> [ReactionPreset] {
        ReactionPresets.all + presets.reactions().filter { p in !ReactionPresets.all.contains { $0.name == p.name } }
    }

    public func setReaction(_ preset: ReactionPreset) {
        reaction = preset.map
        reactionName = preset.name
        settings.reaction = preset.map
        settings.reactionName = preset.name
        visualsVersion += 1
        autosave()
    }

    /// Used by the mapping editor; the style becomes "Custom" until saved.
    public func setReactionMap(_ map: ReactionMap) {
        reaction = map
        reactionName = "Custom"
        settings.reaction = map
        settings.reactionName = "Custom"
        visualsVersion += 1
        scheduleSave()
    }

    public func saveReaction(named name: String) {
        let preset = ReactionPreset(name: name, map: reaction)
        try? presets.save(preset)
        setReaction(preset)
    }

    public func lookPresets() -> [LookPreset] {
        let builtIn = themeID == ButterflyGardenModel.id ? ButterflyGardenModel.builtInLooks : []
        return builtIn + presets.looks(for: themeID).filter { p in !builtIn.contains { $0.name == p.name } }
    }

    public func applyLook(_ look: LookPreset) {
        var state = look.state
        state.lookPresetName = look.name
        saveThemeState(state, for: look.themeID)
    }

    public func saveLook(named name: String) {
        var state = themeState(for: themeID)
        state.lookPresetName = name
        try? presets.save(LookPreset(name: name, themeID: themeID, state: state))
        saveThemeState(state, for: themeID)
    }

    /// A random, tasteful look for the current theme (macros kept).
    public func surprise() {
        let current = themeState(for: themeID)
        var state = Surprise.look(specs: ThemeRegistry.parameters(for: themeID), seed: UInt64.random(in: 1...UInt64.max))
        state.macros = current.macros
        saveThemeState(state, for: themeID)
    }

    private var saveTask: Task<Void, Never>?
    /// Saves after edits settle (0.5 s), so dragging a slider doesn't write on every tick.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            self?.autosave()
        }
    }

    public func autosave() {
        if settings.instrument != nil, case .playing = status {
            settings.instrument?.stateData = engine.currentInstrumentState()
        }
        settings.masterVolume = engine.masterVolume
        try? store.save(settings)
    }

    private func startAutosave() {
        guard autosaveTimer == nil else { return }
        autosaveTimer = Timer.scheduledTimer(withTimeInterval: Self.autosaveInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.autosave() }
        }
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.autosave()
                self?.launchGuard.markStable()
            }
        }
    }
}
