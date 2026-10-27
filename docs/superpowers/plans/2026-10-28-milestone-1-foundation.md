# Milestone 1: Foundation, MIDI, Plugin Host & Midnight Steinway — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A downloadable Intel Mac app that plays the real Intimate Grand Piano (via the installed Splice INSTRUMENT Audio Unit) from a MIDI keyboard, with the Midnight Steinway theme reacting to every note.

**Architecture:** A Swift package with four targets. `InStrumCore` holds all platform-free logic (MIDI parsing, performance state, keyboard geometry, settings, visual scene model) and is fully unit-tested. `InStrumAudio` wraps CoreMIDI and AVAudioEngine/Audio Unit hosting. `InStrumApp` holds the app model and SwiftUI/Metal views. A thin `InStrumMeants` executable starts the app. GitHub Actions tests everything on a Mac runner, builds an x86_64 app bundle, and publishes it as a Release.

**Tech Stack:** Swift 5.10 tools, SwiftPM, XCTest, CoreMIDI, AVFoundation (AVAudioEngine, AVAudioUnit, AVAudioUnitComponentManager), SwiftUI, MetalKit (shaders compiled at runtime from source strings), GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-10-28-in-strum-meants-design.md`

## Global Constraints

- Target: Intel (x86_64), macOS 13.0 or newer (`platforms: [.macOS(.v13)]`, `LSMinimumSystemVersion` 13.0).
- `// swift-tools-version:5.10` (avoids Swift 6 strict-concurrency mode).
- No third-party dependencies in this milestone.
- Paid sample libraries are never copied, extracted, converted or decrypted. Plugins are only loaded and played in place.
- A sustain pedal is optional. Nothing may require one.
- Visuals run separately from audio. A slow frame must never delay or glitch a note. MIDI goes to the plugin directly from the CoreMIDI callback, never via the main thread.
- Audio output buffer: 128 frames.
- Visual target: 60 fps.
- Bundle identifier `com.michaelscalzo.instrummeants`, display name **In Strum Meants**.
- Personal use: the app is ad-hoc signed only (`codesign -s -`). It is not notarised or distributed.
- This workspace has no Swift toolchain. Every "Run" step means: push the branch and read the GitHub Actions run (`gh run watch --exit-status`). Expected outputs refer to that run's log.
- Commits end with the session attribution lines from the harness.

## Review Focus

1. **Velocity-0 note-on.** Many keyboards send key-release as Note On with velocity 0. It must release the note, never trigger a silent note. Test: Task 2.
2. **Real-time bytes inside a message.** Keyboards interleave Active Sensing (0xFE) and Clock (0xF8), even mid-message. They must be skipped without breaking running status. Test: Task 2.
3. **Keyboard unplugged while keys or pedal are held.** No stuck notes: the plugin gets all-notes-off and the visuals clear. Tests: Tasks 3 and 9.
4. **Saved plugin missing at launch** (uninstalled, renamed, or failed to load). The app opens normally and shows the instrument picker with a plain message. No crash. Test: Task 9.
5. **Corrupt or unreadable settings file.** Defaults are used, the bad file is kept as `settings.corrupt.json`, and there is no crash. Test: Task 5.

---

## File Structure

```
Package.swift
Sources/
  InStrumCore/                 # platform-free, unit-tested
    MIDIMessage.swift          # MIDIMessage enum + MIDIParser
    PerformanceState.swift     # PerformanceEvent, PerformanceState (held notes, pedal, chords, intensity)
    KeyboardLayout.swift       # 88-key geometry
    ComputerKeyMap.swift       # Mac keyboard → notes for on-screen keyboard
    AppSettings.swift          # AppSettings, InstrumentChoice, SettingsStore
    LaunchGuard.swift          # unclean-exit detection for Safe Mode
    VisualScene.swift          # VisualScene protocol, SceneFrame, KeyVisual
    MidnightSteinwayScene.swift
  InStrumAudio/                # macOS frameworks
    MIDIInput.swift            # CoreMIDI client
    PluginCatalog.swift        # instrument AU discovery
    AudioEngine.swift          # AVAudioEngine host, MIDI scheduling, level meter, panic
  InStrumApp/
    AppModel.swift             # wiring, autosave, safe mode, panic
    InstrumentEngine.swift     # protocol AppModel depends on (AudioEngine conforms)
    Views/MainView.swift
    Views/InstrumentPicker.swift
    Views/PluginWindowController.swift
    Views/OnScreenKeyboard.swift
    Visuals/MetalCanvas.swift  # NSViewRepresentable MTKView
    Visuals/SceneRenderer.swift
    Visuals/MidnightSteinwayShaders.swift  # shader source string
  InStrumMeants/
    main.swift                 # @main entry → InStrumApp
Tests/
  InStrumCoreTests/ (one file per Core source)
  InStrumAudioTests/AudioEngineTests.swift, MIDIInputTests.swift
  InStrumAppTests/AppModelTests.swift
Packaging/Info.plist
Scripts/make-app.sh
.github/workflows/build.yml
```

---

### Task 1: Repository, package skeleton and CI

