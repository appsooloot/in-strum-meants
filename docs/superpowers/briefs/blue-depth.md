# Sound brief: Blue Depth (after "Underwater")

The first instrument on the **analogue voice core**.

## Facts
- **The song:** "Underwater", by RÜFÜS DU SOL, from *Solace* (2018), **track 7**, 5:49.
  - It was released on 10 August 2018 as the album's second single.
  - It was written and produced by Jon George, Tyrone Lindqvist and James Hunt.
  - It was nominated for Best Dance Recording at the 62nd Grammys. [Wikipedia][wp], [Spotify][sp]
- **Key and tempo:** **F♯ minor**, **118 BPM** in 4/4, so the felt pulse is also 118.
  - Tunebat and SongBPM both take their figures from Spotify's analysis, so they count as one source. Check by ear. [Tunebat][tb], [SongBPM][sb]
- **How it was made:**
  - "Underwater came from a patch that we found on the Prophet-6. An arpeggiated delayed part starts the entire song and quickly bursts into the entire track." [MusicTech 2021][mt]
  - "The very first thing is what you hear at the start, it's that arp … we were taking turns trying to put a delay on it, kind of like an echo, so it makes it hard to play in time." (James Hunt) [PAPER 2019][pp]
  - "That song in particular was a celebration of the Prophet … every different sound is a different iteration of what it does well, like the big bass hits." (Jon George) [PAPER 2019][pp]
  - *Solace*'s sound leaned on the Sequential Prophet-6, the OB-6 and the Minimoog Model D. [MusicTech][mt]
- **How it sounds:** "It opens with blinking, repetitive synth, murky as if coming through depths of blue. A chorus of ghostly voices lures you deeper." [Billboard 2018][bb]
- **Spotify search:** `Underwater RÜFÜS DU SOL`

## What we're matching
- **The blink:**
  - Held notes at C3 and above are arpeggiated on a **sixteenth-note grid at 118 BPM** (127.1 ms per step), in the order they were pressed.
  - Each step re-plucks the note. The gate shortens from 70% to 25% of a step as Blink rises.
- **The delay that makes it hard to play in time:**
  - A **dotted-eighth echo**: 0.75 × 60 / 118 = **381.4 ms**.
  - Each repeat is darker than the last, with a slow wow, ping-ponging across the stereo field.
- **Murk:**
  - The filter's ceiling falls from 7 kHz to 650 Hz, and a slow 0.06–0.15 Hz current sways it.
  - At Murk 1 the centroid is at most half its value at Murk 0.
- **Ghostly voices:**
  - A wordless "oo"/"oh" choir an octave above the held notes. It swells in over 1.2–2.5 s, is spread wide and sits deep in the reverb.
  - On a held triad, Ghosts 1 against 0 raises the 250–900 Hz energy by **≥ 6 dB**.
- **The big bass:**
  - Notes below C3 aren't arpeggiated. They are held voices with a strong sub, a more open filter and gentle drive.
  - They carry **≥ 6 dB** more energy below 120 Hz than the same note at Bass 0.
- **The voice:**
  - A saw-leaning pulse plus a saw detuned +6 cents, and a sub-octave, through a 4-pole ladder.
  - A fast filter envelope gives the pluck.
  - About ±3 cents of analogue "slop".
- **Tuning:** within 2 cents with the DRY hook, within 6 cents with slop. Fine tune and transpose are exact.
- **CPU:** < 6% for 8 held, arpeggiated notes with the echo and ghosts.

## What we'll do better
- **The arp follows your hands.** It plays the notes in the order you press them, at the record's tempo, with the pedal holding notes in.
- **The left hand is the bass.** Below C3 you get the song's big bass hits, held and not arpeggiated.
- **Lean in.** Pressure opens the filter and brings the ghost voices forward; the wheel bends everything ±2 semitones.
- **Every part is a dial:** Blink, Murk, Ghosts, Echo, Bass, Tempo, Space and Width.

## Play-along notes
- **Key:** F♯ minor, with Tempo at 118.
- Hold chords in the right hand and let the arp blink. Play long bass notes in the left. Let go and the echo rings on.
- **Tuning:** concert pitch, Fine tune 0. Try ±10 cents by ear if the record sits off 440.

## Preset starting values

| Preset | blink | murk | ghosts | echo | bass | tempo | space | width |
|---|---|---|---|---|---|---|---|---|
| Blue Depth | .60 | .55 | .40 | .50 | .55 | 118 | .55 | .60 |
| Ghost Signal | .35 | .45 | .75 | .65 | .30 | 118 | .70 | .70 |
| Pressure Hull | .75 | .80 | .25 | .40 | .80 | 118 | .45 | .50 |
| Surface Light | .50 | .25 | .35 | .55 | .40 | 118 | .50 | .65 |

[wp]: https://en.wikipedia.org/wiki/Underwater_(R%C3%BCf%C3%BCs_Du_Sol_song)
[sp]: https://open.spotify.com/track/5ZvHcR4OSwvEV5IhigbTOT
[tb]: https://tunebat.com/Info/Underwater-R-F-S-DU-SOL/5ZvHcR4OSwvEV5IhigbTOT
[sb]: https://songbpm.com/@rufus-du-sol/underwater
[mt]: https://musictech.com/features/interviews/rufus-du-sol-new-album-surrender-when-we-write-we-arent-thinking-about-a-specific-aesthetic-were-searching-for-a-feeling
[pp]: https://www.papermag.com/rufus-du-sol
[bb]: https://www.billboard.com/music/music-news/rufus-du-sol-underwater-8469613
