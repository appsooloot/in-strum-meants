# Small Wins (Keep That, Sleep Fade, Hold the Moment, Breathing Ambience, Reduce Motion, the Chime in Key) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Six small wins for every world: keep a take as MIDI, a sleep fade to night and silence, the soft pedal holding the moment, breathing beds, the Mac's Reduce Motion followed, and the lounge's chime in key.

**Architecture:**
- **Takes** stay in Core's memory until Keep writes them.
- **Time** belongs to `SceneDirector`. Each frame it takes one `SceneControls` and returns one `SceneReport`. It turns hold, sleep dim and Reduce Motion into the sky's, world's and renderers' dt, an exposure scale and the breathed ambience.
- **Sound:** the sleep gain is a run-time input volume on the two buses, and the chime reads the temple bell's key.

**Tech stack:** Swift 6.1 (Swift 5 mode), SwiftUI, AppKit, AVFoundation, C++17 (`-O2`), SwiftPM, XCTest. Metal is untouched.

**Spec:** `docs/superpowers/specs/2026-11-04-small-wins-design.md` (section numbers below refer to it).

**Builds on:** `sets-11-12` at 4db63eb, merged in whenever it moves.
- **Sets 9 & 10's key input:** `AmbienceScene.key`, `isd_ambience_set_key(ISDAmbience*, int root, int major)`, and the bell's `isd_ambience_debug_bell_hz`, which never retunes mid-ring.
- **Deep Water's ambience** (`s11-amb`) is unmerged. It brings `AmbienceSource.sonar, .hullCreak, .whaleSong, .bubbles, .snappingShrimp, .fishChorus` and `AmbienceScene.bubbleBurst`, so Task 8 names those sources by raw value.

## Global constraints

The Sets 7 & 8 plan's Global constraints hold. So do the standing rules (spec §1), each defended by a test:
- **Personal use.**
- **Older settings and saves still load.** New fields use `decodeIfPresent` with a default, clamped like their neighbours.
- **Every world stays smooth on Smooth:** no new GPU pass, and no shader change.
- **Flashes go through `FlashLimiter`.** Held time adds none.
- **Nothing is written to disk until the player asks:** takes live in memory, the folder is made on the first keep, and the sleep timer is never saved.
- **The CI test budget is 8 minutes** for the whole suite (about 2.5 now): renders at 640 × 360 with at most six captures a test, and no test simulates over 45 minutes of Core time or 2 minutes of ambience audio.

In addition:
- **No toolchain.** The agents' machines have no Swift toolchain, and CI (GitHub Actions) is down.
  - **Every agent is its own Swift 6.1 compiler** (Swift 5 mode): check calls, `private`/`private(set)` across files, actor isolation (`AppModel` is `@MainActor`; its `nonisolated` members touch only its locks) and exhaustive switches by hand.
  - **DSP bounds** are measured on the C++ mirror harness (`$SP/amb9/build.sh prog.cpp out <worktree> g++|clang++` with `h9.hpp`; `$SP` as in the Sets 7 & 8 plan) under both compilers, with the values in the commit message.
  - **Shaders:** none is planned; any change passes `python3 -I Scripts/mslcheck/mslcheck.py <root>`.
  - **Numeric Core bounds** are checked on a Python mirror (`python3 -I`). `$SP/sw/breath.py` gives the breath's: at level 0.8 over seeds 1–8 and all 15 beds, ≥ 11 mean crossings in 10 minutes and no flat run over 17 s; at seed `0xB4EA7E`, no pair above 0.56 correlation.
- **Names and copy:**
  - **Takes:** `~/Music/In Strum Meants/Takes/YYYY-MM-DD HH.mm — <set or world name>.mid`, plus a `.json`.
  - **The Play menu:** "Keep That" (⌘K), "Keep the Last 10 Minutes", "Hold the Moment" (⌘⇧H).
  - **The main bar:** `bookmark`, `hourglass`, and `moon` (`moon.fill` while running, with "23 min", then "45 s").
  - **Sound & MIDI:** "Keyboard layout"; "Hold the moment with" (Soft pedal / Sostenuto pedal / Off).
  - **The visual settings:** "Ambience breathes" and "Breathing depth" (World); "Follow the Mac's Reduce Motion" (Display).
  - **Toasts:** "Kept · 4:12", "Nothing to keep yet", "Couldn't save the take", "You're awake."
  - **Hooks:** `isd_ambience_debug_strike_chime`, `isd_ambience_debug_chime_hz`.
- **Branches** come from `small-wins`, which Task 0 cuts.
- **Pushes** retry up to 5 times, 15 s apart, past GitHub's intermittent 500s.
- **Commits** end with exactly:
  ```
  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01ULKkTMxvdQ8D5dSkwTFLPe
  ```

## Review focus

1. **The ring's edges:** two hours at the 250,000 cap, a take reaching past the oldest event, notes held across a take's edges, and the gesture's late note-offs. Pinned in Task 1.
2. **The gesture misfiring:** trills, runs, chords containing the three keys and a third tap never fire it, and it follows a narrower keyboard. Pinned in Tasks 1 and 2.
3. **A hold left on:** 30 minutes held in real time glides back to the true sky; quick mode resumes where it stopped; a world switched to while held stays still; panic ends the pedal's hold, not a latched one. Pinned in Task 3.
4. **Waking at the fade's edges:** a wake in the last second, after the end or mid-wake, or a new time chosen while dim, all glide back over 3 s. The saved volumes survive a mid-fade autosave. Pinned in Tasks 5 and 6.
5. **Older settings and sets:** settings without the new keys, or with bad values, load, and applying a set leaves breathing alone. Pinned in Tasks 0 and 8.
6. **Flashes:** none while held, and the wake's exposure rise stays inside `FlashLimiter`'s rule. Pinned in Tasks 3, 5 and 7.

## Rulings recorded while planning