**Files:**
- Create: `Package.swift`, `Sources/*/Placeholder.swift` (one per target, deleted as real files arrive), `Sources/InStrumMeants/main.swift`, `Tests/InStrumCoreTests/SmokeTests.swift`, `.github/workflows/build.yml`, `.gitignore` (`.build/`, `*.xcodeproj`, `dist/`)

**Interfaces:**
- Produces: targets `InStrumCore`, `InStrumAudio` (depends on Core), `InStrumApp` (depends on Core and Audio), executable `InStrumMeants` (depends on App); test targets `InStrumCoreTests`, `InStrumAudioTests`, `InStrumAppTests`. CI job `test` on `macos-15` runs `swift test`.

- [ ] **Step 1: Get the repo.** Ask Michael to create an empty private GitHub repo named `in-strum-meants`. Attach it with `mcp__claude-code-remote__add_repo` (access `push`) and clone it. Copy `docs/` from this workspace into it.
- [ ] **Step 2: Write the smoke test**

```swift
final class SmokeTests: XCTestCase {
    func testCoreModuleLoads() { XCTAssertEqual(InStrumCore.version, "0.1.0") }
}
```

- [ ] **Step 3: Write `Package.swift` and `public enum InStrumCore { public static let version = "0.1.0" }`.** Also write the workflow: trigger on push and pull_request; job `test` on `macos-15` with steps checkout → `swift --version` → `swift test`.
- [ ] **Step 4: Push and run.** Run: `gh run watch --exit-status`. Expected: job `test` passes, `testCoreModuleLoads` passed.
- [ ] **Step 5: Commit** `chore: package skeleton and CI`.

---

### Task 2: MIDI parser

**Files:**
- Create: `Sources/InStrumCore/MIDIMessage.swift`
- Test: `Tests/InStrumCoreTests/MIDIParserTests.swift`

**Interfaces:**
- Produces:

```swift
public enum MIDIMessage: Equatable {
    case noteOn(channel: UInt8, note: UInt8, velocity: UInt8)   // velocity 1...127 only
    case noteOff(channel: UInt8, note: UInt8)
    case controlChange(channel: UInt8, controller: UInt8, value: UInt8)
    case pitchBend(channel: UInt8, value: UInt16)               // 0...16383, centre 8192
    case other                                                  // recognised but unused (aftertouch, program change)
}
public struct MIDIParser {
    public init()
    public mutating func parse(_ bytes: [UInt8]) -> [MIDIMessage]   // stateful across calls
}
```

- [ ] **Step 1: Write the failing tests**

```swift
func testNoteOn() { XCTAssertEqual(p.parse([0x90, 60, 100]), [.noteOn(channel: 0, note: 60, velocity: 100)]) }
func testVelocityZeroNoteOnIsNoteOff() { XCTAssertEqual(p.parse([0x91, 60, 0]), [.noteOff(channel: 1, note: 60)]) }
func testNoteOffMessage() { XCTAssertEqual(p.parse([0x80, 60, 64]), [.noteOff(channel: 0, note: 60)]) }
func testRunningStatus() {
    XCTAssertEqual(p.parse([0x90, 60, 100, 64, 90, 60, 0]),
        [.noteOn(channel: 0, note: 60, velocity: 100), .noteOn(channel: 0, note: 64, velocity: 90), .noteOff(channel: 0, note: 60)])
}
func testRunningStatusAcrossCalls() {
    _ = p.parse([0x90, 60, 100])
    XCTAssertEqual(p.parse([62, 80]), [.noteOn(channel: 0, note: 62, velocity: 80)])
}
func testRealTimeBytesMidMessageAreIgnored() {
    XCTAssertEqual(p.parse([0x90, 0xFE, 60, 0xF8, 100]), [.noteOn(channel: 0, note: 60, velocity: 100)])
}
func testSustainPedalCC() { XCTAssertEqual(p.parse([0xB0, 64, 127]), [.controlChange(channel: 0, controller: 64, value: 127)]) }
func testPitchBend() { XCTAssertEqual(p.parse([0xE0, 0x00, 0x40]), [.pitchBend(channel: 0, value: 8192)]) }
func testSysExIsSkipped() {
    XCTAssertEqual(p.parse([0xF0, 0x7E, 0x01, 0xF7, 0x90, 60, 100]), [.noteOn(channel: 0, note: 60, velocity: 100)])
}
func testDataBytesWithoutStatusAreIgnored() { XCTAssertEqual(MIDIParser().parse([60, 100]), []) }
func testProgramChangeIsOther() { XCTAssertEqual(p.parse([0xC0, 5]), [.other]) }
```

- [ ] **Step 2: Run.** Expected: FAIL, `cannot find 'MIDIParser'`.
- [ ] **Step 3: Implement `MIDIParser.parse(_:)`.** State is `runningStatus: UInt8?` plus pending data bytes. 0xF8–0xFF are skipped without touching state. 0xF0 enters sysex-skip until 0xF7. Other 0xF1–0xF7 clear running status. Data lengths: 0xC0/0xD0 take 1 byte, the rest take 2.
- [ ] **Step 4: Run.** Expected: all `MIDIParserTests` pass.
- [ ] **Step 5: Commit** `feat(core): MIDI parser`.

