# Sets 13 & 14 ("Fire & Neon": Volcano Rim, Neon Night Drive) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship Sets 13 and 14, each with one of everything (world, visual, instrument, sky feature, weather, ambience): the vintage-synth core's first two instruments (Magma Bass; Replicant Brass with Chrome Bass), and the Excitement system (Energy, Big moments, Surprises, Build and drop) in every world.

**Architecture:**
- The engines are C++ behind the existing C API, on the grown header-only `AnalogVoice.hpp`, plus a shared `Arp.hpp`.
- Excitement is a Core machine owned by `SceneDirector`, handed to every model through `ExcitementAware`.
- The sky features (red sprites, satellites) are seeded Core machines drawn analytically in `skyRadiance`.
- The weathers (Ashfall, Supercell) go through `WeatherKind`, the shared weather layer and `WeatherAmbience`.
- The worlds follow the Core-model, App-renderer split.

**Tech stack:** Swift 6.1 (Swift 5 mode), SwiftUI, Metal (MSL in Swift strings), C++17 (`-O2`), SwiftPM, XCTest.

**Spec:** `docs/superpowers/specs/2026-11-05-fire-and-neon-design.md` (section numbers below refer to it). The brief is `2026-11-05-fire-and-neon-brief.md`.

**Builds on:** `small-wins`, the integration branch with Sets 7–12 and Small Wins so far.
- Cut `sets-13-14` from `small-wins` once Deep Water's Tasks 6 and 10–12 are merged into it.
- Merge `small-wins` in again whenever it moves.

## Global constraints

**Carried over unchanged:**
- The Sets 11 & 12 plan's constraints: platforms, no third-party code or samples, the Sound Core rules, the ambience rules, the Smooth rules, `FlashLimiter`, no `pow` of a possibly negative base.
- `director.visualDt` for animation, the bloom-at-dt-0 rule (notes played while time is held bloom at once), and `gentle:` honoured.

**Engines:** `ISD_ENGINE_MAGMA_BASS = 12`, `ISD_ENGINE_REPLICANT_BRASS = 13`.
- Home Lights' engines become 14 and 15 when it is built, and its spec is updated then.

**Parameter addresses:**
- **Magma Bass:** `ISD_P_GROWL = 130`, `ISD_P_HEAT = 131`, `ISD_P_ERUPT = 132`, `ISD_P_RUMBLE = 133`, `ISD_P_GRIT = 134`, `ISD_P_FLOW = 135`, `ISD_P_SHAPE = 136`, `ISD_P_MONO = 137`, `ISD_P_SPARK = 138`, `ISD_P_RES = 139`.
- **Replicant Brass:** `ISD_P_SWELL_RB = 140`, `ISD_P_BLAZE = 141`, `ISD_P_UNISON_WIDTH = 142`, `ISD_P_HALL = 143`, `ISD_P_CHROME = 144`, `ISD_P_PUNCH = 145`, `ISD_P_ARP_MODE = 146`, `ISD_P_ARP_RATE = 147`, `ISD_P_SPLIT = 148`, `ISD_P_TEMPO_RB = 149` (70…170, default 120).
- Both use the mood parameters 100–104 like every engine.
- `ISD_P_SWELL` (71) is not reused, because Home Lights' organ takes it.

**Test hooks (unit 3):**
- `ISD_P_DEBUG_MB_DRY = 217` (no fold, drive or spark)
- `ISD_P_DEBUG_RB_NO_ARP = 218`
- `ISD_P_DEBUG_RB_DRY = 219` (no chorus or hall)

**Ambience:** appended after Deep Water's six, making 50.
- **C:** `ISD_AMB_VENT_RUMBLE, ISD_AMB_LAVA_HISS, ISD_AMB_STEAM_VENT, ISD_AMB_ROCKFALL, ISD_AMB_ERUPTION_BOOM, ISD_AMB_PLUME_THUNDER, ISD_AMB_WET_TYRES, ISD_AMB_WIPERS, ISD_AMB_ENGINE, ISD_AMB_PASSING_CAR, ISD_AMB_ROOF_RAIN, ISD_AMB_FAR_SIREN`
- **Swift:** `AmbienceSource.ventRumble, .lavaHiss, .steamVent, .rockfall, .eruptionBoom, .plumeThunder, .wetTyres, .wipers, .engine, .passingCar, .roofRain, .farSiren`

