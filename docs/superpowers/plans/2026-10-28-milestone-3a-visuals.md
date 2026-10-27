# Milestone 3A — Visual Engine, Customisation & Butterfly Garden — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Butterfly Garden ships first (Release A: theme engine, roles, playing analysis, butterflies, HDR render stack, front settings panel, installer). Presets, mapping editor, sound character, instrument dials, Listen and hands-free control follow (Release B).

**Architecture:** Behaviour lives in `InStrumCore` and is unit-tested: parameters, inputs, roles, links, playing analysis, theme simulations, flash limiting, auto quality, presets and control bindings. `InStrumAudio` adds analysers (sound character, dials, Mac audio, mic) that publish inputs. `InStrumApp` draws themes through a shared HDR Metal render stack and builds settings panels from parameter declarations. A `SceneDirector` (Core) ties events, inputs, links, parameters and the active theme together each frame.

**Tech Stack:** Swift 5.10 tools / Swift 6.1 compiler (Swift 5 mode), XCTest, Metal (runtime-compiled shaders, rgba16Float targets), Accelerate (vDSP FFT), ScreenCaptureKit (system audio), AVAudioEngine (mic), AUParameterTree, SwiftUI; packaging with `dmgbuild` (pip) + `rsvg-convert` (Homebrew librsvg) + `iconutil`.

**Spec:** `docs/superpowers/specs/2026-10-28-milestone-3a-visuals-design.md` (and the master spec `docs/superpowers/specs/2026-10-28-in-strum-meants-design.md`).

## Global Constraints

- Intel x86_64, macOS 13.0+, `// swift-tools-version:5.10`; no third-party Swift dependencies.
- Nothing touches the instrument's sound path; analysers read copies on their own threads; visuals never delay notes (`AppModel.handleMIDI` stays send-first).
- 60 fps target; Auto quality steps down one level if the frame rate averages below 55 fps for 2 s, and back up after 10 s of headroom.
- Flash safety on by default: at most 3 large brightness jumps per second; **Gentle visuals** halves flash and sparkle intensity.
- Butterflies capped at 600 on High (Lite 200, Ultra 1,200).
- Settings never lose data: unknown/missing/invalid saved values fall back to defaults and are clamped; Build 2 `settings.json` must load unchanged.
- Presets live in `~/Library/Application Support/In Strum Meants/Presets/` (`look/` and `reaction/` subfolders, `.json`).
- No workspace Swift toolchain: every "Run" is a GitHub Actions run on `macos-15`, read through check-run annotations; preview frames are read from the `previews` branch.
- Each push to `main` publishes a Release; work happens on branch `m3a`.

## Review Focus

1. **Switching theme while notes or pedal are held.** The new theme starts clean, with no stuck butterflies, glow or crash, and the sound is unaffected. Test: Task 7 `testSwitchingThemeWhileHoldingIsClean`.
2. **A Build 2 `settings.json` with no theme states.** It loads; the instrument, touch and buffer are kept; theme values are defaults. Test: Task 1 `testBuild2SettingsStillLoad`.
3. **An unknown theme id in settings.** It falls back to Midnight Steinway. Test: Task 7 `testUnknownThemeFallsBack`.
4. **A saved value of the wrong kind**, e.g. a number where a choice is expected. That value uses its default; the others are kept. Test: Task 1 `testWrongKindValueFallsBackToDefault`.
5. **A zero-size or resized drawable** (window minimised, full screen). It doesn't crash, and targets reallocate. Test: Task 5 `testResizeToZeroIsHarmless`.

---

## File Structure

```
Sources/InStrumCore/
  Parameters.swift          ParamKind, ParamValue, RGBA, GradientStop, ParamSpec, ParameterSet, Macro
  Roles.swift               Role, RoleValues
  Inputs.swift              InputID, InputFamily, InputFrame, InputHub (smoothing)
  Links.swift               Target, Curve, Link, ReactionMap, ReactionMap.evaluate
  ReactionPresets.swift     built-in Reaction maps
  PlayingAnalyzer.swift     chord quality, direction, leaps, busyness, crescendo, spread, repetition, silence, key
  ThemeModel.swift          ThemeModel protocol, AnyThemeModel, ThemeRegistry
  SceneDirector.swift       per-frame orchestration
  FlashLimiter.swift
  AutoQuality.swift         QualityLevel, AutoQuality
  ButterflyGarden/ButterflyGardenModel.swift, ButterflyParams.swift
  MidnightSteinway/MidnightSteinwayModel.swift (wraps existing MidnightSteinwayScene)
  Presets.swift             LookPreset, ReactionPreset, PresetStore, Surprise, morph
  ControlBindings.swift     ControlAction, Binding, BindingStore logic, ShortcutMap
  ScriptedPerformance.swift demo performance for previews/tests
  (modify) MIDIMessage.swift, PerformanceState.swift, AppSettings.swift
Sources/InStrumAudio/
  SoundCharacter.swift      SoundCharacterAnalyzer
  AudioFeatures.swift       AudioFeatureExtractor (level, bands, beat, tempo)
  DialReader.swift
  MacAudioListener.swift, MicListener.swift
  (modify) AudioEngine.swift (instrument tap feeds analyser)
Sources/InStrumApp/
  Visuals/RenderStack.swift, PostShaders.swift, ThemeRenderer.swift (protocol)
  Visuals/ButterflyRenderer.swift, ButterflyShaders.swift
  Visuals/SteinwayRenderer.swift (replaces SceneRenderer.swift)
  Visuals/PreviewRenderer.swift
  Views/SettingsPanel.swift, ParamControl.swift, MappingEditor.swift, AllSettingsView.swift, ControlsView.swift, PresetBar.swift, ListenControls.swift
  (modify) AppModel.swift, MainView.swift, MetalCanvas.swift, OnScreenKeyboard.swift
Packaging/AppIcon.svg, dmg-background.svg, dmg_settings.py
Scripts/make-dmg.sh
Tests/InStrumCoreTests/ (one file per Core file), Tests/InStrumAudioTests/, Tests/InStrumAppTests/
.github/workflows/build.yml (previews job, dmg)
```

---

# Release A — Butterfly Garden

### Task 1: Parameters and per-theme settings