Each ruling notes what it costs if it turns out wrong.
- **Seams first:** Task 0 lands every shared-file change (settings, controls and report, canvas wiring, gain, toast, slots, `AppModel` access); the spec's `SceneDirector.sleepDim` is `controls.sleepDim`. Cost: none.
- **"Keyboard layout" had no range** (`KeyboardLayout` is fixed at A0–C8), so Task 0 adds `KeyboardRange`. Cost: one picker; without it a 61-key keyboard can't reach the gesture.
- **Takes record what the instrument heard** (raw, after the touch curve, the spec's kinds only) and end at min(now, last event + 2 s), with pedals, bend and pressure at tick 0. Cost: one constant.
- **"Exact in milliseconds" means within half a tick** (0.92 ms at 68 BPM, the slowest credit); ticks round from absolute times. Cost: none at these tempos.
- **A tap is the three keys alone within 80 ms;** two taps start ≤ 1.5 s apart, a third starts a new count, and the taps are erased. Cost: two constants.
- **Keeps never overwrite** (`… 2`); the title is the set's name while its world shows. Cost: none.
- **The sleep gain is the buses' input volume** on the main mixer, after the level tap, so saved volumes never see it. Cost: none.
- **Sleep curves:** gain 0.001 + 0.999·cos²(πp/2), then silence; dim sin²(πp/2); a linear 3 s wake; afterwards the world rests dim and silent, timer Off, until input. Cost: one function.
- **`sleepDim` slides the sun toward min(altitude, −14°),** so Deep night stays at −30°. Cost: one line.
- **Held time also freezes reactions;** release eases over a 0.6 s smoothstep, and the real-time sky glides back over it. Cost: one function.
- **Notes born in held time start at their bloom,** or ripples, traced lines and butterflies would be invisible. Cost: one constant per visual.
- **Breathing lives in `AppSettings.breath`,** since sets carry `AmbienceSettings` and `applySet` overwrites it. Cost: moving two fields.
- **Exactly the spec's fifteen beds breathe,** by raw value; one-shots and other sources don't. Cost: one table.
- **The breath:** P₁ 40–90 s, P₂ = P₁ × 1.35–1.75, quantised to 0.01, on real time so it breathes through holds. Cost: one line.
- **Reduce Motion halves the renderers' dt,** not the Core world's, and pins Galaxy Warp at its 0.1 drift. Cost: one factor.
- **The chime plays the key's pentatonic in MIDI 75–87;** bit 32 marks a sensed key (before one, today's six), and a strike with all 4 slots ringing takes the oldest. Cost: one table.
- **The chime is tested on its struck f0** and keeps its 0.8 send. Cost: dropping it to 0.3 if it sounds off.
- **Merge into `sets-11-12`, not `main`.** Cost: a rebase.
- **RED by construction**, as before. Cost: none.

## File structure

| Path | Responsibility |
|---|---|
| `Sources/InStrumCore/SceneControls.swift` | New: `HoldPedal`, `KeyboardRange`, `AmbienceBreathSettings`, `SceneControls`, `SceneReport` |
| `Sources/InStrumCore/AppSettings.swift` | The four new settings |
| `Sources/InStrumCore/SceneDirector.swift` | Controls in, report out; hold, ease, sleep dim; `visualDt`, `exposureScale`; the breathed scene |
| `Sources/InStrumCore/{Sky/LivingSky,Inputs,Worlds/GalaxyWarp}.swift` | `step(…, dim:)`; `InputID.reduceMotion`; the drift |
| `Sources/InStrumCore/Takes/*.swift` | New: the ring, the gesture, the SMF writer and reader, the note, file names |
| `Sources/InStrumCore/{SleepFade,Sound/AmbienceBreath}.swift` | New: the timer's curves and waking; the swell |
| `Sources/InStrumCore/Worlds/{LakeRipples,TideLines,GlowWake,SteamLines,RakeLines}.swift`, `ButterflyGarden/ButterflyGardenModel.swift` | Bloom at dt 0 |
| `Sources/InStrumAudio/AudioEngine.swift`, `Sources/InStrumApp/InstrumentEngine.swift` | `sleepGain` |
| `Sources/InStrumApp/{AppModel,AppModel+Takes,AppModel+Sleep,AppModel+Hold,AppModel+ReduceMotion,ReduceMotionWatcher}.swift` | Seams; each feature's model code; the Mac's flag |
| `Sources/InStrumApp/Visuals/{ThemeCanvas,PreviewRenderer}.swift` | Controls in, report out; `visualDt`, exposure, effective Gentle visuals, the director's scene |
| `Sources/InStrumApp/Views/SmallWins/*.swift`, `Views/{MainView,SettingsPopover,SettingsPanel,SkyControls}.swift`, `InStrumMeantsApp.swift` | Bar controls, the Play menu, the toast; settings rows |
| `Sources/InStrumDSP/{Ambience.hpp,Ambience.cpp,include/InStrumDSP.h}` | The chime in key; two hooks |

Local tools: `$SP/amb9/`, `$SP/sw/breath.py`, `Scripts/mslcheck`.

## Running order and merge notes

- **Wave 1, in parallel:** Tasks 0, 1, 4, 5 and 10. Only Task 0 touches shared App files.
- **Wave 2, after Task 0:** Tasks 3, 8 and 9; Task 2 once 1 is in; Task 6 once 5 is in.
- **Wave 3:** Task 7, after Tasks 3 and 4.
- **Last:** Task 11.
- **Merge order:** 0 → 1, 4, 5, 10 → 3, 8, 9 → 2, 6 → 7 → 11. If `s11-amb` lands first, merge it before Task 10.
- **Conflicts.** Keep both sides of each:
  - `ThemeCanvas`/`PreviewRenderer` branches merged later (tea house, garden, submarine, reef) keep `dt: dt` and take `gentle: gentle`;
  - `LivingSky.step` gains `dim:` here and `meteors:` in Deep Water;
  - `SceneDirector.step` gains `instrumentPulse` and `meteors.mode` in Deep Water;
  - Deep Water adds sources and sonar hooks to `Ambience.{hpp,cpp}` and `InStrumDSP.h`;
  - Tasks 2, 6 and 9 add `AppModel` properties after `presets`, `autosaveTimer` and `terminateObserver`.

---

### Task 0: Branch, settings, seams and the run-time gain
**Files:**
- Create: `Sources/InStrumCore/SceneControls.swift`; `Sources/InStrumApp/Views/SmallWins/{KeepButton,HoldPad,SleepMenu,PlayMenu,ToastBanner}.swift`.
- Modify: `AppSettings`, `SceneDirector`, `InstrumentEngine`, `AudioEngine`, `AppModel`, `ThemeCanvas`, `PreviewRenderer`, `MainView`, `InStrumMeantsApp` (`.commands { PlayMenu(model:) }`), `.github/workflows/build.yml`.
- Tests: `SettingsStoreTests`, `SceneDirectorTests`, `AudioEngineTests`, `AppModelTests`. `FakeEngine` gains `var sleepGain: Float = 1`.