**Names:**
- **Sets:** `volcano-rim` / **Volcano Rim** / *Molten* (`Mood.molten`); `neon-night-drive` / **Neon Night Drive** / *Wired* (`Mood.wired`). Mood values are in spec §10.
- **Instruments:** **Magma Bass** (`magmaBass`, `isMG`); **Replicant Brass** (`replicantBrass`, `isRB`), whose left hand is Chrome Bass.
- **Visuals:** **Magma Veins** (`MagmaVeins`) and **Light Trails** (`LightTrails`).
- **Sky:** `RedSprites` and `Satellites`, with modes `sprites.mode` and `satellites.mode` (`.off/.natural/.often`, default `.natural`). There is also a new `SkyState.farStorm`.
- **Weather:** `.ashfall` ("Ashfall") and `.supercell` ("Supercell"). `WeatherValues` gains `ash` and `rotation`, both defaulting to 0.
- **Excitement:** `Excitement`, `ExcitementFrame`, `BigMoment`, `Surprise`, `ExcitementAware`, and `SceneControls.excitement` (`ExcitementSettings`: energy `.auto/.manual(Float)`, moments `.off/.some/.lots`, surprises `.off/.rare/.often`, buildAndDrop `Bool`).
- **Credit:** `holdMyLiquor` (Kanye West, "Hold My Liquor", *Yeezus*, 2013). Neon Night Drive is place-born.

**`SkyU` rows:** 44 → 60. That's 6 for sprites, 8 for satellites, and 2 for the supercell: its axis and phase, then its green tint and rotation.

**Credits and respect:**
- The neon is wordless glyphs: no text, brands or logos.
- There are no police or emergency symbols.
- Nothing imitates a film; *Tears in Rain* is only a preset name.
- Cards are original art.

