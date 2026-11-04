# Sound brief: Reef Marimba (Set 12, Great Barrier Reef)

This instrument is born from its place, so it has no song credit. It is the first instrument on the **modal mallet core**.

## Facts
- **The bar:**
  - A marimba bar is undercut so that its lowest three partials are tuned roughly **1 : 4 : 10**. The third partial is often about 9.2 times the fundamental. [CCRMA][cc], [La Favre][lf]
  - The second partial needs to be within **±15 cents** of the double octave for a clear pitch (Bork and Meyer). [La Favre][lf]
- **Decay:** "When the frequencies of the partials of a bar behave like 1:4:10, the second partial decays four times as quickly, the third partial ten times as quickly as the fundamental." (Bork 1995) [La Favre][lf]
- **Mallets:**
  - Soft, heavy mallets excite the lower modes, and players use them at the bass end. Hard mallets are used at the treble.
  - Softer mallets damp the higher partials. [La Favre][lf], [VSL][vsl]
  - Stick contact lasts about **1–2 ms**, and less when struck harder (steelpan sticks: 1.2–2.2 ms). [KTH 1988][kth]
- **The resonator:**
  - Each bar has a tube closed at the far end and tuned to its fundamental. "If there were no resonator pipe, there would just be a soft popping sound when the wooden bar was hit." [Yamaha][ya]
  - Coupling the tube radiates more at the fundamental and shortens the bar's decay. [J. Sound Vib. 2023][jsv]
- **Strike point:** a free bar's second bending mode is antisymmetric, so it has a node at the centre. Striking there leaves the 4× partial silent, which is why players strike a little off centre. This follows from the bending modes of a free-free beam, the same model the bar-and-resonator study uses. [J. Sound Vib. 2023][jsv]
- **Steel:** steelpan notes have their lowest three partials tuned to the octave and twelfth, or to the double octave. Harder strikes add upper partials. [Hansen & Rossing][hr]

## What we're matching
- **Partials:** with the BAR_ONLY hook on A3, peaks at **1**, **3.99 ± 0.02** and **9.2–10** times f0. The third partial is 9.2 from C5 up, rising to 10.0 at C2–C4.
- **Decay:**
  - The fundamental's T60 is 2.6 s at C2, falling to 0.35 s at C7.
  - The 4× partial's T60 is **1/4 ± 20%** of the fundamental's, and the third partial's **1/10 ± 25%**.
- **Mallet:**
  - Contact time τ runs from 4.5 ms (soft yarn) to 0.6 ms (hard rubber), and velocity shortens it by up to 40%.
  - On A3, Mallet 1 against 0 raises the 2–6 kHz energy over the first 50 ms by **≥ 12 dB**.
- **Strike:** at Strike 0 (the centre) the 4× partial is **≥ 20 dB** below its level at Strike 0.5.
- **Tube:** Tube 1 against 0 lifts the fundamental's band by **≥ 6 dB**, and the bar's own decay shortens by about 15%.
- **Roll:**
  - Hold a note and after 0.3 s it rolls at **9–13 Hz**, with alternating mallets and ±12% jitter.
  - Pressure raises the rate to 16 Hz and the stroke strength up to 0.95 of the velocity.
- **Steel:** at Steel 1 the 2× partial is present at **≥ −20 dB**.
- **Range:** C2–C7. Notes outside it fold by octaves.
- **Tuning:** within 2 cents. **CPU:** < 6% for a 12-note chord plus a 4-note roll.

## What we'll do better
- **It rolls for you.** A marimba can't sustain a note, so players roll. Hold a key and it rolls; press harder and the roll swells.
- **The mallet is a dial.** You can go from soft yarn in the bass to hard rubber at the top. The bass softens itself the way players choose softer mallets low down.
- **Sunlight on the bars.** The Steel dial adds a tuned steel shimmer over the wood.
- **Every part is a dial:** Mallet, Strike, Tube, Roll, Steel, Space and Width.

## Playing notes
- Runs and broken chords suit it. Hold long notes and let them roll.
- Use the Night Reef preset after dusk. It has softer mallets, longer rolls and more space.

## Preset starting values

| Preset | mallet | strike | tube | roll | steel | space | width |
|---|---|---|---|---|---|---|---|
| Reef Marimba | .45 | .40 | .70 | .35 | .20 | .35 | .55 |
| Soft Yarn | .15 | .35 | .85 | .45 | .00 | .40 | .50 |
| Lagoon Steel | .60 | .45 | .55 | .25 | .70 | .40 | .60 |
| Night Reef | .30 | .50 | .80 | .55 | .10 | .55 | .60 |

[cc]: https://ccrma.stanford.edu/CCRMA/Courses/152/percussion.html
[lf]: https://www.lafavre.us/tuning-marimba.htm
[vsl]: https://www.vsl.co.at/academy/percussion/marimba
[kth]: https://www.speech.kth.se/qpsr/1988/1988_29_4_059-073.pdf
[ya]: https://www.yamaha.com/en/musical_instrument_guide/marimba/mechanism/mechanism002.html
[jsv]: https://www.sciencedirect.com/science/article/pii/S0022460X22007118
[hr]: http://www.hangblog.org/pdf/hansen_rossing_the-caribbean-steelpan-and-some-offsprings.pdf
