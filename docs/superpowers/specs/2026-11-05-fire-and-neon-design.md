# Sets 13 & 14: Volcano Rim and Neon Night Drive ("Fire & Neon"), Design Spec

**Date:** 2026-11-05
**Status:**
- Written to Michael's instructions of 5 Nov: less boring worlds, variables for more excitement, at least one bass, and synths. Build more, polish later. No questions.
- The inputs are in `2026-11-05-fire-and-neon-brief.md`. Every choice the brief doesn't settle is in §17, with what it costs if Michael decides otherwise.
- **This run goes before Home Lights.** Home Lights (`2026-11-05-sets-13-14-design.md`) becomes Sets 15 & 16, and its engines and parameters move up when it is built.

**Builds on:**
- `2026-11-04-sets-11-12-design.md`: the analogue-voice core (`AnalogVoice.hpp`), meteors and `SkyU`'s 44 rows, `instrumentPulse`, and the sonar in key.
- `2026-11-04-sets-9-10-design.md`: pitch bend and aftertouch, ambience in key, and optional credits (place cards).
- `2026-10-28-sets-3-4-design.md`: the coast road's driving model (`CoastRoadModel`, `CoastLights`) and ambience events.
- `2026-11-04-small-wins-design.md`: `SceneControls`, `visualDt`, `holding` (Hold the Moment), and Follow Reduce Motion.

**Backlog:**
- **Worlds:** #2 Volcano Rim and #26 Neon Night Drive.
- **SkyKit:** red sprites, with far storms (Set 13), and satellite passes and flares (Set 14). Both come from pairings §7.4.
- **WeatherKit:** Ashfall, with embers (Set 13), and Supercell (Set 14), after backlog #6 Supercell Sky.
- **Ambience:** two new families: the volcano's 6 sources and the drive's 6.
- **New for every world:** the Excitement system (§5).

---

## 1. Purpose

The last three runs were calm, and Michael found the latest build "okay, was expecting more". This run is the loud one, and it has three goals:
- **The worlds answer you.** Every hard chord changes something you can see within a frame: lava spits, an eruption, a lightning strike, the road opening up.
- **The first basses and the first synth brass** stand beside the pianos, bells and pads, and they start the vintage-synth core that about 14 later worlds need.
- **Every world gets more exciting, not just these two.** The Excitement system (§5) gives the eleven existing worlds an energy reading, a signature big moment, rare surprises, and build and drop.

### Success looks like
- Playing a hard low chord on Volcano Rim sets off an eruption you feel in the sub-bass and see in the sky, the first time, with no settings touched.
- Neon Night Drive's car speeds up when you play faster and harder. Its neon changes with your chords, and a big chord after a build brings a "drop".
- Magma Bass growls, and its filter visibly and audibly rips open with velocity. Replicant Brass swells like a film score, and Chrome Bass drives the left hand with a tempo-locked arpeggio.
- In every existing world, hammering a chord does something new and fitting, and resting lets the world settle again.
- Smooth on the Intel Mac. Flashes stay inside `FlashLimiter`. Gentle visuals, Reduce Motion and Hold the Moment all calm it. Old saves load.

### Standing rules (unchanged)
- **One of everything, per set (1:1:1:1:1:1):** each set has its own world, its visual, an original instrument, a new sky feature, a new weather and a new ambience family, all tied by a mood. Each set's sky feature and weather reach every world that has a sky.
- **Original synthesis only:** no samples, and no protected library copied, extracted or decrypted.
- **Credits are text plus a Spotify link only;** place-born sets get a place card.
- **Smooth on the Intel Mac:** ≤ 1 MP, no per-pixel ray marching, ≤ 3 noise octaves, no buffers made per frame.
- **Every flash goes through `FlashLimiter`.** Older saves still load. Tests come first.
- **Respect over cliché.**

---

## 2. The two sets

| | Set 13 | Set 14 |
|---|---|---|
| World | **Volcano Rim** (`volcano-rim`) | **Neon Night Drive** (`neon-night-drive`) |
| Visual | **Magma Veins** | **Light Trails** |
| Instrument | **Magma Bass** (`magmaBass`, subtype `isMB`, `ISD_ENGINE_MAGMA_BASS = 12`) | **Replicant Brass** with **Chrome Bass** in the left hand (`replicantBrass`, subtype `isRB`, `ISD_ENGINE_REPLICANT_BRASS = 13`) |
| Core | **Vintage-synth core**: grows `AnalogVoice.hpp` (§4.1) | the same |
| Mood | *Molten* (`Mood.molten`) | *Wired* (`Mood.wired`) |
| Credit | Kanye West, "Hold My Liquor" (*Yeezus*, 2013), the backlog's credit | Place card ("Gassed Up" by Wombat pending Michael's listen) |
| Signature big moment | **Eruption** | **The Drop** |
| SkyKit | **Red sprites** (with far storms): seen from the rim above storms on the plain | **Satellite passes and flares**: lights crossing the sky between the towers, with the odd bright flare |
| WeatherKit | **Ashfall**, with embers at the rim | **Supercell**: a rotating storm with a wall cloud, green-tinted light, inflow gusts, hail bursts and lightning |
| Ambience | `ventRumble`, `lavaHiss`, `steamVent`, `rockfall`, `eruptionBoom`, `plumeThunder` | `wetTyres`, `wipers`, `engine`, `passingCar`, `roofRain`, `farSiren` (in key) |
| Default light | Deep night | Deep night |

Both sets go at the end of the gallery, in this order.

---

## 3. How it fits together

