# Sound brief: Orbit Pad, after "Innerbloom" (intro)

## Facts
- **Song:** "Innerbloom", RÜFÜS (RÜFÜS DU SOL). **Album:** *Bloom*. **Track:** 11 of 11 (the closer). **Released:** 22 January 2016. **Length:** 9:36 (album) / 9:38. [Wikipedia: Bloom][b1], [Wikipedia: Innerbloom][i1]
- **Writers and producers:** Tyrone Lindqvist, Jon George, James Hunt. [b1], [i1]
- **Described sound:** "woozy synths unspooling towards a perfectly weighted anthem of the interior" (The Guardian), "blissful electronic atmosphere" (The AU Review). Lindqvist called it "probably the most personal song we've written". Genre: electronic, deep house, progressive house. [i1]
- **Key:** D♯/E♭ major. **Tempo:** 122 BPM. [SongBPM][s1]
- **Not documented:** I found no published credit for the specific synths or patches. Everything below the facts is our original design aimed at the *described character* ("woozy", "unspooling", "blissful"). Michael's ear on the play-along test is the final judge.

## What we're matching (measurable targets)
| Quality | Target |
|---|---|
| Register | Chords around E♭3–B♭4, with the sub an octave or two below. Best in MIDI 48–79 |
| Tone colour | Warm, soft-edged analogue saws. Never buzzy at the start. Centroid at vel 90, MIDI 63, 0.3–0.8 s: **400–650 Hz** |
| Bloom ("unspooling") | The filter opens slowly as a chord is held. Centroid at 3.0–3.5 s: **1.5–2.5×** the early value (default Bloom) |
| Woozy | Gentle pitch drift and detune with no wobbly vibrato. Unison spread about **±10 cents**. Drift **±2–3 cents** below 0.3 Hz |
| Attack | Fades in over **0.6–1.2 s** at default |
| Release | Drifts away. Audible (> −40 dB) **2 s** after release. Gone below −90 dB by **12 s** (space 0) |
| Space | Big and wide. Wet **40–55%**, RT60 **3.5–5 s**, L/R correlation **0.2–0.5**. Light shimmer at default |
| Movement | Slow swirling: cutoff, pan and detune LFOs at **0.05–0.25 Hz**. Gentle chorus |

## What we'll do better
- **Touch:** velocity sets how bright each chord blooms, so playing becomes part of the build.
- **Endless, never-looping movement:** every voice drifts on its own path.
- **Shimmer and space you can dial:** from intimate to weightless.

## Play-along notes
- **Key:** E♭ major at 122 BPM. Orbit Pad is tuned to A = 440 Hz.
- **Fine tune:** if it sounds sour against the recording, try small ±cents adjustments.
- **What to play:** long chords (E♭ / B♭ / Cm / A♭ shapes) held across bars blend best with the intro's atmosphere. Lower the Bloom time to follow quicker changes.

## Patch starting values (dials 0…1; fine tune and transpose 0)
| Preset | bloom | drift | motion | shimmer | brightness | space |
|---|---|---|---|---|---|---|
| Orbit Pad (default) | 0.55 | 0.40 | 0.45 | 0.25 | 0.50 | 0.55 |
| Earthrise | 0.75 | 0.30 | 0.30 | 0.15 | 0.40 | 0.50 |
| Weightless | 0.50 | 0.45 | 0.55 | 0.60 | 0.55 | 0.75 |
| Re-entry | 0.25 | 0.35 | 0.50 | 0.20 | 0.75 | 0.45 |

## Measured against the targets (Task 6, 48 kHz, default patch, neutral mood)
A five-saw unison beats, so a half-second centroid of one note swings by about ±25%. Centroids below are means over MIDI 59–67, scaled to MIDI 63.

| Quality | Target | Measured |
|---|---|---|
| Tone colour (centroid, vel 90, 0.3–0.8 s) | 400–650 Hz | **401 Hz** |
| Bloom (centroid at 3.0–3.5 s ÷ early) | 1.5–2.5× | **1.94×** mean (single notes 1.2–2.6×). One plain saw: 1.72× at worst |
| Unison spread | about ±10 cents | **±11.8 cents** (3 + 22·Drift) |
| Drift | ±2–3 cents below 0.3 Hz | **up to ±2.6 cents**: a random walk that drifts back over ~1.5 s, low-passed at 0.3 Hz |
| Attack | 0.6–1.2 s | within 1 dB of the held level at **0.83 s** |
| Release | > −40 dB at 2 s; < −90 dB by 12 s | **−20 dB** at 2 s (held chord). Dry, it is gone (−200 dBFS) at 12 s |
| Wet | 40–55% | **50%** of a held chord's energy |
| RT60 | 3.5–5 s | **4.3 s** (size 0.51, shimmer 0.25) |
| L/R correlation | 0.2–0.5 | **0.36** (held chord) |
| Movement | LFOs 0.05–0.25 Hz, gentle chorus | each voice: cutoff ±20%, pan ±0.4 and detune ±3 cents at its own 0.05–0.25 Hz rates. Chorus taps 7–15 ms at 0.17, 0.23 and 0.31 Hz |
| Clean top | — | MIDI 96 plain saw, filter fully open: inharmonic energy **−57 dB** (4-point B-spline BLEP) |
| Level | — | single note −23 dBFS RMS (vel 90). Six-note chord −15 dBFS RMS, peak 0.71 |

### Presets (vel 90, neutral mood)
| Preset | Early centroid | Bloom | Within 1 dB at | Held chord L/R | Character check |
|---|---|---|---|---|---|
| Orbit Pad | 401 Hz | 1.94× | 0.83 s | 0.36 | default |
| Earthrise | 359 Hz | 1.68× | 1.07 s | 0.31 | warmer, slower ✓ |
| Weightless | 414 Hz | 1.86× | 0.76 s | 0.34 | more shimmer and space ✓ |
| Re-entry | 495 Hz | 1.77× | 0.52 s | 0.45 | brighter, faster ✓ |

Under the Spaceship Lounge's dreamy mood, the bloom slows a little (1.5×), the space widens (L/R 0.1, about 60% wet) and the release lengthens.

## Spectrogram check log
- **build-113, first CI render of the demo:** each chord's top end swells in over about 2 s and closes as it is released. The bottom was thick: every chord note carried its own sub, stacking up to six sines between 30 and 120 Hz.
  - **Change:** the sub now follows the lowest held note, crossfading over 80 ms. The octave-down pulses thin out in the bass (40% at MIDI 36, full from MIDI 54).
- **After the change (local render of the same demo):**
  - 250 Hz–1 kHz carries the body, at −15 to −20 dB.
  - 4–16 kHz swells to about −35 dB under each held chord.
  - 20–80 Hz sits at −40 to −50 dB, a single clear low end.

[b1]: https://en.wikipedia.org/wiki/Bloom_(R%C3%BCf%C3%BCs_album)
[i1]: https://en.wikipedia.org/wiki/Innerbloom
[s1]: https://songbpm.com/@rufus-du-sol/innerbloom
