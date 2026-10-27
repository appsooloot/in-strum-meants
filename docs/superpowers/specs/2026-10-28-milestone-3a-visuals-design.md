# Milestone 3A — Visual Engine, Customisation & Butterfly Garden — Design Spec

**Date:** 2026-10-28
**Status:** Awaiting your review
**Builds on:** `2026-10-28-in-strum-meants-design.md` (Milestone 1 and Build 2 are shipped)

---

## 1. Purpose

Make the visuals as beautiful and expressive as the instrument. Your playing, and the actual sound of the instrument, should shape a living scene precisely and intuitively, and you can customise every part of it without ever being overwhelmed.

### Success looks like
1. **Butterfly Garden** looks stunning on your Intel MacBook Pro and stays smooth (60 fps target, never stutters the sound).
2. You can *see* the difference between a soft note and a hard one, a held chord and a staccato run, a warm bass and a bright synth.
3. Changing the look takes one click (presets, Surprise me) or as much depth as you like (Advanced).
4. Any input can be re-wired to any reaction in a few clicks, and Reaction presets feel right in every theme.
5. Spotify, YouTube or the microphone can add atmosphere without ever making the visuals look wrong.
6. Installing a new version is a polished drag-to-Applications experience with a proper app icon.

### What you told me
- Butterfly Garden is the flagship. The other five themes follow in 3C.
- Customisation is layered: simple up front, endless in **Advanced**.
- Listen has three independent switches: Instrument, Mac audio (the main one), Microphone.
- The instrument drives the precise visuals; Mac audio and mic drive atmosphere only.
- Everything should be customisable in essential *and* seemingly non-essential ways, and extendable later.
- Mappings must be easy to switch around, with presets that match mapping to visuals intuitively.

---

## 2. Milestone 3 stages

| Stage | Contents |
|---|---|
| **3A (this spec)** | Installer and icon · parameter engine · Look and Reaction presets · roles and remappable reactions with mapping editor · instrument sound-character and dial reading · Listen switches · visual engine upgrade · flash safety · Butterfly Garden · Midnight Steinway on the new engine · hands-free control · per-theme memory · preview renders |
| **3B** | Palette studio · Material studio · backgrounds layer (static and dynamic) · Auto-evolve · Performance Portrait · second-screen output · performance recording |
| **3C** | Moonlit Lake · Velvet Theatre · Golden Hour · Fireworks Finale · Galaxy Warp (on the finished engine; Sonnet) |

---

## 3. How it fits together

```
 Keys (MIDI) ─────────────┐
 Playing analysis ────────┤
 Instrument sound ────────┤   INPUTS            ROLES              THEME
 Instrument dials ────────┼──▶ (named,     ──▶ Energy, Size,  ──▶ Butterfly Garden /
 Mac audio  [switch] ─────┤    0…1 values)     Motion, …          Midnight Steinway
 Microphone [switch] ─────┘        │            (or a theme         │
                                   │             setting directly)  │
                          Reaction preset /                   Look preset /
                          Mapping editor                      settings panels
                                                                   │
                                                  Visual engine: simulate → render
                                                  → glow, depth, grade, grain
                                                  → flash safety → screen
```

New parts, each with one job:

| Part | Job | Lives in |
|---|---|---|
| **Parameter engine** | Declares settings; holds values; builds panels; presets; Surprise me; morph | Core |
| **Input hub** | Turns every source into named 0…1 inputs, smoothed | Core |
| **Playing analysis** | Chords, melody direction, leaps, busyness, crescendo, spread, repetition, silence, key | Core |
| **Mapping (routes)** | Input → role or setting, with amount, curve, on/off | Core |
| **Sound character** | Analyses the instrument's own output (attack, brightness, ring, texture, loudness, width) | Audio |
| **Dial reader** | Watches the instrument plugin's own knobs | Audio |
| **Listeners** | Mac audio and microphone → level, bass, mid, treble, beat | Audio |
| **Theme** | Declares its settings and how roles look; simulates its world | Core (behaviour) + App (drawing) |
| **Visual engine** | Shared render stack, quality levels, flash safety | App |
| **Settings panel** | Front layer and Advanced, built from declarations | App |
| **Hands-free control** | Shortcuts and MIDI-learn | Core (bindings) + App |
| **Installer** | DMG, background art, icon | Packaging/CI |

**Rule kept from Milestone 1:** nothing here touches the instrument's sound path. All analysis reads copies of audio on separate threads; visuals never delay notes.

---

## 4. Parameter engine

### 4.1 Declaring settings
Each theme lists its settings once. Each setting has:
- `id` (stable, e.g. `wings.iridescence`), display name, group, short help text
- kind: **slider** (range, default, unit), **whole number**, **switch**, **choice** (named options), **colour**, **gradient** (2–6 colour stops)
- tier: **hero** (front panel) or **advanced**
- `surprise`: whether Surprise me may change it, and the "tasteful" sub-range it may pick from

