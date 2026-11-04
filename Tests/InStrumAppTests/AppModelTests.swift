import XCTest
import AudioToolbox
import Combine
@testable import InStrumApp
@testable import InStrumAudio
@testable import InStrumCore

final class FakeEngine: InstrumentEngine {
    var started = 0
    var loaded: [InstrumentChoice] = []
    var loadError: Error?
    var sent: [[UInt8]] = []
    var panicCount = 0
    var state: Data? = Data([1, 2, 3])
    var audioLevel: Float = 0
    var masterVolume: Float = 0.8
    var bufferFrames: UInt32 = 128
    var loadDelay: UInt64 = 0
    var log: [String] = []

    func start() throws { started += 1 }
    func loadInstrument(_ choice: InstrumentChoice) async throws {
        log.append("load")
        if loadDelay > 0 { try? await Task.sleep(nanoseconds: loadDelay) }
        if let e = loadError { throw e }
        loaded.append(choice)
    }
    func currentInstrumentState() -> Data? { state }
    func send(_ bytes: [UInt8]) { sent.append(bytes) }
    func panic() { panicCount += 1 }
    var applied: [Patch] = []
    var moods: [Mood] = []
    func applyPatch(_ patch: Patch) { applied.append(patch) }
    func setMood(_ mood: Mood) { moods.append(mood) }
    var scenes: [AmbienceScene] = []
    var ambienceVolume: Float = 0.25
    var ambienceEnabled = true
    var ambienceStarts = 0, startedBeforeAmbience = false
    func startAmbience() async { ambienceStarts += 1; startedBeforeAmbience = started > 0 }
    func setAmbience(_ s: AmbienceScene) { scenes.append(s) }
    // Output
    var isRunning = true
    var restarts = 0
    var outputDevices: [OutputDevice] = []
    var selected: [String?] = []
    var failingUIDs: Set<String> = []
    var outputSampleRate: Double = 48_000
    var healthNote: String?
    var healthChecks = 0
    func restartAudio() { restarts += 1 }
    func selectOutputDevice(uid: String?) -> Bool {
        selected.append(uid)
        return uid.map { !failingUIDs.contains($0) } ?? true
    }
    func checkHealth() -> String? { healthChecks += 1; return healthNote }
    /// A real unit for the tests that watch its dials move (nil, as before, for every other test).
    var unit: AUAudioUnit?
    var loadedAudioUnit: AUAudioUnit? { unit }
}

/// Stands in for the MIDI input in tests.
final class FakeMIDI: MIDIControlling {
    var disabled: Set<String> = []
    var rescans = 0
    var activity: [String: Double] = [:]
    func setDisabled(_ names: Set<String>) { disabled = names }
    func rescan() { rescans += 1 }
    func lastActivity(_ name: String) -> Double? { activity[name] }
}

@MainActor
final class AppModelTests: XCTestCase {
    var dir: URL!
    var engine: FakeEngine!
    var store: SettingsStore!

