# In Strum Meants — Design Spec

**Date:** 2026-10-28
**Status:** Awaiting your review
**Owner:** Michael (personal use only, not for sale or distribution)

---

## 1. Purpose

A personal Mac app you play with a MIDI keyboard. It gives your favourite sounds gorgeous animated themes, makes them sound even better, and keeps working if the companies that sold you those sounds stop supporting them.

### Success looks like
1. You open the app, play your keyboard, and hear **Intimate Grand Piano exactly as it sounds in Splice**, with no added lag.
2. With the A/B button, you can hear that our Sound Shaping makes it **better** (your judgement, by ear).
3. The visuals react to every note, how hard you play, how long you hold, the pedal and chords, smoothly on your Mac.
4. If Splice or Spitfire ever disappear, the app still plays music using sounds you own outright (Phase 2).

### Your setup
- Intel Mac, macOS 13.7.4 (Ventura)
- Splice INSTRUMENT, Spitfire Audio and LABS installed
- A MIDI keyboard. A sustain pedal is **optional**: everything works without one (see 5.1)

### Ground rules
- The paid sample libraries are **never copied, extracted, converted or decrypted**. They are played in place, through their own plugins, inside our app. That is how the app "imports" them.
- Signature Sounds are **original patches inspired by** the reference songs. No song recordings are sampled.

---

## 2. Decisions made

| Decision | Choice |
|---|---|
| Overall approach | **Hybrid**: Phase 1 hosts your plugins; Phase 2 adds sounds you own forever |
| Technology | **Native Swift app**: AVAudioEngine (sound), SwiftUI + Metal (visuals) |
| Code home | **Private GitHub repository** on your account |
| How you get the app | GitHub builds it automatically; you download it from Releases |
| Target machine | Intel (x86_64), macOS 13.0 or newer |
| First instrument | Intimate Grand Piano (via Splice INSTRUMENT) |
| "Better" means | All five equally: tone, space, feel, experience, visuals |

---

## 3. How the app fits together

```
MIDI keyboard
     │
     ▼
┌─────────────┐
│ MIDI Input  │──────────────────────────────┐
└─────────────┘                              │
     │ notes, velocity, pedal                │ same events, same moment
     ▼                                       ▼
┌──────────────┐   ┌───────────────┐   ┌───────────────┐   ┌────────────────┐
│ Feel (touch  │──▶│ Sound Source  │──▶│ Sound Shaping │──▶│ Speakers /     │
│ curve, pedal)│   │ (plugin, synth│   │ (warmth → … → │   │ headphones     │
└──────────────┘   │  or samples)  │   │  limiter)     │   └────────────────┘
                   └───────────────┘   └──────┬────────┘
                                              │ audio level
                                              ▼
                                       ┌───────────────┐   ┌───────────────┐
                                       │ Visual Engine │◀──│ Theme Library │
                                       └───────────────┘   └───────────────┘
                     ┌──────────┐
                     │ Settings │  (remembers everything, autosaves)
                     └──────────┘
```

Each part has one job and talks to the others through a small, clear interface, so a theme can never break the sound and a new sound can never break a theme.

| Part | Job | Depends on |
|---|---|---|
| **MIDI Input** | Listens to any connected keyboard; turns messages into note/pedal events; sends them to sound and visuals simultaneously | macOS CoreMIDI |
| **Feel** | Reshapes velocity with a touch curve; handles half-pedalling | MIDI Input |
| **Sound Source** | Produces the raw sound. Three kinds: **Plugin Host**, **Synth Engine**, **Sample Player** | Feel |
| **Sound Shaping** | Our improvements chain (Section 5) | Sound Source |
| **Visual Engine** | Draws the keyboard and effects at 60fps using Metal | MIDI Input, audio level |
| **Theme Library** | Each theme is one self-contained module | Visual Engine |
| **Settings** | Remembers instrument, sound settings, themes, favourites; autosaves | everything |

---

## 4. Sound sources

### 4.1 Plugin Host (Phase 1)
- Scans the Mac for instrument plugins (Audio Units) and lists them: Splice INSTRUMENT, Spitfire, LABS, and any others.
- You choose one and open its own window **once** to pick a preset (e.g. Intimate Grand Piano). The app saves the plugin's state so it reopens ready to play.
- The plugin plays exactly as normal. Our app only feeds it notes and processes its output.
- If a plugin needs its company's login or licence, that is between you and the plugin; the app cannot change it.

### 4.2 Synth Engine (ours, owned forever)
Built from oscillators, filters and envelopes, with no recordings needed.