### 4.2 Values
- Every theme remembers its own values (per-theme memory). Switching themes and coming back restores them.
- **Reset to default** on any setting, group or the whole theme.
- Unknown or missing values in old saves fall back to defaults; out-of-range values are clamped.

### 4.3 Macros (front layer)
Six macros sit above every theme: **Intensity, Speed, Density, Glow, Calm ↔ Chaos, Colour Temperature**. Each theme declares which of its settings each macro moves and by how much. Macros scale around the current values, so they never fight your detailed settings.

### 4.4 Presets
Two independent kinds, so any look can pair with any reaction style:
- **Look preset:** a theme's setting values (colours, wing style, density…). Theme-specific.
- **Reaction preset:** the mapping (which inputs drive which roles). Works in every theme.

Preset features: save, rename, delete, favourite, **Surprise me** (random within tasteful ranges), **morph slider** between two presets (sliders and colours blend smoothly; choices and switches flip at the halfway point). Presets are small files in `~/Library/Application Support/In Strum Meants/Presets/`, so you can back them up or share them.

Built-in Reaction presets: **Expressive Pianist** (default), **Calm Ambient**, **Synth Explorer**, **Music Party**, **Minimal**, **Wild**.
Built-in Look presets for Butterfly Garden: **Monarch Morning**, **Morpho Dream**, **Golden Hour Meadow**, **Moonlit Moths**, **Crystal Garden**, **Neon Night**.

---

## 5. Inputs

All inputs are smoothed (configurable rise and fall) so nothing jitters. Values are 0…1, or −1…1 where direction matters.

**Keys (exact):** note pitch, velocity, held time, release speed, sustain pedal (incl. half-pedal; also Auto-Sustain/Latch when added), soft pedal (CC67), sostenuto (CC66), mod wheel (CC1), pitch bend, channel aftertouch, poly aftertouch, expression (CC11), and any other knob/fader CC (named "CC 21" etc., renameable).

**Playing analysis (over time):** chord quality (major / minor / tense / open), melody direction, interval leaps, busyness (notes per second), crescendo / diminuendo, hand spread, repetition, silence length, current key (pitch-class histogram estimate).