**Compiling: CI works.**
- Push the branch to the `mick` remote (`mickscalz/instrumentum`; the appsooloot account's Actions are locked for billing).
- Run `$SP/ciwatch.sh <sha>` in the background, where `$SP` = `/tmp/claude-0/-home-claude/5e9d351e-db02-586c-a41c-b9df62c86187/scratchpad`. Each run takes 10–25 minutes, so batch your fixes.
- Shaders also pass `python3 -I Scripts/mslcheck/mslcheck.py <root>` before pushing.
- Push to `origin` too.

**Commits** end with the session's attribution lines.

## Review focus

1. **Moments under a hammering.** Ten seconds of fff chords at 8 a second must fire no more moments than the cooldown allows, keep each world's flash count inside `FlashLimiter`, and never stack two eruptions or drops. Pinned in Task 5 (Core) and in Tasks 11 and 13 (worlds).
2. **Notes moved by the split or the arp.**
   - Moving Split, or switching Arp mode, while keys are held must release each note on the voice that started it: no stuck brass, no orphaned bass.
   - Switching instrument, world or preset mid-arp, panic, or a pedal held through a switch must silence the arp within 50 ms.
   - Pinned in Tasks 1 and 3.
3. **A quiet keyboard.** With no notes for 5 minutes (or MIDI unplugged), Energy decays to 0, tension to 0, and surprises stop. Sleep Fade and Hold the Moment freeze or stop everything. Pinned in Task 5.
4. **Old saves.** A build-249 save, and a Sets 7–12 save without `excitement`, `ash`, `rotation`, `sprites.mode` or `satellites.mode`, load with defaults. Pinned in Tasks 5, 8 and 9.
5. **Gentle and Reduce Motion.**
   - Gentle visuals: no flash from eruptions, drops, the tunnel strobe, fireworks, supercell lightning or flares, only glows.
   - Reduce Motion: no camera shake, Energy capped at 0.5 visually.
   - Pinned in Tasks 5, 9, 12 and 14.

---

### Task 0: Branch, previews, briefs, reservations
- [ ] **Branch:** cut `sets-13-14` from `small-wins` and add it to the previews `if:` in `.github/workflows/build.yml`.
- [ ] **Briefs:** write `docs/superpowers/briefs/magma-bass.md` and `replicant-brass.md` in the format of `blue-depth.md`, with the facts, targets, playing notes and preset tables from spec §4.2–§4.3.
- [ ] **Reserve numbers:** add the engine, parameter and test-hook numbers (Global constraints) to `include/InStrumDSP.h`. Don't add the engines yet. The ambience numbers come with Task 10, because adding them changes `ISD_AMB_COUNT` and the tables sized by it.
- [ ] **Commit:** `chore: Sets 13 & 14 branch, previews, briefs and reserved numbers`.

### Task 1: The vintage-synth core grows, and the shared arpeggiator (DSP)
**Files:**
- Modify: `AnalogVoice.hpp` (`Shaper` with ADAA fold and drive, `Unison<N>`, `FilterEnv`, `Glide`, `VoiceMode`, `MonoKeys`, `DrivenLadder`).
- Create: `Arp.hpp`.
- **Status:** done in the integrator's session on `sets-13-14`. It was verified with a C++ harness under g++ and clang: the arp's timing, modes, swing, hold, reset and phrase gap; the unison's equal power; the glide's arrival; and ADAA cutting aliasing by 10–13 dB. The Swift tests for these pieces go through the engines in Tasks 2 and 3, since the core has no C API of its own. Blue Depth is untouched.

**Interfaces** (as built; read the headers' API comments):
- `isd::analog::Shaper{ set(drive, fold, asym), reset(), process(x) }`: ADAA fold, then drive.
- `Unison<N>{ setCount(n), setSpread(cents), reset(seed), next(baseInc) }`
- `FilterEnv{ set(a, d, s, r, sr), setDepth(oct), setVelocityDepth(vd), gate(on, vel), next() / advance(n) → octaves }`
- `Glide{ setTime(s, sr), jump(st), glideTo(st), advance(n) → st, gliding() }`
- `VoiceMode{ poly, mono, legato }`, `MonoKeys{ press, release, top, topVelocity }`
- `DrivenLadder{ setDrive, setResonance, setCutoff, snapCutoff, process }`
- `isd::Arp{ prepare(sr, seed), setMode, setRate(beatsPerStep), rateFromIndex(i), setOctaves, setGate, setSwing, setHold, setTempo, keyDown(note, vel, clock), keyUp(note, clock), reset(), poll(clock, Event&) → bool, samplesToNext(clock), running() }`. Engines call `poll` until it returns false at each sub-block start, and render at most `samplesToNext` samples.

**Steps:** done (see Status). Tasks 2 and 3 carry the Swift-level tests (the drive's growl, the glide and the arp's timing through the engines). The C++ harness is `Scripts/dsp-harness/core_test.cpp` (see its README).

### Task 2: Magma Bass (DSP)
**Files:** `MagmaBass.{hpp,cpp}`, `Synth.cpp` (the engine 12 table, in spec §4.2's dial order; mood 100–104; hook 217), `Tests/InStrumAudioTests/DSP/MagmaBassTests.swift`, `CPUBudgetTests.swift`.

**Interfaces:**
- **Produces:**
  - `ISD_ENGINE_MAGMA_BASS` renders through `isd_synth_*`.
  - Swift dial order: Growl, Heat, Erupt, Rumble, Grit, Flow, Shape, Mono, Spark, Res, Space, Width.
  - `isd::magma::isEruptChord(notes, velocities, times)`: three or more note-ons within 40 ms, mean velocity ≥ 0.8, mean pitch < 48. The world's `BigMoments` uses the same rule (Task 5), so the sound's swell and the world's eruption agree. This replaces the spec's `ISD_H_MAGMA_ERUPT` hook (decision in the commit message).

**Steps:**
- [ ] **Write the tests** (RED):
  - `testMagmaTuning`: with DRY, E1–C4 are within 3 cents.
  - `testVelocityRipsTheFilterOpen`: on a held A1 over 0.05–0.4 s, the share of 0.5–4 kHz energy is ≥ 4 dB higher at vel 127 than vel 25 at the defaults, and ≥ 9 dB at Growl 0.
  - `testRumbleAddsSubTwo`: energy at f/4 is ≥ 10 dB higher at Rumble 1 than at 0.
  - `testGrowlDrives`: the third-to-first harmonic ratio rises monotonically with Growl.
  - `testMonoLegatoGlides`: with Mono, overlapping notes glide (no new onset with the DRY hook), and the pitch arrives within Flow's time.
  - `testSparkOnlyAboveC4`: C5 at Spark 1 has ≥ 6 dB more 2–6 kHz energy than at Spark 0. C3 is unchanged (±0.5 dB).
  - `testEruptChordSwells`: an fff four-note chord below C3 raises the 30–80 Hz RMS over 0.3–1.2 s by ≥ 2.5 dB against an mf chord. `isEruptChord` agrees with it.
  - `testMagmaCeiling`: a 6-note fff chord with Growl 1, Res .9 and Rumble 1 peaks ≤ −0.3 dBFS and stays finite.
  - `testStealingDoesNotClick`: the click detector passes over a full pool.
  - `CPUBudgetTests.testMagmaBassBudget`: < 6% for 6 held notes at Growl .8.
- [ ] **Implement** per spec §4.2, with presets *Magma*, *Basalt*, *Fissure* and *Ember Glide*.
- [ ] **Push to `mick`**, run `ciwatch.sh`, and fix until green.
- [ ] **Commit:** `feat(dsp): Magma Bass, the first bass on the vintage-synth core`.

### Task 3: Replicant Brass with Chrome Bass (DSP)
**Files:** `ReplicantBrass.{hpp,cpp}`, `Synth.cpp` (the engine 13 table; mood 100–104; hooks 218, 219), `Tests/InStrumAudioTests/DSP/ReplicantBrassTests.swift`, `CPUBudgetTests.swift`.

**Interfaces:**
- **Produces:**
  - `ISD_ENGINE_REPLICANT_BRASS`.
  - Swift dial order: Swell, Blaze, Width, Hall, Chrome, Punch, Arp, Rate, Split, Tempo, Space.
  - The engine remembers which layer (brass or bass) each held note started on.

**Steps:**
- [ ] **Write the tests** (RED):
  - `testSwellFollowsTheDial`: the time for 1–4 kHz energy to reach 90% is 40 ± 10 ms at Swell 0 and ≥ 450 ms at Swell 1.
  - `testBlareAtFullVelocity`: with Width 0 and the DRY hook on C4, the share above 1.5 kHz peaks within 100 ms at vel 127, ≥ 1.5× the peak at vel 76, which comes after 150 ms.
  - `testWidthSpreadsTheStack`: stereo correlation falls from ≥ 0.9 at Width 0 to ≤ 0.5 at Width 1.
  - `testSplitRoutesAndHolds` (Review focus 2): C2 plays bass, C4 plays brass. Moving Split to C5 while C4 is held, then releasing C4, releases the brass voice. There are no stuck voices after 1 s (RMS < −80 dBFS with the DRY hook).
  - `testChromeArpIsSampleAccurate`: Played, 1/16, Tempo 120; the onsets of a held C2-G2 are within 1 sample of 125 ms steps.
  - `testBendBladeAndFall`: a full bend gives +700 ± 10 cents. On release of the key with bend held, the pitch falls back over ≤ 120 ms.
  - `testArpStopsOnSwitch` (Review focus 2): a preset change mid-arp is silent within 50 ms.
  - `testReplicantCeiling`: a 10-note fff chord with Hall 1 peaks ≤ −0.3 dBFS, finite.
  - The click detector over a full pool.
  - `CPUBudgetTests.testReplicantBrassBudget`: < 8% for 6 brass notes plus a 2-note arp.
- [ ] **Implement** per spec §4.3, with presets *Replicant*, *Tears in Rain*, *Chrome Rush* and *Night Brass*.
- [ ] **Push to `mick`**, run `ciwatch.sh`, and fix until green.
- [ ] **Commit:** `feat(dsp): Replicant Brass with Chrome Bass and the arp in the left hand`.

### Task 4: Both instruments in the app, the Arp row, the cards
**Files:** `Patch.swift` (cases `magmaBass`, `replicantBrass`, with the presets), `BuiltInCatalog.swift` (`isMG`, `isRB`), the instrument panel (an Arp row for engines with `supportsArp`), `CreditLibrary.swift` (`holdMyLiquor`), `CardArt.swift` (cases `volcanoRim`, `neonNightDrive` with original art and easter eggs, spec §11), and tests (`PresetsTests`, `BuiltInLoadingTests`, `InspiredByCardTests`).

**Steps:**
- [ ] **Write the tests:**
  - Both engines load with their dial orders.
  - Presets round-trip.
  - The Arp row appears for Blue Depth, Magma Bass and Replicant Brass only.
  - The `holdMyLiquor` card has a text and Spotify-link credit only.
  - The drive's place card renders.
  - The cards breathe at the felt pulse (research the song's key and tempo; mark both "check by ear" in the release notes).
- [ ] **Implement it**, push to `mick` and get CI green.
- [ ] **Commit:** `feat(app): Magma Bass and Replicant Brass in the app, the Arp row, their cards`.

### Task 5: Excitement (Core) and its controls
**Files:**
- Create: `Sources/InStrumCore/Excitement/{Excitement,BigMoments,Surprises,Tension}.swift`; `Tests/InStrumCoreTests/ExcitementTests.swift`.
- Modify: `SceneDirector.swift` (owns an `Excitement`; it feeds note-ons and offs, steps with `visualDt`, hands the frame to every `ExcitementAware` model, and freezes when `holding`); `SceneControls` (`excitement: ExcitementSettings`, Codable with defaults); the scene panel and All settings (the Excitement section, spec §5); `AppModel` (gentle and Reduce Motion caps; Sleep Fade turns moments and surprises off).

**Interfaces:**
- **Produces:**
  - `ExcitementFrame { energy, tension, moment: BigMoment?, surprise: Surprise?, drop }`
  - `BigMoment { kind: .chord/.crescendo, strength: Float, low: Bool, isDrop: Bool }`
  - `Surprise { index: Int, seed: UInt64 }`. The index is into the world's own list.
  - `protocol ExcitementAware { mutating func setExcitement(_ e: ExcitementFrame) }`
  - `protocol SurpriseListing { static var surpriseCount: Int { get } }`
  - The formulas, thresholds, cooldowns and scheduler means are in spec §5.1–§5.4.

**Steps:**
- [ ] **Write the tests** (RED):
  - `testEnergyRisesFastFallsSlow`: 2 s of fff sixteenths takes Energy to ≥ 0.8 within 0.6 s, and silence brings it to ≤ 0.2 within 10 s.
  - `testHardChordFiresAMoment`: on Some, one chord of 4 notes at vel 0.9 within 30 ms gives one moment, strength ≥ 0.5. `low` is true below C3.
  - `testCooldownHolds` (Review focus 1): 10 s of fff chords at 8 a second gives ≤ 2 moments on Some and ≤ 4 on Lots.
  - `testCrescendoFires`: Energy rising from 0.3 to 0.8 over 2 s fires one `.crescendo`.
  - `testSurprisesAreSpacedAndNeverRepeat`: on Rare over a simulated hour of playing, all gaps are ≥ 90 s and no surprise repeats the last. On Often, all gaps are ≥ 30 s.
  - `testQuietKeyboardStopsEverything` (Review focus 3): after 5 minutes of silence, Energy is 0, tension is 0, and there are no surprises.
  - `testDropNeedsTension`: a moment with tension below 0.6 isn't a drop. Climbing pitch for 4 s and then a hard chord is (`isDrop`), and tension resets to 0.
  - `testHoldFreezesExcitement`: while `holding`, the frame doesn't change and no events fire.
  - `testGentleAndReduceMotionCaps` (Review focus 5): gentle forces moments to Some and surprises to Rare. Reduce Motion reports `visualEnergy = min(energy, 0.5)`.
  - `testOldSavesLoad` (Review focus 4): `SceneControls` JSON without `excitement` decodes to the defaults.
  - **Determinism:** the same seed and performance give the same events.
- [ ] **Implement** per spec §5, and make every existing model adopt `ExcitementAware` with an empty body for now.
- [ ] **Push to `mick`** and get CI green.
- [ ] **Commit:** `feat(core): Excitement: energy, big moments, surprises, build and drop`.

### Task 6: Every existing sky world gets its moment, surprises and build and drop (batch A)
**Worlds:** Moonlit Lake, Golden Hour Beach, Coast Road, Aurora Fjord, Bioluminescent Bay, Tea House Snow and Zen Rock Garden, as spec §5.5 lists them. Each world gets its Core model's handling and its renderer's drawing.

**Constraints:**
- Each world's work is ≤ 0.5 ms a frame.
- Fixed pools only.
- Flash events go through the scene's `FlashLimiter`.
- Reuse what each world draws already: the lake's meteor slots, the beach's fireworks from the original Fireworks Finale theme, the coast's beam, and so on.

**Steps:**
- [ ] **Write the tests** for each world:
  - `testMomentChangesTheFrame`: the preview renderer's frame differs by ≥ 2% of pixels 0.5 s after a moment.
  - `testSurprisesAllPlay`: each surprise index, played in turn, changes the frame and ends within its time.
  - `testBuildThenDrop`: tension 0.8, then a drop, gives the release.
  - The existing flash test over a hammered minute (Review focus 1).
- [ ] **Implement** per spec §5.5, push to `mick`, get CI green and report the preview PNGs.
- [ ] **Commit:** `feat(worlds): excitement in the seven sky worlds`.

### Task 7: The rest of the worlds (batch B)
**Worlds:** Spaceship Lounge, Snowbound Cabin, Bedroom at Dawn, Butterfly Garden, Midnight Steinway, Submarine Window and Great Barrier Reef. They follow the same steps and tests as Task 6.
- [ ] **Commit:** `feat(worlds): excitement in the interiors, space and Deep Water`.

### Task 8: Sky: red sprites and far storms; satellite passes and flares
**Files:**
- Create: `Sky/RedSprites.swift`, `Sky/Satellites.swift`; tests `RedSpritesTests.swift`, `SatellitesTests.swift`.
- Modify: `LivingSky.swift` (`farStorm`, the two modes; Codable defaults), `SkyLayer.swift` and `SkyShaders.swift` (16 `SkyU` rows: 44 → 60, with the supercell's 2 reserved for Task 9), the Sky extras section (two new rows), and the panel.

**Steps:**
- [ ] **Write the tests:**
  - **Sprites:** only at sun altitude below −12° with storm, thunderheads, dryLightning or a far storm. Each lasts 80–160 ms. Their added luminance is ≤ 0.04. They pass the flash test.
  - **Far storms:** on Natural, about 1 per 2–4 hours of clear-night viewing, each 5–20 minutes, seeded.
  - **Satellites:**
    - only while the sun is below −6° and the satellite is sunlit (height-based);
    - shadow entry falls on the anti-sun side;
    - flares peak ≤ Venus and last 2–10 s;
    - station passes happen once or twice an evening;
    - the city skyglow hides satellites fainter than mag 2 (as a world flag);
    - 4–10 an hour after dusk on Natural.
  - **Old saves** without the modes load as Natural (Review focus 4).
- [ ] **Implement** per spec §6, with mslcheck clean. Push to `mick` and get CI green with sky previews (a sprite mid-flash, a pass, a flare).
- [ ] **Commit:** `feat(sky): red sprites over far storms; satellite passes and flares`.

### Task 9: Weather: Ashfall with embers; the Supercell
**Files:** `Weather.swift` (`.ashfall`, `.supercell`; `ash`, `rotation`), `Sky/Supercell.swift` (the staged event), the shared weather and cloud layers (ash through the snow path; embers where `emberSource`; the supercell's rotating wall cloud, mammatus, green grade and hail), `WeatherAmbience.swift`, `WorldWeather.swift` (the Random Beautiful tables), and tests.

**Steps:**
- [ ] **Write the tests:**
  - **Ashfall:** has spec §7.1's values; embers only appear when `emberSource` is set; the sun and moon redden under it.
  - **Supercell:** its stages run Approach → Core → Clearing over 8 minutes; when picked it holds Clearing; Calm random never picks it; its lightning passes the flash test; under gentle there is no flash (Review focus 5).
  - **Old weathers** are unchanged, and old saves load (Review focus 4).
  - **Random Beautiful** offers Ashfall only at the volcano and Supercell only at the four storm worlds and the drive.
- [ ] **Implement** per spec §7, push to `mick` and get CI green with previews (ash over the lake, the supercell's core over the beach).
- [ ] **Commit:** `feat(weather): Ashfall with embers; the Supercell`.

### Task 10: Ambience: the volcano and drive families
**Files:** `Ambience.cpp`/`.hpp` (12 sources), `AmbienceScene.swift`, the triggers (eruption boom on Eruption; passing cars from the drive's traffic; wipers at the wiper rate; the far siren in key through the existing in-key family) and tests.

**Steps:**
- [ ] **Write the tests:**
  - Each source is finite and bounded at 1.0.
  - The vent rumble sits ≥ 10 dB under Magma Bass at defaults.
  - The engine's pitch follows speed and drops at shifts.
  - Passing cars Doppler down.
  - The far siren lands on the key's scale tones (±10 cents) and is off under gentle.
  - Together they're < 8% CPU at 0.6.
- [ ] **Implement** per spec §8.3 and §9.3, push to `mick` and get CI green.
- [ ] **Commit:** `feat(ambience): the volcano and the drive`.

### Task 11: Volcano Rim model and Magma Veins (Core)
**Files:** `Worlds/VolcanoRimModel.swift` (`SkyAware`, `MoodAware`, `ExcitementAware`, `AmbienceProviding`), `Worlds/MagmaVeins.swift`, `SceneDirector.swift` (the registry entry), tests.

**Interfaces:**
- **Produces:**
  - `VolcanoRimModel` state for the renderer: crack glows (64 cells), blobs (a pool of 24), bombs (16), embers (400), plume lightning strokes (4), the eruption phase, the breach river and the camera shake.
  - `MagmaVeins`: 96 veins and a plate set.

**Steps:**
- [ ] **Write the tests** (spec §8.1–§8.2):
  - A note brightens the cell nearest its key's position.
  - Below C3, a note spits 1–3 blobs.
  - An Eruption's height and bomb count scale with strength.
  - A drop opens the breach.
  - Energy drives the fountain, the river, the embers and the lightning rate (0.05 → 0.6 a second).
  - Camera shake is 0 under Reduce Motion.
  - Pools never grow.
  - A hammered minute stays inside `FlashLimiter` (Review focus 1).
  - Magma Veins: chords connect veins; a moment splits the plates.
- [ ] **Implement**, push to `mick` and get CI green.
- [ ] **Commit:** `feat(core): Volcano Rim and Magma Veins`.

### Task 12: The volcano renderer
**Files:** `Visuals/Worlds/VolcanoRimRenderer.swift`, `VolcanoRimShaders.swift`, `MagmaVeinsRenderer.swift`, `ThemeCanvas`/`PreviewRenderer` branches (including `editingSky`), and preview tests.

**Steps:**
- [ ] **Implement** per spec §8 and §12:
  - the Voronoi crust from 64 seeds;
  - blackbody colours from 700 to 1450 K;
  - plume billboards (≤ 12), lit from below;
  - instanced embers;
  - the sky with the plume's glow;
  - the strokes from the existing lightning;
  - ≤ 6 ms at 1 MP.
- [ ] **Checks:** mslcheck clean; the preview tests pass at deep night, Energy 0, Energy 1 and mid-Eruption; no flash under gentle (Review focus 5); the preview PNGs reported.
- [ ] **Commit:** `feat(app): the Volcano Rim renderer and Magma Veins`.

### Task 13: Neon Night Drive model, Light Trails and the windscreen (Core and Window Kit)
**Files:** `Worlds/NeonNightDriveModel.swift` (on `CoastRoadModel`'s speed and distance and on `CoastLights`), `Worlds/LightTrails.swift`, the Window Kit's windscreen (`WindowSpec.windscreen(...)` with wipers), tests.

**Steps:**
- [ ] **Write the tests** (spec §9.1–§9.2):
  - Speed is 0.25 + 0.55·Energy and follows `instrumentPulse`.
  - The neon hue eases towards the chord's colour over 0.4 s.
  - Each note pulses a sign.
  - The road studs follow the arp's onsets.
  - Tension closes the towers in and strobes the tunnel at ≤ 3 Hz.
  - The Drop bursts onto the bridge, and the city-wide neon wave stays inside `FlashLimiter` (Review focus 1).
  - The surprises play.
  - The wipers' rate follows rain.
  - Light Trails' ring holds 128 and never grows.
- [ ] **Implement**, push to `mick` and get CI green.
- [ ] **Commit:** `feat(core): Neon Night Drive, Light Trails and the windscreen`.

### Task 14: The drive renderer
**Files:** `Visuals/Worlds/NeonNightDriveRenderer.swift`, `NeonNightDriveShaders.swift`, `LightTrailsRenderer.swift`, the `ThemeCanvas`/`PreviewRenderer` branches, and preview tests.

**Steps:**
- [ ] **Implement** per spec §9 and §12:
  - road and tower planes;
  - hashed window grids;
  - SDF neon glyphs (≤ 48, wordless);
  - the wet-road streak reflections;
  - the windscreen rain and wipers;
  - bloom;
  - ≤ 7 ms at 1 MP.
- [ ] **Checks:** mslcheck clean; previews at deep night, Energy 0, Energy 1 and mid-Drop; under gentle, no strobe and no neon flash (Review focus 5); the PNGs reported.
- [ ] **Commit:** `feat(app): the Neon Night Drive renderer and Light Trails`.

### Task 15: Sets 13 & 14, gallery, release notes, demos
- [ ] **Sets:** add both to `SetLibrary` (spec §2 and §11) at the end of the gallery. Galaxy Warp is each world's third visual.
- [ ] **Release notes:**
  - the two worlds and two instruments;
  - the Excitement controls and what each world now does (spec §5.5);
  - the new sky features and weathers;
  - a play-along tip each;
  - "check by ear" for the credit's key and tempo;
  - "Gassed Up" as a possible credit.
- [ ] **Demos:** a Magma Bass eruption riff, and a Replicant Brass swell over the Chrome arp.
- [ ] **Tests:** the set tests (one of everything per set), the gallery order, and loading old saves (Review focus 4).
- [ ] **Commit:** `feat: Sets 13 & 14, Fire & Neon`.

### Task 16: A short review, one fix pass, release
- [ ] **Review:** one fresh reviewer across the branch, on the Review focus first.
- [ ] **Fix:** one fix pass.
- [ ] **CI:** green on `mick`.
- [ ] **Merge:** merge into `small-wins`, which stays the integration branch.
- [ ] **Hand it over:** send Michael the dmg link with a 5-line "try this" list.
- [ ] **Status doc:** write `claude/2026-11-0X-sets-13-14-status.md` and update the backlog (#2 and #26 done; red sprites, satellites, Ashfall and Supercell done).

## Execution
Subagent-driven, at most **two agents at a time** on Extra effort. The integrator (the main session) merges, fixes small things and keeps the docs.

**Order:**
- Tasks 0 and 1 are done (the integrator). The agents split up:
  - **Agent A** takes 2 → 3 → 4 (the instruments).
  - **Agent B** takes 5 → 6 → 7 (Excitement).
- Then A takes 8 → 9 → 10 and B takes 11 → 12, followed by 13 → 14 split between them, then 15 and 16.
