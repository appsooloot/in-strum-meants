# Small Wins: Keep That, Sleep Fade, Hold the Moment, Breathing Ambience, Reduce Motion, the Chime in Key: Design Spec

**Date:** 2026-11-04
**Status:**
- Written to Michael's standing instruction to work through the backlog without questions unless they are absolutely necessary.
- The pairings doc §8 lists these six as the "easy feature wins that build on what exists".
- They touch every world but add no new set.
- Building starts when the current set runs leave room.
- §9 lists every choice made without asking, with what it would cost if Michael decides otherwise.

**Builds on:**
- `2026-11-04-scape-instrument-pairings-and-ideas.md`: §7.10 items 1, 11 and 14; §7.11 item 1; §7.12 items 1 and 8; §8.
- The Sets 9 & 10 key input (`AmbienceScene.key`, `isd_ambience_set_key`).

---

## 1. Purpose and success
Six small features that make every world better to live with.

1. **Keep that:** you never lose a good take.
   - The app quietly keeps what you play, in memory only.
   - One button saves the last take as a MIDI file, with a note of the world, instrument, sky and key it was played in.
2. **Sleep fade:** choose a timer and the whole world drifts to night and silence over its last minutes.
3. **Hold the moment:** press the soft pedal (or the on-screen pad, or ⌘⇧H) and the sky, weather and world stop still while you keep playing.
   - Your notes pile up in the frozen scene.
   - Let go, and everything carries on.
4. **Breathing ambience:** rain, wind and surf swell and recede on their own, in long, slow arcs, so the world never sounds like a loop.
5. **Follow Reduce Motion:** when the Mac's Reduce Motion setting is on, the app moves gently without being asked.
6. **The chime in key:** the Spaceship Lounge's chime joins the temple bell and the sonar in following the key you play in.

**Standing rules hold:**
- Personal use.
- Older settings load.
- Every world stays smooth on Smooth.
- Flashes go through `FlashLimiter`.
- Nothing is written to disk until you ask.

---

## 2. Keep that

- **The keeper (Core: `TakeKeeper`):**
  - It holds a ring of timestamped performance events from the last **2 hours**: note on and off with velocity, the sustain, soft and sostenuto pedals, pitch bend and pressure.
  - The cap is 250,000 events, and the oldest drop first.
  - It lives in memory only and is never saved by itself.
- **A take** runs from the first note after the last silence of 8 s or more before the most recent note, to now. It is at most 30 minutes long.
  - "Silence" means no notes held and no note-on.
  - If the newest note was more than 10 minutes ago, there is nothing to keep.
- **Keep that** has three triggers:
  - a button, a bookmark icon in the main bar;
  - ⌘K;
  - a **key gesture**: tap the top three black keys of your keyboard together, twice within 1.5 s. These are the highest F♯, G♯ and A♯ in the range set in Keyboard layout, or F♯7, G♯7 and A♯7 on a full 88.
    - The gesture itself is cut from the take.
    - The app shows a small "Kept" toast with the take's length.
- **The file:**
  - A Standard MIDI File, type 0, at 480 ppq. The tempo is the set's credit tempo if it has one, otherwise 120, with event times exact in milliseconds.
  - The track name is the set's name.
  - It is saved to `~/Music/In Strum Meants/Takes/` as `YYYY-MM-DD HH.mm — <set or world name>.mid`, with a `.json` beside it holding:
    - the set id, the world id and the instrument (patch id and dial values);
    - the sky (city, local time, sun altitude, moon phase, weather kind);
    - the key estimate (`AmbienceKey`, if known);
    - the app version.
- **Keep the last 10 minutes** (a menu item) saves the last 10 minutes regardless of silences.
- **Privacy:** nothing leaves memory until you press Keep, and quitting empties the ring. The folder is created on the first keep.
- **Tests:**
  - the SMF writer round-trip;
  - take boundaries (8 s silences, 30-minute cap, the 10-minute rule);
  - the gesture is detected, cut, and never fired by a chord that contains those notes once;
  - the ring stays bounded over 200,000 events;
  - the JSON fields.

## 3. Sleep fade

- **The control:** the timer is a moon button in the main bar, with a menu: Off / 15 / 30 / 45 / 60 / 90 minutes. The remaining time shows beside the moon.
- **The fade** runs over the last 10 minutes, or the whole timer if it is shorter:
  - **Sound:** the instrument's master gain and the ambience volume fall to silence along a gentle curve (−60 dB at the end; the gain follows `cos²` of the fade's progress).
    - These are run-time multipliers. Your saved volumes are never changed.
  - **Light:** the world dims toward night.
    - `SceneDirector.sleepDim` (0…1) slides the held sun altitude down to −14° (deep blue night) and lowers the exposure by up to a stop.
    - Particle and visual motion slows by up to half.
    - The weather keeps going.
- **The end:**
  - Audio goes silent. The engine keeps running so the next note works.
  - The view rests on a dim night.
  - The timer turns itself Off.
- **Waking:** any key, pedal or click during the fade cancels it. Sound and light come back over 3 s, and the timer turns Off. ("You're awake.")
- **Persistence:** none. The timer is per session.
- **Tests:**
  - the gain curve's shape and end level;
  - the dim slides the hold;
  - a note cancels and restores over 3 s;
  - saved volumes are untouched;
  - the timer ends Off.

