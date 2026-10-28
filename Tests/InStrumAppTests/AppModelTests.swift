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

    // MARK: - Worlds drive the ambience

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
        XCTAssertTrue(PatchLibrary.all.allSatisfy { $0.creditID.flatMap { CreditLibrary.credit(id: $0) } != nil })
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