**Interfaces — Produces.** Core types get `public init`s with these defaults.
- **`HoldPedal`:** `enum HoldPedal: String, Codable, CaseIterable { case soft, sostenuto, off }`, with `controller: UInt8?` (67/66/nil) and `displayName`.
- **`KeyboardRange`:** `enum KeyboardRange: String, Codable, CaseIterable { case keys88, keys76, keys61, keys49 }`, with `low`/`high: UInt8` (21…108, 28…103, 36…96, 36…84) and `displayName` ("88 keys (A0–C8)", …).
- **`AmbienceBreathSettings`:** `struct AmbienceBreathSettings: Codable, Equatable { enabled = true; depth = 1.0 }`, with `depth` clamped to 0…1.5.
- **`SceneControls`:** `struct SceneControls: Equatable { holdRequested = false; holdPedal = HoldPedal.soft; sleepDim = 0.0; reduceMotion = false; breath = AmbienceBreathSettings() }`.
- **`SceneReport`:** `struct SceneReport: Equatable { holding = false; sky: SkyState? = nil; key: AmbienceKey? = nil }`.
- **`AppSettings`:** `holdPedal = .soft`, `keyboardRange = .keys88`, `breath`, `followReduceMotion = true`.
- **`SceneDirector`:**
  - `public var controls`;
  - `public private(set) var holding, visualDt`, where `visualDt` is the step's dt until Task 3;
  - `public var exposureScale: Float`, 1 until Task 3;
  - `public var report: SceneReport`;
  - `public func ambience(for frame: Any, at t: Double) -> AmbienceScene`, moved from `ThemeCanvas.ambience(for:key:)`.
- **Audio:** `InstrumentEngine.sleepGain: Float { get set }`. `AudioEngine.sleepGain` (0…1) sets `instrumentBus.volume` and `ambienceBus.volume`, re-applied after `rebuildOutput()` and `startAmbience()`.
- **`AppModel` state:**
  - `public internal(set) var sceneControls`;
  - `public private(set) var sceneReport`, with `noteSceneReport(_:)`, which publishes `holdShown`;
  - `@Published public internal(set) var holdLatched, holdPressed, sleepRemaining: TimeInterval?, reduceMotionActive`;
  - `@Published public private(set) var holdShown`;
  - `effectiveGentleVisuals = gentleVisuals || reduceMotionActive`.
- **`AppModel` toast:** `struct Toast: Equatable { text, symbol: String; id: Int }`, and `@Published public private(set) var toast`. It is set by `showToast(_ text: String, symbol: String)`, and clears after 2.5 s unless replaced.
- **`AppModel` activity:** `nonisolated var lastActivityTime: Double`, under `live`. It holds the last note-on or CC 64/66/67 through `perform`, or the last `nonisolated noteUserActivity(at t: Double = ProcessInfo.processInfo.systemUptime)`.
- **`AppModel` setters:**
  - `setHoldPedal`, `setKeyboardRange`, `setBreath` (getter `breathSettings`) and `setFollowReduceMotion`;
  - each saves, and has a getter named for its setting;
  - the pedal and the breath also reach `sceneControls`.
- **`AppModel` access:** `settings`, `live` (and `Live`) and `dialReader` drop `private`, and `visualsVersion` becomes `public internal(set)`.
- **Views:**
  - `KeepButton`, `HoldPad` and `SleepMenu` sit after the main bar's `Spacer()`, as `EmptyView` for now;
  - `ToastBanner` sits over the canvas;
  - `PlayMenu: Commands` = `CommandMenu("Play") { KeepMenuItems(model:); Divider(); HoldMenuItems(model:) }`, with the two item views as placeholders in `KeepButton.swift` and `HoldPad.swift`.

**Steps:**
- [ ] **Branch:** cut `small-wins` from `sets-11-12` (4db63eb), add `|| github.ref == 'refs/heads/small-wins'` to the previews job's `if:`, and commit this plan.
- [ ] **Tests:**
  - `testSmallWinsSettingsLoadWithDefaults` (Review focus 5): older settings → `.soft`, `.keys88`, breath on at 1, follow on; `"holdPedal": "kazoo"` → `.soft`; depth 9 → 1.5; all round-trip.
  - `testDefaultControlsChangeNothing`: over 60 lake steps, `visualDt == dt`, `exposureScale == 1`, `report.sky == lastSky`, and the ambience is the frame's with the key.
  - `testSleepGainLeavesTheVolumesAlone` (manual rendering): at master 0.7, ambience 0.4 and gain 0.25, both volumes read back unchanged and a held note is 12.0 ± 0.5 dB quieter; 1.7 clamps to 1.
  - `testSmallWinsSettingsAreSavedAndSteerTheDirector`: each setter saves and reloads, and `.sostenuto` and depth 0.5 reach `sceneControls`.
  - `testActivityIsKeysAndPedals`: note-on at 5 → 5; note-off at 6 → 5; CC 64 at 7 → 7; CC 1 at 8 → 7; `noteUserActivity(at: 9)` → 9.
  - `testToastClearsItself`: gone after 2.6 s, and a newer toast outlives the older timer.
- [ ] **Implement** in `ThemeCanvas.drawFrame` and `PreviewRenderer.render`:
  - the frame's own step becomes `frameDt` (`frameStep` in the previews);
  - `director.controls` is set before `handle`, from `model.sceneControls` or, in the previews, a new `controls: ((Double) -> SceneControls)? = nil`;
  - after `step`, `let dt = director.visualDt`;
  - every branch passes `gentle: gentle` (`model.effectiveGentleVisuals`);
  - send `director.ambience(for: frame, at: now)` and `noteSceneReport(director.report)`;
  - post exposure × `exposureScale` (the previews gain `capture(_:exposureScale: Float = 1)`).
- [ ] **Commit:** `chore: Small Wins branch, settings, seams and the run-time gain`.

### Task 1: TakeKeeper, the key gesture and the SMF writer (Core)
**Files:** `Sources/InStrumCore/Takes/{TakeKeeper,KeyGesture,StandardMIDIFile,TakeNote,TakeStore}.swift`; tests `Tests/InStrumCoreTests/{TakeKeeper,KeyGesture,StandardMIDIFile,TakeStore}Tests.swift`.

**Interfaces — Produces:**
- **`TakeEvent` and `Take`:** `struct TakeEvent: Equatable { time: Double; message: MIDIMessage }`, in seconds from the take's start, and `struct Take: Equatable { events: [TakeEvent]; duration: Double }`.
- **`struct KeyGesture`:**
  - `static let together = 0.08, within = 1.5`;
  - `static func triple(low: UInt8, high: UInt8) -> [UInt8]?`: F♯, G♯ and A♯ of the highest octave wholly in range;
  - `init(notes: [UInt8])`;
  - `mutating func feed(_ m: MIDIMessage, at t: Double) -> Double?`, which returns the first tap's start.
