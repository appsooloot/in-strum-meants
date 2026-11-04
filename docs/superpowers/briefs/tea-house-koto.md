# Sound brief: Tea House Koto (Set 9, Tea House Snow)

Place-born: no song credit. The first instrument on the **plucked-string core**.

## Facts
- **The koto:** a 13-string zither about 1.8 m long, of paulownia, with a movable bridge under each string; plucked with plectra on the thumb, index and middle fingers of the right hand. [Gagaku (Stanford)][gk], [Denburg][dn]
- **Tuning:** the standard tuning is **hirajōshi** (40% of the traditional repertoire); from string 5 it runs E, F, A, B, C, E… — a minor-sounding pentatonic. String 1 sits at the same pitch as string 5 and is used as a drone. [Ando 1989][an], [Denburg][dn]
- **Tone:** "very treble sounding when plucked nearer to the bridges, and … more gentle … further away"; decay is "quite quick" next to the Chinese zheng, though the body rings audibly for more than six seconds. [Denburg][dn], [JASA 2020][fe]
- **Body:** measured resonances near 33, 50, 100, 194, 220 and 285 Hz, with 100 Hz dominant; a 20–40 Hz thump from the internal struts. [JASA 2020][fe]
- **Techniques:** **oshi** presses the string on the far side of its bridge to raise the pitch a semitone or a whole tone; **yuri** is a vibrato from a lighter, moving press; **hiki-iro** lowers a struck note slightly; **chirashi-zume** and **suri-zume** are plectrum scrapes. [Pro Musica Nipponia][pm], [Ando 1989][an]

## What we're matching
- **Pick position** 0.12 (near the bridge) … 0.5: pick 0.15 against 0.5 on A3 has **≥ 6 dB** more 2–6 kHz energy over its first 100 ms.
- **Silk** (string material): the loss filter's cutoff 9 kHz (crisp tetron) … 2.5 kHz (soft silk); silk 1 against 0 lowers the 0.3–0.6 s centroid by **≥ 25%**.
- **Decay:** A3 reaches −40 dB in **2–4 s**; an octave up decays 0.6× as long.
- **Press (oshi) on the pitch wheel:** up to +2 semitones, gliding over 25 ms, with **no re-attack** (no 10 ms window more than 6 dB under the one before).
- **Yuri on aftertouch:** a slow, irregular 4–6 Hz vibrato of 10–20 cents at full pressure, starting 150 ms after the pluck.
- **Sympathy (Bloom):** the 13 open strings ring softly; with E4 plucked, B4's energy over 1–2 s is **≥ 10 dB** above the same with the bank off.
- **Scrape:** velocity ≥ 118 adds a 2 ms plectrum scrape (3–8 kHz).
- **Tuning** within 2 cents; **CPU** < 6% for a 12-note chord with the bank (CI).

## What we'll do better
- **The press and the vibrato are yours:** the wheel is oshi, pressure is yuri, so the koto's most expressive techniques are under your hands, not baked in.
- **The open strings answer you:** every note wakes its neighbours in the tuning, the koto's bloom.
- **Every part is a dial:** Pick, Silk, Body, Bloom, Yuri, Space, Width.

## Playing notes
- Hirajōshi on E: E, F, A, B, C (and the octaves). Phrases that fall to the low E and leave space between notes sound most like the instrument.
- Press up with the wheel *after* plucking, then let it fall back; touch pressure on long notes for yuri.

## Preset starting values

| Preset | pick | silk | body | bloom | yuri | space | width |
|---|---|---|---|---|---|---|---|
| Tea House Koto | .55 | .45 | .50 | .40 | .30 | .35 | .50 |
| Winter Strings | .35 | .70 | .60 | .55 | .20 | .45 | .55 |
| Near the Bridge | .15 | .25 | .40 | .25 | .35 | .25 | .45 |
| Night Tea | .45 | .60 | .55 | .60 | .40 | .50 | .50 |

[gk]: https://gagaku.stanford.edu/en/strings/koto
[dn]: https://www.atlasensemble.nl/assets/files/instruments/Koto/Koto%20by%20Moshe%20Denburg,%20VICO.pdf
[an]: https://researchmap.jp/ANDO_Masateru/published_papers/44279058/attachment_file.pdf
[fe]: https://pubs.aip.org/asa/jasa/article/148/5/3153/631851/A-finite-element-model-of-the-Japanese-koto
[pm]: http://www.promusica.or.jp/english/koto.html
