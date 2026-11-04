# Sound brief: Zen Shakuhachi (Set 10, Zen Rock Garden)

Place-born: no song credit. The first instrument on the **breath-wind core**.

## Facts
- **The shakuhachi:** an end-blown bamboo flute with four finger holes and a thumb hole; the 1.8-shaku instrument's basic notes are D, F, G, A, C. The jet meets the bore at an open sharp edge, so it works at minima of the acoustic impedance like other flutes, but with neither the Western flute's narrow chimney nor its short upstream resonator. [UNSW (Wolfe & Smith)][uw], [NFA][nfa]
- **Meri and kari:** lowering the head (meri) and raising it (kari), with half-holing, bend the pitch down and up and change the timbre — meri is darker and softer. The player's face baffles the radiation, and its large changes in position give the instrument its flexibility of pitch and timbre. [UNSW][uw], [NFA][nfa]
- **Yuri:** a vibrato from head movement, **not** the diaphragm; "less regularity of speed and amplitude" is expected than in Western flute vibrato. [NFA][nfa]
- **Muraiki:** an explosive, breathy attack.
- **The sound ideal:** "the sound of wind in a decaying bamboo grove." [NFA][nfa]

## What we're matching
- **Attack:** a note begins as air and becomes tone; at Air 1 the level reaches −6 dB of its plateau **no sooner than 200 ms**, at Air 0 within **80 ms**.
- **Breath:** the air path −24 … −6 dB under the tone.
- **Meri on aftertouch:** up to **−150 cents** at full pressure (Bend 1) and **≥ 25%** darker (the bore's reflection low-pass 5 → 1.8 kHz); **kari** on the wheel up to +100 cents, brighter.
- **Muraiki:** velocity 120 against 60 has **≥ 6 dB** more 2–6 kHz energy over the first 150 ms (normalised by the steady level).
- **Yuri:** strongest rate in **3–5 Hz**, ±8–20 cents, its period varying **≥ 10%** cycle to cycle, starting after 0.4 s.
- **Bamboo:** two bore formants near 600 Hz and 1.9 kHz (Q about 3) and a 3 ms key-click at 1.5–3 kHz.
- **Range:** D4–D6; notes below D4 fold up an octave.
- **Tuning** within 5 cents once locked (a flute model drifts a little by design); fine tune and transpose exact within 2 cents. **CPU** < 6% for 8 voices with echo (CI).

## What we'll do better
- **Pressure is meri:** lean into the key and the note sinks and darkens, the way the player's head drops.
- **Breath you can hear:** soft notes are mostly air, hard ones burst with muraiki.
- **A mountain echo** as a dial, for the garden's open air.
- **Every part is a dial:** Breath, Air, Bend, Bamboo, Yuri, Echo, Space, Width.

## Playing notes
- The five notes D, F, G, A, C (and their octaves) are the instrument's own; long notes with silence between them suit it best.
- Press into long notes for meri, then release to let the pitch rise back; play a hard accent for a muraiki burst.

## Preset starting values

| Preset | breath | air | bend | bamboo | yuri | echo | space | width |
|---|---|---|---|---|---|---|---|---|
| Zen Shakuhachi | .45 | .55 | .60 | .50 | .40 | .30 | .40 | .45 |
| Mountain Breath | .60 | .70 | .70 | .45 | .50 | .70 | .60 | .55 |
| Hollow Bamboo | .30 | .35 | .40 | .85 | .30 | .15 | .25 | .40 |
| Still Air | .75 | .90 | .50 | .40 | .25 | .40 | .55 | .50 |

[uw]: https://newt.phys.unsw.edu.au/jw/shakuhachiresults.html
[nfa]: https://www.nfaonline.org/docs/default-source/committees-documents/global-flutes-committee/shakuhachi--then-and-now.pdf