- **`struct TakeKeeper`:**
  - `static let horizon = 7200.0, cap = 250_000, silence = 8.0, longest = 1800.0, stale = 600.0, tail = 2.0`;
  - `init(low: UInt8 = KeyboardLayout.lowestNote, high: UInt8 = KeyboardLayout.highestNote)` and `setRange(low:high:)`;
  - `count`;
  - `@discardableResult mutating func record(_ m: MIDIMessage, at t: Double) -> Double?`, which returns the gesture's start;
  - `lastTake(endingAt now: Double) -> Take?`;
  - `lastMinutes(_ seconds: Double = 600, endingAt now: Double) -> Take?`, which runs from its first note-on.
- **`enum StandardMIDIFile`:**
  - `static let ppq: UInt16 = 480`;
  - `static func write(_ take: Take, name: String, bpm: Double) -> Data`: type 0, with no running status;
  - `static func read(_ data: Data) -> (name: String, bpm: Double, events: [TakeEvent])?`, which accepts running status;
  - `static func vlq(_ v: UInt32) -> [UInt8]`.
- **`struct TakeNote: Codable, Equatable`** (nil fields are omitted):
  - `setID: String?` and `worldID`;
  - `instrument { patchID: String?; name; dials: [String: Double] }`;
  - `sky: Sky? { city, localTime, weather: String; sunAltitude, moonPhase: Double }`;
  - `key: AmbienceKey?`, `appVersion` and `seconds`.
- **`struct TakeStore`:**
  - `static var defaultDirectory` (`.musicDirectory` + `In Strum Meants/Takes`) and `init(directory:)`;
  - `static func fileStem(title:date:timeZone:) -> String`;
  - `func save(midi: Data, note: TakeNote, title: String, at date: Date, timeZone: TimeZone = .current) throws -> URL`, which makes the folder, then writes the `.mid` and the `.json` atomically.

**Steps:**
- [ ] **Tests** in `TakeKeeperTests`:
  - `testOnlyThePlayingIsKept`: note on/off, CC 64/66/67, bend and both pressures are kept (8 events). CC 1, 7, 11 and `.other` are dropped.
  - `testTakeStartsAfterTheLastLongSilence`: 0.3 s notes every 0.5 s over 0–20 s and 29–40 s. The take ending at 41 starts with the 29 s note-on at time 0. With the second phrase at 28.1 s, it starts at 0.
  - `testHeldKeysAreNotSilence`: a key held 0–15 s, then a note at 15.5 s → it starts at 0.
  - `testThePedalAloneIsSilence`: keys up at 5 s under the sustain, then a note at 14 s → it starts at 14, with CC 64 = 127 at 0.
  - `testTakesAreAtMostThirtyMinutes`: a note every 2 s for 45 minutes → 1797–1800 s.
  - `testNothingToKeepAfterTenMinutes`: with the last note at 0, nil at 600.5, and a take at 599.5.
  - `testLastTenMinutesIgnoresSilences`: phrases at 0–30 s and 300–310 s → `lastMinutes(endingAt: 320)` holds both, from 0.
  - `testTakeEdgesStayClean` (Review focus 1): a key down before the start loses its note-off; one down at the end is closed there; an earlier bend of 12000 is written at 0; each note-on has exactly one later note-off.
  - `testTheRingStaysBounded` (Review focus 1): 200,000 events over 3 h keep the last 2 h (133,334 ± 2). 300,000 in an hour keep exactly the newest 250,000, recorded in under 1 s.
- [ ] **Tests** in `KeyGestureTests` (a tap is three note-ons within 30 ms, released 100 ms later):
  - `testTheTopThreeBlackKeys`: (21, 108) → [102, 104, 106]; (28, 103) and (36, 96) → [90, 92, 94]; (36, 84) → [78, 80, 82]; (100, 105) → nil.
  - `testTwoTapsWithinOneAndAHalfSecondsFire`: taps at 0 and 0.9 s fire once, at the second tap's third note-on, returning 0. Taps at 0 and 1.6 s don't, and a third at 2.4 s fires, returning 1.6.
  - `testAChordContainingTheKeysNeverFires` (Review focus 2): no fire for D♯7 with the three (twice in 1 s), the three plus a G2 within 80 ms, the three over 120 ms, a 2 s F♯7–G♯7 trill with A♯7 runs, or one tap.
  - `testThreeTapsFireOnce` (Review focus 2): taps at 0, 0.6 and 1.2 s → one fire, at 0.6 s.
  - `testTheGestureIsCutFromTheTake`: music, then the gesture at 25 s → `record` returns 25; takes ending at 25 and at 40 hold no gesture note and no orphan note-off; `count` ignores the late note-offs.
- [ ] **Tests** in `StandardMIDIFileTests`:
  - `testHeaderAndTrack`: the file starts `4D 54 68 64 00 00 00 06 00 00 00 01 01 E0`, then `MTrk` with the rest's length. The track opens `00 FF 03 <len> <name> 00 FF 51 03 07 A1 20` and closes `FF 2F 00`.
  - `testVariableLengthQuantities`: 0, 127, 128, 8192, 0x0FFFFFFF → `00`, `7F`, `81 00`, `C0 00`, `FF FF FF 7F`.
  - `testTempoMeta`: 84 BPM → `0A E6 2E` (714,286 µs); 68 → `0D 76 B1` (882,353 µs).
  - `testEveryKindRoundTrips`: on channel 3, velocities 1 and 127, release velocity 30, CC 64/66/67 at 0/64/127, bends 0/8192/16383, pressures 0/127 and poly (60, 99) read back equal, in order.
  - `testTimesAreExactToTheMillisecond`: 2,000 random millisecond times over 30 minutes, at 68, 84 and 120 BPM, read back within half a tick (0.92, 0.75 and 0.53 ms), the last included.
- [ ] **Tests** in `TakeStoreTests`:
  - `testFileNames`: 2026-11-04 21:07 in Australia/Melbourne with "Moonlit Lake" → `2026-11-04 21.07 — Moonlit Lake`; again → `… 2`; "AC/DC: Live" → `AC-DC- Live`.
  - `testTheFolderIsMadeOnTheFirstKeep`: nothing exists until `save`, and then just the two files.
  - `testTheNotesFields`: exactly the interface's keys; `sky` and `key` are absent when nil; the note decodes back equal.
- [ ] **Implement** per spec §2 and the rulings, with the ring as a preallocated circular buffer.
- [ ] **Commit:** `feat(core): keep that: the take keeper, the key gesture and a MIDI file writer`.

### Task 2: Keep that in the app
**Depends on:** Tasks 0 and 1.

