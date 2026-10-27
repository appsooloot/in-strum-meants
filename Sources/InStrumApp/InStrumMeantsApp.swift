import SwiftUI
import AppKit
import InStrumCore
import InStrumAudio

/// Owns the long-lived pieces: sound engine, MIDI input and app model.
@MainActor
final class AppContainer: ObservableObject {
    let audio: AudioEngine
    let model: AppModel
    private var midi: MIDIInput?

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("In Strum Meants", isDirectory: true)
        audio = AudioEngine()
        model = AppModel(engine: audio, store: SettingsStore(directory: support),
                         launchGuard: LaunchGuard(directory: support))
        let model = self.model
        midi = try? MIDIInput(
            onBytes: { bytes, time in model.handleMIDI(bytes: bytes, time: time) },
            onSourcesChanged: { names, removed in
                Task { @MainActor in model.midiSourcesChanged(names: names, removed: removed) }
            })
        if let names = midi?.sourceNames, !names.isEmpty { model.midiSourcesChanged(names: names, removed: false) }
    }
}

public struct InStrumMeantsApp: App {
    @StateObject private var container = AppContainer()

    public init() {
        NSApplication.shared.setActivationPolicy(.regular)
    }

    public var body: some Scene {
        WindowGroup("In Strum Meants") {
            MainView(model: container.model, audio: container.audio)
                .frame(minWidth: 900, minHeight: 560)
                .preferredColorScheme(.dark)
        }
    }
}