    let splice = InstrumentChoice(name: "Splice INSTRUMENT", componentType: kAudioUnitType_MusicDevice,
                                  componentSubType: 0x53504C49, componentManufacturer: 0x53504C43)

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        engine = FakeEngine()
        store = SettingsStore(directory: dir)
    }

    private func makeModel() -> AppModel {
        AppModel(engine: engine, store: store, launchGuard: LaunchGuard(directory: dir),
                 presets: PresetStore(directory: dir.appendingPathComponent("Presets")))
    }

    func testLaunchRestoresSavedInstrument() async throws {
        var s = AppSettings.default; s.instrument = splice; try store.save(s)
        let m = makeModel()
        await m.launch(skipPluginInSafeMode: false)
        XCTAssertEqual(m.status, .playing(instrumentName: "Splice INSTRUMENT"))
        XCTAssertEqual(engine.loaded, [splice])
        XCTAssertEqual(engine.started, 1)
    }

    func testLaunchStartsAmbienceAfterSound() async {
        let m = makeModel()
        await m.launch(skipPluginInSafeMode: false)
        XCTAssertEqual(engine.ambienceStarts, 1)
        XCTAssertTrue(engine.startedBeforeAmbience)
    }

    // MARK: - Sound & MIDI settings

    func testChannelFilterLetsOnlyTheChosenChannelThrough() {
        let m = makeModel()
        m.setMIDIChannel(2)
        m.handleMIDI(bytes: [0x90, 60, 100], time: 0)
        XCTAssertTrue(engine.sent.isEmpty, "channel 1 is filtered out")
        m.handleMIDI(bytes: [0x91, 60, 100], time: 0)
        XCTAssertEqual(engine.sent.count, 1)
        m.setMIDIChannel(nil)
        m.handleMIDI(bytes: [0x90, 62, 100], time: 0)
        XCTAssertEqual(engine.sent.count, 2, "all channels again")
    }

    func testMIDIChoicesAreRememberedAndPassedOn() {
        let m = makeModel()
        let midi = FakeMIDI()
        m.midi = midi
        m.setMIDIChannel(4)
        m.setMIDISource("Keystation 88", enabled: false)
        XCTAssertEqual(midi.disabled, ["Keystation 88"])
        m.autosave()
        let again = makeModel()
        let midi2 = FakeMIDI()
        again.midi = midi2
        XCTAssertEqual(again.midiChannel, 4)
        XCTAssertEqual(again.disabledMIDISources, ["Keystation 88"])
        XCTAssertEqual(midi2.disabled, ["Keystation 88"], "the saved choice reaches the MIDI input at launch")
        m.setMIDISource("Keystation 88", enabled: true)
        XCTAssertEqual(midi.disabled, [])
        m.rescanMIDI()
        XCTAssertEqual(midi.rescans, 1)
    }

    func testChoosingAnOutputGoesToTheEngineAndIsRemembered() async {
        engine.outputDevices = [OutputDevice(id: 7, uid: "speakers", name: "MacBook Pro Speakers")]
        let m = makeModel()
        await m.launch(skipPluginInSafeMode: false)
        m.selectOutputDevice("speakers")
        XCTAssertEqual(engine.selected.last, "speakers")
        XCTAssertEqual(m.outputDeviceUID, "speakers")
        XCTAssertNil(m.audioNote)
        m.autosave()
        engine.selected.removeAll()
        let again = makeModel()
        await again.launch(skipPluginInSafeMode: false)
        XCTAssertEqual(engine.selected, ["speakers"], "the chosen output comes back at launch")
    }

    func testAMissingOutputFallsBackToTheDefault() async throws {
        var s = AppSettings.default; s.outputDeviceUID = "gone"; try store.save(s)
        engine.failingUIDs = ["gone"]
        let m = makeModel()
        await m.launch(skipPluginInSafeMode: false)
        XCTAssertEqual(engine.selected, ["gone", nil])
        XCTAssertNil(m.outputDeviceUID)
        XCTAssertTrue(m.audioNote?.contains("default") ?? false, m.audioNote ?? "no note")
    }

    func testHealthChecksReachTheEngineAndShowWhatHappened() {
        let m = makeModel()
        m.checkAudioHealth()
        XCTAssertEqual(engine.healthChecks, 1)
        XCTAssertNil(m.audioNote)
        engine.healthNote = "The sound stopped and was restarted."
        m.checkAudioHealth()
        XCTAssertEqual(m.audioNote, "The sound stopped and was restarted.")
    }

    func testChoosingTheSameOutputAgainLeavesTheSoundAlone() async {
        engine.outputDevices = [OutputDevice(id: 7, uid: "speakers", name: "MacBook Pro Speakers")]
        let m = makeModel()
        await m.launch(skipPluginInSafeMode: false)
        m.selectOutputDevice("speakers")
        m.selectOutputDevice("speakers")
        XCTAssertEqual(engine.selected, ["speakers"], "re-choosing the same output would cut the sound for nothing")
        m.selectOutputDevice(nil)
        m.selectOutputDevice(nil)
        XCTAssertEqual(engine.selected, ["speakers", nil])
    }

    func testRescanReleasesHeldNotes() {
        let m = makeModel()
        m.midi = FakeMIDI()
        let before = engine.panicCount
        m.rescanMIDI()
        XCTAssertGreaterThan(engine.panicCount, before, "a key held while its keyboard reconnects would hang")
    }

    func testRestartAudio() {
        let m = makeModel()
        m.restartAudio()
        XCTAssertEqual(engine.restarts, 1)
    }

    func testTestNotePlaysMiddleC() async throws {
        let m = makeModel()
        m.playTestNote()
        XCTAssertEqual(engine.sent.first, [0x90, 60, AppModel.screenVelocity])
        try await Task.sleep(nanoseconds: 900_000_000)
        XCTAssertTrue(engine.sent.contains([0x80, 60, 0]), "and lets it go")
    }

    // MARK: - Worlds drive the ambience

    func testIndoorsAndWetnessCountAsChanges() {
        let base = AmbienceScene(levels: [.fire: 0.7])
        XCTAssertTrue(AppModel.ambienceChanged(base, AmbienceScene(levels: [.fire: 0.7], indoors: 0.2)))
        XCTAssertTrue(AppModel.ambienceChanged(base, AmbienceScene(levels: [.fire: 0.7], wetness: 0.2)))
        XCTAssertTrue(AppModel.ambienceChanged(base, AmbienceScene(levels: [.fire: 0.7], snowOnGlass: 0.2)))
        XCTAssertFalse(AppModel.ambienceChanged(base, AmbienceScene(levels: [.fire: 0.7], indoors: 0.005)))
    }

    /// The key the player is in counts as a change (the temple bell retunes at its next strike), and the canvas puts
    /// the director's key on every frame's scene.
    func testKeyCountsAsAChange() {
        let base = AmbienceScene(levels: [.templeBell: 0.5])
        let inD = AmbienceScene(levels: [.templeBell: 0.5], key: AmbienceKey(root: 2, major: true))
        var inDMinor = inD
        inDMinor.key?.major = false
        XCTAssertTrue(AppModel.ambienceChanged(base, inD), "a key is sensed")
        XCTAssertTrue(AppModel.ambienceChanged(inD, inDMinor), "the mode changes")
        XCTAssertTrue(AppModel.ambienceChanged(inD, base), "the key can't be sensed any more")
        XCTAssertFalse(AppModel.ambienceChanged(inD, inD))
        let m = makeModel()
        m.updateAmbience(base, at: 0)
        m.updateAmbience(inD, at: 1)
        m.updateAmbience(inD, at: 2)
        XCTAssertEqual(engine.scenes.count, 2, "the new key goes through, once")
        XCTAssertEqual(engine.scenes.last?.key, AmbienceKey(root: 2, major: true))
        let lake = SceneDirector(themeID: MoonlitLakeModel.id, state: ThemeState(), reaction: ReactionPresets.expressivePianist)
        let key = AmbienceKey(root: 7, major: false)
        let scene = ThemeCanvas.ambience(for: lake.step(dt: 1.0 / 30, t: 0, quality: .lite), key: key)
        XCTAssertEqual(scene.key, key, "the frame's scene carries the key")
        XCTAssertGreaterThan(scene.level(.water), 0.5, "and the world's own soundscape")
        let steinway = SceneDirector(themeID: MidnightSteinwayModel.id, state: ThemeState(), reaction: ReactionPresets.expressivePianist)
        XCTAssertEqual(ThemeCanvas.ambience(for: steinway.step(dt: 1.0 / 30, t: 0, quality: .lite), key: key).key, key, "every theme carries it")
        XCTAssertNil(ThemeCanvas.ambience(for: steinway.step(dt: 1.0 / 30, t: 0.1, quality: .lite), key: nil).key)
    }

    func testLeavingTheCabinUnmufflesTheBeach() {
        let m = makeModel()
        m.updateAmbience(AmbienceScene(levels: [.fire: 0.7, .wind: 0.5], indoors: 1, snowOnGlass: 1), at: 0)
        m.updateAmbience(AmbienceScene(levels: [.surf: 0.8, .palms: 0.4]), at: 1)
        let sent = engine.scenes.last
        XCTAssertEqual(sent?.level(.surf), 0.8)
        XCTAssertEqual(sent?.indoors, 0)
        XCTAssertEqual(sent?.snowOnGlass, 0)
    }

    func testAmbienceForwardingIsThrottled() {
        let m = makeModel()
        let lake = AmbienceScene(levels: [.water: 0.8, .crickets: 0.6], activity: 0.2)
        for i in 0..<60 { m.updateAmbience(lake, at: Double(i) / 60) }
        XCTAssertEqual(engine.scenes.count, 1, "an unchanging scene is sent once")
        engine.scenes.removeAll()
        for i in 0..<60 {
            var s = lake
            s.levels[.water] = 0.5 + Double(i) * 0.005
            m.updateAmbience(s, at: 1 + Double(i) / 60)
        }
        XCTAssertLessThanOrEqual(engine.scenes.count, 10, "at most 10 a second")
        XCTAssertGreaterThanOrEqual(engine.scenes.count, 5, "but changes do get through")
        // Tiny wobbles don't count; thunder always counts and is never lost to the throttle.
        let sent = engine.scenes.last ?? lake
        engine.scenes.removeAll()
        var wobble = sent; wobble.levels[.water] = (sent.levels[.water] ?? 0) + 0.005
        m.updateAmbience(wobble, at: 3)
        XCTAssertTrue(engine.scenes.isEmpty, "a 0.005 wobble is not a change")
        var clap = wobble; clap.thunder = 0.4
        m.updateAmbience(clap, at: 3.01)
        m.updateAmbience(wobble, at: 3.05)
        var near = wobble; near.thunder = 0.7
        m.updateAmbience(near, at: 3.06)   // too soon: held back, not dropped
        m.updateAmbience(wobble, at: 3.2)
        XCTAssertEqual(engine.scenes.compactMap(\.thunder), [0.4, 0.7])
    }

    /// A wave held back by the throttle still goes (once); a change of speed always counts.
    func testSpeedAndWaveSurviveTheThrottle() {
        let m = makeModel()
        let road = AmbienceScene(levels: [.road: 0.8, .surf: 0.5], speed: 0.8, surfDistance: 0.9)
        m.updateAmbience(road, at: 3)
        engine.scenes.removeAll()
        var breaking = road; breaking.wave = 0.6
        m.updateAmbience(breaking, at: 3.01)   // too soon: held back, not dropped
        m.updateAmbience(road, at: 3.05)
        m.updateAmbience(road, at: 3.2)
        XCTAssertEqual(engine.scenes.compactMap(\.wave), [0.6])
        var slow = road; slow.speed = 0
        m.updateAmbience(slow, at: 3.4)
        XCTAssertEqual(engine.scenes.last?.speed, 0)
    }

    func testSpeedFallsWhenTheWorldChanges() {
        let m = makeModel()
        m.updateAmbience(AmbienceScene(levels: [.road: 0.8], speed: 0.8), at: 1)
        m.updateAmbience(AmbienceScene(levels: [.water: 0.8]), at: 2)
        XCTAssertEqual(engine.scenes.last?.speed, 0)
        XCTAssertNil(engine.scenes.last?.wave)
    }

    func testAPendingWaveStaysOnTheBeach() {
        let m = makeModel()
        let beach = AmbienceScene(levels: [.surf: 0.9, .palms: 0.5], surfDistance: 0.15)
        m.updateAmbience(beach, at: 3)
        engine.scenes.removeAll()
        var breaking = beach; breaking.wave = 0.7
        m.updateAmbience(breaking, at: 3.01)                                   // held back by the throttle
        let lounge = AmbienceScene(levels: [.shipHum: 0.6, .airFlow: 0.4])
        m.updateAmbience(lounge, at: 3.05)                                     // the world changes before it's sent
        m.updateAmbience(lounge, at: 3.2)
        m.updateAmbience(lounge, at: 3.4)
        XCTAssertFalse(engine.scenes.isEmpty)
        XCTAssertTrue(engine.scenes.allSatisfy { $0.wave == nil }, "the beach's wave doesn't crash in the lounge")
    }

    /// A burst of bubbles held back by the throttle still goes, once (two inside one tenth of a second go as the
    /// bigger), and a burst due as the world changes stays behind.
    func testBubbleBurstsSurviveTheThrottle() {
        let m = makeModel()
        let sub = AmbienceScene(levels: [.shipHum: 0.35, .sonar: 0.5, .bubbles: 0.15], indoors: 0.85)
        m.updateAmbience(sub, at: 3)
        engine.scenes.removeAll()
        var small = sub; small.bubbleBurst = 0.4
        var big = sub; big.bubbleBurst = 0.9
        m.updateAmbience(small, at: 3.01)   // too soon: held back, not dropped
        m.updateAmbience(big, at: 3.05)
        m.updateAmbience(sub, at: 3.2)
        m.updateAmbience(sub, at: 3.4)
        XCTAssertEqual(engine.scenes.compactMap(\.bubbleBurst), [0.9])
        XCTAssertTrue(AppModel.ambienceChanged(sub, AmbienceScene(levels: [.shipHum: 0.35, .sonar: 0.5, .bubbles: 0.15, .hullCreak: 0.4],
                                                                  indoors: 0.85)), "a new source counts")
        let n = makeModel()
        n.updateAmbience(sub, at: 3)
        engine.scenes.removeAll()
        n.updateAmbience(big, at: 3.01)                                         // held back by the throttle
        let lake = AmbienceScene(levels: [.water: 0.8, .crickets: 0.6])
        n.updateAmbience(lake, at: 3.05)                                        // the world changes before it's sent
        n.updateAmbience(lake, at: 3.2)
        n.updateAmbience(lake, at: 3.4)
        XCTAssertFalse(engine.scenes.isEmpty)
        XCTAssertTrue(engine.scenes.allSatisfy { $0.bubbleBurst == nil }, "the submarine's bubbles don't rise by the lake")
    }

    func testAmbienceSettingsPersist() async {
        let m = makeModel()
        m.setAmbienceVolume(0.4)
        m.setAmbienceCloseness(0.8)
        m.setAmbienceEnabled(false)
        XCTAssertEqual(engine.ambienceVolume, 0.4, accuracy: 1e-6)
        XCTAssertFalse(engine.ambienceEnabled)
        m.autosave()   // as the periodic timer or quitting would
        let loaded = store.load().ambience
        XCTAssertEqual(loaded.volume, 0.4, accuracy: 1e-9)
        XCTAssertEqual(loaded.closeness, 0.8, accuracy: 1e-9)
        XCTAssertFalse(loaded.enabled)
        // A fresh launch hands them to the engine.
        engine = FakeEngine()
        let again = makeModel()
        await again.launch(skipPluginInSafeMode: false)
        XCTAssertEqual(engine.ambienceVolume, 0.4, accuracy: 1e-6)
        XCTAssertFalse(engine.ambienceEnabled)
        // Closeness leans the world's own closeness toward you.
        again.updateAmbience(AmbienceScene(levels: [.water: 0.8], closeness: 0.5), at: 0)
        XCTAssertEqual(engine.scenes.last?.closeness ?? 0, 0.8, accuracy: 1e-9)
    }

    func testNonWorldThemesSilenceAmbience() throws {
        let m = makeModel()
        let lakeDirector = SceneDirector(themeID: MoonlitLakeModel.id, state: ThemeState(), reaction: ReactionPresets.expressivePianist)
        let lake = ThemeCanvas.ambience(for: lakeDirector.step(dt: 1.0 / 30, t: 0, quality: .lite))
        XCTAssertGreaterThan(lake.level(.water), 0.5)
        m.updateAmbience(lake, at: 0)
        let garden = SceneDirector(themeID: ButterflyGardenModel.id, state: ThemeState(), reaction: ReactionPresets.expressivePianist)
        let quiet = ThemeCanvas.ambience(for: garden.step(dt: 1.0 / 30, t: 0, quality: .lite))
        XCTAssertEqual(quiet, .silent)
        m.updateAmbience(quiet, at: 0.5)
        XCTAssertEqual(engine.scenes.count, 2)
        XCTAssertTrue(engine.scenes.last?.levels.isEmpty ?? false, "switching to Butterfly Garden sends silence")
        let steinway = SceneDirector(themeID: MidnightSteinwayModel.id, state: ThemeState(), reaction: ReactionPresets.expressivePianist)
        XCTAssertEqual(ThemeCanvas.ambience(for: steinway.step(dt: 1.0 / 30, t: 0, quality: .lite)), .silent)
    }

    // MARK: - Sets

    private func visual(_ m: AppModel) -> String {
        ThemeRegistry.parameterSet(for: m.themeID, state: m.themeState(for: m.themeID)).choice("visual")
    }

    func testApplySetLoadsEverything() async {
        let m = makeModel()
        await m.launch(skipPluginInSafeMode: false)
        engine.ambienceEnabled = false
        await m.applySet("moonlit-lake")
        XCTAssertEqual(engine.loaded.last.flatMap { BuiltInCatalog.engine(for: $0) }, .feltGlass)
        XCTAssertEqual(engine.applied.last?.id, "felt-glass")
        XCTAssertEqual(engine.moods.last, .serene)
        XCTAssertEqual(m.mood, .serene)
        XCTAssertTrue(engine.ambienceEnabled)
        XCTAssertEqual(m.themeID, MoonlitLakeModel.id)
        XCTAssertEqual(visual(m), "Lake Ripples")
        XCTAssertEqual(m.activeSetID, "moonlit-lake")
        XCTAssertFalse(m.isSetModified)
        XCTAssertEqual(store.load().activeSetID, "moonlit-lake")
        // A second set swaps the engine too.
        await m.applySet("spaceship-lounge")
        XCTAssertEqual(engine.loaded.last.flatMap { BuiltInCatalog.engine(for: $0) }, .orbitPad)
        XCTAssertEqual(engine.applied.last?.id, "orbit-pad")
        XCTAssertEqual(engine.moods.last, .dreamy)
        XCTAssertEqual(m.themeID, SpaceshipLoungeModel.id)
        XCTAssertEqual(visual(m), "Galaxy Warp")
        // The mood comes back with the set on the next launch.
        engine = FakeEngine()
        let again = makeModel()
        XCTAssertEqual(again.activeSetID, "spaceship-lounge")
        XCTAssertEqual(again.mood, .dreamy)
        await again.launch(skipPluginInSafeMode: false)
        XCTAssertEqual(engine.moods.last, .dreamy)
    }

    func testApplyingGoldenHourBeachLoadsHoneyTape() async {
        let m = makeModel()
        await m.launch(skipPluginInSafeMode: false)
        await m.applySet("golden-hour-beach")
        XCTAssertEqual(engine.loaded.last.flatMap { BuiltInCatalog.engine(for: $0) }, .honeyTape)
        XCTAssertEqual(engine.applied.last?.id, "honey-tape")
        XCTAssertEqual(engine.moods.last, .warmHaze)
        XCTAssertEqual(m.mood, .warmHaze)
        XCTAssertEqual(m.themeID, GoldenHourBeachModel.id)
        XCTAssertEqual(visual(m), "Tide Lines")
        XCTAssertEqual(m.activeSetID, "golden-hour-beach")
        XCTAssertFalse(m.isSetModified)
    }

    func testApplyingCoastRoadLoadsHazeBells() async {
        let m = makeModel()
        await m.launch(skipPluginInSafeMode: false)
        await m.applySet("coast-road")
        XCTAssertEqual(engine.loaded.last.flatMap { BuiltInCatalog.engine(for: $0) }, .hazeBells)
        XCTAssertEqual(engine.applied.last?.id, "haze-bells")
        XCTAssertEqual(engine.moods.last, .restless)
        XCTAssertEqual(m.mood, .restless)
        XCTAssertEqual(m.themeID, CoastRoadModel.id)
        XCTAssertEqual(visual(m), "Coast Lights")
        XCTAssertEqual(m.activeSetID, "coast-road")
        XCTAssertFalse(m.isSetModified)
    }

    func testApplyingSnowboundCabinLoadsCabinFelt() async {
        let m = makeModel()
        await m.launch(skipPluginInSafeMode: false)
        await m.applySet("snowbound-cabin")
        XCTAssertEqual(engine.loaded.last.flatMap { BuiltInCatalog.engine(for: $0) }, .cabinFelt)
        XCTAssertEqual(engine.applied.last?.id, "cabin-felt")
        XCTAssertEqual(engine.moods.last, .hushedWarm)
        XCTAssertEqual(m.mood, .hushedWarm)
        XCTAssertEqual(m.themeID, SnowboundCabinModel.id)
        XCTAssertEqual(visual(m), "Frost Grow")
        XCTAssertEqual(m.activeSetID, "snowbound-cabin")
        XCTAssertFalse(m.isSetModified)
        m.saveThemeState(ThemeState(values: ["visual": .choice("Galaxy Warp")]), for: SnowboundCabinModel.id)
        XCTAssertTrue(m.isSetModified)
        await m.restoreSet()
        XCTAssertFalse(m.isSetModified)
        XCTAssertEqual(visual(m), "Frost Grow")
    }

    func testApplyingBedroomDawnLoadsMorningBox() async {
        let m = makeModel()
        await m.launch(skipPluginInSafeMode: false)
        await m.applySet("bedroom-dawn")
        XCTAssertEqual(engine.loaded.last.flatMap { BuiltInCatalog.engine(for: $0) }, .morningBox)
        XCTAssertEqual(engine.applied.last?.id, "morning-box")
        XCTAssertEqual(engine.moods.last, .softWaking)
        XCTAssertEqual(m.mood, .softWaking)
        XCTAssertEqual(m.themeID, BedroomDawnModel.id)
        XCTAssertEqual(visual(m), "Curtain Light")
        XCTAssertEqual(m.activeSetID, "bedroom-dawn")
        XCTAssertFalse(m.isSetModified)
        m.applyPatch(PatchLibrary.all.first { $0.id == "snooze" }!)   // another Morning Box preset
        XCTAssertTrue(m.isSetModified)
        await m.restoreSet()
        XCTAssertEqual(m.builtInPatch?.id, "morning-box")
        XCTAssertFalse(m.isSetModified)
    }

    func testApplyingAuroraFjordLoadsPolarChoir() async {
        let m = makeModel()
        await m.launch(skipPluginInSafeMode: false)
        m.setAmbienceEnabled(false)
        m.setAmbienceVolume(0.6)
        await m.applySet("aurora-fjord")
        XCTAssertEqual(engine.loaded.last.flatMap { BuiltInCatalog.engine(for: $0) }, .polarChoir)
        XCTAssertEqual(engine.applied.last?.id, "polar-choir")
        XCTAssertEqual(m.builtInPatch?.id, "polar-choir")
        XCTAssertEqual(engine.moods.last, .electricAwe)
        XCTAssertEqual(m.mood, .electricAwe)
        XCTAssertEqual(m.themeID, AuroraFjordModel.id)
        XCTAssertEqual(visual(m), "Curtain Lights")
        XCTAssertTrue(engine.ambienceEnabled)
        XCTAssertEqual(engine.ambienceVolume, Float(AmbienceSettings().volume), accuracy: 1e-6)
        XCTAssertEqual(m.activeSetID, "aurora-fjord")
        XCTAssertFalse(m.isSetModified)
        m.saveThemeState(ThemeState(values: ["visual": .choice("Galaxy Warp")]), for: AuroraFjordModel.id)
        XCTAssertTrue(m.isSetModified)
        await m.restoreSet()
        XCTAssertFalse(m.isSetModified)
        XCTAssertEqual(visual(m), "Curtain Lights")
        m.applyPatch(PatchLibrary.all.first { $0.id == "far-voices" }!)   // another Polar Choir preset
        XCTAssertTrue(m.isSetModified)
        await m.restoreSet()
        XCTAssertEqual(m.builtInPatch?.id, "polar-choir")
        XCTAssertFalse(m.isSetModified)
    }

    func testApplyingBioluminescentBayLoadsPlanktonKeys() async {
        let m = makeModel()
        await m.launch(skipPluginInSafeMode: false)
        m.setAmbienceEnabled(false)
        m.setAmbienceVolume(0.6)
        await m.applySet("bioluminescent-bay")
        XCTAssertEqual(engine.loaded.last.flatMap { BuiltInCatalog.engine(for: $0) }, .planktonKeys)
        XCTAssertEqual(engine.applied.last?.id, "plankton-keys")
        XCTAssertEqual(m.builtInPatch?.id, "plankton-keys")
        XCTAssertEqual(engine.moods.last, .secretGlow)
        XCTAssertEqual(m.mood, .secretGlow)
        XCTAssertEqual(m.themeID, BioluminescentBayModel.id)
        XCTAssertEqual(visual(m), "Glow Wake")
        XCTAssertTrue(engine.ambienceEnabled)
        XCTAssertEqual(engine.ambienceVolume, Float(AmbienceSettings().volume), accuracy: 1e-6)
        XCTAssertEqual(m.activeSetID, "bioluminescent-bay")
        XCTAssertFalse(m.isSetModified)
        m.saveThemeState(ThemeState(values: ["visual": .choice("Galaxy Warp")]), for: BioluminescentBayModel.id)
        XCTAssertTrue(m.isSetModified)
        await m.restoreSet()
        XCTAssertFalse(m.isSetModified)
        XCTAssertEqual(visual(m), "Glow Wake")
        m.applyPatch(PatchLibrary.all.first { $0.id == "glow-wake" }!)   // another Plankton Keys preset
        XCTAssertTrue(m.isSetModified)
        await m.restoreSet()
        XCTAssertEqual(m.builtInPatch?.id, "plankton-keys")
        XCTAssertFalse(m.isSetModified)
        // Switching between the two night sets swaps the engine back.
        await m.applySet("aurora-fjord")
        XCTAssertEqual(engine.loaded.last.flatMap { BuiltInCatalog.engine(for: $0) }, .polarChoir)
        XCTAssertEqual(m.themeID, AuroraFjordModel.id)
    }

    func testApplyingTeaHouseLoadsTheKoto() async {
        let m = makeModel()
        await m.launch(skipPluginInSafeMode: false)
        m.setAmbienceEnabled(false)
        m.setAmbienceVolume(0.6)
        await m.applySet("tea-house-snow")
        XCTAssertEqual(engine.loaded.last.flatMap { BuiltInCatalog.engine(for: $0) }, .teaHouseKoto)
        XCTAssertEqual(engine.applied.last?.id, "tea-house-koto")
        XCTAssertEqual(m.builtInPatch?.id, "tea-house-koto")
        XCTAssertEqual(engine.moods.last, .delicate)
        XCTAssertEqual(m.mood, .delicate)
        XCTAssertEqual(m.themeID, TeaHouseSnowModel.id)
        XCTAssertEqual(visual(m), "Steam Lines")
        XCTAssertTrue(engine.ambienceEnabled)
        XCTAssertEqual(engine.ambienceVolume, Float(AmbienceSettings().volume), accuracy: 1e-6)
        XCTAssertEqual(m.activeSetID, "tea-house-snow")
        XCTAssertFalse(m.isSetModified)
        // The tea house's other visual is Frost Grow on the paper (it has no Galaxy Warp).
        m.saveThemeState(ThemeState(values: ["visual": .choice("Frost Grow")]), for: TeaHouseSnowModel.id)
        XCTAssertEqual(visual(m), "Frost Grow")
        XCTAssertTrue(m.isSetModified)
        await m.restoreSet()
        XCTAssertFalse(m.isSetModified)
        XCTAssertEqual(visual(m), "Steam Lines")
        m.applyPatch(PatchLibrary.all.first { $0.id == "winter-strings" }!)   // another Tea House Koto preset
        XCTAssertTrue(m.isSetModified)
        await m.restoreSet()
        XCTAssertEqual(m.builtInPatch?.id, "tea-house-koto")
        XCTAssertFalse(m.isSetModified)
    }

    func testApplyingTheGardenLoadsTheShakuhachi() async {
        let m = makeModel()
        await m.launch(skipPluginInSafeMode: false)
        m.setAmbienceEnabled(false)
        m.setAmbienceVolume(0.6)
        await m.applySet("zen-rock-garden")
        XCTAssertEqual(engine.loaded.last.flatMap { BuiltInCatalog.engine(for: $0) }, .zenShakuhachi)
        XCTAssertEqual(engine.applied.last?.id, "zen-shakuhachi")
        XCTAssertEqual(m.builtInPatch?.id, "zen-shakuhachi")
        XCTAssertEqual(engine.moods.last, .orderedCalm)
        XCTAssertEqual(m.mood, .orderedCalm)
        XCTAssertEqual(m.themeID, ZenRockGardenModel.id)
        XCTAssertEqual(visual(m), "Rake Lines")
        XCTAssertTrue(engine.ambienceEnabled)
        XCTAssertEqual(engine.ambienceVolume, Float(AmbienceSettings().volume), accuracy: 1e-6)
        XCTAssertEqual(m.activeSetID, "zen-rock-garden")
        XCTAssertFalse(m.isSetModified)
        m.saveThemeState(ThemeState(values: ["visual": .choice("Galaxy Warp")]), for: ZenRockGardenModel.id)
        XCTAssertTrue(m.isSetModified)
        await m.restoreSet()
        XCTAssertFalse(m.isSetModified)
        XCTAssertEqual(visual(m), "Rake Lines")
        m.applyPatch(PatchLibrary.all.first { $0.id == "mountain-breath" }!)   // another Zen Shakuhachi preset
        XCTAssertTrue(m.isSetModified)
        await m.restoreSet()
        XCTAssertEqual(m.builtInPatch?.id, "zen-shakuhachi")
        XCTAssertFalse(m.isSetModified)
        // Switching between the two still places swaps the engine back.
        await m.applySet("tea-house-snow")
        XCTAssertEqual(engine.loaded.last.flatMap { BuiltInCatalog.engine(for: $0) }, .teaHouseKoto)
        XCTAssertEqual(m.themeID, TeaHouseSnowModel.id)
        XCTAssertEqual(m.mood, .delicate)
    }

    /// Review focus 4: settings saved by the eight-set build (Sets 7 & 8, with the bay applied and a sky from before rime
    /// frost and iridescent cloud) open on this build's ten-set gallery: the bay is still the active set, unmodified, with
    /// its mood; the sky's two new dials take their defaults; and the two still places apply from there and come back on
    /// the next launch.
    func testAnEightSetSaveOpensOnTheTenSetGallery() async throws {
        let older = makeModel()
        await older.launch(skipPluginInSafeMode: false)
        await older.applySet("bioluminescent-bay")
        // The file as that build wrote it: its sky had no iridescence or rime speed yet, and it knew no still place.
        let url = dir.appendingPathComponent("settings.json")
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        var json = try XCTUnwrap(saved as? [String: Any])
        var sky = try XCTUnwrap(json["sky"] as? [String: Any])
        XCTAssertNotNil(sky["iridescence"]); XCTAssertNotNil(sky["rimeSpeed"])
        sky.removeValue(forKey: "iridescence"); sky.removeValue(forKey: "rimeSpeed")
        json["sky"] = sky
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        let written = try String(contentsOf: url, encoding: .utf8)
        for key in ["iridescence", "rimeSpeed", "tea-house-snow", "zen-rock-garden"] { XCTAssertFalse(written.contains(key), key) }
        XCTAssertTrue(written.contains("bioluminescent-bay"))

        engine = FakeEngine()
        let m = makeModel()
        XCTAssertEqual(m.activeSetID, "bioluminescent-bay")
        XCTAssertEqual(m.mood, .secretGlow)
        XCTAssertEqual([m.skySettings.iridescence, m.skySettings.rimeSpeed], [1, 1])
        await m.launch(skipPluginInSafeMode: false)
        XCTAssertEqual(engine.loaded.last.flatMap { BuiltInCatalog.engine(for: $0) }, .planktonKeys)
        XCTAssertEqual(m.builtInPatch?.id, "plankton-keys")
        XCTAssertEqual(engine.moods.last, .secretGlow)
        XCTAssertEqual(m.themeID, BioluminescentBayModel.id)
        XCTAssertEqual(visual(m), "Glow Wake")
        XCTAssertFalse(m.isSetModified, "the bay comes back as it was set")
        // The gallery: the eight it knew, in their places, then the two still places.
        XCTAssertEqual(SetLibrary.all.count, 10)
        XCTAssertEqual(SetLibrary.all.firstIndex { $0.id == "bioluminescent-bay" }, 7)
        XCTAssertEqual(SetLibrary.all.suffix(2).map(\.id), ["tea-house-snow", "zen-rock-garden"])
        await m.applySet("tea-house-snow")
        XCTAssertEqual(engine.loaded.last.flatMap { BuiltInCatalog.engine(for: $0) }, .teaHouseKoto)
        XCTAssertEqual(m.activeSetID, "tea-house-snow")
        XCTAssertFalse(m.isSetModified)
        await m.applySet("zen-rock-garden")
        XCTAssertEqual(engine.loaded.last.flatMap { BuiltInCatalog.engine(for: $0) }, .zenShakuhachi)
        XCTAssertFalse(m.isSetModified)
        XCTAssertEqual(store.load().activeSetID, "zen-rock-garden")
        XCTAssertEqual(store.load().sky, m.skySettings)
        // And the garden comes back on the next launch, with its mood.
        engine = FakeEngine()
        let again = makeModel()
        XCTAssertEqual(again.activeSetID, "zen-rock-garden")
        XCTAssertEqual(again.mood, .orderedCalm)
    }

    func testChangingAPartMarksModifiedAndRestoreReverts() async {
        let m = makeModel()
        await m.launch(skipPluginInSafeMode: false)
        await m.applySet("moonlit-lake")
        XCTAssertFalse(m.isSetModified)
        m.saveThemeState(ThemeState(values: ["visual": .choice("Galaxy Warp")]), for: MoonlitLakeModel.id)
        XCTAssertTrue(m.isSetModified)
        await m.restoreSet()
        XCTAssertFalse(m.isSetModified)
        XCTAssertEqual(visual(m), "Lake Ripples")
        // Other parts count too: the preset, the world, the ambience.
        m.applyPatch(PatchLibrary.all.first { $0.id == "lullaby" }!)
        XCTAssertTrue(m.isSetModified)
        await m.restoreSet()
        XCTAssertEqual(m.builtInPatch?.id, "felt-glass")
        m.setTheme(ButterflyGardenModel.id)
        XCTAssertTrue(m.isSetModified)
        await m.restoreSet()
        XCTAssertEqual(m.themeID, MoonlitLakeModel.id)
        m.setAmbienceEnabled(false)
        XCTAssertTrue(m.isSetModified)
        await m.restoreSet()
        XCTAssertFalse(m.isSetModified)
        XCTAssertTrue(engine.ambienceEnabled)
    }

    // MARK: - Final review fixes

    func testAmbienceAndSkyControlsPublishChanges() {
        let m = makeModel()
        var changes = 0
        let sub = m.objectWillChange.sink { _ in changes += 1 }
        defer { sub.cancel() }
        m.setAmbienceEnabled(false)
        XCTAssertEqual(changes, 1, "toggling ambience re-renders the controls")
        m.setAmbienceVolume(0.3)
        XCTAssertEqual(changes, 2)
        m.setAmbienceCloseness(0.7)
        XCTAssertEqual(changes, 3)
        var s = SkySettings(); s.dayMinutes = 20
        m.setSky(s)
        XCTAssertEqual(changes, 4)
    }

    func testContinuousControlsDebounceSaves() async throws {
        let m = makeModel()
        let before = m.saveCount
        for i in 0..<60 { m.setAmbienceVolume(Double(i) / 60) }
        var s = SkySettings()
        for i in 0..<60 { s.dayMinutes = Double(2 + i * 58 / 59); m.setSky(s) }   // 2…60, the slider's range
        for i in 0..<60 { m.setAmbienceCloseness(Double(i) / 60) }
        XCTAssertEqual(m.saveCount, before, "dragging a slider never writes on every tick")
        try await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertEqual(m.saveCount, before + 1, "one save once the drag settles")
        XCTAssertEqual(store.load().ambience.volume, 59.0 / 60, accuracy: 1e-9)
        XCTAssertEqual(store.load().sky.dayMinutes, 60)
        // Discrete changes still save at once.
        m.setAmbienceEnabled(false)
        XCTAssertEqual(m.saveCount, before + 2)
    }

    func testApplySetIgnoresTapsWhileLoading() async throws {
        let m = makeModel()
        await m.launch(skipPluginInSafeMode: false)
        engine.loadDelay = 300_000_000
        async let first: () = m.applySet("moonlit-lake")
        try await Task.sleep(nanoseconds: 60_000_000)
        await m.applySet("spaceship-lounge")   // a second tap while the first is loading
        await first
        XCTAssertEqual(m.activeSetID, "moonlit-lake")
        XCTAssertEqual(m.themeID, MoonlitLakeModel.id)
        XCTAssertEqual(engine.loaded.count, 1)
        XCTAssertEqual(engine.loaded.last.flatMap { BuiltInCatalog.engine(for: $0) }, .feltGlass)
        XCTAssertEqual(m.mood, .serene)
        XCTAssertFalse(m.isSetModified)
    }

    func testSkySettingsPersist() {
        let m = makeModel()
        let version = m.visualsVersion
        var s = SkySettings(); s.timeMode = .frozen; s.frozenHour = 5.5; s.cityID = "reykjavik"; s.weatherMode = .pick; s.weather = .snow
        m.setSky(s)
        XCTAssertEqual(m.skySettings, s)
        XCTAssertGreaterThan(m.visualsVersion, version)
        m.autosave()
        XCTAssertEqual(store.load().sky, s)
        XCTAssertEqual(makeModel().skySettings, s)
    }

    func testFirstLaunchAsksForInstrument() async {
        let m = makeModel()
        await m.launch(skipPluginInSafeMode: false)
        XCTAssertEqual(m.status, .needsInstrument(message: nil))
    }

    func testMissingPluginShowsPicker() async throws {
        var s = AppSettings.default; s.instrument = splice; try store.save(s)
        engine.loadError = AudioEngineError.pluginNotFound("Splice INSTRUMENT")
        let m = makeModel()
        await m.launch(skipPluginInSafeMode: false)
        guard case let .needsInstrument(message?) = m.status else { return XCTFail("status \(m.status)") }
        XCTAssertTrue(message.contains("Splice INSTRUMENT"))
        XCTAssertTrue(message.contains("couldn't be found"))
    }

    func testUncleanPreviousExitOffersSafeMode() async throws {
        var s = AppSettings.default; s.instrument = splice; try store.save(s)
        _ = LaunchGuard(directory: dir).beginLaunch()      // previous run never settled
        let m = makeModel()
        XCTAssertTrue(m.offersSafeMode)
        await m.launch(skipPluginInSafeMode: true)
        XCTAssertEqual(m.status, .safeMode)
        XCTAssertTrue(engine.loaded.isEmpty)
    }

    func testCleanPreviousExitDoesNotOfferSafeMode() {
        XCTAssertFalse(makeModel().offersSafeMode)
    }

    func testMIDIReachesEngineBeforeVisuals() {
        let m = makeModel()
        m.handleMIDI(bytes: [0x90, 60, 100], time: 0)
        XCTAssertEqual(engine.sent, [[0x90, 60, 100]])
        XCTAssertEqual(m.drainEvents(), [.noteOn(note: 60, velocity: Float(100) / 127)])
        XCTAssertEqual(m.drainEvents(), [])
    }

    func testSourceRemovedPanicsAndClearsVisuals() {
        let m = makeModel()
        m.handleMIDI(bytes: [0x90, 60, 100], time: 0)
        m.midiSourcesChanged(names: [], removed: true)
        XCTAssertEqual(engine.panicCount, 1)
        XCTAssertEqual(m.drainEvents().last, .allNotesOff)
    }

    func testSourceAddedDoesNotPanic() {
        let m = makeModel()
        m.midiSourcesChanged(names: ["Keystation 49"], removed: false)
        XCTAssertEqual(engine.panicCount, 0)
        XCTAssertEqual(m.midiSourceNames, ["Keystation 49"])
    }

    func testOnScreenKeyboardShownWithoutSources() {
        let m = makeModel()
        m.midiSourcesChanged(names: [], removed: false)
        XCTAssertTrue(m.showsOnScreenKeyboard)
        m.midiSourcesChanged(names: ["Keystation 49"], removed: false)
        XCTAssertFalse(m.showsOnScreenKeyboard)
    }

    func testPlayFromScreenSendsVelocity90() {
        let m = makeModel()
        m.playFromScreen(note: 64, down: true)
        m.playFromScreen(note: 64, down: false)
        XCTAssertEqual(engine.sent, [[0x90, 64, 90], [0x80, 64, 0]])
    }

    func testPanicButtonSilencesAndClears() {
        let m = makeModel()
        m.handleMIDI(bytes: [0x90, 60, 100], time: 0)
        m.panic()
        XCTAssertEqual(engine.panicCount, 1)
        XCTAssertEqual(m.drainEvents().last, .allNotesOff)
    }

    func testChoosingPluginLoadsSavesAndPlays() async {
        let m = makeModel()
        await m.launch(skipPluginInSafeMode: false)
        let info = PluginInfo(id: "x", name: "Splice INSTRUMENT", manufacturer: "Splice",
                              description: AudioComponentDescription(componentType: splice.componentType,
                                                                     componentSubType: splice.componentSubType,
                                                                     componentManufacturer: splice.componentManufacturer,
                                                                     componentFlags: 0, componentFlagsMask: 0))
        await m.choose(info)
        XCTAssertEqual(m.status, .playing(instrumentName: "Splice INSTRUMENT"))
        XCTAssertEqual(store.load().instrument?.componentSubType, splice.componentSubType)
    }

    func testAutosaveStoresPluginState() async throws {
        var s = AppSettings.default; s.instrument = splice; try store.save(s)
        let m = makeModel()
        await m.launch(skipPluginInSafeMode: false)
        m.autosave()
        XCTAssertEqual(store.load().instrument?.stateData, Data([1, 2, 3]))
    }

    func testVolumeIsAppliedAndSaved() async {
        let m = makeModel()
        await m.launch(skipPluginInSafeMode: false)
        m.setVolume(0.3)
        XCTAssertEqual(engine.masterVolume, 0.3, accuracy: 0.001)
        XCTAssertEqual(store.load().masterVolume, 0.3, accuracy: 0.001)
    }

    private func info(_ name: String, _ sub: UInt32) -> PluginInfo {
        PluginInfo(id: name, name: name, manufacturer: "Test",
                   description: AudioComponentDescription(componentType: kAudioUnitType_MusicDevice,
                                                          componentSubType: sub, componentManufacturer: 0x54455354,
                                                          componentFlags: 0, componentFlagsMask: 0))
    }

    func testConcurrentChoosesLoadOnlyOnce() async {
        let m = makeModel()
        await m.launch(skipPluginInSafeMode: false)
        engine.loadDelay = 50_000_000
        async let a: Void = m.choose(info("One", 1))
        async let b: Void = m.choose(info("Two", 2))
        _ = await (a, b)
        XCTAssertEqual(engine.loaded.count, 1)
        XCTAssertFalse(m.isLoading)
    }

    func testLaunchIsIdempotent() async throws {
        var s = AppSettings.default; s.instrument = splice; try store.save(s)
        let m = makeModel()
        await m.launch(skipPluginInSafeMode: false)
        await m.launch(skipPluginInSafeMode: false)
        XCTAssertEqual(engine.started, 1)
        XCTAssertEqual(engine.loaded.count, 1)
    }

    func testInstrumentChangeClosesPluginWindowFirst() async {
        let m = makeModel()
        await m.launch(skipPluginInSafeMode: false)
        m.willChangeInstrument = { [engine] in engine!.log.append("close-window") }
        await m.choose(info("One", 1))
        XCTAssertEqual(engine.log, ["close-window", "load"])
    }

    func testHeavyTouchLowersVelocityForSoundAndVisuals() {
        let m = makeModel()
        m.setTouchCurve(.heavy)
        m.handleMIDI(bytes: [0x90, 60, 40], time: 0)
        let v = TouchCurve.heavy.apply(40)
        XCTAssertEqual(engine.sent, [[0x90, 60, v]])
        XCTAssertEqual(m.drainEvents(), [.noteOn(note: 60, velocity: Float(v) / 127)])
        XCTAssertEqual(store.load().touchCurve, .heavy)
    }

    func testLaunchAppliesSavedBufferAndTouch() async throws {
        var s = AppSettings.default; s.bufferFrames = 512; s.touchCurve = .light; try store.save(s)
        let m = makeModel()
        await m.launch(skipPluginInSafeMode: false)
        XCTAssertEqual(engine.bufferFrames, 512)
        XCTAssertEqual(m.touchCurve, .light)
    }

    func testSetBufferFramesAppliesAndSaves() {
        let m = makeModel()
        m.setBufferFrames(128)
        XCTAssertEqual(engine.bufferFrames, 128)
        XCTAssertEqual(store.load().bufferFrames, 128)
    }

    func testThemeDefaultsToSteinwayAndPersistsChoice() {
        let m = makeModel()
        XCTAssertEqual(m.themeID, MidnightSteinwayModel.id)
        m.setTheme(ButterflyGardenModel.id)
        XCTAssertEqual(store.load().themeID, ButterflyGardenModel.id)
        XCTAssertEqual(makeModel().themeID, ButterflyGardenModel.id)
    }

    func testUnknownSavedThemeFallsBack() throws {
        var s = AppSettings.default; s.themeID = "from-the-future"; try store.save(s)
        XCTAssertEqual(makeModel().themeID, MidnightSteinwayModel.id)
    }

    func testThemeStateSavedAndVersionBumps() {
        let m = makeModel()
        let before = m.visualsVersion
        m.saveThemeState(ThemeState(values: ["rays": .number(0.9)]), for: ButterflyGardenModel.id)
        XCTAssertGreaterThan(m.visualsVersion, before)
        XCTAssertEqual(m.themeState(for: ButterflyGardenModel.id).values["rays"], .number(0.9))
        m.autosave()
        XCTAssertEqual(store.load().themeStates[ButterflyGardenModel.id]?.values["rays"], .number(0.9))
    }

    func testDefaultReactionIsExpressivePianist() {
        let m = makeModel()
        XCTAssertEqual(m.reactionName, "Expressive Pianist")
        XCTAssertEqual(m.reaction, ReactionPresets.expressivePianist)
        XCTAssertEqual(m.allReactions().prefix(6).map(\.name), ReactionPresets.all.map(\.name))
    }

    func testChoosingReactionPersists() {
        let m = makeModel()
        m.setReaction(ReactionPresets.all[3])
        XCTAssertEqual(makeModel().reactionName, "Music Party")
        XCTAssertEqual(makeModel().reaction, ReactionPresets.musicParty)
    }

    func testEditedMappingIsCustomAndSavable() {
        let m = makeModel()
        var map = m.reaction
        map.links.removeFirst()
        m.setReactionMap(map)
        XCTAssertEqual(m.reactionName, "Custom")
        m.saveReaction(named: "My Style")
        XCTAssertTrue(m.allReactions().contains { $0.name == "My Style" && $0.map == map })
        XCTAssertEqual(m.reactionName, "My Style")
    }

    func testLooksIncludeBuiltInsAndSavedOnes() {
        let m = makeModel()
        m.setTheme(ButterflyGardenModel.id)
        XCTAssertEqual(m.lookPresets().prefix(6).map(\.name), ButterflyGardenModel.builtInLooks.map(\.name))
        m.saveThemeState(ThemeState(values: ["rays": .number(0.95)]), for: ButterflyGardenModel.id)
        m.saveLook(named: "Bright")
        XCTAssertTrue(m.lookPresets().contains { $0.name == "Bright" })
    }

    func testApplyingLookSetsStateAndName() {
        let m = makeModel()
        m.setTheme(ButterflyGardenModel.id)
        let look = ButterflyGardenModel.builtInLooks[3]
        m.applyLook(look)
        XCTAssertEqual(m.themeState(for: ButterflyGardenModel.id).values["time"], .choice("Moonlight"))
        XCTAssertEqual(m.themeState(for: ButterflyGardenModel.id).lookPresetName, look.name)
    }

    func testSurpriseChangesTheLook() {
        let m = makeModel()
        m.setTheme(ButterflyGardenModel.id)
        let before = m.themeState(for: ButterflyGardenModel.id)
        m.surprise()
        XCTAssertNotEqual(m.themeState(for: ButterflyGardenModel.id), before)
    }

    // MARK: - Built-in instruments

    func testChoosingBuiltInPlays() async throws {
        let m = makeModel()
        await m.launch(skipPluginInSafeMode: false)
        let felt = try XCTUnwrap(BuiltInCatalog.instruments.first { $0.name == "Felt Glass" })
        await m.choose(felt)
        XCTAssertEqual(engine.loaded.last, felt.choice())
        XCTAssertEqual(m.status, .playing(instrumentName: "Felt Glass"))
        XCTAssertTrue(m.isBuiltIn)
        XCTAssertEqual(m.builtInPatch, PatchLibrary.defaultPatch(for: .feltGlass))
        XCTAssertEqual(engine.applied, [PatchLibrary.defaultPatch(for: .feltGlass)])
    }

    func testApplyPatchIsNoOpForPlugins() async throws {
        var s = AppSettings.default; s.instrument = splice; try store.save(s)
        let m = makeModel()
        await m.launch(skipPluginInSafeMode: false)
        m.applyPatch(PatchLibrary.defaultPatch(for: .feltGlass))
        XCTAssertFalse(m.isBuiltIn)
        XCTAssertNil(m.builtInPatch)
        XCTAssertTrue(engine.applied.isEmpty)
    }

    func testCreditsArePresent() {
        let c = CreditLibrary.comeBackToEarth, i = CreditLibrary.innerbloom
        XCTAssertFalse(c.line.isEmpty); XCTAssertFalse(i.line.isEmpty)
        XCTAssertEqual(c.year, 2018); XCTAssertEqual(i.year, 2016)
        XCTAssertGreaterThan(c.tempoBPM, 0); XCTAssertGreaterThan(i.tempoBPM, 0)
        XCTAssertEqual(CreditLibrary.credit(id: "innerbloom"), i)
        // Every credit a preset names is in the library, and an instrument's presets share one credit (none at all for an
        // instrument born from a place).
        for p in PatchLibrary.all {
            if let id = p.creditID { XCTAssertNotNil(CreditLibrary.credit(id: id), p.id) }
            XCTAssertEqual(p.creditID, PatchLibrary.defaultPatch(for: p.engine).creditID, p.id)
        }
    }

    /// Tea House Koto is born from its place (Tea House Snow), not a song: its presets carry no credit, so their names
    /// are plain (spec §4.2's values).
    func testTeaHouseKotoPresetsHaveNoCredit() {
        let presets = PatchLibrary.patches(for: .teaHouseKoto)
        XCTAssertEqual(presets.map(\.id), ["tea-house-koto", "winter-strings", "near-the-bridge", "night-tea"])
        XCTAssertEqual(presets.map(\.displayName), ["Tea House Koto", "Winter Strings", "Near the Bridge", "Night Tea"])
        for p in presets {
            XCTAssertNil(p.creditID, p.id)
            XCTAssertNil(p.credit, p.id)
            XCTAssertEqual(p.displayName, p.name, p.id)
        }
        XCTAssertEqual(PatchLibrary.defaultPatch(for: .teaHouseKoto).id, "tea-house-koto")
        XCTAssertEqual(Set(presets.flatMap { $0.values.keys }), ["pick", "silk", "body", "bloom", "yuri", "space", "width"])
        let dials = ["pick", "silk", "body", "bloom", "yuri", "space", "width"]
        let expected: [String: [Double]] = ["tea-house-koto": [0.55, 0.45, 0.50, 0.40, 0.30, 0.35, 0.50],
                                            "winter-strings": [0.35, 0.70, 0.60, 0.55, 0.20, 0.45, 0.55],
                                            "near-the-bridge": [0.15, 0.25, 0.40, 0.25, 0.35, 0.25, 0.45],
                                            "night-tea": [0.45, 0.60, 0.55, 0.60, 0.40, 0.50, 0.50]]
        for p in presets {
            let values = dials.map { p.values[$0] ?? -1 }
            XCTAssertEqual(values, expected[p.id], p.id)
        }
        XCTAssertEqual(BuiltInEngine.teaHouseKoto.displayName, "Tea House Koto")
    }

    /// Zen Shakuhachi is born from its place (Zen Rock Garden), not a song: its presets carry no credit, so their names
    /// are plain (spec §4.4's values).
    func testZenShakuhachiPresetsHaveNoCredit() {
        let presets = PatchLibrary.patches(for: .zenShakuhachi)
        XCTAssertEqual(presets.map(\.id), ["zen-shakuhachi", "mountain-breath", "hollow-bamboo", "still-air"])
        XCTAssertEqual(presets.map(\.displayName), ["Zen Shakuhachi", "Mountain Breath", "Hollow Bamboo", "Still Air"])
        for p in presets {
            XCTAssertNil(p.creditID, p.id)
            XCTAssertNil(p.credit, p.id)
            XCTAssertEqual(p.displayName, p.name, p.id)
        }
        XCTAssertEqual(PatchLibrary.defaultPatch(for: .zenShakuhachi).id, "zen-shakuhachi")
        let dials = ["breath", "air", "bend", "bamboo", "yuri", "echo", "space", "width"]
        XCTAssertEqual(Set(presets.flatMap { $0.values.keys }), Set(dials))
        let expected: [String: [Double]] = ["zen-shakuhachi": [0.45, 0.55, 0.60, 0.50, 0.40, 0.30, 0.40, 0.45],
                                            "mountain-breath": [0.60, 0.70, 0.70, 0.45, 0.50, 0.70, 0.60, 0.55],
                                            "hollow-bamboo": [0.30, 0.35, 0.40, 0.85, 0.30, 0.15, 0.25, 0.40],
                                            "still-air": [0.75, 0.90, 0.50, 0.40, 0.25, 0.40, 0.55, 0.50]]
        for p in presets {
            let values = dials.map { p.values[$0] ?? -1 }
            XCTAssertEqual(values, expected[p.id], p.id)
        }
        XCTAssertEqual(BuiltInEngine.zenShakuhachi.displayName, "Zen Shakuhachi")
    }

    /// Reef Marimba is born from its place (Great Barrier Reef), not a song: its presets carry no credit, so their names
    /// are plain.
    func testReefMarimbaPresetsHaveNoCredit() {
        let presets = PatchLibrary.patches(for: .reefMarimba)
        XCTAssertEqual(presets.map(\.id), ["reef-marimba", "soft-yarn", "lagoon-steel", "night-reef"])
        XCTAssertEqual(presets.map(\.displayName), ["Reef Marimba", "Soft Yarn", "Lagoon Steel", "Night Reef"])
        for p in presets {
            XCTAssertNil(p.creditID, p.id)
            XCTAssertNil(p.credit, p.id)
            XCTAssertEqual(p.displayName, p.name, p.id)
        }
        XCTAssertEqual(PatchLibrary.defaultPatch(for: .reefMarimba).id, "reef-marimba")
        XCTAssertEqual(BuiltInEngine.reefMarimba.displayName, "Reef Marimba")
    }

    /// The instrument's pulse (spec §7.6) follows the patch: Blue Depth's Tempo, with Blink as the gate, while Blink is
    /// up; nil at Blink 0, for every other engine and for a plugin. Switching instrument clears it, and the instrument's
    /// own dials move it as they turn.
    func testInstrumentPulseFollowsThePatch() async throws {
        let m = makeModel()
        await m.launch(skipPluginInSafeMode: false)
        XCTAssertNil(m.instrumentPulse, "no instrument yet")
        let depth = try XCTUnwrap(BuiltInCatalog.instruments.first { $0.name == "Blue Depth" })
        await m.choose(depth)
        XCTAssertEqual(m.instrumentPulse, InstrumentPulse(bpm: 118, gate: 0.60), "its default preset")
        var values = PatchLibrary.defaultPatch(for: .blueDepth).values
        values["tempo"] = 100
        values["blink"] = 0.4
        m.applyPatch(Patch(id: "slow", name: "Slow", engine: .blueDepth, values: values))
        XCTAssertEqual(m.instrumentPulse, InstrumentPulse(bpm: 100, gate: 0.4))
        values["blink"] = 0
        m.applyPatch(Patch(id: "still", name: "Still", engine: .blueDepth, values: values))
        XCTAssertNil(m.instrumentPulse, "Blink 0: no arp, so no pulse")
        m.applyPatch(try XCTUnwrap(PatchLibrary.all.first { $0.id == "pressure-hull" }))
        XCTAssertEqual(m.instrumentPulse, InstrumentPulse(bpm: 118, gate: 0.75))
        let felt = try XCTUnwrap(BuiltInCatalog.instruments.first { $0.name == "Felt Glass" })
        await m.choose(felt)
        XCTAssertNil(m.instrumentPulse, "switching instrument clears it")
        await m.choose(depth)
        XCTAssertEqual(m.instrumentPulse, InstrumentPulse(bpm: 118, gate: 0.60))
        await m.choose(info("One", 1))
        XCTAssertNil(m.instrumentPulse, "a plugin has none")
        // Every other engine has none, whatever its dials say.
        for kind in BuiltInEngine.allCases where kind != .blueDepth {
            XCTAssertNil(InstrumentPulse(engine: kind, values: ["blink": 1, "tempo": 120]), kind.rawValue)
        }
        XCTAssertNil(InstrumentPulse(engine: nil, values: ["blink": 1, "tempo": 120]))
        // The dials move it too: the Tempo turned on the instrument's own panel, then Blink turned all the way down.
        let unit = try BuiltInInstrumentAU(componentDescription: BuiltInCatalog.description(for: .blueDepth), options: [])
        engine.unit = unit
        await m.choose(depth)
        let atStart: Double = m.instrumentPulse?.bpm ?? 0
        XCTAssertEqual(atStart, 118, accuracy: 1e-4)
        let tempo = try XCTUnwrap(unit.parameterTree?.allParameters.first { $0.identifier == "tempo" })
        let blink = try XCTUnwrap(unit.parameterTree?.allParameters.first { $0.identifier == "blink" })
        tempo.setValue(140, originator: nil)
        for _ in 0..<200 where abs((m.instrumentPulse?.bpm ?? 0) - 140) > 1e-3 { try await Task.sleep(nanoseconds: 10_000_000) }
        let turned: Double = m.instrumentPulse?.bpm ?? 0, gate: Double = m.instrumentPulse?.gate ?? 0
        XCTAssertEqual(turned, 140, accuracy: 1e-3, "the Tempo dial moves the pulse")
        XCTAssertEqual(gate, 0.6, accuracy: 1e-6)
        blink.setValue(0, originator: nil)
        for _ in 0..<200 where m.instrumentPulse != nil { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNil(m.instrumentPulse, "and Blink at 0 stops it")
        // The director carries what the canvas hands it, through a world switch (it is the instrument's, not the world's).
        let director = SceneDirector(themeID: MoonlitLakeModel.id, state: ThemeState(), reaction: ReactionPresets.expressivePianist)
        XCTAssertNil(director.instrumentPulse)
        director.instrumentPulse = InstrumentPulse(bpm: 118, gate: 0.6)
        director.switchTheme(to: SpaceshipLoungeModel.id, state: ThemeState())
        XCTAssertEqual(director.instrumentPulse, InstrumentPulse(bpm: 118, gate: 0.6))
    }

    /// Blue Depth's arp and echo run on their own clock, so a change of preset, world or set while it plays sends all
    /// notes off to the instrument (spec §13, review focus 1): the arp stops, the echo empties, the next phrase starts a
    /// fresh grid, and the visuals let go with the sound. Any other instrument rings on through the same changes, as
    /// it always has.
    func testSwitchesStopBlueDepthsArp() async throws {
        let allOff: [UInt8] = [0xB0, 123, 0]
        let m = makeModel()
        await m.launch(skipPluginInSafeMode: false)
        let depth = try XCTUnwrap(BuiltInCatalog.instruments.first { $0.name == "Blue Depth" })
        await m.choose(depth)
        m.handleMIDI(bytes: [0x90, 61, 100], time: 0)   // a note held, blinking
        engine.sent.removeAll()
        _ = m.drainEvents()
        m.applyPatch(try XCTUnwrap(PatchLibrary.all.first { $0.id == "ghost-signal" }))
        XCTAssertEqual(engine.sent, [allOff], "a preset switch stops the arp")
        XCTAssertEqual(m.drainEvents(), [.allNotesOff], "and the visuals let go with it")
        engine.sent.removeAll()
        m.setTheme(MoonlitLakeModel.id)
        XCTAssertEqual(engine.sent, [allOff], "a world switch stops it")
        engine.sent.removeAll()
        m.setTheme(MoonlitLakeModel.id)
        XCTAssertTrue(engine.sent.isEmpty, "the same world again changes nothing")
        // A set switch changes the world (stopping the arp) before its own instrument, Orbit Pad, loads.
        await m.applySet("spaceship-lounge")
        XCTAssertEqual(engine.sent, [allOff], "a set switch stops it, once")
        XCTAssertEqual(engine.loaded.last.flatMap { BuiltInCatalog.engine(for: $0) }, .orbitPad)
        // Any other instrument rings on through the same changes.
        engine.sent.removeAll()
        m.applyPatch(try XCTUnwrap(PatchLibrary.all.first { $0.id == "weightless" }))
        m.setTheme(MoonlitLakeModel.id)
        await m.restoreSet()
        await m.choose(info("One", 1))
        m.setTheme(BioluminescentBayModel.id)
        XCTAssertTrue(engine.sent.isEmpty, "Orbit Pad's and a plugin's tails are left alone")
    }

    func testHoneyTapePresetsCarryTheirCredit() {
        let presets = PatchLibrary.patches(for: .honeyTape)
        XCTAssertEqual(presets.map(\.id), ["honey-tape", "sea-flute", "velvet-strings", "old-reel"])
        for p in presets { XCTAssertTrue(p.displayName.hasSuffix("· after \"Music to Watch Boys To\""), p.displayName) }
        XCTAssertEqual(PatchLibrary.defaultPatch(for: .honeyTape).id, "honey-tape")
        let credit = try? XCTUnwrap(CreditLibrary.credit(id: "music-to-watch-boys-to"))
        XCTAssertEqual(credit?.artist, "Lana Del Rey"); XCTAssertEqual(credit?.album, "Honeymoon")
        XCTAssertEqual(credit?.year, 2015); XCTAssertEqual(credit?.trackNumber, 2)
        XCTAssertEqual(credit?.key, "C♯ minor"); XCTAssertEqual(credit?.tempoBPM, 132)
    }

    func testCabinFeltPresetsCarryTheirCredit() {
        let presets = PatchLibrary.patches(for: .cabinFelt)
        XCTAssertEqual(presets.map(\.id), ["cabin-felt", "fireside", "snow-horn", "late-night"])
        for p in presets { XCTAssertTrue(p.displayName.hasSuffix("· after \"Stay\""), p.displayName) }
        XCTAssertEqual(PatchLibrary.defaultPatch(for: .cabinFelt).id, "cabin-felt")
        XCTAssertEqual(PatchLibrary.defaultPatch(for: .cabinFelt).values["horn"], 0.30)
        XCTAssertEqual(presets.first { $0.id == "fireside" }?.values["horn"], 0, "Fireside is piano only")
        let credit = CreditLibrary.credit(id: "stay")
        XCTAssertEqual(credit?.song, "Stay"); XCTAssertEqual(credit?.artist, "Mac Miller")
        XCTAssertEqual(credit?.album, "The Divine Feminine"); XCTAssertEqual(credit?.year, 2016)
        XCTAssertEqual(credit?.trackNumber, 3); XCTAssertEqual(credit?.key, "F♯ major"); XCTAssertEqual(credit?.tempoBPM, 134)
    }

    func testMorningBoxPresetsCarryTheirCredit() {
        let presets = PatchLibrary.patches(for: .morningBox)
        XCTAssertEqual(presets.map(\.id), ["morning-box", "music-box", "wall-of-light", "snooze"])
        for p in presets { XCTAssertTrue(p.displayName.hasSuffix("· after \"Dunno\""), p.displayName) }
        XCTAssertEqual(PatchLibrary.defaultPatch(for: .morningBox).id, "morning-box")
        XCTAssertEqual(presets.first { $0.id == "music-box" }?.values["box"], 1)
        XCTAssertEqual(presets.first { $0.id == "wall-of-light" }?.values["build"], 0.90)
        let credit = CreditLibrary.credit(id: "dunno")
        XCTAssertEqual(credit?.song, "Dunno"); XCTAssertEqual(credit?.artist, "Mac Miller")
        XCTAssertEqual(credit?.album, "Swimming"); XCTAssertEqual(credit?.year, 2018)
        XCTAssertEqual(credit?.trackNumber, 10); XCTAssertEqual(credit?.key, "C♯ major"); XCTAssertEqual(credit?.tempoBPM, 82)
    }

    func testPolarChoirPresetsCarryTheirCredit() {
        let presets = PatchLibrary.patches(for: .polarChoir)
        XCTAssertEqual(presets.map(\.id), ["polar-choir", "far-voices", "bowed-glass", "hush"])
        for p in presets { XCTAssertTrue(p.displayName.hasSuffix("· after \"Wings\""), p.displayName) }
        XCTAssertEqual(PatchLibrary.defaultPatch(for: .polarChoir).id, "polar-choir")
        XCTAssertEqual(PatchLibrary.defaultPatch(for: .polarChoir).values["vowel"], 0.55)
        XCTAssertEqual(presets.first { $0.id == "bowed-glass" }?.values["glass"], 0.85)
        XCTAssertEqual(Set(presets.flatMap { $0.values.keys }), ["vowel", "breath", "glass", "swell", "shimmer", "space", "width"])
        let credit = CreditLibrary.credit(id: "wings")
        XCTAssertEqual(credit?.song, "Wings"); XCTAssertEqual(credit?.artist, "Mac Miller")
        XCTAssertEqual(credit?.album, "Swimming"); XCTAssertEqual(credit?.year, 2018)
        XCTAssertEqual(credit?.trackNumber, 6); XCTAssertEqual(credit?.key, "A♭ major"); XCTAssertEqual(credit?.tempoBPM, 119)
    }

    func testPlanktonKeysPresetsCarryTheirCredit() {
        let presets = PatchLibrary.patches(for: .planktonKeys)
        XCTAssertEqual(presets.map(\.id), ["plankton-keys", "glow-wake", "tide-tines", "midnight-bay"])
        for p in presets { XCTAssertTrue(p.displayName.hasSuffix("· after \"Happiness Is a Butterfly\""), p.displayName) }
        XCTAssertEqual(PatchLibrary.defaultPatch(for: .planktonKeys).id, "plankton-keys")
        XCTAssertEqual(PatchLibrary.defaultPatch(for: .planktonKeys).values["tine"], 0.55)
        XCTAssertEqual(presets.first { $0.id == "glow-wake" }?.values["sparkle"], 0.85)
        XCTAssertEqual(presets.first { $0.id == "tide-tines" }?.values["bark"], 0.60)
        XCTAssertEqual(Set(presets.flatMap { $0.values.keys }), ["tine", "bark", "sparkle", "tremolo", "phase", "space", "width"])
        let credit = CreditLibrary.credit(id: "happiness-is-a-butterfly")
        XCTAssertEqual(credit?.song, "Happiness Is a Butterfly"); XCTAssertEqual(credit?.artist, "Lana Del Rey")
        XCTAssertEqual(credit?.album, "Norman Fucking Rockwell!"); XCTAssertEqual(credit?.year, 2019)
        XCTAssertEqual(credit?.trackNumber, 13); XCTAssertEqual(credit?.key, "D major"); XCTAssertEqual(credit?.tempoBPM, 68)
    }

    func testHazeBellsPresetsCarryTheirCredit() {
        let presets = PatchLibrary.patches(for: .hazeBells)
        XCTAssertEqual(presets.map(\.id), ["haze-bells", "church-keys", "night-drive", "lo-fi"])
        for p in presets { XCTAssertTrue(p.displayName.hasSuffix("· after \"High by the Beach\""), p.displayName) }
        XCTAssertEqual(PatchLibrary.defaultPatch(for: .hazeBells).id, "haze-bells")
        let credit = CreditLibrary.credit(id: "high-by-the-beach")
        XCTAssertEqual(credit?.artist, "Lana Del Rey"); XCTAssertEqual(credit?.album, "Honeymoon")
        XCTAssertEqual(credit?.year, 2015); XCTAssertEqual(credit?.trackNumber, 5)
        XCTAssertEqual(credit?.key, "B minor"); XCTAssertEqual(credit?.tempoBPM, 132)
    }

    func testPresetNamesCarryCredit() {
        XCTAssertEqual(PatchLibrary.defaultPatch(for: .feltGlass).displayName, "Felt Glass · after \"Come Back to Earth\"")
        XCTAssertEqual(Patch(id: "x", name: "Plain", engine: .feltGlass, values: [:]).displayName, "Plain")
    }
}