**Files:**
- Create: `Sources/InStrumApp/AppModel+Takes.swift`, `Tests/InStrumAppTests/KeepThatTests.swift`.
- Modify:
  - `AppModel.swift`: `Live.keeper`, recorded in `perform`; `var takeStore` after `presets`; `setKeyboardRange` updates the keeper.
  - `KeepButton.swift`.
  - `SettingsPopover.swift`: "Keyboard layout" under MIDI keyboards, captioned "Tap its top three black keys together, twice, to keep a take."

**Interfaces — Produces:**
- **`AppModel`:**
  - `keepThat(at t: Double = ProcessInfo.processInfo.systemUptime)` and `keepLastTenMinutes(at:)`;
  - `var takeStore = TakeStore(directory: TakeStore.defaultDirectory)`;
  - `takeTitle()`: the file's and the track's name;
  - `takeTempo()`: the set's credit `tempoBPM`, else 120;
  - `takeNote(seconds:)`.
- **The note's sources:**
  - `themeID`, and `activeSetID` while its world shows;
  - `builtInPatch?.id`, `settings.instrument?.name`, and dials by `DialInfo.name` from `dialReader?.currentValues()`;
  - `sceneReport.sky`, with the city from `settings.sky.cityID` or `Cities.defaultCity(for: .current)`, and `SkyControls.clock(hourOfDay)`;
  - `sceneReport.key`;
  - `CFBundleShortVersionString`, or "dev".
- **The views:**
  - `KeepButton`: the bookmark, with help "Keep that: save your last take (⌘K)" and the context menu "Keep the last 10 minutes";
  - `KeepMenuItems.shortcut = KeyboardShortcut("k", modifiers: .command)`.

**Steps:**
- [ ] **Tests:**
  - `testKeepThatSavesTheLastTake`: the lake, 0.25 s notes every 0.5 s over 100–110 s, then `keepThat(at: 120)` → `… — Moonlit Lake.mid` and its `.json`, 12.25 s long, and "Kept · 0:12".
  - `testTheTempoIsTheSetsCredit`: the lake set → 714,286 µs. No set, or a place-born set → 500,000.
  - `testNothingToKeep`: "Nothing to keep yet", and no folder.
  - `testTheGestureKeepsWithoutItself`: after the taps through `handleMIDI` and a main-actor turn, there is one take, ending before the first tap, and the toast.
  - `testTheGestureFollowsTheKeyboardLayout` (Review focus 2): with `.keys61`, 90/92/94 keep, and 102/104/106 don't.
  - `testKeepTheLastTenMinutes`: phrases of 0.25 s notes at 0–30 s and 300–310 s, then a keep at 320 → 0–312.25 s.
  - `testTheNoteCarriesTheMoment`: the world, set, instrument, "Melbourne" and the report's key.
  - `testNothingIsWrittenUntilKeep`: 2,000 notes, and no folder.
  - `testTheShortcutIsCommandK`.
- [ ] **Implement:**
  - the gesture keeps via `Task { @MainActor in self.keepThat(at: start) }`;
  - writes are synchronous (a take is under 1 MB);
  - a failed save toasts "Couldn't save the take".
- [ ] **Commit:** `feat(app): keep that: the bookmark, ⌘K, the key gesture and the Kept toast`.

### Task 3: Held time, the sleep dim and the gentle drift (Core)
**Depends on:** Task 0.

**Files:**
- `SceneDirector.swift`;
- `Sky/LivingSky.swift`: `step(now:dt:hold:aurora:dim:)`, with `dim` defaulting to 0;
- `Inputs.swift`, `Worlds/GalaxyWarp.swift`;
- test `Tests/InStrumCoreTests/HeldTimeTests.swift`.

**Interfaces — Produces:**
- **Constants and `timeScale`:** `SceneDirector.holdEase = 0.6` and `nightAltitude = -14.0`. `public private(set) var timeScale` is 0 while held, then smoothstep(0, 0.6, t − release).
- **`holding`:** `controls.holdRequested`, or the hold pedal down (`.control(controls.holdPedal.controller, value ≥ 0.5)`). `.allNotesOff` lets the pedal go.
- **Per step:**
  - sky dt = dt × `timeScale`;
  - world dt = sky dt × (1 − 0.5·`sleepDim`);
  - `visualDt` = world dt, halved under `reduceMotion`;
  - `exposureScale = exp2(−sleepDim)`.
- **While held:**
  - the sky's instant freezes, and glides back to the clock by `timeScale`;
  - at `timeScale` 0, the world gets the hold's first `InputFrame`, roles and offsets.
- **`LivingSky.step(…, dim:)`:** after the hold, `altitude += (min(altitude, −14) − altitude) × dim`.
- **Reduce Motion:**
  - `InputID.reduceMotion = InputID("comfort.reduceMotion")` goes into each step's `InputFrame`, never into the hub;
  - while it reads above 0.5, Galaxy Warp aims at `GalaxyWarp.driftSpeed: Float = 0.1`.

**Steps:**
- [ ] **Tests** in `HeldTimeTests`:
  - `testAHeldSecondChangesNothing`: every theme, held after 2 s. The first held frame equals the 60th at 1/60 s (through `Mirror`, minus `ambience`), and so does `lastSky`.
  - `testNotesStillArriveWhileHeld`: a note adds a ripple in the next frame, and the next 60 frames are equal.
  - `testReleaseEasesTimeBackIn`: `timeScale` is 0.5 ± 0.02 at +0.3 s, and 1 from +0.6 s. The world gains 0.3 ± 0.02 s by then.
  - `testALongHoldInRealTimeCatchesUpSmoothly` (Review focus 3): Melbourne at sunset, held for 30 minutes → the sun is still while held, moves ≤ 0.5° per 1/60 s step after release, and is within 1e-6° of an unheld director from +0.6 s.
  - `testQuickModeResumesWhereItStopped` (Review focus 3): on a 12-minute day, `hourOfDay` is constant over 60 s held, and has advanced 0.0233 ± 0.0005 h 1 s after release.
  - `testSwitchingWorldsWhileHeld` (Review focus 3): held on the lake, then switched to the beach → the beach stays still, then runs after release.
  - `testTheSoftPedalHoldsAndTheSettingSwitchesIt`: `.soft`: CC 67 at 127 holds and at 0 releases; `.sostenuto`: CC 66 holds and CC 67 doesn't; `.off`: neither.
  - `testPanicLetsTheHoldPedalGo` (Review focus 3): `.allNotesOff` ends a pedal hold, but not `holdRequested`.
  - `testFlashesPauseWhileHeld` (Review focus 6): the stormy lake's `lastSky.lightning` and the bay's `lighthouseFlash` hold for 30 s.
  - `testSleepDimSlidesTheHeldSun`: Golden hour (5°) at dim 0, 0.5 and 1 → 5°, −4.5° and −14° (±1e-9); Deep night stays −30°; the noon lake at dim 1 → −14°.
  - `testSleepSlowsTheWorldNotTheWeather`: at dim 1, the frame's `time` gains 0.5·dt, and a weather blend ends on the same step as at dim 0.
  - `testExposureFallsAStop`: dim 0, 0.5 and 1 → 1, 0.7071 and 0.5 (±1e-4).
  - `testVisualDtCombinesEverything` (dt 1/60): plain 1/60; Reduce Motion 1/120; dim 1 1/120; both 1/240; held 0.
  - `testReduceMotionKeepsGalaxyWarpAdrift`: the lounge, fortissimo chords every 0.25 s for 3 s → `warpSpeed` ≤ 0.1 + 1e-6 with Reduce Motion and > 0.5 by 3 s without; the hub never lists the input.
