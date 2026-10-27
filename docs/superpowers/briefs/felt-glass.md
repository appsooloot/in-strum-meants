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

## Spectrogram check log
_(Filled in during Task 5: comparison of rendered demo spectrograms against the targets above.)_

[w1]: https://en.wikipedia.org/wiki/Come_Back_to_Earth
[w2]: https://ipfs.ssi.eecc.de/ipns/en.wikipedia-on-ipfs.org/wiki/Swimming_(Mac_Miller_album)
[c1]: https://cavac.at/cavacopedia/Come%20Back%20to%20Earth
[s1]: https://songbpm.com/@mac-miller/come-back-to-earth
[m1]: https://musiciwant.com/song/come-back-to-earth-mac-miller
