# Sound brief: Magma Bass (Volcano Rim)

The first bass on the **vintage-synth core** (the grown `AnalogVoice.hpp`). Spec: `docs/superpowers/specs/2026-11-05-fire-and-neon-design.md` §4.1–§4.2.

## Facts
- **The set's credit:** "Hold My Liquor", by Kanye West, from *Yeezus* (2013), track 5. It is the backlog's credit for Volcano Rim.
  - Spotify search: `Hold My Liquor Kanye West`.
  - Describe its production only from sources found at build time; nothing here is taken from the recording.
  - **Check the key and the felt pulse by ear** before the card relies on them. Found so far: A♭ major at 104 BPM (audiokeychain), 80 BPM with no key (musiciwant); Wikipedia calls it a house ballad on "pulsating synths and metallic, distorted stabs" over "a slow, steady 4/4 beat", which fits 80.
- **Why a volcano gets growl:**
  - Pairings rule 11: "save growl and grit for real menace: volcanoes and storms".
  - Rule 2: low notes belong to big, grounded things.
  - Low brass is the volcano precedent in film scoring, and the synth bass here is its electronic cousin.
- **The analogue lineage:** a mono-synth bass voice (oscillator, sub, ladder low-pass, drive), as on classic analogue monos and polys. Everything is synthesised; nothing is sampled or modelled from a specific product.

## What we're matching
- **The growl:**
  - Pre-filter drive and a sine wavefolder, oversampled 2×.
  - The ladder's own feedback saturation, so resonance growls rather than whistles.
  - Growl moves all three together.
- **The rip:**
  - The filter envelope's depth scales with velocity (Erupt).
  - Velocity also drives the growl itself (0.35…1 into the shaper), so a hard note both opens the filter and saturates harder.
  - Measured on A1 over 0.05–0.4 s: the share of 0.5–4 kHz is **≥ 4 dB** higher at fff than pp at the defaults, and **≥ 9 dB** at Growl 0. A spectral centroid hardly moves on a low bass, because the first harmonics carry nearly all the power.
  - Aftertouch adds +1.5 octaves.
- **The weight:**
  - A sub square an octave down, and a sine **Rumble** two octaves down.
  - At Rumble 1, the f/4 energy is **≥ 10 dB** above Rumble 0.
  - A 25 Hz high-pass and a soft shelf keep the bus clean.
- **The right hand:** above C4, notes play the **Spark**, a band-passed, folded partial an octave up at about −14 dB, so chords up high add fire, not mud.
- **The eruption:**
  - A hard low chord swells the rumble by +3 dB over 1.2 s, on the same rule the world uses: `isEruptChord`, which means three or more notes within 40 ms, mean velocity ≥ 0.8, below C3.
  - So the sound and the eruption land together.
- **Glide:** Flow sets 5–600 ms. With Mono, overlapping notes glide legato without retriggering.
- **Tuning:** within 3 cents (DRY hook). Fine tune and transpose are exact.
- **The ceiling:** a 6-note fff chord at Growl 1, Res 0.9 and Rumble 1 peaks ≤ −0.3 dBFS.

## What we do better
- Velocity is a real performance control, not just a level.
- The right-hand Spark makes the bass playable as a two-handed instrument.
- The eruption swell ties the sound to the world.

## Playing notes
- Play low, hard chords to set off the volcano.
- Hold a fifth in the left hand and roll the mod wheel for the wobble.
- Switch on Mono with Flow up for gliding lead lines in the low register.

## Presets
| Preset | Growl | Heat | Erupt | Rumble | Grit | Flow | Shape | Mono | Spark | Res |
|---|---|---|---|---|---|---|---|---|---|---|
| *Magma* (default) | .55 | .50 | .70 | .35 | .25 | .20 | .15 | off | .40 | .35 |
| *Basalt* | .40 | .30 | .55 | .70 | .15 | .35 | .05 | on | .20 | .25 |
| *Fissure* | .65 | .70 | .80 | .20 | .35 | .10 | .40 | off | .50 | .60 |
| *Ember Glide* | .50 | .55 | .60 | .30 | .20 | .70 | .25 | on | .30 | .40 |

*Fissure* also shortens the amp decay to 0.45 s.