- [ ] **Implement** per spec §3, §4 and §6.
- [ ] **Commit:** `feat(core): hold the moment, the sleep dim and Reduce Motion's drift in the director's clock`.

### Task 4: Note visuals bloom when time is held (Core)
**Files:** `Worlds/{LakeRipples,TideLines,GlowWake,SteamLines,RakeLines}.swift`, `ButterflyGarden/ButterflyGardenModel.swift`; test `Tests/InStrumCoreTests/BloomTests.swift`.

**The rule:** in a step whose dt is exactly 0, each item at age 0 starts at its bloom, its first moment at full brightness and shape.

Already full at birth, so unchanged: Coast Lights, Curtain Lights, Glow Wake's patches and wakes, Frost Grow, Galaxy Warp, the lantern flake, Rake Lines' rings and strokes, and the Steinway.

| Visual | Born while held with |
|---|---|
| `LakeRipples` | ripple `age = bloomAge` (0.15 s); chord firefly `age = fireflyBloomAge` (0.6 s) |
| `TideLines` | `drawn = 1`, `age = bloomAge` (0.3 s) |
| `GlowWake` | dart `age = dartBloomAge` (0.25 s) |
| `SteamLines` | wisp `rise = height`; chord puff `age = puffBloomAge` (0.15 s) |
| `RakeLines` | chord wave `age = waveBloomAge` (0.4 s), with its offset |
| `ButterflyGardenModel` | flyer `age = bloomAge` (0.25 s) |

**Steps:**
- [ ] **Tests** in `BloomTests`:
  - `testLakeRipplesBloomWhenTimeIsHeld`: a note at dt 0 → age 0.15, unchanged by further dt-0 steps; `step(dt: 0.1)` → 0.25 ± 1e-6; fireflies → 0.6.
  - `testTideLinesAreTracedAtOnce`: `drawn` 1, at age 0.3.
  - `testGlowWakeDartsBloom`: every dart is at 0.25.
  - `testSteamWispsRiseAtOnce`: velocity 0.5 → rise 0.65, with puffs at full strength.
  - `testRakeWaveBlooms`: age 0.4, with brightness = strength × (1 − 0.6·min(1, offset / reach)) ± 1e-6.
  - `testButterfliesFadeInAtOnce`: opacity 1.
  - `testAHeldStepChangesNothingElse`: a second empty dt-0 step leaves all six equal.
  - `testRunningTimeIsUntouched`: at dt 1/60, a new item is 1/60 s old, as today.
- [ ] **Commit:** `feat(worlds): notes played while time is held bloom at once`.

### Task 5: The sleep fade's clock (Core)
**Files:** `Sources/InStrumCore/SleepFade.swift`; test `Tests/InStrumCoreTests/SleepFadeTests.swift`.

**Interfaces — Produces:** `public struct SleepFade: Equatable`, with:
- **Constants:** `static let choices = [15, 30, 45, 60, 90]`, `fadeSeconds = 600.0`, `wakeSeconds = 3.0` and `endGain: Float = 0.001`; plus `static func curve(_ p: Double) -> Float`.
- **`start(minutes:at:)`:** starts or restarts the countdown, and keeps any wake glide. It fades over the last 10 minutes, or the whole timer if that is shorter.
- **`@discardableResult wake(at:) -> Bool`:** true if it woke a fading or resting world. It is ignored before the fade.
- **`turnOff(at:)`:** wakes a fading or resting world, and otherwise stops.
- **Readings:**
  - `gain(at:) -> Float` and `dim(at:) -> Double`;
  - `remaining(at:) -> Double?`: nil unless counting down;
  - `isFading(at:)`: true during the fade, and while resting after it.

**Steps:**
- [ ] **Tests** in `SleepFadeTests`:
  - `testGainCurve` (15 minutes): 1 until 300 s; at p 0, 0.25, 0.5, 0.75, 1 → 1, 0.853700, 0.500500, 0.147300, 0.001 (±1e-6), which is −60 ± 0.01 dB; never rising; 0 after 900 s.
  - `testShortTimersFadeAllTheWay`: a 6-minute timer fades from 0.
  - `testDimFollowsTheFade`: 0 before the fade, 0.5 at p 0.5, and 1 from the end.
  - `testANoteRestoresOverThreeSeconds` (a wake at p 0.5): gain 0.5005 + 0.4995·s/3 at s = 0, 1.5, 3 (±1e-4); dim 0.5·(1 − s/3); off from 3 s.
  - `testTheTimerEndsOff`: after 900 s, `remaining` is nil, the gain 0, the dim 1 and `isFading` true. A wake restores.
  - `testInputBeforeTheFadeIsIgnored`: a wake at 100 s returns false.
  - `testWakingAtTheEdges` (Review focus 4): wakes 0.5 s before the end, 1 s after it, or twice in a glide move gain and dim ≤ 0.034 per 0.1 s; `start(minutes: 30)` 1 s into a wake from the end keeps the glide (0.5 ± 0.01 at 1.5 s, 1 at 3 s).
  - `testWakingNeverFlashes` (Review focus 6): exp2(−dim) rises < 0.025 per `FlashLimiter.window`.
- [ ] **Commit:** `feat(core): the sleep fade's timer, curves and waking`.

### Task 6: The sleep timer in the app
**Depends on:** Tasks 0 and 5.

**Files:**
- Create: `Sources/InStrumApp/AppModel+Sleep.swift`, `Tests/InStrumAppTests/SleepTimerTests.swift`.
- Modify:
  - `AppModel.swift`, after `autosaveTimer`: `var sleepFade = SleepFade()`, `var sleepTicker: Timer?`, `var sleepClock: () -> Double = { ProcessInfo.processInfo.systemUptime }`;
  - `SleepMenu.swift`.