**Files:** Create `Sources/InStrumCore/Parameters.swift`; Modify `Sources/InStrumCore/AppSettings.swift`; Test `Tests/InStrumCoreTests/ParametersTests.swift`, extend `SettingsStoreTests.swift`

**Interfaces — Produces:**
```swift
public struct RGBA: Codable, Equatable { public var r, g, b, a: Double; public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) }
public struct GradientStop: Codable, Equatable { public var position: Double; public var color: RGBA }
public enum ParamKind: Equatable { case slider(ClosedRange<Double>), integer(ClosedRange<Int>), toggle, choice([String]), color, gradient }
public enum ParamValue: Codable, Equatable { case number(Double), bool(Bool), choice(String), color(RGBA), gradient([GradientStop]) }
public struct ParamSpec: Identifiable {
    public let id: String, name: String, group: String, help: String
    public let kind: ParamKind, defaultValue: ParamValue
    public let hero: Bool
    public let surprise: ClosedRange<Double>?   // sliders/integers: tasteful range; non-nil for choice/color/toggle = may randomise (range ignored)
}
public enum Macro: String, CaseIterable, Codable { case intensity, speed, density, glow, chaos, temperature }
public struct ParameterSet {
    public init(specs: [ParamSpec], saved: [String: ParamValue] = [:], macros: [Macro: Double] = [:])
    public let specs: [ParamSpec]
    public func value(_ id: String) -> ParamValue          // effective (after macros)
    public func number(_ id: String) -> Double              // .number/.bool(1/0) else 0
    public func choice(_ id: String) -> String
    public func color(_ id: String) -> RGBA
    public mutating func set(_ id: String, _ v: ParamValue) // validates + clamps; wrong kind ignored
    public mutating func reset(_ id: String); mutating func resetGroup(_ group: String); mutating func resetAll()
    public var macros: [Macro: Double]                       // -1...1, 0 = neutral
    public var saved: [String: ParamValue] { get }           // only non-default base values
    public func withOffsets(_ offsets: [String: Double]) -> ParameterSet  // link deltas in "fraction of range" units
}
public struct ThemeState: Codable, Equatable { public var values: [String: ParamValue] = [:]; public var macros: [Macro: Double] = [:]; public var lookPresetName: String? }
// AppSettings gains: themeStates: [String: ThemeState] = [:], quality: String = "auto", gentleVisuals = false
```
Macro rule: a theme supplies `macroTargets: [Macro: [(id: String, weight: Double)]]`; effective number = clamp(base + macro × weight × span/2).

- [ ] **Step 1: Write failing tests**
  - `testSliderClampsToRange`: set 5.0 on `0...1` gives 1.0.
  - `testChoiceMustBeAnOption`: an invalid choice keeps the previous value.
  - `testWrongKindValueFallsBackToDefault` (RF4): `saved: ["s": .choice("x")]` for a slider gives the default.
  - `testResetSingleGroupAll`.
  - `testSavedContainsOnlyNonDefaults`.
  - `testMacroScalesAroundBase`: base 0.5, weight 1, macro +1 on `0...1` gives 1.0; macro −0.5 gives 0.25; base unchanged.
  - `testOffsetsAddFractionOfRange`: `0...10`, base 2, offset +0.5 gives 7.
  - `testGradientNeedsTwoToSixStops`.
  - `testBuild2SettingsStillLoad` (RF2): Build 2 JSON (instrument, themeID, masterVolume, touchCurve, bufferFrames) loads with those values, and `themeStates` is empty.
  - `testThemeStateRoundTrips`.