---

### Task 3: Performance state (held notes, pedal, chords, intensity)

**Files:**
- Create: `Sources/InStrumCore/PerformanceState.swift`
- Test: `Tests/InStrumCoreTests/PerformanceStateTests.swift`

**Interfaces:**
- Consumes: `MIDIMessage` (Task 2)
- Produces:

```swift
public enum PerformanceEvent: Equatable {
    case noteOn(note: UInt8, velocity: Float)   // velocity 0...1 = raw/127
    case noteOff(note: UInt8)
    case pedal(down: Bool, amount: Float)       // CC64; down when value >= 64, amount = value/127
    case chord(notes: [UInt8])                  // sorted ascending
    case allNotesOff
}
public struct PerformanceState {
    public static let chordWindow: Double = 0.03     // seconds
    public static let intensityHalfLife: Double = 1.0 // seconds
    public init()
    public private(set) var heldNotes: [UInt8: Float]   // note → velocity
    public private(set) var pedalDown: Bool
    public private(set) var intensity: Float            // 0...1
    /// Applies a message at time t (seconds, monotonic). Returns events to forward to visuals.
    public mutating func apply(_ message: MIDIMessage, at t: Double) -> [PerformanceEvent]
    public mutating func reset() -> [PerformanceEvent]  // returns [.allNotesOff]
    public mutating func decay(to t: Double)            // updates intensity
}
```

- [ ] **Step 1: Write the failing tests**

```swift
func testNoteOnHoldsNoteWithNormalisedVelocity() {
    let ev = s.apply(.noteOn(channel: 0, note: 60, velocity: 127), at: 0)
    XCTAssertEqual(ev, [.noteOn(note: 60, velocity: 1.0)]); XCTAssertEqual(s.heldNotes[60], 1.0)
}
func testNoteOffReleases() { _ = s.apply(.noteOn(channel: 0, note: 60, velocity: 64), at: 0)
    XCTAssertEqual(s.apply(.noteOff(channel: 0, note: 60), at: 0.1), [.noteOff(note: 60)]); XCTAssertNil(s.heldNotes[60]) }
func testPedalThreshold() {
    XCTAssertEqual(s.apply(.controlChange(channel: 0, controller: 64, value: 63), at: 0), [.pedal(down: false, amount: 63/127)])
    XCTAssertEqual(s.apply(.controlChange(channel: 0, controller: 64, value: 64), at: 0), [.pedal(down: true, amount: 64/127)])
}
func testThreeNotesWithinWindowEmitChord() {
    _ = s.apply(.noteOn(channel: 0, note: 64, velocity: 80), at: 0.000)
    _ = s.apply(.noteOn(channel: 0, note: 60, velocity: 80), at: 0.010)
    let ev = s.apply(.noteOn(channel: 0, note: 67, velocity: 80), at: 0.020)
    XCTAssertTrue(ev.contains(.chord(notes: [60, 64, 67])))
}
func testNotesOutsideWindowAreNotAChord() {
    _ = s.apply(.noteOn(channel: 0, note: 60, velocity: 80), at: 0)
    _ = s.apply(.noteOn(channel: 0, note: 64, velocity: 80), at: 0.2)
    XCTAssertFalse(s.apply(.noteOn(channel: 0, note: 67, velocity: 80), at: 0.4).contains { if case .chord = $0 { return true }; return false })
}
func testRepeatedNoteRetriggers() { _ = s.apply(.noteOn(channel: 0, note: 60, velocity: 40), at: 0)
    XCTAssertEqual(s.apply(.noteOn(channel: 0, note: 60, velocity: 120), at: 0.1).first, .noteOn(note: 60, velocity: 120/127)) }
func testAllNotesOffCCClearsEverything() {        // CC120 and CC123
    _ = s.apply(.noteOn(channel: 0, note: 60, velocity: 80), at: 0); _ = s.apply(.controlChange(channel: 0, controller: 64, value: 127), at: 0)
    XCTAssertEqual(s.apply(.controlChange(channel: 0, controller: 123, value: 0), at: 0.1), [.allNotesOff])
    XCTAssertTrue(s.heldNotes.isEmpty); XCTAssertFalse(s.pedalDown)
}
func testResetWhileHoldingClearsNotesAndPedal() {  // Review Focus 3
    _ = s.apply(.noteOn(channel: 0, note: 60, velocity: 80), at: 0); _ = s.apply(.controlChange(channel: 0, controller: 64, value: 127), at: 0)
    XCTAssertEqual(s.reset(), [.allNotesOff]); XCTAssertTrue(s.heldNotes.isEmpty); XCTAssertFalse(s.pedalDown)
}
func testIntensityRisesWithFastPlayingAndHalvesAfterOneSecond() {
    for i in 0..<20 { _ = s.apply(.noteOn(channel: 0, note: UInt8(60 + i % 12), velocity: 100), at: Double(i) * 0.05) }
    let peak = s.intensity; XCTAssertGreaterThan(peak, 0.5)
    s.decay(to: 0.95 + 1.0); XCTAssertEqual(s.intensity, peak / 2, accuracy: 0.02)
}
func testNotesOutside88KeysStillReportedForSound() {
    XCTAssertEqual(s.apply(.noteOn(channel: 0, note: 10, velocity: 100), at: 0), [.noteOn(note: 10, velocity: 100/127)])
}
```

