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

## Spectrogram check log
_(Filled in during Task 6.)_

[b1]: https://en.wikipedia.org/wiki/Bloom_(R%C3%BCf%C3%BCs_album)
[i1]: https://en.wikipedia.org/wiki/Innerbloom
[s1]: https://songbpm.com/@rufus-du-sol/innerbloom
