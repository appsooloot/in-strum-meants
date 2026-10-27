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
    }
    nonisolated private let live = OSAllocatedUnfairLock(uncheckedState: Live())

    private let store: SettingsStore
    private let launchGuard: LaunchGuard
    private var settings: AppSettings
    private var launched = false
    private var autosaveTimer: Timer?
    private var terminateObserver: NSObjectProtocol?

    public init(engine: InstrumentEngine, store: SettingsStore, launchGuard: LaunchGuard) {
        self.engine = engine
        self.store = store
        self.launchGuard = launchGuard
        self.settings = store.load()
        self.offersSafeMode = launchGuard.beginLaunch()
    }

    // MARK: - Launch and instruments

    /// Runs once; later calls do nothing.
    public func launch(skipPluginInSafeMode: Bool) async {
        guard !launched else { return }
        launched = true
        engine.masterVolume = settings.masterVolume
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
    public nonisolated func handleMIDI(bytes: [UInt8], time: Double) {
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