- [ ] **Step 2: Run.** Expected: FAIL, `cannot find 'PerformanceState'`.
- [ ] **Step 3: Implement.** Chord rule: when a note-on arrives, collect notes whose note-on time is within `chordWindow` of it and are still held. If there are 3 or more and that set hasn't already been emitted, append `.chord`. Intensity: each note-on adds `velocity * 0.15`, capped at 1. Decay is exponential with `intensityHalfLife`, applied before each update. CC120/CC123 behave like `reset()`. Pedal up does not release held notes.
- [ ] **Step 4: Run.** Expected: all pass.
- [ ] **Step 5: Commit** `feat(core): performance state`.

---

### Task 4: Keyboard geometry and computer-key mapping

**Files:**
- Create: `Sources/InStrumCore/KeyboardLayout.swift`, `Sources/InStrumCore/ComputerKeyMap.swift`
- Test: `Tests/InStrumCoreTests/KeyboardLayoutTests.swift`, `ComputerKeyMapTests.swift`

**Interfaces:**
- Produces:

```swift
public struct KeyRect: Equatable { public let note: UInt8; public let isBlack: Bool; public let x: Float; public let width: Float } // x, width in 0...1
public enum KeyboardLayout {
    public static let lowestNote: UInt8 = 21   // A0
    public static let highestNote: UInt8 = 108 // C8
    public static func isBlack(_ note: UInt8) -> Bool
    public static func keys(from low: UInt8 = lowestNote, to high: UInt8 = highestNote) -> [KeyRect] // white keys first, then black (draw order)
    public static func key(for note: UInt8) -> KeyRect?   // nil outside range
}
public struct ComputerKeyMap {
    public var octaveShift: Int = 0                         // clamped -3...3; Z = down, X = up
    public init()
    public func note(for character: Character) -> UInt8?    // A W S E D F T G Y H U J K → C4(60)...C5(72) + 12*octaveShift
    public mutating func handleOctaveKey(_ character: Character) -> Bool // true if Z/X consumed
}
```

- [ ] **Step 1: Write the failing tests:** 52 white and 36 black keys in the full range; white keys tile 0...1 with no gaps (`sum(width) == 1` within 1e-5); `isBlack(61) == true`, `isBlack(60) == false`; black key width is 0.6 × white width and centred on the boundary between its neighbours; `key(for: 20) == nil`; `note(for: "a") == 60`, `note(for: "k") == 72`, `note(for: "q") == nil`; after 4 × `X`, `octaveShift == 3`; uppercase letters map the same as lowercase.
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement** as specified. Black keys are those whose pitch class is in {1, 3, 6, 8, 10}.
- [ ] **Step 4: Run.** Expected: pass.
- [ ] **Step 5: Commit** `feat(core): keyboard layout and computer key map`.

---

### Task 5: Settings and Safe Mode guard

**Files:**
- Create: `Sources/InStrumCore/AppSettings.swift`, `Sources/InStrumCore/LaunchGuard.swift`
- Test: `Tests/InStrumCoreTests/SettingsStoreTests.swift`, `LaunchGuardTests.swift`

**Interfaces:**
- Produces:

```swift
public struct InstrumentChoice: Codable, Equatable {
    public var name: String                    // e.g. "Splice INSTRUMENT"
    public var componentType: UInt32, componentSubType: UInt32, componentManufacturer: UInt32
    public var stateData: Data?                // AU fullState as binary plist
}
public struct AppSettings: Codable, Equatable {
    public var instrument: InstrumentChoice?
    public var themeID: String = "midnight-steinway"
    public var masterVolume: Float = 0.8
    public static let `default`: AppSettings
}
public final class SettingsStore {
    public init(directory: URL)                // file: directory/settings.json
    public func load() -> AppSettings          // never throws; corrupt → default + renames file to settings.corrupt.json
    public func save(_ s: AppSettings) throws  // atomic write
}
public final class LaunchGuard {
    public init(directory: URL)                // marker: directory/running.marker
    public func beginLaunch() -> Bool          // returns true if previous run ended uncleanly (marker present); then writes marker
    public func markStable()                   // removes marker
}
```

Directory in app: `~/Library/Application Support/In Strum Meants/`. Tests use a fresh temp directory.

- [ ] **Step 1: Write the failing tests:** round-trip save/load equals the original, including `stateData`; load with no file returns `.default`; **corrupt file** (`"{not json"` written to settings.json) → load returns `.default`, `settings.corrupt.json` exists, and no `settings.json` remains (Review Focus 5); unknown extra JSON keys are ignored; `beginLaunch()` is false on first run and true if called again without `markStable()`, and false after `markStable()`.
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement.** Use JSONEncoder/Decoder, and decode with defaults so missing keys fall back to `.default` values. Save with `Data.write(to:options: .atomic)`.
- [ ] **Step 4: Run.** Expected: pass.
- [ ] **Step 5: Commit** `feat(core): settings store and launch guard`.