## 4. Hold the moment

- **The triggers:**
  - the **soft pedal** (CC 67) while it is down. A setting can switch this to the sostenuto pedal (CC 66) or turn it off.
  - the on-screen **Hold** pad, an hourglass in the main bar, while pressed, or toggled by a double-click;
  - **⌘⇧H**, toggled. The computer keys A–K play notes, so Hold needs a shortcut with modifiers.
- **While holding:**
  - `SceneDirector` passes `dt = 0` to the sky, the weather and the world, and freezes the time shaders see.
  - Waves, clouds, rain streaks, particles, the aurora and the camera all stop where they are.
  - **New notes still make their visuals.** They appear at full brightness and hold, because nothing decays at dt 0, so a held moment fills with your playing.
  - The instrument and the ambience play on normally. Weather sounds keep their last levels.
  - Lightning, the lighthouse and other flashes pause in their current state: there are no flashes while time is held.
- **On release:** time resumes from where it stopped, with a 0.6 s ease-in. Held visuals then decay normally.
  - In real-time mode the sky catches up to the true time. The change in that time is tiny, so there is no visible jump.
- **Limits:** visuals that are capped (ripples, patches, wisps) keep their caps; the newest replace the oldest as usual. There is no limit on how long a hold lasts.
- **Tests:**
  - frames are identical across a held second, apart from note visuals;
  - notes during a hold create visuals that keep full brightness;
  - release eases dt back in;
  - the soft pedal and the setting;
  - ⌘⇧H toggles;
  - flashes pause.

## 5. Breathing ambience

- **What it does:** each continuous bed (rain on water, rain on glass, wind, breeze, surf, waterfall, water, crickets, ship hum, air flow, kettle, fire, street, snapping shrimp, lapping) gets a slow, seeded swell.
  - It is the sum of two sines with incommensurate periods drawn from 40–160 s.
  - Depth ±25%, and it never drops below 60% of the level the world asked for.
  - Each source gets its own seed, so they don't move together.
  - One-shot sources (owl, chime, gulls, thunder, waves, bell, sonar) are left as they are.
- **Where it runs:** Core, in `AmbienceBreath.apply(to: inout AmbienceScene, at t: Double)`, called by `SceneDirector` before the scene is published. Levels are quantised to 1% so the App only sends real changes.
- **The setting:** "Ambience breathes" in the ambience settings, on by default. Its depth can be set with a slider at 0…1.5 × (default 1).
- **Tests:**
  - deterministic per seed;
  - depth and floor bounds;
  - one-shots untouched;
  - over 10 minutes the level crosses its mean at least 4 times and never stays flat for 30 s.

## 6. Follow Reduce Motion

- **The setting:** "Follow the Mac's Reduce Motion" in the visual settings, on by default.
- **When it applies:** if the setting is on and `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` is true. The app watches `accessibilityDisplayOptionsDidChangeNotification`.
- **What it does:**
  - The app behaves as if **Gentle visuals** were on.
  - Camera pans run 2× slower.
  - Galaxy Warp's streaks become a slow drift.
  - World particle speeds are halved.
  - Your own Gentle visuals setting is unchanged; the effective value is `gentleVisuals || reduceMotionActive`.
- **Tests:**
  - the effective value under all four combinations;
  - the notification flips it live;
  - the setting decodes with its default.

## 7. The chime in key
- **What changes:** the Spaceship Lounge's chime (`ISD_AMB_CHIME`) plays tones of the key you're in.
  - A major key gives its major pentatonic; a minor key gives its minor pentatonic.
  - Tones are in the chime's existing octave, retuned only between strikes.
- **With no key sensed** it keeps its current notes.
- **Input:** it uses the same key input as the temple bell (Sets 9 & 10).
- **Tests:**
  - with the key D major, every chime partial set is rooted on a tone of D major pentatonic within 3 cents;
  - it never changes mid-ring.

---

## 8. Build order
1. `TakeKeeper`, the SMF writer and the gesture (Core), then the button, ⌘K and the toast (App).
2. The sleep timer (App) and `sleepDim` (Core), with the gain multipliers (App).
3. Hold the moment (Core `SceneDirector`; App triggers and pad).
4. `AmbienceBreath` (Core) and its settings.
5. Follow Reduce Motion (App).
6. The chime in key (DSP).
7. Review, release notes and a status note.

These run on a branch cut from the newest set branch, so the new worlds get the features too.

## 9. Decisions made without asking, and what each would cost to change
1. **The key gesture is the top three black keys, tapped twice.** Cost: a different gesture is one table.
2. **Takes are saved as MIDI with a JSON note, not audio.** Cost: an audio bounce would need a render path; that is out of scope here.
3. **The soft pedal triggers Hold.** Some players use it for its normal job. Cost: the setting switches it to sostenuto or off.
4. **Sleep fade cancels on any input,** rather than extending. Cost: an "extend 15 minutes" option is one menu item.
5. **Breathing is on by default.** Cost: one toggle.
6. **Follow Reduce Motion is on by default.** Cost: one toggle.