| Piece | Where | New or grows |
|---|---|---|
| Vintage-synth core | `Sources/InStrumDSP/AnalogVoice.hpp` | grows: drive, wavefolder, unison, a filter envelope with velocity depth, glide, mono/legato |
| Arpeggiator | `Sources/InStrumDSP/Arp.hpp` (new, shared) | new; Blue Depth's private arp moves onto it, locked by a fingerprint test first |
| Magma Bass, Replicant Brass | `MagmaBass.{hpp,cpp}`, `ReplicantBrass.{hpp,cpp}` | new engines 12 and 13 |
| Excitement | `Sources/InStrumCore/Excitement/` (new): `Excitement.swift`, `BigMoments.swift`, `Surprises.swift`, `Tension.swift` | new; `SceneDirector` owns one |
| `ExcitementAware` | `SceneDirector.swift` | new protocol, which every world model adopts |
| Red sprites | `Sky/RedSprites.swift` (Core), `SkyShaders.swift` (App) | new (Set 13's sky feature) |
| Satellites | `Sky/Satellites.swift` (Core), `SkyShaders.swift` (App) | new (Set 14's sky feature) |
| Ashfall | `Weather.swift` (`.ashfall`), shared weather layer, `WeatherAmbience` | new weather kind (Set 13) |
| Supercell | `Weather.swift` (`.supercell`), `Sky/Supercell.swift` (Core), the cloud and weather layers (App) | new weather kind (Set 14) |
| Ambience | `Ambience.cpp`, 12 new sources (38 → 50) | grows |
| The worlds | `VolcanoRimModel`, `NeonNightDriveModel` (Core); their renderers and shaders (App) | new |
| Visuals | `MagmaVeins`, `LightTrails` (Core) | new |
| Controls | `SceneControls.excitement`, the Excitement section in the panel and in Advanced | new |

---

## 4. The instruments

### 4.1 The vintage-synth core (grows `AnalogVoice.hpp`)
Blue Depth already has two shaped oscillators, a sub, noise, Slop, a 4-pole ladder, a high-pass and two envelopes. The core adds the following, all header-only in `isd::analog` and allocation-free:
- **`Drive`:** a pre-filter soft clipper. `y = tanh(g·x) / tanh(g)` with `g = 1 + 11·drive`, band-limited by 2× oversampling of the clipper alone (a half-band pair). There is also an `asym` term, `x + 0.15·asym·x²` before the tanh, for even-harmonic grit.
- **`Fold`:** a sine wavefolder, `sin(π/2 · (1 + 3·fold) · x)`, after the oscillators and before the drive, oversampled with the drive.
- **`Unison`:** 1–7 saws spread ±`spread` cents, with seeded phases and an equal-power level. This is for the brass's width; the basses use 1–2.
- **`FilterEnv`:** the ladder's own ADSR, with depth in octaves (−4…+6). Its **velocity depth** scales the depth by `(1 − vd) + vd·velocity`, so hard playing opens the filter wide. Aftertouch adds `+pressure × pd` octaves, smoothed at 15 ms.
- **`Glide`:** portamento in constant time (5–600 ms) or constant rate. Legato mode glides only on overlapping notes.
- **Voice modes:** `poly`, `mono` (last-note priority, retrigger), and `legato` (no retrigger, glide).
- **`LadderDrive`:** feedback saturation inside the ladder (the existing tanh), with a gain trim, so resonance growls instead of whistling.

**Cost:**
- Each piece is measured in CI by the existing per-voice cycle test. The budget is 270 cycles per voice per sample, and the 2× clipper is the costliest piece (about 40 cycles).
- Unison saws cost about 12 cycles each, so the brass's 7-saw stack is held to 6 voices (§4.3).

### 4.2 Magma Bass (Set 13)
A growling analogue bass for a crater's edge.

- **Voice:** a shaped oscillator (saw to square), a sub square an octave down, and a sine **Rumble** two octaves down. Then the fold, drive, ladder (with LadderDrive), a high-pass at 25 Hz, and the amp envelope.
- **Voices:** 6, pool 8.
  - Poly by default, with a **Mono** switch (mono-legato, glide 80 ms).
  - Notes above C4 go to a thin "spark" layer instead: a band-passed, folded, octave-up partial, about −14 dB. So the right hand adds fire, not mud.
- **Range:** E0–C6, with foldback above.
- **Dials** (parameter ids 130–139):

| Id | Dial | Range · default | What it does |
|---|---|---|---|
| 130 | **Growl** | 0…1 · 0.55 | Drive 0→1 and LadderDrive together, with the fold riding at 0.4 × Growl² |
| 131 | **Heat** | 0…1 · 0.5 | The cutoff's base, 60 Hz → 2.4 kHz (exponential) |
| 132 | **Erupt** | 0…1 · 0.7 | The filter envelope's velocity depth. At 1, ppp stays dark and fff opens +5 octaves |
| 133 | **Rumble** | 0…1 · 0.35 | The level of the sub-2 sine (with a soft shelf so it never clips the bus) |
| 134 | **Grit** | 0…1 · 0.25 | The asymmetric term and noise into the drive |
| 135 | **Flow** | 0…1 · 0.2 | The glide time, 5 → 600 ms; above 0.6, every note glides |
| 136 | **Shape** | 0…1 · 0.15 | The oscillator's saw → square → narrow pulse |
| 137 | **Mono** | off/on · off | Mono-legato |
| 138 | **Spark** | 0…1 · 0.4 | The level of the right-hand spark layer |
| 139 | **Res** | 0…0.9 · 0.35 | The ladder's resonance |

- **Envelopes:**
  - Amp: A 2 ms, D 0.9 s, S 0.7, R 0.25 s.
  - Filter: A 4 ms, D 0.35 s, S 0.25, R 0.3 s, depth +3 octaves at Erupt 0.7.
  - Velocity also adds up to +4 dB.
- **Aftertouch:** +1.5 octaves of cutoff and +0.2 Growl. **Pitch bend:** ±2 semitones. **Mod wheel:** a slow 5–7 Hz filter wobble.
- **Presets:** *Magma* (the default), *Basalt* (dark, mono, Rumble up), *Fissure* (bright, Res 0.6, short decay) and *Ember Glide* (Mono, Flow 0.7).
- **Signature behaviour:**
  - A hard low chord (velocity > 0.8, three or more notes below C3) adds a 1.2-second *swell* to the rumble (+3 dB, slow attack). That's the sound of the eruption the world plays at the same moment (§5.2).
  - The engine reports it through the existing `instrumentPulse`-style hook as `ISD_H_MAGMA_ERUPT`, so the world and the sound agree.

### 4.3 Replicant Brass and Chrome Bass (Set 14)
A huge, swelling film-score synth brass in the right hand. A punchy bright bass with an arpeggiator in the left.

- **The split:** keys below the **Split** point (default C3; Advanced, E1–C4) play **Chrome Bass**, and keys above it play **Replicant Brass**. With Split off, everything is brass.
- **Replicant Brass:**
  - **Voice:** a 7-saw unison stack (±9 cents), mixed with a pulse at 30%. Then the ladder at 12 dB per octave (2 poles), the brass envelope, then a shared chorus and a big shared hall.
  - **Voices:** 6, pool 8.
  - **The brass envelope:** the filter's attack is slow (180 ms), so every note **swells**. At velocity 1 the attack is 70 ms with a +2-octave overshoot that settles in 300 ms: the "blare".
  - **Aftertouch** brightens (+2 octaves) and adds a 5 Hz vibrato that fades in.
  - **The pitch-bend "blade":** bend glides up to ±7 semitones, with a fall-off on release, like a ribbon.
- **Chrome Bass:**
  - **Voice:** two saws an octave apart plus the sub, a fast filter pluck (decay 140 ms, +4 octaves), and a drive at 0.35.
  - **Voices:** 2, mono-legato by default.
  - **Arp:** the shared arpeggiator (§4.4) on by default for the bass. It plays sixteenths in the order the notes were held, at the world's tempo.
- **Dials** (parameter ids 140–149):

| Id | Dial | Range · default | What it does |
|---|---|---|---|
| 140 | **Swell** | 0…1 · 0.6 | The brass filter's attack, 40 → 600 ms; at 0 it's a stab |
| 141 | **Blaze** | 0…1 · 0.5 | The brass's brightness and overshoot |
| 142 | **Width** | 0…1 · 0.7 | The unison spread, ±2 → ±16 cents, and the chorus depth |
| 143 | **Hall** | 0…1 · 0.55 | The shared hall's send (a size of 0.85 fixed: the Blade Runner scale) |
| 144 | **Chrome** | 0…1 · 0.6 | Chrome Bass's level against the brass |
| 145 | **Punch** | 0…1 · 0.5 | The bass pluck's depth and drive |
| 146 | **Arp** | Off / Up / Down / Played / Random · Played | The bass's arpeggiator mode |
| 147 | **Rate** | 1/4, 1/8, 1/8T, 1/16, 1/16T, 1/32 · 1/16 | The arpeggiator's rate against the tempo |
| 148 | **Split** | off, E1…C4 · C3 | The split point |
| 149 | **Tempo** | 70…170 · 120 BPM | The tempo. With **Follow**, it tracks the played tempo (`instrumentPulse`) |

- **Presets:** *Replicant* (the default), *Tears in Rain* (Swell 0.85, Hall 0.8; no film quote is used, the name is only a nod), *Chrome Rush* (Arp Up 1/16, Punch 0.8) and *Night Brass* (split off, brass only).

### 4.4 The shared arpeggiator (`Arp.hpp`)
- **Modes:** Up, Down, Up-down, Played and Random (seeded).
- **Octaves:** 1–3. **Gate:** 0.1–1.0. **Swing:** 0–0.5. **Hold:** latches the last chord until a new one.
- **Timing:**
  - It is sample-accurate against `samplesToNextArpEvent()`, the way Blue Depth already schedules.
  - Its tempo comes from the engine's Tempo parameter, or from the app's `instrumentPulse` when Follow is on.
  - Its rate menu is shared.
- **Blue Depth's private arp moves onto it.** A fingerprint test locks Blue Depth's current output first, so nothing it plays changes.
- **The app:** an **Arp** row in the instrument panel for any engine that declares `supportsArp` (Blue Depth, Magma Bass, Replicant Brass at first). It has Mode, Rate and Hold, and the sustain pedal can act as Hold (an Advanced option).

### 4.5 CPU budget (measured in CI)
- **Magma Bass:** 6 voices × about 230 cycles.
- **Replicant Brass:** 6 voices × about 260 cycles (7 saws).
- **Chrome Bass:** 2 × about 150 cycles.
- **The shared chorus and hall:** about 6% of one core.
- **The budget test:** a 10-note chord plus the arp, on the macos-15 runner, must stay under the existing per-engine limit.

---

## 5. Excitement: variables for every world

A shared Core system, `Excitement`, owned by `SceneDirector`, reads how you play and gives every world four things: **Energy**, **Big moments**, **Surprises**, and **Build and drop**.

World models adopt `ExcitementAware`:

```swift
public protocol ExcitementAware {
    mutating func setExcitement(_ e: ExcitementFrame)
}
public struct ExcitementFrame: Equatable {
    public var energy: Float          // 0…1, smoothed (§5.1)
    public var tension: Float         // 0…1 (§5.4)
    public var moment: BigMoment?     // set for exactly one step when a moment fires (§5.2)
    public var surprise: Surprise?    // set for exactly one step (§5.3)
    public var drop: Float            // 0…1, the release envelope after a drop (§5.4)
}
```

**The panel:** an **Excitement** section in the scene panel and in All settings (`SceneControls.excitement`, Codable, with defaults so old saves load):
- **Energy:** Auto or Manual, with a dial for Manual.
- **Big moments:** Off, Some or Lots (the default is Some).
- **Surprises:** Off, Rare or Often (the default is Rare).
- **Build and drop:** on or off (the default is on).

**What calms it:**
- **Gentle visuals:** big moments go to Some, flash events lose their flash (their motion stays), and surprises go to Rare.
- **Reduce Motion (when Small Wins lands):** Energy caps at 0.5 visually, and moments play at half strength.
- **Hold the Moment:** freezes Excitement along with everything else.

### 5.1 Energy
```
e_raw = 0.45·v̄ + 0.35·rate + 0.20·size
  v̄    = mean velocity of note-ons in the last 2 s (0 if none)
  rate = clamp(note-ons per second / 8, 0, 1)
  size = clamp((notes held − 1) / 7, 0, 1)
```
- **Smoothing:** a one-pole, 0.25 s up and 4 s down, so it leaps when you dig in and settles slowly when you stop. Silence for 3 s pulls it towards 0 at the slow rate.
- **The mapping:** each world maps Energy to its own busy, bright and fast dials. Every world's mapping is listed in §5.5.
- **The existing reaction system:** keeps its `Role.energy` (per visual). The two are different: a visual's role energy follows the instant, while scene Energy is the world's slower state.

### 5.2 Big moments
A **moment** fires on either of two triggers.

**A hard chord:**
- three or more note-ons within 40 ms;
- mean velocity at or above the threshold (Some: 0.78; Lots: 0.65);
- and at least 2.5 s since the last moment (Some: 6 s; Lots: 2.5 s).

**A crescendo:**
- Energy rises by 0.35 or more within 3 s and passes 0.75.

**The event:** `BigMoment(kind: .chord | .crescendo, strength: 0…1, low: Bool)`, where `low` means the chord's mean pitch is below C3. `strength` = (velocity − threshold) / (1 − threshold), with a floor of 0.3.

**What each world does:** every world names one **signature moment** (§5.5) and plays it at that strength.
- Moments that light the sky ask the scene's `FlashLimiter` for budget. When there isn't enough, they play darker but still move. Under gentle visuals they never flash.
- **Tests:**
  - A seeded performance fires exactly the expected moments.
  - No moment fires inside the cooldown.
  - A flash moment within the budget passes the existing flash test (≤ 3 flashes a second, no red flash over 20% of the screen).

### 5.3 Surprises
- **Each world lists 3–5 surprises** (§5.5). A seeded scheduler (per world and session) picks one at random intervals:
  - **Rare:** a mean of 4 minutes, never sooner than 90 s.
  - **Often:** a mean of 75 s, never sooner than 30 s.
  - It never repeats the last surprise.
- **They only happen while you're playing** (Energy > 0.1 at some point in the last 20 s), so a parked world stays calm. Sleep Fade turns them off.
- **They're real where possible:** a fireball, a sprite, a comet's tail, a breaching whale, a satellite flare.

### 5.4 Build and drop
**Tension** rises while:
- pitch climbs (the mean of the last 8 note-ons rises by more than 5 semitones over 4 s);
- or the playing gets louder and denser (Energy's slope is above 0.05 a second);
- and it falls back slowly when neither is true (−0.08 a second).

**The drop:** when tension is above 0.6 and a big moment fires, the world gets a **drop**:
- tension snaps to 0;
- `drop` jumps to 1 and decays over 2.5 s;
- the world plays its release (§5.5).

**Tension's look:** each world shows tension as gathering: light pulls in, the wind rises, the lava swells. That way the drop has something to release.

### 5.5 What each world does
The new worlds are in §8 and §9. Each existing world gets the following:

| World | Energy drives | Signature moment | Surprises | Build → drop |
|---|---|---|---|---|
| Moonlit Lake | ripple density, the wind on the water | a **meteor burst** over the lake (5–12 meteors from one radiant, mirrored) | a fireball, an owl crossing the moon, a fish rising | the mist gathers, then lifts all at once |
| Spaceship Lounge | the warp's star speed | a **warp jump** (the stars stretch, then snap back) | a comet passing the window, a far ship's lights, a pulsar blink | the hum rises, then the jump |
| Golden Hour Beach | the surf height, the gulls | **fireworks** down the beach (3–9 shells, through the limiter) | a dolphin pod, a kite, a green flash at sunset (real) | the swell builds, then a big wave |
| Coast Road | the car's speed, the traffic | **the lighthouse beam sweeps round** with a horn swell | a fox crossing, a far train, a shooting star | headlights gather, then the road opens onto the sea |
| Snowbound Cabin | snowfall, the fire's flare | **the fire roars up** and snow whirls past the glass | an owl on the sill, the aurora's edge, a star through a break in the clouds | the wind rises, then the gust |
| Bedroom at Dawn | the curtains' breath, the dust motes | **the sun breaks through**: the light floods in | a bird on the sill, a paper plane past the window, a rainbow | the light gathers, then the flood |
| Aurora Fjord | the aurora's speed and height | an **aurora surge** (a corona overhead) | a fireball, an orca's blow in the fjord, a satellite flare | the curtains gather, then the surge |
| Bioluminescent Bay | the plankton's glow | a **wave of light** across the whole bay | a manta's glow, a turtle, a fireball | the glow gathers under the surface, then breaks |
| Tea House Snow | snowfall, the lanterns | a **gust of snow** off the roof, with the temple bell | a fox on the path, a crane flying over, a crystal flash | the snow thickens, then the gust |
| Zen Rock Garden | the rake lines' flow | the **shishi-odoshi strikes** and the ripples run out across the gravel | a deer at the wall, a falling leaf storm, a moonbow | the water fills, then the knock |
| Submarine Window | the creatures' traffic | a **whale passes** the porthole | an anglerfish light, a squid cloud of light, a far sub's sonar | the dark gathers, then the whale |
| Great Barrier Reef | the fish schools, the coral pulse | a **spawning burst** (coral release, through the limiter) | a manta, a turtle, a reef shark's slow pass | the school tightens, then it bursts |
| Butterfly Garden, Midnight Steinway | the existing reactions | Butterfly: **a swarm takes off**. Steinway: **the spotlight blooms** | Butterfly: a hummingbird, rain on the glass. Steinway: a dust motes' shimmer, the curtain stirring | the light gathers, then the bloom |

All of them are **original, simple animations** built on what each world already draws: particle bursts, light envelopes, an existing creature or a sprite. None needs a new heavy renderer, and every world's work is ≤ 0.5 ms a frame (see §12).

---

## 6. Sky (SkyKit): one new feature per set

### 6.1 Set 13: red sprites

**The phenomenon:**
- Red sprites are faint red-to-magenta flashes 50–90 km up, above strong thunderstorms more than 100 km away.
- Each lasts 10–100 ms, shaped like a jellyfish or a carrot: a red crown with bluish tendrils below.
- They are best seen at night with a dark sky over a distant storm.

**In the app (Core, `RedSprites`):**
- **When:** sprites appear when it is night (sun altitude below −12°) and the sky has thunderheads, storm or dryLightning, either in this world's weather or as **far storms**.
  - **Far storms** are a new low-probability state for clear nights: a storm below the horizon in one direction, with lightning flickering on the horizon clouds. It is seeded and lasts 5–20 minutes of viewing.
- **Rate:** about one every 20–60 s during a far storm. A surprise or a big moment can call one too.
- **Shape:** each sprite is 1–3 columns at a seeded azimuth, 4–9° above the horizon and 2–4° tall, lit for 80–160 ms with a 60 ms glow fade.
- **How it's drawn:** an analytic shape in `skyRadiance` (no texture, no ray march) in 6 new `SkyU` rows: 3 slots × (azimuth, altitude, size, brightness) plus timing.
- **Brightness:** never more than a faint glow (it adds at most 0.04 of the sky's luminance). That's far below any flash threshold, but it still passes through the limiter's accounting.
- **Settings:** All settings → Sky extras: **Red sprites** Off / Natural (the default) / Often.

### 6.2 Set 14: satellite passes and flares
**The phenomenon:**
- After dusk and before dawn, sunlit satellites cross a dark sky as steady points, taking 2–6 minutes from horizon to horizon.
- Some fade out as they enter Earth's shadow.
- A few flash briefly to −3…−8 mag when a flat panel catches the sun: a flare lasting 2–10 s.
- Bright stations cross slowly and steadily at about −2…−4 mag.
- Freshly launched trains cross as a short line of evenly spaced points.

**In the app (Core, `Satellites`):**
- **When:** passes appear only while the sky is dark enough (sun below −6°), the satellite is still in sunlight, and it's within about 2.5 hours of dusk or dawn.
  - Sunlit is worked out from the satellite's height (350–1200 km) and the sun's depression, so passes fade into shadow at the right side of the sky.
- **Seeded and plausible, not live orbits** (a later option can load a real orbit snapshot):
  - each pass has an inclination-shaped great-circle track, a speed set by its height, a brightness from its size and phase, and a shadow-entry point;
  - a **station** pass is rare (one or two an evening) and bright;
  - **trains** are rare (Natural: about one a week of viewing).
- **Rate:** Natural is about 4–10 passes an hour after dusk, falling off through the night. Often is 3× that.
- **Flares:**
  - Up to one an hour, with a 6-second brightening and fade. They peak no brighter than Venus.
  - They pass through `FlashLimiter`'s accounting. They aren't flashes (they last seconds), but the cap keeps them gentle.
  - A big moment or surprise can call one.
- **How it's drawn:** points in `skyRadiance`, through the existing real-star point path so they sit among the stars at the same size.
  - 4 slots × (position, velocity on the sphere, brightness, shadow time) take 8 new `SkyU` rows.
  - A train is one slot with a count and spacing.
- **Settings:** All settings → Sky extras: **Satellites** Off / Natural (the default) / Often.
- **In Neon Night Drive:** passes are seen between the towers, and the city's skyglow hides the faint ones (only satellites brighter than mag 2 show there).

---

## 7. Weather (WeatherKit): one new weather per set

### 7.1 Set 13: Ashfall

**What it is:** fine grey ash drifting down after a far eruption: soft, slow and warm-lit.
- At the volcano it falls with **embers**: orange particles that rise first, then fall.
- In other worlds it is the grey fall alone, with a brownish haze and a red-tinted sun or moon.

**Values:** `WeatherValues(cloud: 0.55, rain: 0, snow: 0, mist: 0.35, wind: 0.25)`, plus a new `ash: Float` (0…1, default 0 so old weathers are unchanged).
- The shared weather layer draws ash through the **snow particle path**, recoloured grey, falling at 0.6× the snow's speed and tumbling more.
- **Embers** go only where the world sets `emberSource` (Volcano Rim).

**Light:**
- The sun and moon redden and dim, following the existing smoke-haze extinction.
- The sky gets a brown-grey low haze.

**Sound:** a faint dry hiss (ash on leaves, roofs or the windscreen) through `WeatherAmbience`. Highs are slightly muffled (a −2 dB shelf above 6 kHz on ambience).

**Where it appears:** it can be picked in every sky world. Random Beautiful includes it only for Volcano Rim.

### 7.2 Set 14: Supercell
**What it is:** a rotating thunderstorm on the horizon and coming closer, after backlog #6 Supercell Sky.
- A broad rain-free base with a lowered, slowly turning **wall cloud**.
- A **striated** updraft tower and an anvil spreading overhead, with **mammatus** under it at the edges.
- An eerie **green tint** to the light under the core (real, from deep cloud and red sunlight).
- **Inflow gusts** towards the storm, then a **hail burst** and heavy rain as the core passes.
- Frequent lightning, through the limiter.

**It's staged:** like the Cool Change in the Home Lights spec, it runs as an event over 8 minutes of viewing by default (Advanced, 3–20 minutes):
1. **Approach:** the wall cloud turns on the horizon, distant lightning flickers, and inflow gusts blow towards it.
2. **Core:** the green light, a hail burst, then heavy rain and close lightning.
3. **Clearing:** the rain eases, mammatus hang overhead, and the stars come out behind it.

When picked, it plays once and then holds Clearing. In Random it plays and moves on.

**Values:** `WeatherValues(cloud: 0.85, rain: 0.6, snow: 0, mist: 0.15, wind: 0.6, gust: 0.8)`, plus a new `rotation: Float` (0…1, default 0). The phase moves cloud, rain, hail and lightning through the stages.

**How it's drawn:**
- The wall cloud and tower use the existing cloud layer's shapes with a slow rotation of their noise domain about the wall cloud's axis (no new octaves).
- The mammatus are a lobed under-surface (a 2-octave cellular pattern) on the anvil's layer.
- The green tint is a grade on the scene's light under the core, at most a 12% shift.
- The hail is the shared precipitation path with a bounce.

**Sound:** the gust roar, hail on the world's surfaces (through the existing hail synthesis), heavy rain, and close and far thunder (the existing thunder, with a longer roll).

**Excitement:** while it's on, big moments in sky worlds can call a lightning strike. A supercell is also a far storm, so red sprites can appear above its anvil at night (§6.1).

**Where it appears:** it can be picked in every sky world. Random Beautiful includes it only where storms already appear (Coast Road, Golden Hour Beach, Neon Night Drive, Moonlit Lake). Calm random weather never picks it.

---

## 8. Set 13: Volcano Rim

### 8.1 World
- **The scene:** you stand on the rim of a broad crater at night.
- **The view, from bottom to top:**
  - **Below** is a lava lake: a dark crust broken by glowing cracks, with slow convection cells, fountains and a lava river running out through a breach.
  - **Across the crater** is the far rim, lit orange from below.
  - **Above it** an ash plume climbs and bends with the wind, lit from inside by the lava and flickering with volcanic lightning.
  - **Beyond** is a dark plain with far storms (red sprites), and the stars are above.
- **The camera:** sits low on your rim, looking across. Black basalt rocks in the foreground catch the orange light, and **embers** drift up past the view.
- **How it's drawn** (all analytic or 2D, ≤ 3 noise octaves):
  - **The lava lake:** a 2D Voronoi crust (precomputed cell seeds, animated by a slow flow field), with crack glow from the cell-edge distance.
  - **The temperature:** blackbody colour from 700 K (dark red) to 1400 K (orange-yellow). Cracks run at 1100–1300 K, and fountains peak at 1450 K.
  - **The plume:** layered billboards from a 3-octave noise, lit from below by the lake's mean glow.
  - **Lightning:** strokes from the existing storm lightning, redrawn as short branching paths inside the plume, through `FlashLimiter`.
- **The sky:** the full Living Sky with real stars. The plume adds glow to the low sky in its direction.

**How it answers you:**
- **Every note:** a crack brightens near where the note lands across the lake (low notes left, high notes right), and the glow follows velocity.
- **Low notes:** below C3, a **spit** throws 1–3 lava blobs on ballistic arcs, with cooling colour and a splash.
- **Chords:** the convection speeds up with chord size.
- **Energy:** drives the fountains' height, the river's speed, the ember density and the plume's lightning rate (0.05 → 0.6 a second).
- **Tension:** the lake swells and the cracks pulse brighter in time with `instrumentPulse`.

**The signature moment, Eruption:**
- A fountain column rises 3–6 lake-widths over 0.8 s, then bombs arc out and land on the far rim with sparks.
- The plume billows, a lightning cluster fires (through the limiter) and the ground shakes (a 0.15° camera shake, off under Reduce Motion).
- `eruptionBoom` and Magma Bass's rumble swell play together.
- The strength scales the height and the number of bombs.

**The drop, Breach:** the far rim's breach opens and a bright new lava river pours out across the crater floor, then slowly crusts over.

**Surprises:**
- a **fireball** in the sky;
- a **rockfall** down the inner wall, with sound;
- a **steam blast** from a vent;
- **red sprites** over the plain;
- a **lava tree** (a pillar left standing as the river drops).

### 8.2 Visual: Magma Veins (Core, `MagmaVeins`)
- **What it shows:** the second visual is a full-frame view down into the lake. The crust is a field of plates, and each note lights a vein that branches from its key's position and cools from yellow to red to black.
- **How the veins grow:** chords connect their notes' veins, and big moments split the plates apart to show the bright magma.
- **The data:** `MagmaVeins` holds up to 96 veins, as a fixed array with no allocation, plus a seeded plate set. The renderer draws them as distance-field strokes.

### 8.3 Ambience (six sources, the volcano family)
- **`ventRumble`:** a sub-heavy rumble (20–60 Hz), with slow surges that follow the lake's convection, felt more than heard. Its level is capped so it never fights Magma Bass (−10 dB under the bass at the bus).
- **`lavaHiss`:** a crackling hiss from the lake: filtered noise with sparse crackle grains, brighter where the cracks glow.
- **`steamVent`:** occasional jet hisses from vents (one every 8–30 s), with rising band-pass noise.
- **`rockfall`:** rocks bouncing down the crater wall: tumbling impacts, getting farther away and darker.
- **`eruptionBoom`:** a deep boom with a crackling tail and falling rocks. It plays on Eruption, and its sub is shared with Magma Bass's swell.
- **`plumeThunder`:** short, sharp cracks from the plume's lightning, closer and drier than storm thunder.

---

## 9. Set 14: Neon Night Drive

### 9.1 World
- **The scene:** you're in the passenger seat of a car on an elevated city expressway at night, in rain.
- **The view:**
  - **Through the windscreen:** the road runs ahead with taillights and oncoming headlights.
  - **The towers:** a city skyline of dark towers with lit windows, and **neon signs** on rooftops and walls. The signs are abstract glyphs and shapes, never words, logos or brands.
  - **The windscreen:** rain beads on it and the **wipers** sweep at a speed set by the rain.
- **Reuse:** the coast road's driving model (`CoastRoadModel`'s speed and distance, and `CoastLights`) and the Window Kit's rain-on-glass, extended for a windscreen.
- **How it's drawn:**
  - **Planes:** the road, the barriers and the street lights are planes in perspective.
  - **The towers:** layered silhouettes, with window grids from a hash (no texture fetch per window).
  - **The neon:** SDF glyph strokes with bloom, through the existing post bloom.
  - **The wet road:** mirrors the neon with a 2D streaked reflection, the road's own highlights stretched along it.

**How it answers you:**
- **Speed:** the car's speed is `0.25 + 0.55·Energy`, plus the tempo. It follows `instrumentPulse`, so at 140 BPM you're flying.
- **The neon's colour:** follows the chord (major is warm magenta, amber and pink; minor is cool cyan, blue and violet), easing over 0.4 s.
- **Each note:** a sign pulses on and blinks in time with its rhythm.
- **Chrome Bass's arp:** lights a row of **road studs** racing towards you in time.
- **Tension:** the towers close in, the tunnel lights ahead start to strobe gently (≤ 3 Hz, through the limiter), and the rain gets heavier.

**The signature moment, The Drop:** the car bursts out of a tunnel onto a bridge over the harbour.
- The whole city opens up and every neon sign fires at once, in a wave that runs along the skyline (through the limiter).
- Light trails streak, and the speed surges for 2 s.
- If tension was high, it is **the drop**: a 2.5-second release, where the city's lights breathe out and the rain hangs in slow motion for a moment.

**Surprises:**
- a **train** of lit carriages crossing an overpass;
- a **far lightning** strike behind the towers (with sprites);
- a **sign that flickers and dies**;
- a **police-free light bar**: an abstract light passing, never police or emergency branding;
- **the rain stopping** for a moment as you pass under a bridge.

### 9.2 Visual: Light Trails (Core, `LightTrails`)
- **What it shows:** the second visual is a long-exposure view down the expressway from above. Every note draws a streak of light along a lane, coloured by its chord, with its length set by its duration and its brightness by its velocity.
- **Lanes:** the arp's notes run in the left lanes, the brass in the right.
- **Big moments:** draw an interchange bloom, where streaks fan out across the ramps.
- **The data:** `LightTrails` holds up to 128 streaks in a fixed ring buffer.

### 9.3 Ambience (six sources, the drive family)
- **`wetTyres`:** tyre hiss on a wet road, getting louder and brighter with speed.
- **`wipers`:** the wiper's rubber squeak and thunk at the wiper rate, which follows the rain.
- **`engine`:** a smooth, warm engine and gear hum that follows speed: pitch rises, then drops at each automatic shift. It's quiet, under the music.
- **`passingCar`:** cars passing in the next lane, with Doppler and a whoosh. Their rate follows the traffic.
- **`roofRain`:** rain on the roof and glass, through the existing rain synthesis with a car-cabin filter.
- **`farSiren`:** a far wordless siren that rises and falls, **in key** (ambience in key). It is rare, never close, and Off under gentle.

---

## 10. Mood

- **Molten** (Volcano Rim): `Mood(energy: 0.85, warmth: 0.95, brightness: 0.4, space: 0.75, motion: 0.65)`
- **Wired** (Neon Night Drive): `Mood(energy: 0.9, warmth: 0.3, brightness: 0.8, space: 0.55, motion: 0.95)`

These are the most energetic moods in the app, spread away from the calm ones (pairings rule 21).

---

## 11. Sets, credits and cards

- **Set 13, Volcano Rim:**
  - Magma Bass, *Magma*; the Volcano Rim world; Magma Veins as the second visual.
  - Credited to "Hold My Liquor" (Kanye West). The card is text plus a Spotify link.
  - The card's key and pulse are researched at build time and marked for Michael's ear check.
  - Its card art is original: a crater glow, an ember rising at the felt pulse, and an easter egg (a tiny lava tree on the far rim).
- **Set 14, Neon Night Drive:**
  - Replicant Brass, *Replicant*, with Chrome Bass split at C3; the Neon Night Drive world; Light Trails as the second visual.
  - A **place card**: an expressway at night with neon glyphs and a wiper's arc.
  - Easter egg: one sign's glyph is the app's own icon shape.
  - "Gassed Up" (Wombat) is noted in the release notes as a possible credit once Michael has listened.
- **The gallery:** both cards go at the end. They also join Galaxy Warp as each world's third visual, as the other worlds do.
- **Release notes:** the two worlds, the two instruments, the Excitement controls and what each existing world now does, plus a play-along tip for each new set.

---

## 12. Performance

- **The Volcano renderer:** one full-screen pass for the lake (the Voronoi from 64 precomputed seeds), one for the plume billboards (≤ 12), plus embers (≤ 400 points, instanced) and the sky. The target is ≤ 6 ms at 1 MP on the Intel GPU.
- **The Drive renderer:**
  - The road and tower planes in one pass.
  - Neon glyphs as an instanced SDF quad set (≤ 48 signs).
  - The windscreen rain from the Window Kit, the post bloom, and the sky.
  - Target: ≤ 7 ms.
- **Excitement:** O(1) per note in Core. The surprises' and moments' animations reuse each world's existing draw paths, with ≤ 0.5 ms each.
- **No buffers are made per frame.** The veins, trails, embers and bombs all live in fixed pools.
- **Audio:** see §4.5. The 12 new ambience sources together stay under 8% of a core at their defaults.

---

## 13. Reliability

- **Flashes:**
  - The volcano's lightning, the eruption, the Drop's neon wave, the tunnel strobe, fireworks and sprites all go through the scene's `FlashLimiter` (≤ 3 flashes a second; red flashes held to the stricter limit).
  - Gentle visuals turns their flashes into glows.
- **Old saves:** `SceneControls.excitement`, `WeatherValues.ash`, the red-sprites setting and the new parameters all have defaults. A save from build 249 or from Sets 7–12 loads unchanged.
- **Determinism:** moments, surprises, embers and bombs are all seeded. The same performance and seed draw the same frames (for the preview tests).
- **The instruments:**
  - Magma Bass's rumble and the brass's hall can't clip the bus: a soft limiter on each engine's output, tested with a 10-note fff chord.
  - Stolen voices release in 5 ms with no clicks, checked by the click detector.
- **Hold the Moment** freezes Excitement, embers, bombs and the car. **Sleep Fade** turns off surprises and moments.

---

## 14. Testing

Tests come first, RED then GREEN. They run in CI on macos-15.

**DSP:**
- **The core:**
  - Drive and Fold are band-limited (aliasing under −60 dB at a 2 kHz saw, 44.1 kHz).
  - Unison has equal power.
  - Glide reaches its target within its time.
- **Magma Bass:**
  - Velocity opens the cutoff (spectral centroid fff > 3× ppp).
  - Rumble adds energy at the note's sub-2.
  - Mono-legato glides without retriggering.
  - `ISD_H_MAGMA_ERUPT` fires on a hard low chord only.
- **Replicant Brass:**
  - The swell's attack follows Swell.
  - The blare's overshoot appears at velocity 1 only.
  - The split routes correctly.
  - The arp is sample-accurate at 120 BPM in sixteenths.
  - Blue Depth's fingerprint is unchanged after the arp moves.
- **All:** finite output, CPU budget, click detector and the 10-note fff ceiling.

**Excitement:**
- Energy's attack and release times.
- Moments fire on seeded hard chords and never inside the cooldown. A crescendo fires one.
- Surprises respect their minimum spacing, never repeat and stop when idle.
- A drop needs tension above 0.6.
- Gentle, Reduce Motion and Hold all calm it as listed.

**The worlds:**
- **Volcano model:** notes brighten cracks at the right place, low notes spit, Eruption scales with strength, and Breach follows a drop.
- **Drive model:** speed follows Energy and the tempo, the colour follows the chord, and the studs follow the arp.
- **Every existing world:** handles a moment, a surprise and a drop without crashing, and its moment changes its frame (a pixel-difference test on the preview renderer).

**Sky and weather:**
- Sprites only at night with storms or far storms, under the brightness cap.
- Satellites only while dark and sunlit, entering shadow on the correct side; flares capped at Venus; city skyglow hides those fainter than mag 2.
- Ashfall's values, embers only at the volcano, and old weathers unchanged.
- The Supercell's stages run in order, hold Clearing when picked, never come up in Calm random, and its lightning passes the flash test.

**Flash:** both new worlds and every moment pass the existing flash test.

**Previews:** both worlds at deep night, at Energy 0, at Energy 1, and mid-Eruption or mid-Drop.

**Saves:** a build-249 save and a Sets 7–12 save load.

---

## 15. Build order

1. The core grows (Drive, Fold, Unison, FilterEnv, Glide, voice modes), with tests. The shared `Arp.hpp`, with Blue Depth's fingerprint locked first.
2. **Magma Bass** → the app, the "Hold My Liquor" card, and a **preview build**.
3. **Replicant Brass and Chrome Bass** → the app, the place card, and a **preview build**.
4. **Excitement** in Core: Energy, Moments, Surprises and Tension, the `ExcitementAware` adoption by every model, and the panel controls.
5. **Each existing world's** moment, surprises and build and drop (§5.5), in two batches: sky worlds, then interiors and space.
6. Set 13's sky and weather: **red sprites** and far storms; **Ashfall** and embers. Set 14's: **satellite passes and flares**; the **Supercell** event.
7. The 12 ambience sources.
8. **Volcano Rim:** the model, Magma Veins and the renderer.
9. **Neon Night Drive:** the model, Light Trails and the renderer (on the coast road's driving model and the Window Kit's windscreen).
10. Sets 13 & 14, the cards, gallery, release notes and demos.
11. One review and fix pass, then merge and release. Short, because Michael wants new things first.

---

## 16. Out of scope
- More basses on the core (Acid, Turbo, Diesel and the rest). They come with their own worlds.
- Supersaw anthems, the Juno, FM keys and the PPG. They're on the core later.
- Driving the car yourself (steering, lanes, choosing exits).
- An eruption you can trigger from the panel without playing. Moments come from playing only, so they stay earned.
- Real volcano data (live eruptions) and real traffic.

---

## 17. Decisions made without asking (with the cost if Michael decides otherwise)

1. **This run goes before Home Lights**, which becomes Sets 15 & 16. Cost: renumbering.
2. **Volcano Rim and Neon Night Drive are the pair,** over Lightning Plains, Race Night, Underground Club and Festival Main Stage. Cost: a new world spec. The core and Excitement carry over.
3. **One instrument per set.** Chrome Bass is Replicant Brass's left-hand split, not its own instrument. Cost: a separate Chrome Bass is a small engine on the same core.
4. **Magma Bass is poly by default** (6 voices) with a Mono switch, so chords growl. Cost: a default flip.
5. **Magma Bass has a right-hand Spark layer** above C4 instead of bass all the way up. Cost: Spark to 0.
6. **Replicant Brass's 7-saw unison** limits it to 6 voices. Cost: more voices with fewer saws (a dial).
7. **The arpeggiator is shared** and Blue Depth's moves onto it, locked by a fingerprint. Cost: none to Blue Depth's sound.
8. **Excitement is on by default** (moments Some, surprises Rare, build and drop on) in every world, including the calm ones. Cost: one switch, or per-world defaults.
9. **Moments come only from playing,** never on a timer. Surprises need recent playing too. Cost: an "ambient surprises" option.
10. **Every flash moment is governed by `FlashLimiter`**, and gentle visuals turns flashes into glows. Cost: none; these are the standing rules.
11. **Each set gets its own sky feature and weather** (1:1:1:1:1:1, as Michael asked on 5 Nov). Set 13 gets red sprites and Ashfall; Set 14 gets satellites and Supercell. All four reach every sky world. Ashfall is only in Random Beautiful at the volcano; Supercell only where storms already appear. Cost: tables.
12. **Red sprites come with "far storms"** on clear nights, so they can be seen without local rain. Cost: a setting (Natural or Often already).
13. **The neon is wordless glyphs and shapes,** with no text, brands or logos, and nothing imitates any film. *Tears in Rain* is a preset name only. Cost: renaming the preset.
14. **Neon Night Drive is place-born** until Michael listens to "Gassed Up". Cost: swapping the card for a credit is a line.
15. **"Hold My Liquor" stays Volcano Rim's credit,** as the backlog has it. Cost: another song.
16. **The camera shake on Eruption** is 0.15°, off under Reduce Motion. Cost: a dial.
17. **The far siren is rare, wordless, far and in key,** and off under gentle. Cost: removing it.
18. **No police or emergency imagery;** the "light bar" surprise is abstract. Cost: none.
19. **The moods "Molten" and "Wired"** are the most energetic in the app. Cost: numbers.
20. **The review and fix pass is short** (one pass), per "build more, fix later". Cost: more polish later.
21. **Satellites are seeded and plausible, not live orbits.** The app works offline and live orbit data would need the network. Cost: a later "real orbits" option that loads a snapshot.
22. **The Supercell is a staged event** (Approach, Core, Clearing) over 8 minutes of viewing. Picked, it holds Clearing. Cost: a looping or real-length version later.