---

### Task 6: Visual scene model and Midnight Steinway behaviour

**Files:**
- Create: `Sources/InStrumCore/VisualScene.swift`, `Sources/InStrumCore/MidnightSteinwayScene.swift`
- Test: `Tests/InStrumCoreTests/MidnightSteinwaySceneTests.swift`

**Interfaces:**
- Consumes: `PerformanceEvent` (Task 3), `KeyboardLayout`/`KeyRect` (Task 4)
- Produces:

```swift
public struct KeyVisual: Equatable { public let key: KeyRect; public var pressed: Bool; public var glow: Float }   // glow 0...1
public struct SceneFrame {
    public var keys: [KeyVisual]           // full 88, draw order
    public var spotlights: [Spotlight]     // one per glowing key: x (0...1), intensity, warmth
    public var bloom: Float                // 0...1, chord bloom across the stage
    public var ambience: Float             // 0...1, from intensity + audio level
}
public struct Spotlight: Equatable { public let x: Float; public var intensity: Float }
public protocol VisualScene {
    static var id: String { get }
    static var displayName: String { get }
    mutating func handle(_ event: PerformanceEvent)
    mutating func step(dt: Double, intensity: Float, audioLevel: Float) -> SceneFrame
}
public struct MidnightSteinwayScene: VisualScene {   // id "midnight-steinway", displayName "Midnight Steinway"
    public static let releaseHalfLife: Double = 0.25     // seconds, pedal up
    public static let pedalHalfLife: Double = 1.5        // seconds, pedal down
    public static let heldFloor: Float = 0.6             // fraction of strike glow kept while held
    public static let bloomHalfLife: Double = 0.6
    public init()
}
```

- [ ] **Step 1: Write the failing tests**

```swift
func testHardNoteGlowsMoreThanSoft() {
    var s = MidnightSteinwayScene(); s.handle(.noteOn(note: 60, velocity: 0.2)); s.handle(.noteOn(note: 72, velocity: 1.0))
    let f = s.step(dt: 0, intensity: 0, audioLevel: 0)
    XCTAssertGreaterThan(glow(f, 72), glow(f, 60)); XCTAssertEqual(glow(f, 72), 1.0, accuracy: 0.01)
}
func testHeldNoteNeverDropsBelowFloor() {
    var s = MidnightSteinwayScene(); s.handle(.noteOn(note: 60, velocity: 1.0))
    let f = s.step(dt: 10, intensity: 0, audioLevel: 0); XCTAssertEqual(glow(f, 60), 0.6, accuracy: 0.01); XCTAssertTrue(pressed(f, 60))
}
func testReleasedNoteFadesWithReleaseHalfLife() {
    var s = MidnightSteinwayScene(); s.handle(.noteOn(note: 60, velocity: 1.0)); s.handle(.noteOff(note: 60))
    XCTAssertEqual(glow(s.step(dt: 0.25, intensity: 0, audioLevel: 0), 60), 0.5, accuracy: 0.02)
}
func testPedalMakesReleasedNotesLinger() {
    var s = MidnightSteinwayScene(); s.handle(.pedal(down: true, amount: 1)); s.handle(.noteOn(note: 60, velocity: 1.0)); s.handle(.noteOff(note: 60))
    XCTAssertEqual(glow(s.step(dt: 1.5, intensity: 0, audioLevel: 0), 60), 0.5, accuracy: 0.02)
}
func testPedalUpReturnsToNormalFade() { /* pedal down, note on/off, pedal up, step 0.25 → 0.5 ± 0.02 */ }
func testChordTriggersBloom() {
    var s = MidnightSteinwayScene(); s.handle(.chord(notes: [60, 64, 67]))
    XCTAssertGreaterThan(s.step(dt: 0, intensity: 0, audioLevel: 0).bloom, 0.9)
}
func testAmbienceFollowsIntensityAndAudio() {
    var s = MidnightSteinwayScene()
    XCTAssertGreaterThan(s.step(dt: 0, intensity: 1, audioLevel: 0.5).ambience, s.step(dt: 0, intensity: 0, audioLevel: 0).ambience)
}
func testAllNotesOffClearsWithinOneFrame() {   // Review Focus 3
    var s = MidnightSteinwayScene(); s.handle(.noteOn(note: 60, velocity: 1)); s.handle(.allNotesOff)
    let f = s.step(dt: 1/60, intensity: 0, audioLevel: 0); XCTAssertFalse(pressed(f, 60)); XCTAssertEqual(glow(f, 60), 0)
}
func testOutOfRangeNoteIgnoredVisually() { var s = MidnightSteinwayScene(); s.handle(.noteOn(note: 10, velocity: 1))
    XCTAssertTrue(s.step(dt: 0, intensity: 0, audioLevel: 0).keys.allSatisfy { $0.glow == 0 }) }
func testBurstOf2000EventsStepsWithinFrameBudget() {
    var s = MidnightSteinwayScene()
    measure { for i in 0..<2000 { s.handle(.noteOn(note: UInt8(21 + i % 88), velocity: 0.8)) }; _ = s.step(dt: 1/60, intensity: 1, audioLevel: 1) }
}  // plus a hard assertion: one handle-burst + step completes in < 4 ms, measured with DispatchTime
```

