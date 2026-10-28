# Sound brief: Haze Bells (after "High by the Beach")

## Facts
- **Song:** "High by the Beach", Lana Del Rey. *Honeymoon* (2015), **track 5** (4:18). Lead single, August 2015. [Wikipedia: Honeymoon][hm], [Wikipedia: High by the Beach][hbtb]
- **Writers and producers:** Lana Del Rey, Rick Nowels and Kieron Menzies.
  - Rick Nowels: synthesizers, keyboards and organ.
  - Kieron Menzies: synth bass, sampler, effects, synthesizers and drum programming. [hm], [hbtb]
- **Key:** **B (harmonic) minor**, with the bridge in D major. Verse and chorus i–VI–iv–V (Bm–G–Em–F♯). [Hooktheory][ht], [SongBPM][sb]
- **Tempo:** **132 BPM** in 4/4, with a half-time trap feel (about 66). [ht], [sb]
- **The sound:**
  - "Prominent, dreamy synth beeps", "brooding, eerie organ", TR-808 drums with hi-hat emphasis, and an opening of waves and vintage keys. [hbtb]
  - Kieron Menzies' Mix with the Masters session covers its "hazy, lo-fi aesthetic": saturation, compression, bit-crushing, delay and filtering, with organ, flute and **dulcitone**. [MWTM][mw]
  - A dulcitone is a keyboard whose hammers strike tuning forks: a pure, celesta-like tone with a bright strike.
  - The chorus came from Del Rey's drives along a beach. [hbtb]
- **Spotify search:** `High by the Beach Lana Del Rey`

## What we're matching
- **Register:**
  - Bells around B3–B6; the "beeps" sit mostly in the octave above middle C and the one above that.
  - Organ underneath, around B2–B4.
- **Tone colour:**
  - A tuning-fork strike: a bright clang near 6.25 × f0 that vanishes in **50–150 ms**, leaving an almost pure ring.
  - Target spectral centroid at mf for B4 (494 Hz): **2–4 kHz in the first 50 ms**, settling to **0.6–1.0 kHz** after 300 ms.
  - The organ is soft and airy: 8′ + 4′ + a little 2⅔′.
- **Attack:**
  - Bells: instant, with a ~10 ms felt thump.
  - Organ: about **30 ms**.
- **Decay:**
  - The bell fundamental rings **3–8 s** to −40 dB (shorter up high).
  - The organ releases in about **150 ms**.
- **Movement:**
  - Organ vibrato and chorus around **6 Hz**.
  - A slow, shared pitch drift (warped record) up to about **±8 cents** at the dial's top.
- **Echo:** **dotted-eighth at 132 BPM = 0.75 × 60 / 132 = 0.3409 s**, filtered and darkening per repeat, with the feedback giving 3–5 audible repeats at the default.
- **Lo-fi:** saturation always on gently; crush (rate and bit reduction) as a parallel tint, never harsh at the default.
- **Space:** wide and dark, behind the echo.

## What we'll do better
- **Every part of the haze is a dial:** echo, crush and drift can be zeroed for a clean bell, or pushed for the full record.
- **Velocity shapes the strike:** a soft touch gives a round fork, a hard one a bright clang.
- **The organ blends in:** one dial brings it up from a whisper to Church Keys.

## Play-along notes
- **Key:** B minor (harmonic: A♯ appears over the F♯ chord).
- **Echo:** the echo is set to the song's dotted-eighth, so repeated notes ripple in time with the record.
- **Tuning:** concert pitch.

## Preset starting values

| Preset | bells | organ | echo | crush | drift | space |
|---|---|---|---|---|---|---|
| Haze Bells | .80 | .25 | .35 | .15 | .30 | .50 |
| Church Keys | .45 | .80 | .25 | .10 | .20 | .60 |
| Night Drive | .80 | .30 | .65 | .15 | .35 | .70 |
| Lo-Fi | .75 | .30 | .40 | .60 | .60 | .45 |

`HazeBells::kEchoSeconds = 0.75f * 60.f / 132.f` (0.340909 s).

[hm]: https://en.wikipedia.org/wiki/Honeymoon_(Lana_Del_Rey_album)
[hbtb]: https://en.wikipedia.org/wiki/High_by_the_Beach
[ht]: https://www.hooktheory.com/theorytab/view/lana-del-rey/high-by-the-beach
[sb]: https://songbpm.com/@lana-del-rey/high-by-the-beach
[mw]: https://mixwiththemasters.com/videos/kieron-menzies-lana-del-rey-high-by-the-beach