- [ ] **Step 2: Run.** Expected: FAIL (types missing).
- [ ] **Step 3: Implement.** `ParamValue` encodes as `{"number":0.5}` style (Swift's synthesized enum Codable). `ParameterSet` keeps `base: [String: ParamValue]` and computes effective values on read.
- [ ] **Step 4: Run.** Expected: all pass.
- [ ] **Step 5: Commit** `feat(core): parameter engine and per-theme settings`.

### Task 2: Richer MIDI events, inputs, roles and links

**Files:** Modify `MIDIMessage.swift`, `PerformanceState.swift`; Create `Roles.swift`, `Inputs.swift`, `Links.swift`, `ReactionPresets.swift`; Tests `InputsTests.swift`, `LinksTests.swift`, update `MIDIParserTests`, `PerformanceStateTests`

**Interfaces — Produces:**
```swift
// MIDIMessage gains: .channelPressure(channel:UInt8, value:UInt8), .polyPressure(channel:UInt8, note:UInt8, value:UInt8)
// PerformanceEvent gains: .control(controller: UInt8, value: Float), .pitchBend(Float /* -1...1 */), .pressure(Float), .release(note: UInt8, speed: Float /* 0 slow...1 fast, from note-off velocity, default 0.5 */)
public enum Role: String, CaseIterable, Codable { case energy, size, motion, direction, brightness, warmth, colorShift, linger, density, atmosphere, chaos }
public struct RoleValues { public subscript(_ r: Role) -> Double }   // direction -1...1, others 0...1, default 0 (direction 0)
public enum InputFamily: String, CaseIterable, Codable { case keys, playing, sound, dials, listening }
public struct InputID: Hashable, Codable, RawRepresentable { public let rawValue: String; public var family: InputFamily }  // prefix before "."
// constants: .velocity "keys.velocity", .held "keys.held", .pedal "keys.pedal", .softPedal "keys.softPedal", .sostenuto "keys.sostenuto",
// .modWheel "keys.modWheel", .pitchBend "keys.pitchBend", .pressure "keys.pressure", .expression "keys.expression", .releaseSpeed "keys.releaseSpeed",
// .cc(n) "keys.cc<n>", .busyness "playing.busyness", .direction "playing.direction", .leap "playing.leap", .crescendo "playing.crescendo",
// .spread "playing.spread", .repetition "playing.repetition", .silence "playing.silence", .chordMajor/.chordMinor/.chordTense "playing.chord*",
// .attack "sound.attack", .brightness "sound.brightness", .ring "sound.ring", .texture "sound.texture", .loudness "sound.loudness", .width "sound.width",
// .dial(address) "dials.<address>", .level/.bass/.mid/.treble/.beat "listening.*"
public struct InputFrame { public var values: [InputID: Double]; public subscript(_ id: InputID) -> Double }   // missing = 0
public final class InputHub { public init(); public func set(_ id: InputID, _ v: Double, at t: Double); public func frame(at t: Double, listenStrength: Double) -> InputFrame }
// smoothing: rise time 0.03 s, fall 0.25 s (exponential); listening inputs × listenStrength
public enum Target: Codable, Hashable { case role(Role), param(String) }
public enum Curve: String, Codable, CaseIterable { case gentle, linear, snappy }   // x², x, √x; sign-preserving
public struct Link: Codable, Equatable, Identifiable { public var id: UUID; public var input: InputID; public var target: Target; public var amount: Double; public var curve: Curve; public var enabled: Bool }
public struct ReactionMap: Codable, Equatable {
    public var links: [Link]; public var groupStrength: [InputFamily: Double]   // default 1
    public func evaluate(_ f: InputFrame) -> (roles: RoleValues, offsets: [String: Double])
}
public enum ReactionPresets { public static let expressivePianist: ReactionMap }  // others added in Task 10
```
Expressive Pianist links (amount): velocity→energy 1, velocity→size 0.8, held→linger 0.3, pedal→linger 0.9, softPedal→brightness −0.4, modWheel→param "wings.iridescence" 0.8 (ignored by themes without it), pitchBend→direction 1, pressure→energy 0.4, releaseSpeed→motion 0.5, busyness→chaos 0.8, busyness→density 0.6, direction→direction 0.5, leap→motion 0.4, crescendo→brightness 0.6, spread→size 0.3, silence→chaos −0.5, chordMajor→warmth 0.5, chordMinor→warmth −0.5, chordTense→chaos 0.3, attack→motion 0.6, brightness→warmth −0.6, ring→linger 0.5, texture→atmosphere 0.8, loudness→energy 0.5, bass→atmosphere 0.3, beat→energy 0.3, level→brightness 0.2.

- [ ] **Step 1: Write failing tests**
  - Parser: `[0xD0, 90]` gives channelPressure; `[0xA0, 60, 70]` gives polyPressure.
  - PerformanceState:
    - CC1 gives `.control(1, v/127)`.
    - Pitch bend 8192 gives `.pitchBend(0)`; 16383 ≈ 1.
    - Note-off velocity 127 gives `.release(note, 1)`.
    - Update `testOtherMessagesProduceNoEvents` → only `.other` yields `[]`. Ledger the ruling.
  - InputHub:
    - `testRiseIsFastFallIsSlow`: set 1 at t0; at +0.03 ≥ 0.6; set 0; at +0.25 ≈ 0.37 ± 0.05.
    - `testListenStrengthScalesOnlyListening`.
    - `testInputFamilyFromPrefix`.
  - Links:
    - `testCurves`: gentle 0.5 → 0.25, snappy 0.25 → 0.5, sign preserved.
    - `testLinksAddAndClamp`: two links → energy 1.0 clamp.
    - `testDirectionRangeIsSigned`.
    - `testDisabledLinkIgnored`.
    - `testGroupStrengthScales`.
    - `testParamTargetProducesOffset`.
    - `testExpressivePianistVelocityDrivesEnergy`.
    - `testReactionMapCodableRoundTrip`.
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement** as specified.
- [ ] **Step 4: Run.** Expected: pass (whole suite).
- [ ] **Step 5: Commit** `feat(core): inputs, roles and reaction links`.

### Task 3: Playing analysis

**Files:** Create `Sources/InStrumCore/PlayingAnalyzer.swift`; Test `PlayingAnalyzerTests.swift`

**Interfaces — Consumes:** `PerformanceEvent`, `InputHub`. **Produces:**
```swift
public enum ChordQuality: Equatable { case none, major, minor, tense, open }
public struct PlayingAnalyzer {
    public init()
    public mutating func handle(_ e: PerformanceEvent, at t: Double)
    public mutating func publish(to hub: InputHub, at t: Double)   // writes playing.* inputs
    public private(set) var chord: ChordQuality
    public private(set) var keyRoot: Int?                           // 0...11 once ≥ 8 notes heard
}
```
Rules:
- **Chord** uses held pitch classes. Major or minor if they contain a root with +4/+3 and +7. Tense if there is any tritone or minor second. Open if root+7 or root+5 with no third. Otherwise none.
- **direction** = sign-weighted mean of the last 6 melodic intervals (highest held note), normalised by 7 semitones and clamped to ±1.
- **leap** = |last interval| / 12, clamped.
- **busyness** = note-ons in the last 2 s / 24.
- **crescendo** = slope of velocities over the last 2 s, scaled so +0.5 per second gives 1.
- **spread** = (highest − lowest held) / 48.
- **repetition** = the share of the last 8 notes that repeat a 2- to 4-note pattern.
- **silence** = seconds since the last note-on / 8, clamped.
- **key** comes from Krumhansl major/minor profiles over a decaying pitch-class histogram.

- [ ] **Step 1: Write failing tests:**
  - C-E-G gives major; A-C-E gives minor; C-F# gives tense; C-G gives open.
  - A rising scale gives direction > 0.5; falling gives < −0.5.
  - C4 → C5 gives leap 1.0.
  - 24 notes in 2 s gives busyness 1.
  - Velocities rising 40 → 120 over 2 s gives crescendo > 0.5.
  - Holding C2 + C6 gives spread 1.0.
  - The pattern C-D-C-D-C-D-C-D gives repetition > 0.7.
  - 8 s after the last note, silence = 1.
  - C-major scale ×2 gives keyRoot 0.
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run.** Expected: pass.
- [ ] **Step 5: Commit** `feat(core): playing analysis`.

### Task 4: Butterfly Garden model

**Files:** Create `Sources/InStrumCore/ButterflyGarden/ButterflyParams.swift`, `ButterflyGardenModel.swift`, `Sources/InStrumCore/ThemeModel.swift`; Test `ButterflyGardenModelTests.swift`

**Interfaces — Produces:**
```swift
public protocol ThemeModel {
    associatedtype Frame
    static var id: String { get }; static var displayName: String { get }
    static var parameters: [ParamSpec] { get }
    static var macroTargets: [Macro: [(id: String, weight: Double)]] { get }
    init()
    mutating func handle(_ e: PerformanceEvent)
    mutating func step(dt: Double, params: ParameterSet, roles: RoleValues, inputs: InputFrame, quality: QualityLevel) -> Frame
}
public enum QualityLevel: String, Codable, CaseIterable { case lite, high, ultra }   // used here; AutoQuality in Task 5
public struct Butterfly: Equatable { public var position: SIMD3<Float> /* x 0...1, y 0...1 up, z depth 0 near...1 far */; public var size: Float; public var hue: Float; public var flapPhase: Float; public var flapRate: Float; public var style: Int; public var glow: Float; public var landed: Bool; public var homeNote: UInt8? }
public struct Bloom: Equatable { public var x: Float; public var openness: Float; public var hue: Float; public var age: Float }
public struct GardenFrame { public var butterflies: [Butterfly]; public var blooms: [Bloom]; public var keys: [KeyVisual]; public var sunHeight: Float; public var rays: Float; public var mist: Float; public var breeze: SIMD2<Float>; public var pollen: Float; public var petals: Float; public var fireflies: Float; public var warmth: Float; public var exposure: Float; public var spiral: Float; public var cameraZoom: Float; public var timeOfDay: String }
public struct ButterflyGardenModel: ThemeModel { public typealias Frame = GardenFrame }  // id "butterfly-garden", "Butterfly Garden"
```
**Parameters** (ids → spec §7.2, ★ = hero):
- wings.style★ choice [Mix, Monarch, Glasswing, Morpho Blue, Moth, Origami, Crystal, Neon, Petal]
- wings.mix slider 0…1
- butterflies.max★ integer 20…1200 (default 300)
- size.min 0.2…1 / size.max 0.5…2.5
- flutter.speed★ 0.2…3
- wings.iridescence★ 0…1
- wings.shimmer
- trail.length 0…1, trail.glow
- lifespan 2…60 s
- flocking 0 drift…1 swarm
- land.onHeld toggle
- color.source choice [Pitch, Chord, Velocity, Palette]
- spawn.rate 0.2…1
- chord.spiral 0…1
- spawn.minVelocity 0…0.5
- flowers.types choice [Mixed, Roses, Poppies, Lotus, Wildflowers, Cherry Blossom]
- bloom.speed★ 0.2…3
- bloom.lifetime 2…60
- petals 0…1, breeze.strength 0…1, breeze.direction −1…1
- foliage 0…1, pollen.sparkle 0…1, fireflies toggle
- time★ choice [Dawn, Morning, Golden Hour, Dusk, Moonlight]
- sun.angle 0…1
- rays★ 0…1, mist 0…1, dof 0…1, glow 0…1, grain 0…1
- grade choice [Natural, Warm Film, Cool Film, Dreamy, Vivid]
- camera.motion choice [Still, Drift, Follow melody], camera.zoom 0.8…1.4, parallax 0…1
- keys.show toggle, keys.height 0.1…0.35
- keys.finish choice [Lacquer, Satin, Ivory, Brushed metal, Gold, Pearl], keys.glowColor color

Macro targets:
- intensity → rays, glow, size.max
- speed → flutter.speed, bloom.speed
- density → butterflies.max, petals, pollen.sparkle
- glow → glow, trail.glow
- chaos → flocking, chord.spiral
- temperature → grade warmth (via `warmth` output)

Behaviour (spec §6.4/§7):
- **On note-on (≥ spawn.minVelocity, in 88-key range):** spawn at the key's x, y 0.08. Size = lerp(size.max, size.min, pitch 0…1) × (0.6 + 0.8 × velocity). flapRate = flutter.speed × (1 + pitch). Hue comes from color.source.
- **Held notes:** with land.onHeld or always, the butterfly hovers at y 0.15–0.3 above its key.
- **On note-off:** the butterfly flies off with an upward/outward velocity scaled by `.release` speed.
- **Pedal / Linger role:** multiplies flapRate by (1 − 0.6 × linger) and trail persistence by (1 + 2 × linger).
- **Chord:** spiral = 1, decaying with half-life 0.8 s. The swarm orbits the chord's centre.
- **Direction role:** shifts the flock target y.
- **Silence ≥ 4 s:** butterflies land (landed = true, flapRate × 0.1) and blooms open.
- **Blooms:** a bloom is created at each melody note's x. Openness grows at bloom.speed; it dies after bloom.lifetime.
- **Cap:** at max count, the oldest non-held butterfly is removed. Quality caps: Lite 200, High 600, Ultra 1,200, combined with min(butterflies.max).
- **Timing:** all motion is deterministic given dt (seeded RNG, seed 42), so tests and previews are stable.

- [ ] **Step 1: Write failing tests**
  - `testHarderNoteMakesBiggerButterfly`.
  - `testLowNoteBiggerThanHigh`.
  - `testHeldNoteHoversAboveItsKey`: x within ±0.02 of the key centre, y 0.15…0.3 after 2 s.
  - `testPedalSlowsWings`: flapRate with linger 1 ≤ 0.45 × without.
  - `testChordStartsSpiral`.
  - `testSilenceLandsButterflies` (5 s with no notes → all landed).
  - `testBloomAppearsWhereMelodyLands`.
  - `testCountCapHolds` (2,000 notes, High → ≤ 600).
  - `testQualityLiteCaps200`.
  - `testOutOfRangeNoteSpawnsNothing`.
  - `testAllNotesOffReleasesHovering`.
  - `testBurstStepsWithinBudget` (2,000 note-ons + 1 step < 8 ms).
  - `testParameterIdsUniqueAndDefaultsValid` (generic helper reused for every theme).
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run.** Expected: pass.
- [ ] **Step 5: Commit** `feat(core): Butterfly Garden model`.

### Task 5: Render stack, flash safety and auto quality

**Files:** Create `Sources/InStrumCore/FlashLimiter.swift`, `AutoQuality.swift`, `Sources/InStrumApp/Visuals/RenderStack.swift`, `PostShaders.swift`, `ThemeRenderer.swift`; Tests `FlashLimiterTests.swift`, `AutoQualityTests.swift`, `Tests/InStrumAppTests/RenderStackTests.swift`

**Interfaces — Produces:**
```swift
public struct FlashLimiter { public init(gentle: Bool = false); public var gentle: Bool
    public mutating func limit(exposure: Float, sparkle: Float, dt: Double) -> (exposure: Float, sparkle: Float) }
// A "large flash" = exposure rising > 0.25 within 0.1 s. After 3 in the trailing 1 s, rises are rate-limited to 0.25/s until the window clears. Gentle multiplies sparkle and any rise by 0.5.
public enum QualitySetting: String, Codable, CaseIterable { case auto, lite, high, ultra }
public struct AutoQuality { public init(setting: QualitySetting); public var setting: QualitySetting
    public mutating func record(frameTime: Double) -> QualityLevel }  // auto: start high; avg fps < 55 over 2 s → step down; ≥ 10 s at fps ≥ 58 → step up
@MainActor final class RenderStack {   // App
    init?(device: MTLDevice, pixelFormat: MTLPixelFormat)
    func resize(width: Int, height: Int)                          // 0 → no-op
    var hdrTarget: MTLTexture? { get }; var depthTarget: MTLTexture? { get }
    func post(into pass: MTLRenderPassDescriptor, commandBuffer: MTLCommandBuffer, settings: PostSettings)
}
struct PostSettings { var bloom: Float; var dof: Float; var focusDepth: Float; var grade: Int; var grain: Float; var vignette: Float; var exposure: Float; var warmth: Float; var quality: QualityLevel }
protocol ThemeRenderer: AnyObject { func render(into stack: RenderStack, commandBuffer: MTLCommandBuffer, time: Double) ; var post: PostSettings { get } }
```
Post chain: HDR (rgba16Float) scene → bright-pass → 5-level downsample/upsample bloom (Lite: 3 levels at half resolution) → DoF gather using the depth texture (skipped on Lite) → grade (5 LUT-free curves from the spec) + warmth → ACES tone map → grain + vignette → drawable.

- [ ] **Step 1: Write failing tests**
  - `testStrobeLimitedToThreeFlashesPerSecond` (10 Hz 0↔1 exposure for 3 s → counted flashes per 1 s window ≤ 3).
  - `testSmoothSwellUnaffected`.
  - `testGentleHalvesSparkle`.
  - `testAutoStepsDownAfterTwoSlowSeconds`.
  - `testAutoStepsUpAfterTenGoodSeconds`.
  - `testFixedSettingNeverChanges`.
  - App (skip if no Metal): `testPostShadersCompile`, `testResizeAllocatesTargets`, `testResizeToZeroIsHarmless` (RF5).
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run.** Expected: pass.
- [ ] **Step 5: Commit** `feat: HDR render stack, flash safety, auto quality`.

### Task 6: Butterfly Garden renderer and preview frames

**Files:** Create `Sources/InStrumApp/Visuals/ButterflyRenderer.swift`, `ButterflyShaders.swift`, `PreviewRenderer.swift`, `Sources/InStrumCore/ScriptedPerformance.swift`; Tests `Tests/InStrumAppTests/ButterflyRendererTests.swift`, `PreviewRenderTests.swift`; Modify `.github/workflows/build.yml`

**Interfaces — Consumes:** `GardenFrame` (Task 4), `RenderStack`/`ThemeRenderer` (Task 5). **Produces:**
```swift
final class ButterflyRenderer: ThemeRenderer { init?(device: MTLDevice, stack: RenderStack); func update(_ frame: GardenFrame, params: ParameterSet) }
public enum ScriptedPerformance { public static let demo: [(time: Double, message: MIDIMessage)] }  // 12 s: soft notes, hard notes, held chord + pedal, fast run, crescendo, 5 s silence
final class PreviewRenderer { init?(width: Int, height: Int); func renderPNGs<T: ThemeModel>(_ type: T.Type, renderer: (MTLDevice, RenderStack) -> ThemeRenderer?, times: [Double], to dir: URL) throws }
```
Look and layers, back to front:
1. Sky gradient by time of day (Dawn rose-peach, Morning pale blue, Golden Hour amber, Dusk violet-coral, Moonlight deep indigo) with a sun or moon disc.
2. Distant foliage silhouettes (3 parallax layers, fbm noise edges).
3. God-rays: screen-space radial blur from the sun, strength = rays × exposure.
4. Meadow band with blooms (SDF petal flowers per type, opening by openness).
5. Butterflies: instanced; each is two hinged wing quads in the vertex shader, flap = sin(phase). Fragment wing patterns are procedural per style (Monarch veins + orange/black + white dots; Glasswing transparent with dark edges; Morpho iridescent blue with a thin-film hue shift by view angle × iridescence; Moth dusty soft; Origami flat-shaded facets; Crystal refractive highlights; Neon emissive outlines; Petal soft gradient). Depth goes into the depth texture for DoF.
6. GPU particles: pollen, petals, fireflies (compute shader, count by quality: Lite 2k, High 8k, Ultra 24k).
7. Keyboard strip (reuses the key instancing with a finish-dependent shader).

Post settings come from params plus roles: exposure = 0.9 + 0.4 × energy; warmth from the grade and the warmth role.

- [ ] **Step 1: Write failing tests** (skip if no Metal device):
  - `testButterflyShadersCompile`.
  - `testRendersNonBlackFrame`: renders `ScriptedPerformance.demo` at t=3 s into a 640×360 offscreen target; mean luminance > 0.05, and the pixel variance shows structure.
  - `testPreviewWritesPNGs` (when env `PREVIEW_DIR` is set, writes `butterfly-t{1,3,5,8,11}.png` at 1280×720 and `steinway-t3.png`).
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement** the renderer, shaders and preview writer (`CGImageDestination` PNG).
- [ ] **Step 4: Add the CI `previews` job.** Runs on `macos-15` after `test`, on pushes to `m3a`. It runs `PREVIEW_DIR=$PWD/previews swift test --filter PreviewRenderTests`, then commits the PNGs to the orphan branch `previews` (force-push, `contents: write`).
- [ ] **Step 5: Run.** Expected: tests pass; `git fetch origin previews` gives 6 PNGs. **Look at every frame** (Read the PNGs). Iterate on the shaders until the garden reads as beautiful at each time: soft dawn, hard notes, chord spiral, run, silence landing. Each iteration is ledgered as `Task 6: look iteration N: <what changed>`.
- [ ] **Step 6: Commit** `feat(app): Butterfly Garden renderer and preview frames`.

### Task 7: Scene director, Midnight Steinway on the new engine, theme switching

**Files:** Create `Sources/InStrumCore/SceneDirector.swift`, `MidnightSteinway/MidnightSteinwayModel.swift`, `ThemeRegistry` (in `ThemeModel.swift`), `Sources/InStrumApp/Visuals/SteinwayRenderer.swift` (from `SceneRenderer.swift`); Modify `MetalCanvas.swift`, `AppModel.swift`; Test `SceneDirectorTests.swift`

**Interfaces — Produces:**
```swift
public enum ThemeRegistry { public static let all: [(id: String, name: String)]   // [midnight-steinway, butterfly-garden]
    public static func resolve(_ id: String) -> String }                            // unknown → "midnight-steinway"
public final class SceneDirector {
    public init(themeID: String, state: ThemeState, reaction: ReactionMap)
    public private(set) var themeID: String
    public func switchTheme(to id: String, state: ThemeState)     // fresh model, carries no held notes
    public func handle(_ events: [PerformanceEvent], at t: Double)
    public func step(dt: Double, t: Double, quality: QualityLevel) -> Any   // GardenFrame or SteinwayFrame
    public var parameters: ParameterSet; public var reaction: ReactionMap
    public let hub: InputHub
}
// MidnightSteinwayModel: ThemeModel wrapping MidnightSteinwayScene. Params: spot.width, spot.warmth, lacquer.sheen, bloom★, haze★, keys.finish, glow★. Roles: energy→exposure, linger→pedal half-life, brightness→spot intensity.
```
AppModel keeps `drainEvents`; MetalCanvas owns `SceneDirector` and picks the renderer by `themeID`. `AppModel` gains `@Published themeID`, `setTheme(_:)`, `themeState(for:)`, `saveThemeState(_:for:)`, `quality`, `gentleVisuals`.

- [ ] **Step 1: Write failing tests:**
  - `testDirectorRoutesEventsToTheme`.
  - `testVelocityReachesEnergyRole`.
  - `testSwitchingThemeWhileHoldingIsClean` (RF1): hold 3 notes + pedal, switch → the new frame has no pressed keys and no hovering butterflies.
  - `testUnknownThemeFallsBack` (RF3).
  - `testThemeStateRestoredOnReturn`.
  - `testMidnightSteinwayParametersValid` (generic helper).
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement** and port the existing Steinway drawing onto `RenderStack` (its look unchanged at default params).
- [ ] **Step 4: Run.** Expected: pass; previews now include Steinway.
- [ ] **Step 5: Commit** `feat: scene director and theme switching`.

### Task 8: Front settings panel

**Files:** Create `Sources/InStrumApp/Views/SettingsPanel.swift`, `ParamControl.swift`; Modify `MainView.swift` (the ⚙ popover becomes "Sound" settings; a new ✦ **Visuals** button and the **S** key toggle the panel)

**Interfaces — Consumes:** `AppModel` theme APIs (Task 7), `ParamSpec`. **Produces:** `struct ParamControl: View` (slider / stepper / toggle / segmented-or-menu / ColorPicker / gradient row of ColorPickers), `struct SettingsPanel: View`.

Panel (right side, 340 pt, `.ultraThinMaterial`), top to bottom:
- theme picker
- six macro sliders (centre-detented)
- the theme's ★ hero settings
- Quality (Auto / Lite / High / Ultra)
- Gentle visuals
- **Reset theme**

Every change is saved through `AppModel.saveThemeState` (debounced 0.5 s).

- [ ] **Step 1: Write failing test** `Tests/InStrumAppTests/SettingsPanelTests.swift`: `testHeroSpecsSelectedForPanel` (a helper `SettingsPanel.heroSpecs(for:)` returns only `hero == true` in declaration order), `testValueEditWritesThemeState`.
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run.** Expected: pass; build green.
- [ ] **Step 5: Commit** `feat(app): visuals settings panel`.

### Task 9: Installer and app icon

**Files:** Create `Packaging/AppIcon.svg`, `Packaging/dmg-background.svg`, `Packaging/dmg_settings.py`, `Scripts/make-dmg.sh`; Modify `Scripts/make-app.sh` (icon), `Packaging/Info.plist` (`CFBundleIconFile` AppIcon, `NSSupportsAutomaticGraphicsSwitching` true, `NSMicrophoneUsageDescription`), `.github/workflows/build.yml`

- **Icon:** an original golden butterfly whose wings are formed from stylised piano keys (ivory/black stripes inside gold outlines), on a deep black-lacquer rounded square with a warm amber glow. Render it with `rsvg-convert` to the 10 iconset sizes, then `iconutil -c icns`.
- **DMG background:** 660×400 (@1x and @2x). Midnight warm gradient (#0B0907 → #1A130C), a faint lacquer sheen, a gold calligraphic arrow from left (icon at 165,190) to right (Applications at 495,190), and the small caption "Drag to install". Use `dmgbuild` with `icon_locations`, `background`, `icon_size 128`, a hidden toolbar, and a window of 660×400.

- [ ] **Step 1: Add a verification step to CI** (it fails first because nothing exists yet): mount the dmg with `hdiutil attach -nobrowse`, then assert:
  - `In Strum Meants.app` exists
  - `Applications` is a symlink to `/Applications`
  - `.background/` exists
  - `Contents/Resources/AppIcon.icns` exists
- [ ] **Step 2: Run.** Expected: FAIL (no dmg).
- [ ] **Step 3: Implement** the art and scripts. CI installs `librsvg` via brew and `dmgbuild` via pip. The release step uploads both the `.dmg` and the `.zip`.
- [ ] **Step 4: Run.** Expected: pass. The dmg is attached to the workflow artifact; render `dmg-background.svg` and `AppIcon.svg` to PNGs in the `previews` job too, and look at them.
- [ ] **Step 5: Commit** `feat: dmg installer and app icon`.

### Task 10: Release A

- [ ] Run the full suite on `m3a`; review the preview frames one last time.
- [ ] Merge `m3a` → `main` (fast-forward) and push. Expected: Release `build-N` with `.dmg` + `.zip`.
- [ ] Ledger: `Release A: build-N`. Message Michael with the install steps and the eye checklist (smoothness, soft vs hard, held/pedal hover, chord spiral, silence landing, theme switch, settings panel, installer).
- [ ] Continue on `m3a` with Release B (no waiting).

---

# Release B — Presets, mapping, sound, dials, Listen, hands-free

### Task 11: Presets, Surprise me, morph

**Files:** Create `Sources/InStrumCore/Presets.swift`; extend `ReactionPresets.swift`; Create `Sources/InStrumApp/Views/PresetBar.swift`; Test `PresetsTests.swift`

**Interfaces — Produces:**
```swift
public struct LookPreset: Codable, Equatable { public var name: String; public var themeID: String; public var state: ThemeState; public var favourite: Bool; public var version: Int = 1 }
public struct ReactionPreset: Codable, Equatable { public var name: String; public var map: ReactionMap; public var favourite: Bool; public var version: Int = 1 }
public final class PresetStore { public init(directory: URL)
    public func looks(for themeID: String) -> [LookPreset]; public func reactions() -> [ReactionPreset]
    public func save(_ p: LookPreset) throws; public func save(_ p: ReactionPreset) throws
    public func delete(look name: String, themeID: String) throws; public func delete(reaction name: String) throws
    public private(set) var unreadable: [String] }                       // file names skipped
public enum Surprise { public static func look(specs: [ParamSpec], seed: UInt64) -> ThemeState }
public func morph(_ a: ThemeState, _ b: ThemeState, specs: [ParamSpec], t: Double) -> ThemeState   // numbers/colours/gradient stops lerp; choice/bool switch at 0.5
// Built-ins: ReactionPresets.calmAmbient, synthExplorer, musicParty, minimal, wild, all: [ReactionPreset]
// Butterfly looks: Monarch Morning, Morpho Dream, Golden Hour Meadow, Moonlit Moths, Crystal Garden, Neon Night (ButterflyGardenModel.builtInLooks)
```
- [ ] **Step 1: Write failing tests:**
  - Round-trip save/load.
  - A damaged file is listed in `unreadable` and the others still load.
  - Surprise values stay within `surprise` ranges for 100 seeds.
  - Surprise never touches specs with `surprise == nil`.
  - Morph at 0/1 equals the ends; at 0.5 sliders are the midpoint and choices take b.
  - All built-in reaction presets evaluate within range in both themes.
  - Built-in looks are valid against specs.
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement** the store plus a preset bar in the panel (Look menu with favourites ★, Save as…, Surprise me, morph slider A↔B; Reaction menu).
- [ ] **Step 4: Run.** Expected: pass.
- [ ] **Step 5: Commit** `feat: look and reaction presets`.

### Task 12: Advanced — All settings and Mapping editor

**Files:** Create `Sources/InStrumApp/Views/AllSettingsView.swift`, `MappingEditor.swift`; Test `Tests/InStrumAppTests/MappingEditorTests.swift`

**Interfaces — Consumes:** `ParameterSet`, `ReactionMap`, `InputID`, `Target`. **Produces:** helpers `MappingEditor.targets(for themeID: String) -> [Target]` (all roles + every slider param of the theme) and `MappingEditor.groups(_ map: ReactionMap) -> [(InputFamily, [Link])]`.

- **All settings:** searchable, grouped, Reset per setting/group.
- **Mapping:** grouped rows `[on] input → [target ▾] amount ▬ curve ▾ ✕`, + Add link, group strength sliders, Save as Reaction preset. Inputs list includes live dial names (Task 14) and CCs seen this session.
- [ ] **Step 1: Write failing tests:** targets include all 11 roles plus theme sliders; grouping is by family in `InputFamily.allCases` order; editing a link's target persists in `AppModel.reaction`.
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run.** Expected: pass.
- [ ] **Step 5: Commit** `feat(app): advanced settings and mapping editor`.

### Task 13: Instrument sound character

**Files:** Create `Sources/InStrumAudio/SoundCharacter.swift`; Modify `AudioEngine.swift` (tap on the instrument node output, separate from the level tap; feeds the analyser on the tap thread); Test `Tests/InStrumAudioTests/SoundCharacterTests.swift`

**Interfaces — Produces:**
```swift
public struct SoundReading: Equatable { public var attack, brightness, ring, texture, loudness, width: Double }   // 0...1
public final class SoundCharacterAnalyzer { public init(sampleRate: Double)
    public func process(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int)
    public func noteOn(at t: Double); public func noteOff(at t: Double)
    public var reading: SoundReading { get } }      // lock-protected
// AudioEngine: public var onSoundReading: ((SoundReading) -> Void)?   (called ≤ 60 Hz)
```
Definitions:
- **attack** = 1 − clamp((time from onset to RMS peak − 5 ms) / 300 ms).
- **brightness** = spectral centroid / 5 kHz (FFT 2048, Hann).
- **ring** = RMS decay time to −30 dB after note-off / 3 s.
- **texture** = spectral flatness.
- **loudness** = RMS dBFS mapped −60…0 → 0…1.
- **width** = side/mid energy ratio, clamped.

AppModel publishes the reading into `InputHub` as `sound.*`.
- [ ] **Step 1: Write failing tests** on synthetic buffers:
  - A click has attack > 0.8; a 400 ms swell has attack < 0.3.
  - A 200 Hz sine has brightness < 0.15; a 6 kHz sine has > 0.8.
  - White noise has texture > 0.6; a sine has < 0.1.
  - A 2 s exponential decay has a larger ring than a 0.1 s decay.
  - Mono gives width ≈ 0; anti-phase gives width ≈ 1.
  - Silence gives loudness 0.
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement** with vDSP.
- [ ] **Step 4: Run.** Expected: pass.
- [ ] **Step 5: Commit** `feat(audio): instrument sound character`.

### Task 14: Instrument dials

**Files:** Create `Sources/InStrumAudio/DialReader.swift`; Test `DialReaderTests.swift`

**Interfaces — Produces:**
```swift
public struct DialInfo: Equatable { public let address: UInt64; public let name: String }
public final class DialReader { public init(audioUnit: AUAudioUnit)
    public var dials: [DialInfo] { get }                    // flattened parameter tree, display names
    public var onChange: ((DialInfo, Double) -> Void)?       // normalised 0...1 via min/max
    public func currentValues() -> [UInt64: Double] }
```
AppModel creates one per loaded instrument and writes `dials.<address>` inputs; the Mapping editor shows `Instrument: <name>`.
- [ ] **Step 1: Write failing tests** with Apple's AUSampler (`aumu`/`samp`/`appl`): dials non-empty with names; changing a parameter value fires `onChange` with the normalised value. With a plugin that has no parameters (DLS), the list is empty and nothing crashes.
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement** with `parameterTree.token(byAddingParameterObserver:)` and `allParameters`.
- [ ] **Step 4: Run.** Expected: pass.
- [ ] **Step 5: Commit** `feat(audio): instrument dial reader`.

### Task 15: Listen — Mac audio and microphone

**Files:** Create `Sources/InStrumAudio/AudioFeatures.swift`, `MacAudioListener.swift`, `MicListener.swift`, `Sources/InStrumApp/Views/ListenControls.swift`; Test `AudioFeaturesTests.swift`

**Interfaces — Produces:**
```swift
public struct ListenReading: Equatable { public var level, bass, mid, treble, beat: Double; public var tempo: Double? }
public final class AudioFeatureExtractor { public init(sampleRate: Double); public func process(_ mono: UnsafePointer<Float>, frames: Int, at t: Double); public var reading: ListenReading { get } }
// bands: <250 Hz, 250 Hz–4 kHz, >4 kHz (FFT 2048, normalised with slow auto-gain); beat = spectral-flux onset pulse decaying 150 ms; tempo from onset autocorrelation 60–180 BPM
public final class MacAudioListener { public init(); public func start(onReading: @escaping (ListenReading) -> Void) async throws; public func stop() }
// SCStream: SCContentFilter(display:excludingApplications:[self app]), config.capturesAudio = true, excludesCurrentProcessAudio = true, minimal 2×2 video at 1 fps
public final class MicListener { public init(); public func start(onReading: @escaping (ListenReading) -> Void) throws; public func stop() }
public enum ListenPermission { case granted, denied, notDetermined }
// AppSettings gains listenMac: Bool = false, listenMic: Bool = false, listenStrength: Double = 0.6
```
UI (in the panel): 🎹 Instrument (always on, informational), 🔊 Mac audio, 🎙 Microphone toggles, Listen strength. On denial a toggle shows **Allow in System Settings** (opens `x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture` / `?Privacy_Microphone`). The two sources are blended by max per field.
- [ ] **Step 1: Write failing tests:**
  - A 60 Hz sine gives bass > 0.7 and treble < 0.1.
  - An 8 kHz sine gives treble > 0.7.
  - A 120 BPM click track over 8 s gives tempo 120 ± 3 and beat pulses aligned within 30 ms.
  - Silence gives level 0.
  - Toggles default off and persist.
  - The Build 2 settings test still passes.
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement.** On a capture error the listener auto-restarts once after 2 s; if it fails again, the toggle shows "reconnecting…" and retries every 10 s.
- [ ] **Step 4: Run.** Expected: pass.
- [ ] **Step 5: Commit** `feat: listen to Mac audio and microphone`.

### Task 16: Hands-free control

**Files:** Create `Sources/InStrumCore/ControlBindings.swift`, `Sources/InStrumApp/Views/ControlsView.swift`; Modify `OnScreenKeyboard.swift`/`MainView.swift` (shortcut monitor), `AppModel.swift` (MIDI-learn intercept before send); Test `ControlBindingsTests.swift`

**Interfaces — Produces:**
```swift
public enum ControlAction: String, Codable, CaseIterable { case nextTheme, previousTheme, nextLook, previousLook, nextReaction, previousReaction, surprise, toggleControls, fullScreen, panic, listenStrength, macroIntensity, macroSpeed, macroDensity, macroGlow, macroChaos, macroTemperature }
public enum ControlSource: Codable, Hashable { case cc(channel: UInt8, number: UInt8), note(channel: UInt8, number: UInt8) }
public struct ControlBindings: Codable, Equatable {
    public var map: [ControlSource: ControlAction]
    public mutating func beginLearning(_ a: ControlAction); public var learning: ControlAction?
    public mutating func consume(_ m: MIDIMessage) -> (consumed: Bool, fired: ControlAction?, value: Double?) }
public enum ShortcutMap { public static func action(for key: String, modifiers: Bool) -> ControlAction? }
// ← → themes, [ ] looks, ; ' reactions, r surprise, f full screen, h controls, s panel (handled by view), Esc panic; nil when modifiers held
```
- `consume` behaviour:
  - While learning, the next CC or note-on binds and is consumed.
  - A bound note-on/off is consumed and never sent to the instrument.
  - A bound CC fires a continuous action with value/127, or a discrete action on rising past 64.
- `AppModel.handleMIDI` runs `consume` (under the existing lock) before `engine.send`.
- [ ] **Step 1: Write failing tests:**
  - Learning binds the next CC.
  - A bound note is not sent (FakeEngine `sent` is empty).
  - A CC above 64 fires a discrete action once per press.
  - A continuous CC gives a value.
  - Bindings round-trip Codable.
  - The shortcut map returns nil with modifiers, and `.panic` for Esc.
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement**, plus the Controls tab (list with Learn / Remove).
- [ ] **Step 4: Run.** Expected: pass.
- [ ] **Step 5: Commit** `feat: shortcuts and MIDI-learn`.

### Task 17: Release B and final review

- [ ] Full suite green; preview frames re-checked; final whole-branch review (fresh reviewer, most capable available model) with this plan's Review Focus; fix Critical/Important with RED→GREEN tests.
- [ ] Merge `m3a` → `main`; Release `build-N` (.dmg + .zip).
- [ ] Message Michael: what's new, install steps, eye-and-ear checklist (spec §14), deferred minors, rulings.