(`glow(f, n)` and `pressed(f, n)` are small test helpers that look up a note in `f.keys`.)

- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement.** Store per-key glow in a fixed 88-slot array indexed by `note - 21`. On note-on, glow is set to max(current, velocity). Each step: held keys decay toward the floor (`velocityAtStrike * heldFloor`) using `releaseHalfLife`; released keys decay toward 0 using the pedal-dependent half-life. Spotlights are keys with glow > 0.05. Ambience = `min(1, 0.15 + 0.5*intensity + 0.35*audioLevel)`.
- [ ] **Step 4: Run.** Expected: pass, burst under 4 ms.
- [ ] **Step 5: Commit** `feat(core): Midnight Steinway scene model`.

---

### Task 7: Plugin catalog and audio engine

**Files:**
- Create: `Sources/InStrumAudio/PluginCatalog.swift`, `Sources/InStrumAudio/AudioEngine.swift`
- Test: `Tests/InStrumAudioTests/AudioEngineTests.swift`

**Interfaces:**
- Consumes: `InstrumentChoice` (Task 5)
- Produces:

```swift
public struct PluginInfo: Identifiable, Equatable { public let id: String; public let name: String; public let manufacturer: String; public let description: AudioComponentDescription }
public enum PluginCatalog { public static func instruments() -> [PluginInfo] }   // type kAudioUnitType_MusicDevice only, sorted by manufacturer then name
public enum AudioEngineError: Error { case pluginNotFound(String), loadFailed(String) }
public final class AudioEngine {
    public init(manualRendering: Bool = false)              // true only in tests
    public func start() throws                               // sets output buffer to 128 frames; restarts on AVAudioEngineConfigurationChange
    public func loadInstrument(_ choice: InstrumentChoice) async throws    // restores stateData into auAudioUnit.fullState
    public func currentInstrumentState() -> Data?           // binary plist of fullState
    public func send(_ bytes: [UInt8])                      // realtime-safe; scheduleMIDIEventBlock, AUEventSampleTimeImmediate
    public func panic()                                     // CC64=0, CC123, CC120 on all 16 channels + note-off 0...127 ch 0
    public var audioLevel: Float { get }                    // RMS of mixer output, 0...1, updated by tap
    public var loadedAudioUnit: AUAudioUnit? { get }        // for the plugin window
    public var masterVolume: Float { get set }
    public func renderOffline(frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer  // manual-rendering tests only
}
```

- [ ] **Step 1: Write the failing tests.** These use Apple's built-in DLS synth, which exists on every Mac: `aumu`/`dls `/`appl`.
  - `testCatalogContainsAppleDLSSynthAndOnlyInstruments`: some item has subtype `dls `, and every item's type is `kAudioUnitType_MusicDevice`.
  - `testNoteProducesSound`: manual-rendering engine, load DLS, `send([0x90,60,110])`, render 4096 frames → peak > 0.01.
  - `testPanicSilencesHeldNote`: note-on, render 4096, `panic()`, render 3 × 44100 frames → peak of the last 4096 frames < 0.001.
  - `testStateRoundTrips`: `currentInstrumentState()` is non-nil, and loading a choice with that data succeeds.
  - `testMissingPluginThrowsPluginNotFound`: subtype `zzzz` → `.pluginNotFound`.
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement.** Use `AVAudioUnitComponentManager.shared().components(matching:)`, `AVAudioUnit.instantiate(with:options: [])` (in-process, which suits AUv2 plugins like Splice INSTRUMENT), attach → connect to `mainMixerNode`. Set the 128-frame buffer via `AudioUnitSetProperty(outputNode.audioUnit!, kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0, ...)`. The level tap is on `mainMixerNode` (bufferSize 512) and stores RMS atomically. For `send`, build the MIDI event block once per load and call it directly; never hop threads.
- [ ] **Step 4: Run.** Expected: pass.
- [ ] **Step 5: Commit** `feat(audio): plugin catalog and audio engine`.

---

### Task 8: MIDI input

**Files:**
- Create: `Sources/InStrumAudio/MIDIInput.swift`
- Test: `Tests/InStrumAudioTests/MIDIInputTests.swift`

**Interfaces:**
- Produces:

```swift
public final class MIDIInput {
    /// onBytes is called on the CoreMIDI thread with raw bytes and a host-time timestamp in seconds.
    public init(onBytes: @escaping ([UInt8], Double) -> Void, onSourcesChanged: @escaping (_ names: [String], _ sourceRemoved: Bool) -> Void) throws
    public private(set) var sourceNames: [String]
}
```