- **Basses:** Deep Sub, Warm Analogue, 808 (with glide), Reese, FM Electric, Rubber Funk, Acid, Soft Pluck.
- **Pads, keys and textures:** lush analogue pads, glassy bells, granular "breathing" textures, shimmer clouds, tape-warped keys, lo-fi dust and vinyl layers.

### 4.3 Sample Player (Phase 2)
- Plays piano and other instruments in the open **SFZ** format, which you can own outright (e.g. free/open grand and felt pianos, or your own recordings).
- Can also load **audio samples you have the right to use**: your own recordings, and royalty-free samples such as the ones in your Splice Sounds library (subject to Splice's licence terms).
- Becomes the automatic fallback if a plugin stops working.

### 4.4 Signature Packs (original sounds inspired by your favourite songs)
Each pack is researched (how the originals were produced), built as original patches and Sound Shaping presets, then refined by your ear against the song.

| Pack | Inspired by | Expected ingredients |
|---|---|---|
| **1. Bloom** | Rüfüs Du Sol: *Innerbloom* (intro) | Slow-blooming hypnotic synth, evolving soundscape |
| **2. Circles & Swimming** | Mac Miller: *Everybody, Dunno, Objects in the Mirror, Come Back to Earth, Hurt Feelings, Self Care, Wings, Small Worlds, Jet Fuel, So It Goes, Stay, Skin, Cinderella, We, Perfect Circle / Godspeed, ROS, I'm Not Real* | Worn characterful pianos, Rhodes-style keys, round warm basses, soft pads, lo-fi tape |
| **3. Dark & Grand** | Kanye West: *Runaway, Hold My Liquor, FADE, Saint Pablo* | Sparse dramatic piano, dark distorted synths, heavy low end, gospel-tinged keys |
| **4. Lana** | Lana Del Rey, four eras (below) | Era-specific |
| **5. Night Shift** | Wombat: *Gassed Up, Bad Words, 5am in Glenorchy* (title to confirm) | Grimy basses, eerie synths (to research) |

**Pack 4: Lana eras**
- *Born to Die / Paradise:* Video Games, Off to the Races, Diet Mountain Dew, Summertime Sadness, This Is What Makes Us Girls, Ride, Cola, Young and Beautiful. Cinematic strings, harps, moody hip-hop drums.
- *Ultraviolence:* West Coast, Brooklyn Baby, Florida Kilos. Hazy psychedelic guitars, drowsy grooves.
- *Honeymoon:* Honeymoon, Music to Watch Boys To, High by the Beach, Freak, Art Deco, Religion, Salvatore. Noir strings, jazzy/dreamy, dark trap undertones.
- *Later:* Cherry, The Greatest, Happiness Is a Butterfly, Dealer, Taco Truck x VB. Soft '70s pianos, Laurel Canyon keys, haunting textures.

Real guitar, strings and horns in these songs come from your **Spitfire/LABS instruments** running in the app, with Pack-specific Sound Shaping on top. Synths, basses and piano characters come from our own engine.

---

## 5. Sound Shaping (how the sound gets better)

Order of the chain:

1. **Feel** (before the instrument): touch curve (Soft / Natural / Firm / custom); half-pedalling if the pedal supports it.
2. **Sound Source** (e.g. the real Intimate Grand Piano).
3. **Warmth:** subtle tape-style saturation.
4. **Tone:** three controls: **Body** (low warmth), **Presence** (clarity), **Air** (sparkle).
5. **Glue:** gentle compressor for a close, intimate feel.
6. **Space:** convolution reverb using freely licensed recordings of real spaces: Intimate Room, Studio, Concert Hall, Cathedral, Dreamy Shimmer.
7. **Width:** stereo widening.
8. **Safety limiter:** nothing ever distorts or blasts your ears.

**Presets:** Original (everything bypassed, exact Splice sound), Intimate+, Concert, Dreamy. Signature Packs add their own.

**A/B button:** one press flips between Original and the shaped sound, at matched loudness so "louder" isn't mistaken for "better".

### 5.1 Playing without a pedal
The app never requires a sustain pedal. For minimal setups:
- **Auto-Sustain toggle:** notes ring on naturally after release, with an adjustable length.
- **Latch option:** sustain can be toggled by a keyboard button, pad, the on-screen button, or the Mac's space bar.
- **Visual fallback:** without a pedal, themes use note length and release instead, so effects still linger beautifully.
- Ear tests skip pedal questions when no pedal is connected.

**Tip shown in-app:** when using our Space, turn the plugin's own reverb down to avoid doubling.

---

## 6. Visual Engine & themes

### 6.1 What visuals react to (all enabled)
- Which key (position and pitch)
- How hard (soft = gentle glow, hard = burst)
- How long (held notes keep glowing / ringing / blooming)
- Sustain pedal (effects linger and trail)
- Chords (simultaneous notes trigger a combined effect)
- Intensity (fast playing builds energy across the scene)
- The sound itself (backgrounds pulse with the actual audio)

### 6.2 Theme structure
Every theme has three layers: **background world**, **keyboard**, **effects**. Each theme is one self-contained module; adding one never affects another.

### 6.3 Features
- Theme gallery with favourites and shuffle
- Full-screen performance mode
- Auto-match: a sound can suggest a theme (e.g. Lana → Art Deco)
- **Lite** switch reduces effects if anything stutters

### 6.4 First release themes
1. **Midnight Steinway** (built first): glossy black, warm spotlight on pressed keys
2. **Moonlit Lake:** each note ripples the water
3. **Velvet Theatre:** curtains part, stage light follows the melody
4. **Golden Hour:** sun rays rise from played keys
5. **Butterfly Garden:** butterflies launch from keys
6. **Fireworks Finale:** velocity sets explosion size
7. **Galaxy Warp:** stars streak with playing intensity

The remaining ideas from the 52-theme list are the backlog, built in later batches.

### 6.5 Performance rule
Visuals run separately from audio. A slow frame can never delay or glitch a note.

---

## 7. Reliability

| Situation | Behaviour |
|---|---|
| No keyboard connected | On-screen keyboard appears (mouse or Mac keyboard) |
| Keyboard unplugged | All notes stop instantly (no stuck notes); auto-reconnects |
| Plugin crashes or won't load | Settings are already autosaved; next launch offers **Safe Mode** (starts without plugins) |
| Splice logs out / stops working | Clear message; falls back to built-in piano (once Phase 2 exists) |
| Audio output changes | Sound follows to the new headphones/speakers |
| Anything goes wrong | **Panic button** silences everything |

---

## 8. Testing

**Automatic (every build, on GitHub):**
- MIDI messages are turned into the right events (notes, velocity, pedal, all-notes-off)
- The Sound Shaping chain never clips (limiter test with loud input)
- Bypass ("Original") passes sound through unchanged
- Themes keep up with a heavy burst of notes

**Your ear tests (checklist each round):**
1. Does it feel instant when you press a key?
2. Do soft and hard playing feel right?
3. Does the pedal behave naturally?
4. A/B: is the shaped sound better than Original?
5. Do the visuals land exactly with the notes?

**Optional reference recording:** a 30–60 second clip of you playing Intimate Grand Piano (soft notes, loud notes, pedalled chord, fast run) lets me measure dynamics, ring time and tone to set targets.

---

## 9. Delivery

1. Code lives in a **private GitHub repo** on your account.
2. Every update triggers an automatic Mac build (Intel, macOS 13+).
3. You download the app from the repo's **Releases** page.
4. First launch: right-click → **Open** (it's unsigned, for personal use).
5. **Previous versions are kept**, so you can always go back.

**Protecting your purchases:** keep copies of your Spitfire/Splice installers and downloaded libraries on an external drive, and hold off on macOS or plugin updates until the app is confirmed working with them.

---

## 10. Build order (milestones)

| # | Milestone | You can… |
|---|---|---|
| 1 | Foundation + MIDI + Plugin Host + Midnight Steinway | Play the real Intimate Grand Piano in our app |
| 2 | Sound Shaping + presets + A/B | Hear it improved and compare |
| 3 | Remaining 6 first-release themes | Switch between all 7 themes |
| 4 | Signature piano characters (Circles, Mirror, Runaway-style) | Play your piano in those worlds |
| 5 | Synth Engine + basses | Play our own basses and pads |
| 6 | Signature Packs (Bloom, Circles & Swimming, Dark & Grand, Lana, Night Shift) | Play the inspired sounds |
| 7 | Sample Player (Phase 2) + automatic fallback | Keep playing even without Splice |
| 8+ | More themes from the backlog, in batches | — |

**Model guide:** Milestones 1, 2, 5 and 7 → Opus. Milestones 3, 6 and 8+ (themes and patch batches) → Sonnet. A clearly marked reminder will appear at each switch point.

---

## 11. Out of scope

- Extracting, converting or copying protected sample libraries
- Sampling or reproducing recordings of the reference songs
- App Store release, code signing, or sharing with others
- Windows or iPad versions
- Recording/DAW features (multitrack, editing). Could be a future idea.
