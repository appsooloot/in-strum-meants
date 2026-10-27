import XCTest
import AudioToolbox
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
        XCTAssertTrue(PatchLibrary.all.allSatisfy { $0.creditID.flatMap(CreditLibrary.credit(id:)) != nil })
    }

    func testPresetNamesCarryCredit() {
        XCTAssertEqual(PatchLibrary.defaultPatch(for: .feltGlass).displayName, "Felt Glass · after \"Come Back to Earth\"")
        XCTAssertEqual(Patch(id: "x", name: "Plain", engine: .feltGlass, values: [:]).displayName, "Plain")
    }
}