- [ ] **Step 1: Write the failing tests.** Create a virtual source with `MIDISourceCreate` in the test. `XCTSkip` if `MIDIClientCreate` fails on the runner.
  - `testReceivesBytesFromNewSource`: after the source appears, `MIDIReceived` of `[0x90,60,100]` arrives at `onBytes` within 1 s.
  - `testRemovingSourceReportsRemoval` (Review Focus 3): dispose the source → `onSourcesChanged(_, true)` within 1 s.
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement.** Use `MIDIClientCreateWithBlock` with notification handling for `.msgObjectAdded/.msgObjectRemoved/.msgSetupChanged`. On any change, reconnect all sources to a `MIDIInputPortCreateWithBlock` port. Pass packet bytes through unchanged; parsing happens in Core.
- [ ] **Step 4: Run.** Expected: pass, or a skip noted in the log.
- [ ] **Step 5: Commit** `feat(audio): MIDI input`.

---

### Task 9: App model (wiring, autosave, Safe Mode, panic, missing plugin)

**Files:**
- Create: `Sources/InStrumApp/InstrumentEngine.swift`, `Sources/InStrumApp/AppModel.swift`
- Test: `Tests/InStrumAppTests/AppModelTests.swift`

**Interfaces:**
- Consumes: Tasks 2, 3, 5, 6, 7, 8
- Produces:

```swift
public protocol InstrumentEngine: AnyObject {
    func start() throws
    func loadInstrument(_ choice: InstrumentChoice) async throws
    func currentInstrumentState() -> Data?
    func send(_ bytes: [UInt8]); func panic()
    var audioLevel: Float { get }; var masterVolume: Float { get set }
}
extension AudioEngine: InstrumentEngine {}

@MainActor public final class AppModel: ObservableObject {
    public enum Status: Equatable { case starting, safeMode, needsInstrument(message: String?), playing(instrumentName: String) }
    @Published public private(set) var status: Status
    @Published public private(set) var midiSourceNames: [String]
    public var showsOnScreenKeyboard: Bool { midiSourceNames.isEmpty }
    public init(engine: InstrumentEngine, store: SettingsStore, launchGuard: LaunchGuard)
    public func launch(skipPluginInSafeMode: Bool) async     // Safe Mode = launch guard tripped AND user chose to skip
    public func choose(_ plugin: PluginInfo) async
    public func handleMIDI(bytes: [UInt8], time: Double)     // forwards bytes to engine first, then queues PerformanceEvents
    public func playFromScreen(note: UInt8, down: Bool)       // velocity 90 for on-screen and Mac keys
    public func midiSourcesChanged(names: [String], removed: Bool)   // removed → panic + state reset
    public func panic()
    public func drainEvents() -> [PerformanceEvent]           // called by renderer each frame; lock-protected queue
    public var intensity: Float { get }
    public func autosave()                                     // writes settings incl. current plugin state
}
```

- [ ] **Step 1: Write the failing tests** with a `FakeEngine` that records calls and can be told to throw.
  - `testLaunchRestoresSavedInstrument`: the store has a choice → status `.playing("Splice INSTRUMENT")`, and the engine received that choice.
  - `testMissingPluginShowsPicker` (Review Focus 4): the fake throws `.pluginNotFound` → status `.needsInstrument(message:)`, and the message contains the plugin name and "couldn't be found".
  - `testUncleanPreviousExitOffersSafeMode`: the guard marker exists and `skipPluginInSafeMode: true` → `.safeMode`, and `loadInstrument` is never called.
  - `testSourceRemovedPanicsAndClearsVisuals` (Review Focus 3): send note-on bytes, then `midiSourcesChanged(names: [], removed: true)` → `engine.panicCount == 1`, and `drainEvents()` ends with `.allNotesOff`.
  - `testMIDIReachesEngineBeforeVisuals`: `handleMIDI([0x90,60,100])` → `engine.sent == [[0x90,60,100]]` and one `.noteOn` is queued.
  - `testOnScreenKeyboardShownWithoutSources`, `testPlayFromScreenSendsVelocity90`.
  - `testAutosaveStoresPluginState`: the fake state `Data([1,2,3])` is saved into `settings.instrument.stateData`.
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement.** `handleMIDI` is called off the main thread: send bytes to the engine immediately, then parse and append events under an `os_unfair_lock`. Do not touch `@Published` from that thread. Autosave runs every 30 s, on choosing a plugin, and on `NSApplication.willTerminateNotification`. Call `launchGuard.markStable()` 10 s after reaching `.playing`.
- [ ] **Step 4: Run.** Expected: pass.
- [ ] **Step 5: Commit** `feat(app): app model`.

---

### Task 10: Windows, Metal renderer and Midnight Steinway look

**Files:**
- Create: `Sources/InStrumApp/Views/MainView.swift`, `InstrumentPicker.swift`, `PluginWindowController.swift`, `OnScreenKeyboard.swift`, `Sources/InStrumApp/Visuals/MetalCanvas.swift`, `SceneRenderer.swift`, `MidnightSteinwayShaders.swift`, `Sources/InStrumMeants/main.swift` (replace the placeholder)

