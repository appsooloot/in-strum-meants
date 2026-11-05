# "Fire & Neon": the brief for the spec

**Date:** 2026-11-05
**From:** Michael's requests on 5 Nov, plus the parts of the pairings doc this run needs. The pairings doc (`2026-11-04-scape-instrument-pairings-and-ideas.md`) lives in the claude.ai project, not the repo, so everything the spec needs from it is copied here.
**Next:** a full design spec, `2026-11-05-fire-and-neon-design.md`, in the same form as `2026-11-04-sets-11-12-design.md`.

## What Michael asked for (his words, 5 Nov)
- "Can we work on less boring worlds and variables for more excitement please."
- "Also want to work on at least one bass instrument and maybe more, or even synths if it suits."
- "Sounds exciting, hope it lives up to the hype."
- "Probably better to just move on to build more and fix up later."

He has played the latest build and finds it "okay, was expecting more". The last three runs were calm (Night Skies, Still Places, Deep Water). This run has to feel **loud, alive and reactive** the first time he plays it: the world should visibly answer every hard chord. Restraint is the default only where the standing rules require it (flash limits, smoothness).

## The two sets

### Volcano Rim (backlog #2) + **Magma Bass**
- **The instrument:** a growling analogue mono and poly bass.
  - A sub-oscillator sits under a gritty saw and pulse.
  - Drive and grit, then a resonant ladder-style filter that **rips open with velocity** and aftertouch.
  - Glide, and a "rumble" dial for sub-harmonics.
  - It starts the **vintage-synth core** (below) and is the first of the planned Synth Engine basses (Magma, Chrome, Acid, Turbo, Diesel, Steam, Fog and Basalt are listed in the original design).
- **The world:** a volcano's crater rim at night, with lava lakes and flows, a glowing ash plume, and embers.
  - The lava answers you: low notes brighten the cracks and send up spits of lava, a hard low chord sets off an **eruption**, and the plume flickers with **volcanic lightning** (a real phenomenon, "dirty thunderstorms").
- **Credit:** the backlog lists "Hold My Liquor" (Kanye West, *Yeezus*, 2013). The pairings doc also notes that low brass is the volcano precedent, and Foghorn, Harmonic Flights and Amplified Cello Quartet are plugin alternatives. Check the key and tempo by research and mark them for Michael's ear check. As always, the credit is text and a Spotify link only.
- **Pairings rules that apply:**
  - **Rule 11:** "Save growl and grit for real menace: volcanoes and storms." This world is one of the few where growl belongs.
  - **Rule 2:** low notes for big, grounded things (mountains, volcano rumble).
  - **Rule 7:** awe gets long, dark tails.

### Neon Night Drive (backlog #26) + **Replicant Brass** + **Chrome Bass**
- **The instruments:**
  - **Replicant Brass** is a huge, swelling CS-80-style synth brass: slow filter swell, detuned pair, ribbon-like pitch bend, aftertouch brightening, a big reverb. It is on the vintage-synth core.
  - **Chrome Bass** is a punchy, bright, sequenced bass played from a **left-hand split**, with a **tempo-locked arpeggiator with Hold**. Both are on the vintage-synth core.
  - It is one set with one instrument that has a split: Replicant Brass is the instrument, and Chrome Bass is its left-hand voice.
- **The world:** a city expressway at night through rain, neon signs and light trails, with the windscreen and wipers in view.
  - The car's speed follows your tempo and how hard you play.
  - The neon's colours follow your chords: major is warm, minor is cool (the existing chord-colour rule).
  - Playing hard brings a "drop", where the road opens up and the lights streak.
- **Precedent:** Blade Runner's CS-80 brass and neon (pairings §2: "Noir and neon: Rhodes, sax or trumpet, FM synth bells"; Space: "Blade Runner's CS-80 brass").
- **Credit:** the pairings doc suggests "Gassed Up" (Wombat, 2019, C♯, 140). But Michael hasn't listened yet, and nothing documents Wombat's instruments, so make this a **place-born set with a place card**. Note "Gassed Up" as a possible credit once he has listened.
- **Pairings rules that apply:**
  - **Rule 10:** energy is bright, sharp and dense.
  - **Rule 4:** angular, metallic and neon worlds get sharper attacks.
  - **Rule 12:** wood, breath, string and bell are fine in cities, and synths belong here.