**Interfaces — Produces:**
- **`AppModel.setSleepTimer(minutes: Int?)`**, where nil is Off.
- **`sleepTick(at now: Double)`**, the 10 Hz timer's body, which tests call directly:
  - activity newer than the fade's start wakes the world at `lastActivityTime`, with "You're awake.";
  - `engine.sleepGain`, `sceneControls.sleepDim` and `sleepRemaining` (whole seconds) follow the fade;
  - the ticker stops once the fade is off.
- **`SleepMenu`:**
  - the moon `Menu`;
  - `static func label(remaining: Double) -> String`: "⌈s/60⌉ min" from 60 s up, else "⌈s⌉ s";
  - a local `NSEvent` monitor for clicks and keys, which calls `noteUserActivity()`.

**Steps:**
- [ ] **Tests** in `SleepTimerTests`:
  - `testTheTimerFadesTheSoundButNotTheSavedVolumes` (Review focus 4): volume 0.6, ambience 0.4, 15 minutes. At 600 s the gain is 0.5005 ± 1e-3 and the dim 0.5 ± 1e-3. After `autosave()`, both volumes are still 0.6 and 0.4.
  - `testTheEndIsSilentDimAndOff`: at 900 s, the gain is 0, the dim 1, and `sleepRemaining` nil.
  - `testANoteWakesTheWorld`: a note at 600 s through `handleMIDI` → gain 0.75 ± 0.01 at 601.5; at 603.1 gain 1, dim 0, "You're awake." and the timer Off.
  - `testAClickWakesItToo`: `noteUserActivity(at: 905)`.
  - `testPlayingBeforeTheFadeKeepsTheTimer`: a note at 100 s.
  - `testTheTimerIsNeverSaved`: there's no sleep key, and a new model starts Off.
  - `testTheMoonLabel`: 900 → "15 min"; 839 → "14 min"; 30 → "30 s".
- [ ] **Commit:** `feat(app): the sleep timer: a moon, a fade to night and silence, and waking`.

### Task 7: Hold the moment in the app
**Depends on:** Tasks 0, 3 and 4.

**Files:**
- Create: `Sources/InStrumApp/AppModel+Hold.swift`, `Tests/InStrumAppTests/HoldTheMomentTests.swift`.
- Modify: `HoldPad.swift`; `SettingsPopover.swift` ("Hold the moment with", under Touch).

**Interfaces — Produces:**
- **`AppModel.toggleHold()`** and **`setHoldPressed(_ down: Bool)`**, each setting `sceneControls.holdRequested = holdLatched || holdPressed`.
- **`HoldMenuItems.shortcut`** = `KeyboardShortcut("h", modifiers: [.command, .shift])`.
- **The hourglass pad:**
  - lit while `holdShown`;
  - pressed by a zero-distance `DragGesture`;
  - latched by `TapGesture(count: 2)`.

**Steps:**
- [ ] **Tests** in `HoldTheMomentTests`:
  - `testThePadHoldsWhilePressed`.
  - `testDoubleClickAndShortcutToggle`: a latch and a press hold until both let go.
  - `testThePedalSettingSteersTheDirector`: under `.off`, CC 67 doesn't hold.
  - **Renders** (640 × 360, skipped without Metal, stepped by `visualDt`):
    - `testAHeldMomentStandsStill`: the rainy night lake and the lounge. Over 1 s held, the difference is < 1e-4, and 1 s after release, > 1e-3.
    - `testNotesFillAHeldMoment`: a held chord changes the frame by > 2e-4. Frames 0.1 s and 1.1 s after it differ by < 1e-4.
    - `testTheHoldEasesOut`: frames 1–2 after release differ less than frames 36–37.
    - `testNoFlashesOnScreenWhileHeld` (Review focus 6): `weather.exposureBoost` is constant over 120 held frames.
- [ ] **Commit:** `feat(app): hold the moment: the soft pedal, the hourglass and ⌘⇧H`.

### Task 8: Breathing ambience
**Depends on:** Task 0. It matches Deep Water's beds by name.

**Files:**
- Create: `Sources/InStrumCore/Sound/AmbienceBreath.swift`; tests `AmbienceBreathTests`, `BreathSettingsTests`.
- Modify:
  - `SceneDirector.swift`: `ambience(for:at:)` breathes while `controls.breath.enabled`, through a stored `AmbienceBreath(seed: 0xB4EA7E)` with its depth from `controls`;
  - `SkyControls.swift`, under Ambience: "Ambience breathes", and "Breathing depth 100%" on a 0…1.5 slider.

**Interfaces — Produces:** `public struct AmbienceBreath`, with:
- `static let beds: Set<String>`: `rainOnWater, rainOnGlass, wind, breeze, surf, waterfall, water, crickets, shipHum, airFlow, kettle, fire, street, snappingShrimp, lapping`;
- `static let swing = 0.25, floor = 0.6, quantum = 0.01`;
- `init(seed: UInt64)` and `var depth = 1.0`;
- `factor(_ source: AmbienceSource, at t: Double) -> Double`;
- `apply(to scene: inout AmbienceScene, at t: Double)`.

The swell:
```swift
// Per bed: var r = SeededRandom(seed: (seed &* 0x9E37_79B9_7F4A_7C15) ^ h), h = FNV-1a of source.rawValue's UTF-8
// (as in LivingSky.dawnIsPastel); draw u, u2, phi1, phi2 with Double(r.unit()), in that order. L is the world's level.
let p1 = 40 + 50 * u, p2 = p1 * (1.35 + 0.4 * u2)
let f = 1 + swing * depth * (sin(2 * .pi * (t / p1 + phi1)) + sin(2 * .pi * (t / p2 + phi2))) / 2
level = (min(1, L * max(floor, f)) / quantum).rounded() * quantum
```

**Steps:**
- [ ] **Tests** in `AmbienceBreathTests`:
  - `testDeterministicPerSeed`: seed 7 matches itself for 600 s, and seed 8 differs.
  - `testDepthAndFloor` (level 0.8): depth 1 within 0.60…1.00; depth 1.5 ≥ 0.48; depth 0 exactly 0.80; every level a multiple of 0.01.
  - `testOneShotsUntouched`: the owl, chime, gulls, bell and (later) sonar exact; `thunder` and `wave` pass through; non-beds untouched.
  - `testBedsMoveOnTheirOwn` (seed `0xB4EA7E`): all factors differ at 300 s, and no pair correlates above 0.9 over 600 s (0.55 measured).
  - `testTheBreathKeepsMoving`: every bed at 0.8, seeds 1–8, sampled every 0.5 s for 600 s → ≥ 4 mean crossings, and never flat for 30 s.
  - `testDeepWaterBedsByName`: `XCTSkip` until `AmbienceSource(rawValue: "snappingShrimp")` exists. Then it breathes, and `sonar` doesn't.
  - `testTheDirectorBreathesWhenAsked`: on, the lake's `.water` moves off the frame's within 120 s; off, they are equal; the depth follows `controls`.
