# Sound brief: Felt Glass, after "Come Back to Earth"

## Facts
- **Song:** "Come Back to Earth", Mac Miller. **Album:** *Swimming*. **Track:** 1 of 13. **Released:** 3 August 2018. **Length:** 2:41. [Wikipedia: Come Back to Earth][w1], [Wikipedia: Swimming][w2]
- **Producers:** Jon Brion and Mac Miller, co-produced by Jeff "Gitty" Gitelman. **Writers:** Malcolm McCormick, Jon Brion, Jeff Gitelman. [w1]
- **Instrumentation as described in reviews:** "trickling piano lines and gauzy synthesised sounds", "orchestral arrangements", "shimmering instrumentals", layered vocals, "delicate". [w1], [cavacopedia][c1]
- **Key:** D. **Tempo:** about 84 BPM. One source gives D / 84 BPM / 2:42 ([SongBPM][s1]); another gives 85 BPM ([MusicIWant][m1]). Use **D, 84 BPM**.
- **Not documented:** I found no published credit for the exact keyboard or synth models. Everything below the facts is our original design aimed at the *described character*. Michael's ear on the play-along test is the final judge.

## What we're matching (measurable targets)
| Quality | Target |
|---|---|
| Register | Lines mostly C4–C6 ("trickling"), with chords in C3–C5. Best tone in MIDI 55–88 |
| Tone colour | Soft, rounded felt piano. At vel 70, MIDI 72: spectral centroid **900–1400 Hz** over the first 300 ms. At vel 30: **< 800 Hz** |
| Attack | Gentle and quick, never clicky. Felt thump present but subtle: **−24 to −18 dB** under the note at the default Felt |
| Decay | Held (pedal up), MIDI 72 reaches **−40 dB in 3–4 s**. MIDI 48 reaches **−40 dB in 7–9 s** |
| Shimmer | A "gauzy", shimmering halo, the Glass layer at default. Glass energy above 2·f₀ swells in over **0.4–0.9 s**, about **−12 dB** under the piano body |
| Space | An intimate room-to-small-hall. Default wet **25–35%**, RT60 **1.8–2.6 s**. Width moderate (L/R correlation 0.4–0.7) |
| Movement | Very slight: the beating of unison pairs only. No obvious chorus or vibrato |

## What we'll do better
- **Touch:** soft playing gets genuinely darker and rounder, not just quieter. That's an expressive range a static texture can't give.
- **Natural sustain:** sympathetic ring with the pedal, and the aftersound tail.
- **Glass layer under your control:** from bare felt to a glass choir.

## Play-along notes
- **Key:** D. Felt Glass is tuned to A = 440 Hz.
- **Fine tune:** if the recording sounds sour against it, try ±5–15 cents with Fine tune. The recording's reference pitch hasn't been measured.
- **Register:** play in the same register as the song's piano lines (around D4–D6). The default Space is chosen to sit in a similar soft room.

## Patch starting values (dials 0…1; fine tune and transpose 0)
| Preset | felt | glass | warmth | ring | space | width |
|---|---|---|---|---|---|---|
| Felt Glass (default) | 0.55 | 0.35 | 0.60 | 0.55 | 0.45 | 0.50 |
| Bare Felt | 0.70 | 0.00 | 0.65 | 0.50 | 0.35 | 0.45 |
| Glass Choir | 0.40 | 0.75 | 0.50 | 0.70 | 0.60 | 0.70 |
| Lullaby | 0.85 | 0.20 | 0.80 | 0.45 | 0.30 | 0.35 |

## Measured against the targets (Task 2, offline renders at 48 kHz, default preset unless noted)
| Target | Measured |
|---|---|
| Centroid, vel 70, MIDI 72, 0–0.3 s: 900–1400 Hz | **1408 Hz** (vel 127: 2305 Hz) |
| Centroid, vel 30, MIDI 72: < 800 Hz | **760 Hz** |
| Softer is darker (MIDI 60, vel 30 vs 110) | **0.29×** |
| MIDI 72 held to −40 dB: 3–4 s | **3.65–3.85 s** (vel 70–127) |
| MIDI 48 held to −40 dB: 7–9 s | **7.7 s** (vel 127); vel 70 just beyond 8 s |
| Thump −24…−18 dB under the note | set to (−18 + 10·felt) dB under the note's initial level (−12.5 dB peak at default, about −20 to −25 dB averaged over the burst) |
| Glass swells over 0.4–0.9 s, about −12 dB under the body | peak at **0.4–0.6 s**, **−11.7 dB** under the body's initial level |
| Space wet 25–35%, RT60 1.8–2.6 s | wet **27%**, RT60 about **2.6 s** |
| Sympathetic ring with the pedal | **−23 to −26 dB** under the notes after the first second |
| Levels | vel 100 C4 peaks −10.8 dBFS, ff C4 −5 dBFS, ff C2 −3 dBFS; a peak limiter (0.9 ceiling) keeps dense ff chords clean |
| CPU (32-note pedalled run + 16-note chord) | **2.2–2.4%** of real time (x86 clang -O2 locally); under the 5% budget in CI |

Preset contrasts (MIDI 72, vel 70): Felt Glass centroid 1457 Hz / −40 dB at 3.85 s · Bare Felt 1344 Hz / 3.25 s (no halo) · Glass Choir 1542 Hz / 4.1 s (long halo) · Lullaby 1164 Hz / 3.6 s (darkest, closest).

## Spectrogram check log
- Task 2: the demo phrase and the four presets were rendered and inspected as spectrograms. Clean partials, a visible glass halo above each note, and natural decays.
- Fixes made from the images:
  - A hard spectral edge on ff bass notes, where the partial cap cut off strong partials: the top quarter of the partials now tapers off.
  - High glass partials ringing as long as low ones: each glass partial's decay now shortens with frequency.
- Low-frequency smear under the chords: checked numerically and found to be window leakage, 44 dB under the notes.
- Task 5 adds the CI-rendered demo and spectrogram for each build.

[w1]: https://en.wikipedia.org/wiki/Come_Back_to_Earth
[w2]: https://ipfs.ssi.eecc.de/ipns/en.wikipedia-on-ipfs.org/wiki/Swimming_(Mac_Miller_album)
[c1]: https://cavac.at/cavacopedia/Come%20Back%20to%20Earth
[s1]: https://songbpm.com/@mac-miller/come-back-to-earth
[m1]: https://musiciwant.com/song/come-back-to-earth-mac-miller