## The vintage-synth core (pairings §5, rank 6)
- **Instruments it makes later:**
  - *Replicant Brass* (CS-80)
  - *Juno Prayer* (for "Saint Pablo")
  - *Anthem Supersaw* and *Anthem Brass*
  - *Acid Bass*
  - Chip Lead
  - *Glass Wave* (PPG)
  - *Twin FM Keys* (DX7)
  - the Magma, Chrome, Turbo and Diesel basses
- **Worlds it unlocks:** about 14, covering every energetic and neon world (Race Night #40, Underground Club #32, Festival Main Stage #31, Rooftop Party #27, Arcade Alley #28, Highway at 3 a.m. #46 and others).
- **Starting point:** the Deep Water run already built an **analogue-voice core** for Blue Depth. Check `Sources/InStrumDSP` and grow it, or share its pieces (oscillators, ladder filter, envelopes). Don't make a parallel copy.
- **CPU:** the research budget is about 270 cycles per voice per sample. Share reverb and chorus across voices.

## "Excitement variables" for every world (Michael's "variables for more excitement")
Design these as a shared system, so every existing world gets them too, not just these two:
1. **Energy.** A live reading (0…1) of how hard and how fast you're playing: velocity, note rate and chord size, smoothed. Each world maps it to busier, brighter and faster.
   - Examples: the bay's plankton, the aurora's speed, the coast road's traffic, snowfall rate, the reef's fish.
   - Show it as a small "Energy" control, with an auto mode and a manual dial.
2. **Big moments.** A hard chord (velocity and size over thresholds) or a crescendo sets off that world's signature event.
   - In the new worlds: an eruption, a lightning strike, a drop.
   - In the existing worlds: fireworks over Golden Hour, a meteor burst in any night sky, a whale breach at the reef or submarine, an aurora surge at the fjord, a wave of bioluminescence in the bay, a gust that sends the tea-house snow swirling.
   - There is a cooldown, and **every flash goes through `FlashLimiter`**, with gentle mode honoured.
3. **Surprises.** Rare random events per world, seeded, never twice the same in a session, and roughly one every few minutes at most.
   - Examples: a fireball meteor, a far lightning sprite, a comet, a shooting light on the road, a breaching whale, a ship's lights passing.
4. **Build and drop.** Rising playing (pitch climbing, getting louder and denser) builds tension in the world: the light gathers, the wind rises, the lava swells. A big chord releases it.
5. **Arpeggiator with Hold** (pairings §7.10.9). It goes into the shared Sound Core, so any instrument can use it, with its rate tied to the tempo.

Keep it honest with the existing features: Hold the Moment (time freeze), Reduce Motion and gentle visuals all calm or skip these. Older saves still load.

## New sky and weather (one each, reaching every sky world)
- **Sky: red sprites.** Faint red upper-atmosphere flashes above distant thunderstorms, a real phenomenon (pairings §7.4). Treat them as distant, brief and gentle, through `FlashLimiter`.
- **Weather: volcanic ash and ember fall** for the volcano, and the weather that fits wet neon city streets for the drive. Pick one new weather that reaches every sky world.
  - The natural fit is **Electrical Storm**: a thunderstorm with real lightning (fork and sheet). It reaches every sky world, and it's the "Lightning Plains" energy Michael may like.
  - It must respect `FlashLimiter` and gentle mode.

## New ambience (one family per set)
- **The volcano:** a deep rumble (sub-bass, felt more than heard), lava hiss and crackle, steam vents, rockfall, eruption booms, thunder from the plume.
- **The drive:** tyres on a wet road, wipers, engine and gear changes that follow the car's speed, passing cars (with Doppler), rain on the roof, a far siren in key (wordless).

## Standing rules (unchanged)
- **One of everything:** each set has a world, its visual, an original instrument, a new sky feature, a new weather and new ambience, tied by a mood.
- **Original synthesis only:** no samples. Credits are text and a Spotify link; place cards for place-born sets.
- **Smooth on the Intel Mac (macOS 13):** ≤ 1 MP, no per-pixel ray marching, ≤ 3 noise octaves, no buffers made per frame.
- **Flashes go through `FlashLimiter`.** Older saves still load. Tests come first.
- **Record every choice made without asking** in the spec, with its cost if Michael decides otherwise.
- **Numbering:** these become **Sets 13 & 14**. Home Lights, already specced as "Sets 13 & 14", becomes 15 & 16 when it is built.
