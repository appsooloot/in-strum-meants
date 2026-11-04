#include "BlueDepth.hpp"
#include "include/InStrumDSP.h"
#include <algorithm>

namespace isd {

namespace {

// Level and tone calibration (see docs/superpowers/briefs/blue-depth.md).
constexpr float kVoiceGain = 0.60f;       // a voice's level at velocity 127, before the master
constexpr float kMaster = 0.62f;          // one loudness with the other built-ins (a chord within 3 dB of Felt Glass)
constexpr float kWetMax = 0.55f;          // the reverb's return at full Space
constexpr float kOscMix = 0.42f;          // the oscillators' sum into the ladder (peaks near 1, so the tanh stays soft)
constexpr float kShapeA = 0.35f;          // oscillator A: a saw-leaning pulse
constexpr float kDetuneCents = 6.f;       // oscillator B sits this far above A; the pair is centred on the note
constexpr float kSubGain = 0.3162f;       // the sub at −10 dB…
constexpr float kBassSubGain = 0.7943f;   // …and −2 dB in a bass voice at Bass 1
constexpr float kNoiseGain = 0.0251f;     // noise at −32 dB
constexpr float kResonance = 0.3f;
constexpr float kKeyTrack = 0.5f;
constexpr float kEnvOctaves = 2.5f;       // the filter envelope's reach above the resting cutoff
constexpr float kAttack = 0.002f, kSustain = 0.15f, kRelease = 0.26f;
constexpr float kFilterAttack = 0.0005f;   // the filter opens almost at once, as a pluck's does
constexpr float kBassSustain = 0.55f;     // a bass voice holds (at Bass 1)
constexpr float kBassLevel = 1.6f;        // and is louder (at Bass 1)
constexpr float kBassFilterDecay = 0.45f;
constexpr float kCeilingOpen = 7000.f, kCeilingMurky = 650.f;
constexpr float kCurrentDepth = 0.18f;    // the slow current sways the ceiling ±18%
constexpr float kDampOpen = 4000.f, kDampMurky = 1200.f;
constexpr float kEchoLoopOpen = 2600.f, kEchoLoopMurky = 1200.f;
constexpr float kWowHz = 0.25f, kWowSeconds = 0.003f;
constexpr float kPressureOctaves = 0.8f;
constexpr float kGhostShape = 0.6f;       // the ghosts' soft pulse
constexpr float kGhostBreath = 0.25f;     // 25% breath noise
constexpr float kGhostDirect = 0.25f;     // the share of the ghosts' source that skips the formants
constexpr float kGhostNorm = 0.585f;      // so a swelled ghost layer sits at −16…−4 dB against the pluck's attack
constexpr float kGhostDry = 0.8f, kGhostSend = 2.4f;    // the ghosts sit mostly in the reverb (3× as wet as dry)
constexpr float kGhostReleaseT60 = 2.5f;
constexpr float kBassSend = 0.5f;         // the bass reaches the reverb lightly and never the echo
constexpr float kPhraseGap = 2.f;         // seconds with nothing held before the arp's clock resets
constexpr float kPanicFade = 0.02f;
const float kAccent[4] = {1.0f, 0.82f, 0.9f, 0.82f};
const float kOo[2] = {325.f, 700.f}, kOh[2] = {450.f, 800.f};

inline float midiHz(float m) { return 440.f * std::exp2((m - 69.f) / 12.f); }
inline float dbGain(float db) { return std::exp2(db * 0.16609640f); }
inline float lerp(float a, float b, float t) { return a + (b - a) * t; }
inline float logLerp(float a, float b, float t) { return a * std::exp2(t * std::log2(b / a)); }
inline float velocityGain(int velocity) { return std::pow(0.35f + 0.65f * (float)std::clamp(velocity, 1, 127) / 127.f, 1.3f); }

/// A 4-point Hermite read of the sample written `d` (≥ 2) samples before position `w` (where the next write goes).
inline float readHermite(const float *b, int len, int w, float d) {
    const float whole = std::floor(d), t = d - whole;
    int i0 = w - (int)whole; if (i0 < 0) i0 += len;
    int im1 = i0 + 1; if (im1 >= len) im1 -= len;
    int i1 = i0 - 1; if (i1 < 0) i1 += len;
    int i2 = i1 - 1; if (i2 < 0) i2 += len;
    const float xm1 = b[im1], x0 = b[i0], x1 = b[i1], x2 = b[i2];
    const float c1 = 0.5f * (x1 - xm1), c2 = xm1 - 2.5f * x0 + 2.f * x1 - 0.5f * x2, c3 = 0.5f * (x2 - xm1) + 1.5f * (x0 - x1);
    return ((c3 * t + c2) * t + c1) * t + x0;
}

} // namespace

// ---------- The echo ----------

void BlueDepth::Echo::prepare(double sampleRate, float maxSeconds) {
    sr = sampleRate;
    // The slowest tempo's dotted eighth, the wow's swing and the interpolation's reach, at this sample rate.
    len = (int)std::ceil(((double)maxSeconds + kWowSeconds + 0.002) * sr) + 8;
    for (auto &b : buf) b.assign((size_t)len, 0.f);
    w = 0;
    hpA = (float)std::exp(-2.0 * M_PI * 110.0 / sr);
    lpA = (float)std::exp(-2.0 * M_PI * kEchoLoopOpen / sr);
}

void BlueDepth::Echo::clear() {
    for (auto &b : buf) std::fill(b.begin(), b.end(), 0.f);
    for (int c = 0; c < 2; ++c) lp[c] = hpX[c] = hpY[c] = 0.f;
    awake = false;
    quiet = 0;
}

void BlueDepth::Echo::beginEmpty() {
    if (!awake) return;   // asleep: the line is already silent (it was cleared as it fell asleep)
    emptying = true;
    fadeStep = 1.f / std::max(1.f, kPanicFade * (float)sr);
}

void BlueDepth::Echo::process(const float *inL, const float *inR, float *outL, float *outR, int n) {
    float inPeak = 0.f;
    int first = -1;
    for (int t = 0; t < n; ++t) {
        const float a = std::max(std::fabs(inL[t]), std::fabs(inR[t]));
        if (a > 1e-6f && first < 0) first = t;
        inPeak = std::max(inPeak, a);
    }
    if (!awake && !emptying) {
        if (first < 0) {
            std::fill(outL, outL + n, 0.f);
            std::fill(outR, outR + n, 0.f);
            from = delay;
            return;
        }
        // Waking from silence: the wow is phased so this phrase's first repeat lands exactly on the dotted eighth.
        awake = true;
        quiet = 0;
        from = delay;
        const double ph = -(double)kWowHz * ((double)first + (double)delay) / sr;
        wowPhase = ph - std::floor(ph);
    }
    const float fsr = (float)sr;
    const float glide = 1.f - std::exp(-(float)n / (0.08f * fsr));
    const float d0 = from, d1 = from + (delay - from) * glide, dd = (d1 - d0) / (float)n;
    from = d1;
    const float depth = kWowSeconds * fsr, wowStep = kWowHz / fsr;
    const float cross = clamp01(width), keep = 1.f - cross;
    float *bl = buf[0].data(), *br = buf[1].data();
    float outPeak = 0.f;
    for (int t = 0; t < n; ++t) {
        float gain = 1.f;
        if (emptying) { fade = std::max(0.f, fade - fadeStep); gain = fade; }
        const float d = std::max(2.f, d0 + dd * (float)(t + 1) + depth * std::sin(kTwoPi * (float)wowPhase));
        wowPhase += wowStep;
        if (wowPhase >= 1.0) wowPhase -= 1.0;
        const float rl = readHermite(bl, len, w, d), rr = readHermite(br, len, w, d);
        // Width crosses each line's repeats into the other side (ping-pong); at 0 each side echoes itself.
        const float fl = keep * rl + cross * rr, fr = keep * rr + cross * rl;
        const float mono = 0.5f * (inL[t] + inR[t]);
        const float xl = (keep * inL[t] + cross * mono) * gain, xr = keep * inR[t] * gain;
        const float x[2] = {xl + feedback * fl, xr + feedback * fr};
        float wr[2];
        for (int c = 0; c < 2; ++c) {
            // Each pass is darker (the one-pole) and loses a little low end (so repeats never build up mud).
            lp[c] = x[c] + (lp[c] - x[c]) * lpA;
            const float hp = hpA * (hpY[c] + lp[c] - hpX[c]);
            hpX[c] = lp[c]; hpY[c] = hp;
            wr[c] = hp;
        }
        bl[w] = wr[0]; br[w] = wr[1];
        if (++w == len) w = 0;
        outL[t] = rl * gain;
        outR[t] = rr * gain;
        outPeak = std::max(outPeak, std::max(std::fabs(rl), std::fabs(rr)));
    }
    if (emptying && fade <= 0.f) { clear(); emptying = false; fade = 1.f; return; }
    if (inPeak < 1e-6f && outPeak < 1e-6f) {
        quiet += n;
        if (quiet > len) { clear(); }   // everything in the line has been heard: asleep until the next sound
    } else {
        quiet = 0;
    }
}

// ---------- The engine ----------

BlueDepth::BlueDepth(double sampleRate)
    : sr(sampleRate), rng(0xB1DE7E9DULL), noise(0x6E05E0F1ULL), reverb(sampleRate, kSub) {
    limiter.init(sr);
    fine.init(sr); blink.init(sr); murk.init(sr); ghosts.init(sr); echoAmt.init(sr); bass.init(sr); space.init(sr);
    width.init(sr); wet.init(sr);
    fine.snap(0); blink.snap(0.60f); murk.snap(0.55f); ghosts.snap(0.40f); echoAmt.snap(0.50f); bass.snap(0.55f);
    space.snap(0.55f); width.snap(0.60f); wet.snap(0);
    echo.prepare(sr, echoSeconds(kSlowestTempo));
    echo.delay = echo.from = echoSeconds(tempo) * (float)sr;
}

bool BlueDepth::arpEnabled() const { return !noArp && blink.target > 1e-3f; }

void BlueDepth::setParam(int address, float value, bool snap) {
    auto set = [&](Smoothed &s) { if (snap) s.snap(value); else s.setTarget(value); };
    switch (address) {
    case ISD_P_FINE_TUNE: set(fine); break;
    case ISD_P_TRANSPOSE: pTranspose = value; break;
    case ISD_P_BLINK: set(blink); break;
    case ISD_P_MURK: set(murk); break;
    case ISD_P_GHOSTS: set(ghosts); break;
    case ISD_P_ECHO: set(echoAmt); break;
    case ISD_P_BASS: set(bass); break;
    case ISD_P_TEMPO:
        tempo = std::clamp(value, kSlowestTempo, 160.f);
        echo.delay = echoSeconds(tempo) * (float)sr;
        if (snap) echo.from = echo.delay;
        break;
    case ISD_P_SPACE: set(space); break;
    case ISD_P_WIDTH: set(width); break;
    case ISD_P_MOOD_ENERGY: mEnergy = value; break;
    case ISD_P_MOOD_WARMTH: mWarmth = value; break;
    case ISD_P_MOOD_BRIGHTNESS: mBright = value; break;
    case ISD_P_MOOD_SPACE: mSpace = value; break;
    case ISD_P_MOOD_MOTION: mMotion = value; break;
    case ISD_P_DEBUG_NO_ARP: noArp = value >= 0.5f; break;
    case ISD_P_DEBUG_DRY: dryHook = value >= 0.5f; break;
    default: break;
    }
}

int BlueDepth::activeVoices() const {
    int n = 0;
    for (const auto &v : voices) if (v.active) ++n;
    return n;
}

float BlueDepth::level(const Voice &v) const {
    return std::max(v.amp.level * kVoiceGain, v.ghostEnv * v.ghostVel * ghostGain * kVoiceGain);
}

BlueDepth::Voice *BlueDepth::voiceFor(int note) {
    Voice *found = nullptr;
    for (auto &v : voices) {
        if (!v.active || v.fading || v.note != note) continue;
        if (!found || (v.held() && !found->held()) || (v.held() == found->held() && v.age > found->age)) found = &v;
    }
    return found;
}

BlueDepth::Voice &BlueDepth::allocate() {
    int sounding = 0;
    Voice *victim = nullptr;
    for (auto &v : voices) {
        if (!v.active || v.fading) continue;
        ++sounding;
        // Voices nobody holds go first (quietest first); otherwise the oldest held note.
        if (!victim) { victim = &v; continue; }
        if (v.held() != victim->held()) { if (!v.held()) victim = &v; continue; }
        if (!v.held() ? level(v) < level(*victim) : v.age < victim->age) victim = &v;
    }
    if (sounding >= kPolyphony && victim) beginFade(*victim);
    for (auto &v : voices) if (!v.active) return v;
    Voice *best = nullptr;
    for (auto &v : voices) if (v.fading && (!best || v.fadeGain < best->fadeGain)) best = &v;
    if (!best) best = &voices[0];
    best->active = false;
    return *best;
}

void BlueDepth::beginFade(Voice &v) {
    if (v.fading) return;
    v.fading = true;
    v.fadeStep = 1.f / (kPanicFade * (float)sr);
}

void BlueDepth::startVoice(Voice &v, int note, int velocity, bool bassVoice) {
    const float fsr = (float)sr;
    v = Voice{};
    v.active = true;
    v.keyDown = true;
    v.note = note;
    v.age = ++noteCounter;
    v.bass = bassVoice;
    v.ghost = note >= kSplit;
    v.pitch = std::clamp((float)note + pTranspose, 0.f, 127.f);
    v.gain = velocityGain(velocity);
    v.ghostVel = v.gain;
    // Each note its own place across the field (Width scales it live); its ghost sings from the other side.
    const float place = (float)((note * 7) % 12) / 5.5f - 1.f;
    v.pan = place;
    v.ghostPan = place >= 0.f ? -1.f : 1.f;
    // Free-running oscillators, the detuned pair centred on the note (power-weighted at the fundamental).
    v.oscA.setShape(kShapeA);
    v.oscA.reset(rng.uniform());
    v.oscB.reset(rng.uniform());
    const float gA = analog::ShapeOsc::fundamentalGain(kShapeA), gA2 = gA * gA;
    const float centre = kDetuneCents / (gA2 + 1.f);
    v.detuneA = -centre;
    v.detuneB = kDetuneCents - centre;
    voiceSeed += 0x9E3779B97F4A7C15ULL;
    v.slop.seed(voiceSeed);
    const float f0 = midiHz(v.pitch);
    v.keyTrack = analog::keyTrack(f0, kKeyTrack);
    v.ladder.setResonance(kResonance);
    v.ladder.snapCutoff(ceiling * v.keyTrack * std::exp2(-kEnvOctaves), fsr);
    // The high-pass clears rumble under the sub (a bass voice keeps everything down to 18 Hz).
    v.hpHz = bassVoice ? 18.f : std::max(18.f, 0.35f * f0);
    v.highPass.set(v.hpHz, 0.7071f, fsr);
    v.amp.setAttack(kAttack, fsr);
    v.amp.setRelease(kRelease, fsr);
    v.filter.setAttack(kFilterAttack, fsr);
    v.filter.setSustain(0.f);
    v.filter.setRelease(kRelease, fsr);
    // The ghost.
    v.ghostOsc.setShape(kGhostShape);
    v.ghostOsc.reset(rng.uniform());
    v.vowelPhase = rng.uniform();
    v.vowelRate = 0.05f + 0.07f * rng.uniform();
    // More ghosts arrive sooner: a 2.5 s swell at the bottom of the dial, 1.2 s at the top (±10% per voice).
    v.ghostSwell = std::clamp(lerp(2.5f, 1.2f, clamp01(ghosts.target)) * (0.9f + 0.2f * rng.uniform()), 1.2f, 2.5f);
    v.formant.q = 4.f;
    v.formant.setGains(1.f, -0.35f);
    v.formant.reset(kOo[0], kOo[1]);
    v.pressure = std::max(channelPressure, polyPressure[note]);
    idle = false;
    idleSamples = 0;
}

/// Plucks a voice from wherever it is now: the amp to `peak`, the filter envelope to the top of its reach.
void BlueDepth::strike(Voice &v, float peak) {
    const float fsr = (float)sr;
    // Lower notes decay longer (amp 500 → 220 ms, filter 320 → 140 ms from C2 to C7); energy shortens both.
    // (From the dials themselves: a note can arrive before the first block has run.)
    const float keyPos = clamp01(((float)v.note - 36.f) / 60.f);
    const float b = v.bass ? clamp01(bass.value) : 0.f, pace = 1.25f - 0.5f * clamp01(mEnergy);
    v.amp.setDecay(lerp(0.5f, 0.22f, keyPos) * pace, fsr);
    v.amp.setSustain(lerp(kSustain, kBassSustain, b));
    v.filter.setDecay(lerp(lerp(0.32f, 0.14f, keyPos) * pace, kBassFilterDecay, b), fsr);
    v.amp.trigger(peak);
    v.filter.trigger(1.f);
    idle = false;
    idleSamples = 0;
}

void BlueDepth::releaseGate(Voice &v) {
    v.amp.release();
    v.filter.release();
}

/// The key and the pedal have both let go of a voice.
void BlueDepth::letGo(Voice &v) {
    v.keyDown = false;
    v.sustained = false;
    if (!v.bass) arpRemove(v.note);
    // A note the arp is playing finishes its step; any other lets its gate go now.
    const bool inStep = gateVoice == indexOf(v) && gateAge == v.age;
    if (!inStep) releaseGate(v);
}

void BlueDepth::noteOn(int note, int velocity) {
    if (velocity <= 0) { noteOff(note); return; }
    note &= 127;
    noteVelocity[note] = velocity;
    noteDown[note] = true;
    const bool isBass = note < kSplit && bass.target > 0.005f;
    Voice *v = voiceFor(note);
    if (v && v->bass != isBass) { beginFade(*v); v = nullptr; }
    if (!v) {
        v = &allocate();
        startVoice(*v, note, velocity, isBass);
    } else {
        // The same key again: its voice carries on from where it is (the ghost swells again from its level).
        v->keyDown = true;
        v->sustained = false;
        v->gain = velocityGain(velocity);
        v->ghostX = std::acos(std::clamp(1.f - 2.f * v->ghostEnv, -1.f, 1.f)) / kPi;
    }
    // Every note from C3 up (all of them at Bass 0) joins the arp's order, even at Blink 0, so turning Blink up
    // sets a held chord blinking. With the arp off (or a bass note) the key strikes at once; otherwise it waits
    // for its step.
    if (isBass) arpRemove(note);   // a bass voice never blinks (even one the pedal held in the order at Bass 0)
    else arpInsert(note);
    if (isBass || !arpEnabled()) strike(*v, v->gain);
    idle = false;
    idleSamples = 0;
}

void BlueDepth::noteOff(int note) {
    note &= 127;
    noteDown[note] = false;
    // The arp's order follows the keys, not the voices (a note whose voice was stolen still leaves it).
    if (!sustain) arpRemove(note);
    for (auto &v : voices) {
        if (!v.active || v.fading || v.note != note || !v.keyDown) continue;
        if (sustain) { v.keyDown = false; v.sustained = true; }
        else letGo(v);
    }
}

void BlueDepth::setSustain(bool down) {
    if (down == sustain) return;
    sustain = down;
    if (!down) {
        for (int i = arpCount - 1; i >= 0; --i) if (!noteDown[arpNotes[i]]) arpRemove(arpNotes[i]);
        for (auto &v : voices) if (v.active && !v.fading && v.sustained && !v.keyDown) letGo(v);
    }
}

void BlueDepth::pitchBend(float semitones) { bendTarget = std::clamp(semitones, -2.f, 2.f); }

void BlueDepth::aftertouch(int note, float pressure) {
    const float p = clamp01(pressure);
    if (note < 0) channelPressure = p; else polyPressure[note & 127] = p;
}

void BlueDepth::resetTouch() {
    bendTarget = bendMid = bendNow = 0.f;
    channelPressure = 0.f;
    for (auto &p : polyPressure) p = 0.f;
}

void BlueDepth::stopArp() {
    arpCount = 0;
    groupStart = 0;
    lastIndex = -1;
    stepCount = 0;
    clockRunning = false;
    gateVoice = -1;
}

void BlueDepth::allNotesOff() {
    for (auto &v : voices) if (v.active) beginFade(v);
    stopArp();
    for (auto &d : noteDown) d = false;
    echo.beginEmpty();
    resetTouch();
}

void BlueDepth::allSoundOff() {
    allNotesOff();
    reverbEmptying = true;
    reverbFadeStep = 1.f / (kPanicFade * (float)sr);
}

// ---------- The arp ----------

void BlueDepth::arpInsert(int note) {
    for (int i = 0; i < arpCount; ++i) if (arpNotes[i] == note) return;   // already in (held by the pedal)
    if (arpCount >= 128) return;
    const int64_t window = (int64_t)std::llround(0.03 * sr);
    int at = arpCount;
    if (groupStart < arpCount && clock - groupLatest <= window) {
        // Within 30 ms of the last press: into the trailing group, low to high.
        at = groupStart;
        while (at < arpCount && arpNotes[at] < note) ++at;
    } else {
        groupStart = arpCount;
    }
    for (int i = arpCount; i > at; --i) arpNotes[i] = arpNotes[i - 1];
    arpNotes[at] = note;
    ++arpCount;
    groupLatest = clock;
    if (lastIndex >= at) ++lastIndex;   // the note that played last keeps its place, so the order runs on from it
}

void BlueDepth::arpRemove(int note) {
    int i = 0;
    while (i < arpCount && arpNotes[i] != note) ++i;
    if (i == arpCount) return;
    for (int j = i; j < arpCount - 1; ++j) arpNotes[j] = arpNotes[j + 1];
    --arpCount;
    if (i < groupStart) --groupStart;
    if (i <= lastIndex) --lastIndex;   // the next step plays the note that followed it
}

void BlueDepth::arpStep(double stepLength) {
    const int index = (lastIndex + 1) % arpCount;
    const int note = arpNotes[index];
    Voice *v = voiceFor(note);
    if (!v) {   // its voice was stolen: the arp takes another
        v = &allocate();
        startVoice(*v, note, noteVelocity[note], false);
        v->keyDown = noteDown[note];
        v->sustained = !noteDown[note];
    }
    // A lighter gate as Blink rises (70% → 25% of a step), shorter still with energy; the accents keep the beat.
    const float gate = std::clamp((0.70f - 0.45f * clamp01(blink.value)) * (1.2f - 0.4f * clamp01(mEnergy)), 0.1f, 0.85f);
    strike(*v, kAccent[stepCount & 3] * velocityGain(noteVelocity[note]));
    gateVoice = indexOf(*v);
    gateAge = v->age;
    gateOffAt = clock + std::max<int64_t>(1, (int64_t)std::llround(gate * stepLength));
    lastIndex = index;
    ++stepCount;
    lastPlayed = clock;
}

void BlueDepth::arpTick() {
    // The step lets its note go at the end of its gate.
    if (gateVoice >= 0 && clock >= gateOffAt) {
        Voice &v = voices[gateVoice];
        if (v.active && !v.fading && v.age == gateAge) releaseGate(v);
        gateVoice = -1;
    }
    const bool playable = arpEnabled() && arpCount > 0;
    if (!clockRunning) {
        if (!playable) return;
        // A phrase begins: the grid starts on this sample, from the first note in the order.
        clockRunning = true;
        nextStep = (double)clock;
        stepCount = 0;
        lastIndex = -1;
    }
    if ((double)clock < nextStep - 0.5) return;
    const double length = (double)stepSeconds(tempo) * sr;
    if (playable) {
        arpStep(length);
    } else if ((double)(clock - lastPlayed) >= (double)kPhraseGap * sr) {
        clockRunning = false;   // nothing held for 2 s: the next note starts a fresh grid
        return;
    }
    nextStep += length;
    while (nextStep < (double)clock + 0.5) nextStep += length;
}

int BlueDepth::samplesToNextArpEvent() const {
    int64_t n = kSub;
    if (clockRunning) n = std::min<int64_t>(n, (int64_t)std::floor(nextStep + 0.5) - clock);
    if (gateVoice >= 0) n = std::min<int64_t>(n, gateOffAt - clock);
    return (int)std::max<int64_t>(1, n);
}

// ---------- Rendering ----------

void BlueDepth::render(float *left, float *right, int frames) {
    int pos = 0;
    while (pos < frames) {
        arpTick();
        const int n = std::min(frames - pos, samplesToNextArpEvent());
        processBlock(left + pos, right + pos, n);
        pos += n;
        clock += n;
    }
}

void BlueDepth::renderVoice(Voice &v, float *pluckL, float *pluckR, float *bassL, float *bassR, float *ghostL, float *ghostR, int n) {
    const float fsr = (float)sr, dt = (float)n / fsr;
    // Pressure glides over about 25 ms.
    const float pTarget = std::max(channelPressure, polyPressure[v.note]);
    v.pressure += (1.f - std::exp(-(float)n / (0.025f * fsr))) * (pTarget - v.pressure);
    // Pitch: the note, fine tune and the wheel; each oscillator its own detune and slop.
    v.slop.advance(dt);
    const float f0 = midiHz(v.pitch + bendNow + 0.01f * fine.value);
    const float incA = std::min(analog::kMaxIncrement, f0 * std::exp2((v.detuneA + v.slop.pitchCents(0, slopDepth)) / 1200.f) / fsr);
    const float incB = std::min(analog::kMaxIncrement, f0 * std::exp2((v.detuneB + v.slop.pitchCents(1, slopDepth)) / 1200.f) / fsr);
    const float fade0 = v.fadeGain;
    const float w = clamp01(width.value);

    if (!v.amp.idle()) {
        // The filter envelope across this block; where it ends sets the cutoff the ladder glides to.
        float fenv = v.filter.level;
        for (int t = 0; t < n; ++t) fenv = v.filter.next();
        const float b = v.bass ? bassNow : 0.f;
        const float octaves = kEnvOctaves * (fenv - 1.f) + b + kPressureOctaves * v.pressure;
        v.ladder.setCutoff(ceiling * v.keyTrack * std::exp2(octaves) * v.slop.cutoffRatio(slopDepth), fsr, n);
        const float subG = (v.bass ? lerp(kSubGain, kBassSubGain, b) : kSubGain) * subBoost;
        const float drive = v.bass ? 1.f + 0.5f * b : 0.f;
        const float g = kVoiceGain * (v.bass ? lerp(1.f, kBassLevel, b) : 1.f);
        const float p = std::clamp(0.7f * w * v.pan, -1.f, 1.f), th = (p + 1.f) * kPi / 4.f;
        const float gl = std::cos(th) * g, gr = std::sin(th) * g;
        float *outL = v.bass ? bassL : pluckL, *outR = v.bass ? bassR : pluckR;
        float fade = fade0;
        for (int t = 0; t < n; ++t) {
            float x = v.oscA.nextWithSub(incA) + v.oscB.next(incB) + subG * v.oscA.sub + kNoiseGain * noise.next();
            x *= kOscMix;
            if (drive > 0.f) x = analog::tanhApprox(drive * x);
            float y = v.highPass.process(v.ladder.process(x)) * v.amp.next();
            if (v.fading) { y *= fade; fade = std::max(0.f, fade - v.fadeStep); }
            outL[t] += y * gl;
            outR[t] += y * gr;
        }
        if (v.amp.idle()) { v.ladder.reset(); v.highPass.reset(); }
    } else {
        v.oscA.skip(n, incA);
        v.oscB.skip(n, incB);
        if (v.filter.level > 0.f) v.filter.clear();
    }

    // The ghost: swells in while the note is held, fades slowly once it is let go.
    if (v.ghost) {
        const float start = v.ghostEnv;
        float target;
        if (v.held()) {
            v.ghostX = std::min(1.f, v.ghostX + dt / v.ghostSwell);
            target = 0.5f - 0.5f * std::cos(kPi * v.ghostX);
        } else {
            target = start * std::exp(-6.9077553f * dt / kGhostReleaseT60);
            if (target < 1e-6f) target = 0.f;
        }
        const float gG = ghostGain * v.ghostVel * (1.f + v.pressure) * kVoiceGain;
        if (gG > 0.f && (start > 1e-6f || target > 1e-6f)) {
            const float incG = std::min(analog::kMaxIncrement, 2.f * f0 / fsr);
            v.vowelPhase += v.vowelRate * dt;
            if (v.vowelPhase >= 1.f) v.vowelPhase -= 1.f;
            const float pos = 0.5f - 0.5f * std::cos(kTwoPi * v.vowelPhase);
            v.formant.setTargets(logLerp(kOo[0], kOh[0], pos) * ghostDrift, logLerp(kOo[1], kOh[1], pos) * ghostDrift);
            v.formant.update(1.f - std::exp(-dt / 0.15f), fsr);
            // The softened source reaches the output through the formants and, a little, directly (so a ghost
            // above both formants, where their skirts cancel, still sings). Each ghost is levelled by that sum's
            // gain at its own fundamental (at most +15 dB), so every note sings as clearly as one on a formant.
            const float softA = std::exp(-kTwoPi * std::min(2500.f, 0.45f * fsr) / fsr);
            float re, im;
            v.formant.response(2.f * f0, re, im);
            {   // the one-pole's response, (1 − a) / (1 − a·e^(−jω)), into the direct path
                const float wg = kTwoPi * 2.f * f0 / fsr, c = 1.f - softA * std::cos(wg), d = softA * std::sin(wg);
                const float k = kGhostDirect * (1.f - softA) / (c * c + d * d);
                re += k * c;
                im -= k * d;
            }
            const float level = 1.f / std::max(0.18f, std::sqrt(re * re + im * im));
            const float gp = std::clamp((0.35f + 0.6f * w) * v.ghostPan, -1.f, 1.f), th = (gp + 1.f) * kPi / 4.f;
            const float gl = std::cos(th) * gG * level, gr = std::sin(th) * gG * level;
            const float de = (target - start) / (float)n;
            float env = start, fade = fade0;
            for (int t = 0; t < n; ++t) {
                const float s = v.ghostOsc.next(incG) + kGhostBreath * 1.7320508f * noise.next();
                v.softZ = s + (v.softZ - s) * softA;
                env += de;
                float y = (v.formant.process(v.softZ) + kGhostDirect * v.softZ) * env;
                if (v.fading) { y *= fade; fade = std::max(0.f, fade - v.fadeStep); }
                ghostL[t] += y * gl;
                ghostR[t] += y * gr;
            }
        } else {
            v.ghostOsc.skip(n, std::min(analog::kMaxIncrement, 2.f * f0 / fsr));
        }
        v.ghostEnv = target;
    }

    if (v.fading) {
        v.fadeGain = std::max(0.f, fade0 - v.fadeStep * (float)n);
        if (v.fadeGain <= 0.f) v.active = false;
    }
}

void BlueDepth::housekeeping() {
    for (auto &v : voices)
        if (v.active && !v.fading && !v.held() && v.amp.idle() && v.ghostEnv < 1e-6f) v.active = false;
}

void BlueDepth::processBlock(float *left, float *right, int n) {
    const float fsr = (float)sr, dt = (float)n / fsr;
    for (int t = 0; t < n; ++t) {
        fine.next(); blink.next(); murk.next(); ghosts.next(); echoAmt.next(); bass.next(); space.next(); width.next();
    }
    // The wheel through two 4 ms smoothers: there within about 25 ms.
    const float kb = 1.f - std::exp(-(float)n / (0.004f * fsr));
    bendMid += kb * (bendTarget - bendMid);
    bendNow += kb * (bendMid - bendNow);
    // The mood under the dials.
    const float motion = 0.5f + clamp01(mMotion);
    slopDepth = dryHook ? 0.f : motion;
    subBoost = 1.f + 0.6f * (clamp01(mWarmth) - 0.5f);
    ghostDrift = 1.f - 0.12f * (clamp01(mWarmth) - 0.5f);
    // Murk: the filter's ceiling (brightness moves it ±20%), swayed by a slow 0.06–0.15 Hz current.
    currentWander += (double)dt / 41.0;
    if (currentWander >= 1.0) currentWander -= 1.0;
    currentPhase += (0.105 + 0.045 * std::sin(2.0 * M_PI * currentWander)) * (double)dt;
    if (currentPhase >= 1.0) currentPhase -= 1.0;
    const float current = dryHook ? 0.f : kCurrentDepth * motion * (float)std::sin(2.0 * M_PI * currentPhase);
    const float m = clamp01(murk.value);
    ceiling = logLerp(kCeilingOpen, kCeilingMurky, m) * (1.f + 0.4f * (clamp01(mBright) - 0.5f)) * (1.f + current);
    bassNow = clamp01(bass.value);
    const float gd = clamp01(ghosts.value);
    ghostGain = dryHook ? 0.f : kGhostNorm * dbGain(-16.f + 12.f * gd) * std::min(1.f, gd / 0.05f);
    // The echo: feedback 0.25–0.7 and mix 0–45%, darker repeats with Murk; mood space adds feedback.
    const float e = clamp01(echoAmt.value);
    echo.feedback = std::clamp(0.25f + 0.45f * e + 0.15f * (clamp01(mSpace) - 0.5f), 0.f, 0.85f);
    echo.mix = 0.45f * e;
    echo.width = clamp01(width.value);
    echo.lpA = std::exp(-kTwoPi * logLerp(kEchoLoopOpen, kEchoLoopMurky, m) / fsr);
    // Space: a dark reverb whose highs die faster with Murk (4 kHz → 1.2 kHz).
    const float sv = clamp01(space.value + 0.6f * (mSpace - 0.5f));
    const float dampHz = logLerp(kDampOpen, kDampMurky, m);
    if (std::fabs(sv - appliedSpace) > 2e-3f || std::fabs(dampHz - appliedDamp) > 10.f) {
        appliedSpace = sv;
        appliedDamp = dampHz;
        // Space's own damping reaches down to 1.5 kHz; a one-pole on the send takes the last of it to 1.2 kHz.
        reverb.configure(0.35f + 0.55f * sv, clamp01((15500.f - dampHz) / 14000.f), 25.f, 0.f);
        sendLPA = std::exp(-kTwoPi * std::min(1.25f * dampHz, 0.45f * fsr) / fsr);
    }
    wet.setTarget(!dryHook && sv > 0.f ? kWetMax * std::pow(sv, 0.77f) : 0.f);

    float pluckL[kSub] = {}, pluckR[kSub] = {}, bassL[kSub] = {}, bassR[kSub] = {};
    float ghostL[kSub] = {}, ghostR[kSub] = {}, echoL[kSub] = {}, echoR[kSub] = {};
    if (!idle) {
        bool anyVoice = false;
        for (auto &v : voices) {
            if (!v.active) continue;
            anyVoice = true;
            renderVoice(v, pluckL, pluckR, bassL, bassR, ghostL, ghostR, n);
        }
        if (dryHook) { if (echo.awake || echo.emptying) { echo.clear(); echo.emptying = false; echo.fade = 1.f; } }
        else echo.process(pluckL, pluckR, echoL, echoR, n);
        float peakAbs = 0;
        for (int t = 0; t < n; ++t)
            peakAbs = std::max(peakAbs, std::max(std::fabs(pluckL[t]) + std::fabs(bassL[t]) + std::fabs(ghostL[t]) + std::fabs(echoL[t]),
                                                 std::fabs(pluckR[t]) + std::fabs(bassR[t]) + std::fabs(ghostR[t]) + std::fabs(echoR[t])));
        if (!anyVoice && !echo.awake && !echo.emptying && peakAbs < 1e-6f) {
            idleSamples += n;
            if (idleSamples >= (int)(0.25f * fsr)) {
                idle = true;
                idleSamples = 0;
                sendLP[0] = sendLP[1] = 0.f;
            }
        } else {
            idleSamples = 0;
        }
    }

    float sendL[kSub], sendR[kSub], revL[kSub] = {}, revR[kSub] = {};
    const float em = echo.mix;
    for (int t = 0; t < n; ++t) {
        const float l = pluckL[t] + kBassSend * bassL[t] + em * echoL[t] + kGhostSend * ghostL[t];
        const float r = pluckR[t] + kBassSend * bassR[t] + em * echoR[t] + kGhostSend * ghostR[t];
        sendLP[0] = l + (sendLP[0] - l) * sendLPA;
        sendLP[1] = r + (sendLP[1] - r) * sendLPA;
        sendL[t] = sendLP[0];
        sendR[t] = sendLP[1];
    }
    if (wet.target > 0.f || wet.value > 1e-5f) {
        reverb.process(sendL, sendR, revL, revR, n);
        reverbLive = true;
    } else if (reverbLive) {
        reverb.clear();
        reverbLive = false;
    }
    for (int t = 0; t < n; ++t) {
        float rg = 1.f;
        if (reverbEmptying) {
            reverbFade = std::max(0.f, reverbFade - reverbFadeStep);
            rg = reverbFade;
        }
        const float w = wet.next() * rg;
        float l = kMaster * (pluckL[t] + bassL[t] + em * echoL[t] + kGhostDry * ghostL[t] + w * revL[t]);
        float r = kMaster * (pluckR[t] + bassR[t] + em * echoR[t] + kGhostDry * ghostR[t] + w * revR[t]);
        limiter.process(l, r);
        left[t] = softLimit(l);
        right[t] = softLimit(r);
    }
    if (reverbEmptying && reverbFade <= 0.f) {
        reverb.clear();
        reverbEmptying = false;
        reverbFade = 1.f;
    }
    if (++blockCount % 4 == 0) housekeeping();
}

} // namespace isd