**Interfaces:**
- Consumes: `AppModel` (Task 9), `MidnightSteinwayScene`/`SceneFrame` (Task 6), `PluginCatalog` (Task 7)
- Produces: `public struct InStrumMeantsApp: App`; `SceneRenderer(device: MTLDevice, model: AppModel)` as `MTKViewDelegate`, with `preferredFramesPerSecond = 60`.

The look (from the spec): glossy black stage, with a warm spotlight cone rising from each glowing key. Keys are piano black/ivory with a warm amber edge-glow whose brightness equals `glow`. A soft golden bloom washes the stage on chords. Ambience raises a faint warm haze. Palette: background `#0B0907`, ivory `#F2EBDD`, black key `#141210`, glow amber `#FFB45A`, spotlight `#FFD9A0`.

- [ ] **Step 1: Write the renderer.** Each frame: `drainEvents()` → `scene.handle` → `scene.step(dt, intensity, audioLevel)` → draw. Pass 1 draws a full-screen quad (background, spotlights as up to 64 uniforms, bloom, ambience). Pass 2 draws an instanced quad per `KeyVisual`. Shaders are compiled with `device.makeLibrary(source:options:)` from `MidnightSteinwayShaders.source`, so no `.metal` build step is needed.
- [ ] **Step 2: Write the views.** `MainView` stacks a top bar (instrument name · **Choose Instrument** · **Open Plugin Window** · **Panic** button · volume slider), then the `MetalCanvas`, then the `OnScreenKeyboard` when `showsOnScreenKeyboard` is true. The on-screen keyboard is two octaves from C4, playable by mouse and by Mac keys through `ComputerKeyMap`. `InstrumentPicker` is a searchable list from `PluginCatalog.instruments()` and shows the `.needsInstrument` message at the top. `PluginWindowController` hosts `auAudioUnit.requestViewController` in an `NSWindow` titled with the plugin name. A Safe Mode prompt at launch offers two buttons: "Start normally" and "Start without plugin".
- [ ] **Step 3: Run.** Push. Expected: `swift build` succeeds in CI and all earlier tests still pass.
- [ ] **Step 4: Commit** `feat(app): windows, renderer, Midnight Steinway`.

---

### Task 11: App bundle and Releases

**Files:**
- Create: `Packaging/Info.plist`, `Scripts/make-app.sh`
- Modify: `.github/workflows/build.yml` (add job `package`, needs `test`)

**Interfaces:**
- Produces: on every push to `main`, a GitHub Release tagged `build-<run_number>` with `In-Strum-Meants-build-<run_number>.zip` containing `In Strum Meants.app`. Earlier releases are never deleted (spec §9).

- [ ] **Step 1: Write `Info.plist`** with `CFBundleIdentifier com.michaelscalzo.instrummeants`, `CFBundleName`/`CFBundleDisplayName In Strum Meants`, `CFBundleExecutable InStrumMeants`, `LSMinimumSystemVersion 13.0`, `NSHighResolutionCapable true`, `CFBundleShortVersionString 0.1.<run_number>` (substituted by the script).
- [ ] **Step 2: Write `make-app.sh <build-number>`.** It runs `swift build -c release --arch x86_64 --product InStrumMeants`, assembles `dist/In Strum Meants.app/Contents/{MacOS,Info.plist}`, runs `codesign --force --deep -s -`, then `ditto -c -k --keepParent` to make the zip.
- [ ] **Step 3: Add the CI job.** Steps: run the script; verify the binary with `lipo -archs` (must print exactly `x86_64`) and `vtool -show-build` (must show `minos 13.0`), failing otherwise; `gh release create build-$GITHUB_RUN_NUMBER dist/*.zip --notes "<commit message + test checklist link>"` (`permissions: contents: write`).
- [ ] **Step 4: Run.** Push to `main`. Expected: both jobs pass, the arch/minos checks print `x86_64` and `13.0`, and a Release `build-N` with the zip appears.
- [ ] **Step 5: Commit** `ci: package Intel app and publish releases`.

---

### Task 12: Michael's acceptance test

- [ ] **Step 1:** Michael downloads the newest Release zip, unzips it, moves the app to Applications, then right-click → **Open** → **Open**.
- [ ] **Step 2:** **Choose Instrument** → Splice INSTRUMENT → **Open Plugin Window** → select Intimate Grand Piano → close the plugin window.
- [ ] **Step 3:** Ear and eye checklist (spec §8), answering each:
  1. Does a key press feel instant?
  2. Does it sound identical to Splice on its own?
  3. Soft vs hard playing feels right, and the glow matches?
  4. Pedal (if connected) makes notes and glow linger. Without a pedal, everything still works?
  5. Do the visuals land exactly with the notes?
  6. Unplug the keyboard mid-chord: does all sound stop? Plug it back in: does it reconnect?
  7. Quit and reopen: is Intimate Grand Piano ready to play straight away?
- [ ] **Step 4:** Any "no" becomes a fix task. Every "yes" means Milestone 1 is done.

---

## Not in this milestone (later plans)
Sound Shaping, presets, A/B and the no-pedal Auto-Sustain/Latch (M2). The other 6 themes, gallery, auto-match and Lite switch (M3). Signature characters and packs (M4, M6). Synth engine (M5). Sample Player and fallback (M7).