**Instrument sound character** (from the instrument's own output, clean): attack sharpness, brightness, ring length, texture (tonal ↔ noisy), loudness, stereo width.

**Instrument dials:** every parameter the plugin publishes (e.g. Splice's Reverb, Hammers, Pedal, Tightness), named as the plugin names them. If a plugin publishes none, this group is simply empty.

**Listening (atmosphere):** Mac audio and microphone, each switchable: level, bass (<250 Hz), mid (250 Hz–4 kHz), treble (>4 kHz), beat, tempo. A **Listen strength** slider (0–100%) scales all listening inputs. With both listening switches off, nothing is captured.

---

## 6. Roles and remappable reactions

### 6.1 Roles
Inputs drive **roles**; each theme decides how a role looks.

| Role | Meaning |
|---|---|
| **Energy** | How big and bright a moment is |
| **Size** | How large things are |
| **Motion speed** | How fast things move |
| **Direction** | Rise ↔ fall, sway (−1…1) |
| **Brightness** | Light and glow |
| **Warmth** | Warm ↔ cool colour |
| **Colour shift** | Hue movement |
| **Linger** | Trails, echoes, how long things last |
| **Density** | How many things there are |
| **Atmosphere** | Mist, haze, depth |
| **Calm ↔ Chaos** | Order ↔ wildness |

### 6.2 Links
A link is: **input → role or a specific theme setting**, with **on/off**, **amount** (−100%…+100%), and **curve** (gentle, linear, snappy). Many links can feed one target; their effects add and are clamped to range.

### 6.3 Mapping editor (Advanced → Mapping)
- A list of every link, grouped by input family (Keys, Playing, Sound, Instrument dials, Listening).
- Change any link's target from a dropdown; add or remove links; adjust amount and curve.
- Group strength sliders: **Keys, Playing, Sound, Instrument dials, Listening**.
- **Save as Reaction preset.**

### 6.4 Default reactions (Expressive Pianist), Butterfly Garden

| Input | Effect |
|---|---|
| Note | A butterfly is born from that key; low = large, slow, deep colour; high = small, quick, pale |
| Velocity | Energy + Size: bigger wings, brighter colour, faster launch, pollen burst |
| Held | It hovers above its key, wings slowly beating |
| Release speed | Quick release = darts away; gentle = drifts off |
| Sustain pedal | Linger: slow-motion wing beats and long trails (half-pedal = half) |
| Soft pedal | Hush: softer light, pastel colours |
| Mod wheel | Wing iridescence |
| Pitch bend | Direction: the breeze and flock sway |
| Aftertouch | The hovering butterfly glows and flutters harder |
| Major / minor / tense chord | Warm spiral swarm and blooms / cool graceful circle / flicker and passing shadow |
| Melody rising / falling | Flock climbs toward the sun / settles toward flowers |
| Leaps | Butterflies arc across the scene |
| Busyness | Calm ↔ Chaos + Density: whirlwind swarm, more pollen |
| Crescendo / diminuendo | Sun and god-rays strengthen / dusk falls |
| Hand spread | Camera pulls back, garden widens |
| Repetition | A butterfly loops, echoing the pattern |
| Silence | Butterflies land on flowers and fold their wings; fireflies at night |
| Key | Garden palette tint |
| Attack sharpness | Motion: darting flicker (sharp) ↔ gliding fade-in (smooth) |
| Brightness | Warmth (inverted) + crisp sparkle |
| Ring length | Linger |
| Texture | Atmosphere: mist and pollen haze |
| Loudness | Energy |
| Instrument reverb dial | Atmosphere depth |
| Instrument tone dials | Wing edge crispness |
| Mac-audio bass / beat / level | Breeze pulse / petal sparkle / glow breathing |
| Mic level | Leaves rustle |

Midnight Steinway gets the same table expressed in its own visuals (light, lacquer sheen, bloom).

---

## 7. Butterfly Garden

### 7.1 The scene
A layered, softly lit garden seen at butterfly height. Foreground blossoms out of focus, a mid-ground meadow where flowers bloom, distant foliage silhouettes and sky. Sun rays fall through drifting pollen and petals. The keyboard sits along the bottom (styled to match, or hidden).

### 7.2 Settings (hero settings marked ★)
- **Butterflies:**
  - ★ wing style (Monarch, Glasswing, Morpho Blue, Moth, Origami, Crystal, Neon, Petal; or a mix)
  - species mix
  - ★ count limit
  - size range
  - ★ flutter speed
  - ★ iridescence
  - wing shimmer
  - trail length and glow
  - lifespan
  - flocking (calm drift ↔ wild swarm)
  - land on held keys (switch)
  - colour source (pitch / chord / velocity / palette)
- **Notes to butterflies:**
  - spawn rate
  - chord spiral strength
  - minimum velocity to spawn
- **Garden:**
  - flower types
  - ★ bloom speed
  - bloom lifetime
  - petal density
  - breeze strength and direction
  - foliage density
  - pollen sparkle
  - fireflies (switch, night only)
- **Light and atmosphere:**
  - ★ time of day (Dawn, Morning, Golden Hour, Dusk, Moonlight)
  - sun angle
  - ★ god-ray strength
  - mist
  - depth-of-field blur
  - bloom glow
  - grain
  - colour grade (Natural, Warm Film, Cool Film, Dreamy, Vivid)
- **Camera:**
  - motion (Still, Drift, Follow melody)
  - zoom
  - parallax depth
- **Keys:**
  - show keys (switch)
  - keyboard height
  - key finish (Lacquer, Satin, Ivory, Brushed metal, Gold, Pearl)
  - glow colour

### 7.3 How it's built
- Butterfly behaviour (spawn, hover, flocking, landing, lifespans) is simulated on the CPU in Core, so it is unit-testable; capped at 600 butterflies (High) to stay smooth on Intel.
- Each butterfly is drawn as two hinged wings that flap in the shader; wing patterns are procedural (no image files), so every style scales cleanly and can be recoloured.
- Pollen, petals and fireflies are GPU particles (thousands).
- Sky, sun, god-rays, foliage silhouettes and blooms are procedural shader layers.

---

## 8. Visual engine upgrade
- **HDR pipeline:** scenes render in high dynamic range, then pass through a shared stack: bloom glow → depth-of-field → colour grade → film grain → vignette → tone mapping.
- **Quality levels:** **Lite** (no depth-of-field, reduced particles, half-resolution glow), **High** (default), **Ultra**. **Auto** steps down one level if frames average slower than 55 fps for 2 seconds, and back up after 10 seconds of headroom.
- **Flash safety (on by default):** limits large, sudden brightness jumps to no more than 3 per second and caps flash brightness. **Gentle visuals** halves flash and sparkle intensity further.
- **Themes share one interface:** declare settings, map roles to visuals, simulate, draw. Midnight Steinway is moved onto it and gains its own settings (spotlight width and warmth, lacquer sheen, bloom strength, haze, key finish).

---

## 9. Listening (Mac audio and microphone)
- **Mac audio:** uses macOS's system-audio capture (macOS 13+), excluding the app's own sound so your instrument isn't counted twice. macOS asks for *Screen & System Audio Recording* permission the first time it's switched on.
- **Microphone:** a separate input; macOS asks for microphone permission the first time.
- Each source is analysed on its own thread into level, bands and beat. Switches can be changed at any time.
- If permission is denied, the switch shows **Allow in System Settings** (opens the right page), and visuals continue with the other sources.

---

## 10. Settings panel
- A panel slides in from the right (toggle with a button or **S**). Visuals stay visible behind it.
- **Front:** theme picker · Look presets bar (favourites, Surprise me, morph) · Reaction preset picker · six macros · the theme's ★ hero settings · Listen switches and Listen strength · Quality · Gentle visuals.
- **Advanced** (tabs): **All settings** (grouped, searchable, with Reset buttons) · **Mapping** · **Controls** (shortcuts and MIDI-learn).

---

## 11. Hands-free control
- **Shortcuts:**
  - ← / → previous/next theme
  - [ / ] previous/next Look preset
  - ; / ' previous/next Reaction preset
  - R Surprise me
  - F full screen
  - H hide all controls
  - S settings panel
  - Esc panic

  Shortcuts are ignored while typing or when Cmd/Ctrl/Option is held (as in Build 1 fixes).
- **MIDI-learn:** click **Learn** next to an action, then move a knob or press a pad on your keyboard. Learnable actions:
  - next/previous theme, Look preset, Reaction preset
  - Surprise me
  - hide controls, full screen, panic
  - continuous: Listen strength and each macro

  Bindings are saved. A note used as a binding is no longer sent to the instrument; Controls lists every binding with **Remove**.

---

## 12. Installer and app icon
- Each release includes **In-Strum-Meants-build-N.dmg** (the zip stays too, as a fallback).
- Opening it shows a designed window:
  - the app icon on the left, **Applications** on the right
  - an elegant gold arrow between them, with "Drag to install" in small type
  - a warm, dark Midnight Steinway background
  - Retina-sharp

  Dragging over an existing copy replaces it (Finder asks to confirm).
- **App icon:** an original design of a golden butterfly whose wings echo piano keys, on deep black lacquer. It is built at every macOS icon size.
- Built automatically in CI. The DMG is generated without Finder scripting, so it is reliable on build machines.

---

## 13. Reliability

| Situation | Behaviour |
|---|---|
| Permission denied (Mac audio / mic) | Switch shows Allow in System Settings; other sources continue |
| System-audio capture stops (e.g. display change) | Restarts automatically; switch shows a brief "reconnecting" note |
| Frame rate drops | Auto quality steps down; sound is never affected |
| Old or damaged preset file | Missing values use defaults; unreadable files are skipped and listed as "couldn't open" |
| Plugin publishes no dials | Instrument dials group is empty; nothing else changes |
| No Metal GPU | Plain message instead of visuals; instrument still plays |

---

## 14. Testing

**Automatic (every build):**
- Parameter engine:
  - declarations are valid (unique ids, defaults in range)
  - clamping
  - per-theme memory and reset
  - macro scaling
  - Surprise me stays in tasteful ranges
  - morph blends and flips correctly
- Presets: save/load round trip, old/damaged file handling.
- Mapping: links add and clamp; amount/curve maths; group strengths; Reaction presets resolve in both themes.
- Playing analysis: chord quality, melody direction, leaps, busyness, crescendo, silence, key, all on scripted note sequences.
- Sound character: synthetic test sounds (sharp click vs slow swell; sine vs noise; bright vs dark) produce the expected readings.
- Listeners: band and beat detection on synthetic audio (a 120 BPM click track is detected as about 120 BPM).
- Butterfly simulation:
  - harder notes make bigger butterflies
  - held notes hover
  - pedal slows wing beats
  - silence lands them
  - the count cap holds
  - a 2,000-note burst steps within budget
- Flash safety: a scripted strobe never exceeds 3 large flashes per second.
- MIDI-learn: bindings capture, trigger and persist; bound notes are not sent to the instrument.
- Shaders compile; DMG contains the app and an Applications link; icon present.

**Preview renders:** each build plays a scripted performance (soft notes, hard notes, chords, fast run, pedal, silence) through each theme on the build machine's GPU and saves still frames. I review them before release.

**Your eye-and-ear test:** a short checklist with each release (smoothness, soft vs hard, synth vs piano difference, presets, mapping editor, Listen with Spotify, installer).

---

## 15. Out of scope for 3A
Palette and Material studios, backgrounds layer, Auto-evolve, Performance Portrait, second screen, recording (all 3B); the other five themes (3C); Sound Shaping, Auto-Sustain and Latch (Milestone 2, still planned).