- [ ] **Tests** in `BreathSettingsTests`: `testApplyingASetLeavesBreathingAlone` (Review focus 5). With breathing off, `applySet("moonlit-lake")` leaves it off, and `isSetModified` false.
- [ ] **Commit:** `feat(ambience): rain, wind and surf breathe in long, slow arcs`.

### Task 9: Follow Reduce Motion
**Depends on:** Task 0.

**Files:**
- Create: `Sources/InStrumApp/{ReduceMotionWatcher,AppModel+ReduceMotion}.swift`, `ReduceMotionTests`.
- Modify:
  - `AppModel.swift`: `var reduceMotionWatcher: ReduceMotionWatching?` after `terminateObserver`; `setFollowReduceMotion` recomputes;
  - `InStrumMeantsApp.swift`: `AppContainer.init` calls `model.startWatchingReduceMotion()`;
  - `SettingsPanel.swift`, in Display after Gentle visuals: "Follow the Mac's Reduce Motion", captioned while it applies with "The Mac's Reduce Motion is on, so the visuals move gently."

**Interfaces — Produces:**
- **`protocol ReduceMotionWatching: AnyObject { var isOn: Bool { get }; var onChange: (() -> Void)? { get set } }`.**
- **`final class SystemReduceMotion`**, which:
  - reads `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`;
  - observes `NSWorkspace.accessibilityDisplayOptionsDidChangeNotification` on `NSWorkspace.shared.notificationCenter`.
- **`AppModel.startWatchingReduceMotion(_ watcher: ReduceMotionWatching = SystemReduceMotion())`.** Now and on each change, it:
  - sets `reduceMotionActive = followReduceMotion && watcher.isOn`;
  - sets `sceneControls.reduceMotion`;
  - bumps `visualsVersion`.

**Steps:**
- [ ] **Tests** in `ReduceMotionTests`:
  - `testEffectiveGentleUnderEveryCombination`: across all 8 combinations, `effectiveGentleVisuals == gentleVisuals || (follow && flag)`, and `gentleVisuals` never changes.
  - `testTheNotificationFlipsItLive`: a fake watcher flips both values and bumps `visualsVersion`.
  - `testTheSettingDecodesWithItsDefault`.
  - `testTheSystemWatcherReadsTheMac`.
- [ ] **Commit:** `feat(app): follow the Mac's Reduce Motion`.

### Task 10: The chime in key (DSP)
**Depends on:** nothing. If `s11-amb` merges first, merge it in before starting.

**Files:**
- `Ambience.hpp`: `AmbienceContext.keySensed`; `setKey(int root, bool major, bool sensed)`; `strikeChime()`, `chimeRingingHz()`.
- `Ambience.cpp`: `Chime`; bit 32 of `ISDAmbience.key`; the hooks.
- `include/InStrumDSP.h`: the hooks.
- Test: `ChimeInKeyTests`, an `extension AmbienceTests`.

**Interfaces — Produces:**
- **Hooks:**
  - `void isd_ambience_debug_strike_chime(ISDAmbience *)`: a strike, through a sequence counter like the bell's;
  - `float isd_ambience_debug_chime_hz(const ISDAmbience *)`: the newest ringing strike's struck f0, or 0.
- **The key:** `set_key` stores `root | major << 4 | 32`, and `sensed` is `(key & 32) != 0`. The bell and the sonar keep reading `key & 15` and `(key >> 4) & 1`.
- **Tones:**
  - sensed: the root's pentatonic (major {0, 2, 4, 7, 9}, minor {0, 3, 5, 7, 10}) in MIDI 75–87;
  - before: today's six.

  Each strike picks its tone as it strikes and keeps it. With all 4 slots ringing, it takes the oldest.

**Steps:**
- [ ] **Tests** in `ChimeInKeyTests`:
  - `testChimeSitsInTheKey`: D major, 60 strikes. Each f0 is within 3 cents of 659.26, 739.99, 880.00, 987.77 or 1174.66 Hz, and all five appear.
  - `testEveryKeyStaysInTheChimesOctave`: 24 keys × 40 strikes. Every f0 is within 3 cents of a tone of its pentatonic in 622.25–1244.51 Hz, and E♭ major gives today's six.
  - `testChimeKeepsItsNotesUntilAKeyIsSensed`: only 622.25, 698.46, 783.99, 932.33, 1046.50 and 1244.51 Hz. `set_key(−1)` changes nothing, before or after D major.
  - `testChimeNeverChangesMidRing`: C major, a strike at 3 s, F♯ minor at 3.5 s → `debug_chime_hz` unchanged at 4, 6 and 8 s; the strongest 600–1300 Hz peak over 3.6–6 s nearest that tone; a strike at 12 s an F♯-minor tone (C♯6 = 1108.73 Hz among them).
  - `testTheBellStillReadsTheKey`: E before any key, and D after D major.
  - `testChimeHzIsZeroWhileSilent`.
- [ ] **Measure** the f0s and the peak on the mirror with g++ and clang++, and put them in the commit message.
- [ ] **Commit:** `feat(ambience): the lounge's chime plays in your key`.

### Task 11: Review, release notes and a status note
**Depends on:** Tasks 0–10, merged.
- [ ] **Two fresh reviewers** (Opus, high effort), with the spec, this plan, the Review focus and the rulings: A for audio and DSP (Task 0's gain, Tasks 8 and 10), B for Core and the app (the rest).
- [ ] **One fix pass:** re-grade by what Michael would hear or see. Critical and Important findings each get a failing test first, and Minor ones go to a ledger.
- [ ] **Late arrivals:** the tea house, garden, submarine and reef renderers take `gentle: gentle`; Deep Lights and Coral Pulse get Task 4's bloom if they fade in; `testDeepWaterBedsByName` is unskipped.
- [ ] **Release notes:** a **Small Wins** paragraph in `build.yml`'s release notes. Things to try: ⌘K and the gesture into GarageBand, a 15-minute timer's end, the soft pedal in the lake's rain, ten minutes of rain, Reduce motion, the lounge's chime, and Smooth still smooth.
- [ ] **Docs:** write the status note `claude/2026-11-04-small-wins-status.md`, and mark the six done in the pairings doc's §8.
- [ ] **Merge** `small-wins` into `sets-11-12` with `--no-ff`: `Small Wins: keep that, sleep fade, hold the moment, breathing ambience, Reduce Motion, the chime in key`.
