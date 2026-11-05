# Sound brief: Replicant Brass with Chrome Bass (Neon Night Drive)

The second instrument on the **vintage-synth core**. Spec: `docs/superpowers/specs/2026-11-05-fire-and-neon-design.md` §4.1, §4.3 and §4.4.

## Facts
- **The set:** place-born, with a place card.
  - "Gassed Up" (Wombat, 2019; listed as C♯, 140) is a possible credit once Michael has listened. Nothing documents its instruments.
- **The precedent:** the neon-noir film-score sound of the early 1980s.
  - It is a big polyphonic analogue "brass": a detuned saw stack, a slow filter swell and a huge reverb, played expressively with a ribbon-like pitch bend and aftertouch.
  - The pairings doc names "Blade Runner's CS-80 brass" as the space and neon precedent.
  - We take the *kind* of sound only: no melody, sample, preset dump or film audio, and the preset name *Tears in Rain* is a nod only.
- **The left hand:** a punchy, bright sequenced bass with an arpeggiator locked to tempo, the engine of night-drive synth music.

## What we're matching
- **The swell:**
  - The brass filter's attack is the Swell dial, 40–600 ms; the time to 90% of the 1–4 kHz energy is 40 ± 10 ms at 0 and ≥ 450 ms at 1.
  - Every note blooms.
- **The blare:**
  - At velocity 1 only, the attack is 70 ms with a +2-octave overshoot that settles over 300 ms, so the centroid peaks ≥ 1.5× its settled value.
  - At velocity 0.6 there is no peak above 1.1×.
- **The width:**
  - A 7-saw unison stack (±2 to ±16 cents with Width), plus a 30% pulse, then a shared chorus.
  - Stereo correlation falls from ≥ 0.9 at Width 0 to ≤ 0.5 at Width 1.
- **The scale:** a big shared hall, size 0.85, with the send on Hall.
- **The blade:**
  - Pitch bend reaches ±7 semitones (+700 ± 10 cents).
  - Releasing a key with the bend held lets the pitch fall back over ≤ 120 ms.
- **Aftertouch:** brightens by +2 octaves and fades in a 5 Hz vibrato.
- **Chrome Bass:**
  - Below the Split (default C3), it plays two saws an octave apart plus the sub, with a fast filter pluck (140 ms, +4 octaves) and drive 0.35.
  - It is mono-legato.
  - The shared arpeggiator is on by default: Played order, sixteenths, sample-accurate against the tempo, or following the played tempo.
- **Safety:**
  - Moving the Split or the Arp mode while keys are held releases each note on the voice that started it.
  - Panic or a switch mid-arp is silent within 50 ms.
  - A 10-note fff chord with Hall 1 peaks ≤ −0.3 dBFS.

## Playing notes
- Hold a low root in the left hand and let the Chrome arp run. Swell slow brass chords over it.
- Dig in for the blare. Bend up a fifth at the end of a phrase.
- Play faster and harder to speed up the drive. A big chord after a build brings the Drop.

## Presets
| Preset | Swell | Blaze | Width | Hall | Chrome | Punch | Arp | Rate | Split |
|---|---|---|---|---|---|---|---|---|---|
| *Replicant* (default) | .60 | .50 | .70 | .55 | .60 | .50 | Played | 1/16 | C3 |
| *Tears in Rain* | .85 | .35 | .80 | .80 | .45 | .35 | Played | 1/8 | C3 |
| *Chrome Rush* | .35 | .65 | .60 | .40 | .75 | .80 | Up | 1/16 | C3 |
| *Night Brass* | .70 | .55 | .75 | .65 | — | — | Off | — | off |
