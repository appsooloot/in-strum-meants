#include "ReefMarimba.hpp"
#include "include/InStrumDSP.h"
#include <algorithm>

namespace isd {

namespace {

// Level and tone calibration (see docs/superpowers/briefs/reef-marimba.md).
constexpr float kGain = 0.205f;            // a strike at velocity 127 (× velocity² and the mallet's mass below it)
constexpr float kMaster = 1.0f;            // one loudness with the other built-ins (see testBuiltInsShareOneLoudness)
constexpr float kWetMax = 0.45f;
constexpr float kSlapMax = 0.30f;          // the slap off the water at Space 1
// The bar: tuned modes at 1, 3.99 and 9.2–10 × f0, each decaying faster by its ratio (Bork), then the untuned
// torsional and lateral modes that give the wood its knock.
constexpr float kRatio2 = 3.99f;
constexpr float kGain2 = 0.50f, kGain3 = 0.35f;
constexpr float kTorsionRatio = 2.7f, kTorsionGain = 0.0631f;   // −24 dB, and fast
constexpr float kLateralRatio = 6.3f, kLateralGain = 0.0316f;   // −30 dB
constexpr float kT60Low = 2.6f, kT60High = 0.35f;               // the fundamental's T60 at C2 and at C7
// The mallet: contact time from soft yarn to hard rubber; velocity shortens it by up to 40%.
constexpr float kTauSoft = 0.0045f, kTauHard = 0.0006f;
constexpr float kMassSoft = 1.2f, kMassHard = 0.8f;   // a soft yarn mallet is heavier: more momentum, 1.5 × hard rubber's
constexpr float kClickFrom = 0.0015f, kClickFull = 0.00036f;   // contact times where the click starts and peaks
constexpr float kClickGain = 0.25f;
// The tube: rings 60% as long as the bar and takes 15% off its fundamental's T60 (the coupling).
constexpr float kTubeShare = 0.6f, kTubeCoupling = 0.15f;
constexpr float kTubeGain = 3.3f;          // the tube's output at Tube 1: +9 dB on the fundamental
// The roll.
constexpr float kRollHold = 0.3f;          // held this long, a note rolls
constexpr float kRollSlow = 9.f, kRollFast = 13.f, kRollPressed = 16.f;   // Hz: Roll 0…1, then full pressure
constexpr float kStroke = 0.55f, kStrokePressed = 0.95f;                // × the note's velocity
constexpr float kRollJitter = 0.12f;
constexpr float kOtherTau = 1.12f, kOtherStrike = 0.06f;               // the second mallet: softer, further out
// The steel layer: a beating pair on f0, the octave and the twelfth, ringing 1.5 × as long as the wood.
constexpr float kSteelGain = 1.20f;        // at Steel 1
constexpr float kSteel2 = 2.20f, kSteel3 = 1.00f;   // a pan's octave and twelfth radiate as strongly as its note
constexpr float kSteelDecay = 1.5f;

inline float barHz(int pitch) { return 440.f * std::exp2(((float)pitch - 69.f) / 12.f); }

/// The bar's own fundamental T60: 2.6 s at C2, falling log-linearly to 0.35 s at C7.
inline float barT60(int pitch) {
    const float u = (float)(pitch - ReefMarimba::kLowest) / (float)(ReefMarimba::kHighest - ReefMarimba::kLowest);
    return kT60Low * std::pow(kT60High / kT60Low, clamp01(u));
}

/// The third tuned mode: 10.0 × f0 up to C4, 9.2 from C5 up.
inline float thirdRatio(int pitch) { return 10.f - 0.8f * clamp01((float)(pitch - 60) / 12.f); }

/// Below C3 players take softer, heavier mallets: the contact lengthens to 1.4 × over the four notes under C3.
inline float bassSoftening(int pitch) { return 1.f + 0.4f * clamp01((float)(48 - pitch) / 4.f); }

/// The small, stiff treble bars cut the contact short: the dial's contact time holds on A3 and scales as 1/√f0
/// (a medium mallet would otherwise sit past the pulse's first null on the top octave and barely speak).
inline float barContact(float f0) { return std::sqrt(220.f / f0); }

/// The Strike dial (0 the centre … 0.5 a standard off-centre stroke … 1 just inside the fundamental's node, a
/// quarter of the bar from its end) as a place on the half-bar, centre 0 … end 1.
inline float strikePlace(float s) { return 0.5f * s * s; }

/// Each bar's own small differences (0…1), the same every time.
inline float barHash(int pitch, float salt) {
    const float x = 0.6180340f * (float)pitch + salt;
    return x - std::floor(x);
}

inline uint64_t barSeed(int pitch, uint64_t salt) { return (0x9E3779B97F4A7C15ULL * (uint64_t)(pitch + 1)) ^ salt; }

} // namespace

ReefMarimba::ReefMarimba(double sampleRate) : sr(sampleRate), reverb(sampleRate, kSub) {
    limiter.init(sr);
    fine.init(sr); mallet.init(sr); strike.init(sr); tube.init(sr); roll.init(sr); steel.init(sr);
    space.init(sr); width.init(sr); wet.init(sr); slapGain.init(sr);
    fine.snap(0); mallet.snap(0.45f); strike.snap(0.40f); tube.snap(0.70f); roll.snap(0.35f); steel.snap(0.20f);
    space.snap(0.35f); width.snap(0.55f); wet.snap(0); slapGain.snap(0);
    holdSamples = std::max(1, (int)std::lround(kRollHold * sr));
    slapLen = std::max(1, (int)std::lround(0.006 * sr));
    for (auto &b : slapBuf) b.assign((size_t)slapLen, 0.f);
    for (auto &f : slapLP) f.setCutoff(6000.f, sr);
}

void ReefMarimba::setParam(int address, float value, bool snap) {
    auto set = [&](Smoothed &s) { if (snap) s.snap(value); else s.setTarget(value); };
    switch (address) {
    case ISD_P_FINE_TUNE: set(fine); break;
    case ISD_P_TRANSPOSE: pTranspose = value; break;
    case ISD_P_MALLET: set(mallet); break;
    case ISD_P_STRIKE: set(strike); break;
    case ISD_P_TUBE: set(tube); break;
    case ISD_P_ROLL: set(roll); break;
    case ISD_P_STEEL: set(steel); break;
    case ISD_P_SPACE: set(space); break;
    case ISD_P_WIDTH: set(width); break;
    case ISD_P_MOOD_ENERGY: mEnergy = value; break;
    case ISD_P_MOOD_WARMTH: mWarmth = value; break;
    case ISD_P_MOOD_BRIGHTNESS: mBright = value; break;
    case ISD_P_MOOD_SPACE: mSpace = value; break;
    case ISD_P_MOOD_MOTION: mMotion = value; break;
    case ISD_P_DEBUG_NO_ROLL: noRoll = value >= 0.5f; break;
    case ISD_P_DEBUG_BAR_ONLY: barOnly = value >= 0.5f; break;
    default: break;
    }
}

int ReefMarimba::activeVoices() const {
    int n = 0;
    for (const auto &v : voices) if (v.active && !v.fading) ++n;
    return n;
}

ReefMarimba::Voice *ReefMarimba::voiceFor(int pitch) {
    for (auto &v : voices) if (v.active && !v.fading && v.pitch == pitch) return &v;
    return nullptr;
}

ReefMarimba::Voice &ReefMarimba::allocate() {
    int sounding = 0;
    Voice *victim = nullptr;
    for (auto &v : voices) {
        if (!v.active || v.fading) continue;
        ++sounding;
        v.level = v.wood.energy() + v.steelNow * v.steelNow * v.steel.energy();
        // Bars ringing out go first, quietest first; then bars still held, quietest first, so a roll goes last.
        if (!victim) { victim = &v; continue; }
        const bool held = pitchHeld[v.pitch] > 0, victimHeld = pitchHeld[victim->pitch] > 0;
        if (held != victimHeld) { if (!held) victim = &v; continue; }
        if (v.level < victim->level) victim = &v;
    }
    if (sounding >= kPolyphony && victim) beginFade(*victim);
    for (auto &v : voices) if (!v.active) return v;
    // Every slot busy (a big chord over a full pool): the quietest bar already fading out makes room.
    Voice *best = nullptr;
    float bestLevel = 0;
    for (auto &v : voices) {
        if (!v.fading) continue;
        const float l = v.fadeGain * v.fadeGain * v.level;
        if (!best || l < bestLevel) { best = &v; bestLevel = l; }
    }
    if (!best) best = &voices[0];
    best->active = false;
    return *best;
}

void ReefMarimba::beginFade(Voice &v) {
    if (v.fading) return;
    v.fading = true;
    v.fadeStep = 1.f / (0.02f * (float)sr);
}

void ReefMarimba::placeVoice(Voice &v) const {
    // Low bars on the left, high on the right, as you stand at the instrument (±0.6 at Width 1).
    const float pan = 0.6f * clamp01(width.value) * std::clamp((float)(v.pitch - 66) / 30.f, -1.f, 1.f);
    const float th = (pan + 1.f) * kPi / 4.f;
    v.gl = std::cos(th);
    v.gr = std::sin(th);
}

void ReefMarimba::startVoice(Voice &v, int pitch) {
    const float f0 = barHz(pitch), T = barT60(pitch);
    const float tubeAmt = barOnly ? 0.f : clamp01(tube.value + 0.4f * (mWarmth - 0.5f));
    const float r3 = thirdRatio(pitch);
    const float rt = kTorsionRatio * (1.f + 0.03f * (2.f * barHash(pitch, 0.13f) - 1.f));
    const float rl = kLateralRatio * (1.f + 0.03f * (2.f * barHash(pitch, 0.71f) - 1.f));
    const ModalBar<8>::Mode wood[5] = {
        {1.f, T, 1.f, 0},
        {kRatio2, T / kRatio2, kGain2, 1},
        {r3, T / r3, kGain3, 2},
        {rt, T / (2.f * rt), barOnly ? 0.f : kTorsionGain, -1},
        {rl, T / rl, barOnly ? 0.f : kLateralGain, -1},
    };
    v.wood.setup(sr, f0, wood, 5, barSeed(pitch, 0xC0A1ULL));
    v.wood.setTube(barOnly ? 0.f : kTubeShare, kTubeCoupling * tubeAmt);
    v.wood.tubeLevel(kTubeGain * tubeAmt, true);   // a new bar starts at the dial's level (no ramp, whatever the block)
    v.wood.setFine(fineRatio);
    // The steel: a pair 0.5–1.5 Hz apart around f0 (each bar its own), then the octave and the twelfth.
    const float beat = 0.5f + barHash(pitch, 0.37f);
    const ModalBar<4>::Mode metal[4] = {
        {1.f - 0.5f * beat / f0, kSteelDecay * T, 0.5f, -1},
        {1.f + 0.5f * beat / f0, kSteelDecay * T, 0.5f, -1},
        {2.f, kSteelDecay * T / 2.f, kSteel2, -1},
        {3.f, kSteelDecay * T / 3.f, kSteel3, -1},
    };
    v.steel.setup(sr, f0, metal, 4, barSeed(pitch, 0x57EE1ULL));
    v.steel.setFine(fineRatio);
    v.active = true; v.fading = false; v.steelOn = false;
    v.pitch = pitch;
    v.steelNow = barOnly ? 0.f : kSteelGain * clamp01(steel.value + 0.4f * (mBright - 0.5f));
    v.level = 0; v.ref = 0;
    v.fadeGain = 1; v.fadeStep = 0;
    placeVoice(v);
    idle = false;
    idleSamples = 0;
}

void ReefMarimba::strikeBar(int pitch, float velocity, bool otherMallet) {
    Voice *v = voiceFor(pitch);
    if (!v) { v = &allocate(); startVoice(*v, pitch); }
    const float vel = clamp01(velocity);
    // Contact time: the dial (energy hardens it), softer in the bass, shorter the harder the strike.
    const float m = clamp01(mallet.value + 0.3f * (mEnergy - 0.5f));
    float tau = kTauSoft * std::pow(kTauHard / kTauSoft, m) * barContact(barHz(pitch)) * bassSoftening(pitch) * (1.f - 0.4f * vel);
    float s = clamp01(strike.value + 0.3f * (mBright - 0.5f));
    if (otherMallet) { tau *= kOtherTau; s = std::min(1.f, s + kOtherStrike); }
    const float amp = kGain * (kMassSoft + (kMassHard - kMassSoft) * m) * vel * vel;
    // A hard mallet clicks on contact: nothing at 1.5 ms of contact, the full click at 0.36 ms.
    const float hard = clamp01(std::log(kClickFrom / tau) / std::log(kClickFrom / kClickFull));
    // The untuned modes knock more the further out the strike (as at the standard stroke at Strike 0.5).
    const float knock = 0.4f + 1.2f * s;
    const float weight[8] = {1.f, 1.f, 1.f, knock, knock, 0.f, 0.f, 0.f};
    v->wood.strike(amp, tau, strikePlace(s), kClickGain * amp * hard * hard, weight);
    const float steelAmt = barOnly ? 0.f : clamp01(steel.value + 0.4f * (mBright - 0.5f));
    if (steelAmt > 0.f) {
        // Harder strikes ring more of the steel's upper partials (their gains follow velocity²).
        const float v2 = vel * vel, steelWeight[4] = {1.f, 1.f, v2, v2};
        v->steel.strike(amp, tau, 0.f, 0.f, steelWeight);
        v->steelOn = true;
    }
    v->level = v->wood.energy() + v->steelNow * v->steelNow * v->steel.energy();
    v->ref = std::max(v->ref, v->level);
}

void ReefMarimba::noteOn(int note, int velocity) {
    if (velocity <= 0) { noteOff(note); return; }
    note &= 127;
    int pitch = note + (int)std::lround(pTranspose);
    while (pitch < kLowest) pitch += 12;
    while (pitch > kHighest) pitch -= 12;
    if (keyDown[note]) noteOff(note);   // the same key again (no note-off between): a fresh note
    keyDown[note] = true;
    keyVel[note] = (float)std::clamp(velocity, 1, 127) / 127.f;
    keyPitch[note] = pitch;
    keyHeld[note] = 0;
    keyOrder[note] = ++pressCounter;
    ++pitchHeld[pitch];
    ++keysDown;
    strikeBar(pitch, keyVel[note], false);
}

void ReefMarimba::noteOff(int note) {
    note &= 127;
    if (!keyDown[note]) return;
    keyDown[note] = false;
    pitchHeld[keyPitch[note]] = std::max(0, pitchHeld[keyPitch[note]] - 1);
    keysDown = std::max(0, keysDown - 1);
    stopRoll(note);   // the bar rings on: a marimba has no dampers
}

void ReefMarimba::setSustain(bool down) { sustain = down; }   // no dampers to lift, and a roll is under the finger

void ReefMarimba::aftertouch(int note, float pressure) {
    const float p = clamp01(pressure);
    if (note < 0) channelPressure = p; else polyPressure[note & 127] = p;
}

void ReefMarimba::stopRoll(int note) {
    keyRolling[note & 127] = false;
    for (auto &r : rolls) if (r.active && r.note == (note & 127)) r.active = false;
}

void ReefMarimba::allNotesOff() {
    for (auto &v : voices) if (v.active) beginFade(v);
    for (auto &r : rolls) r.active = false;
    for (int k = 0; k < 128; ++k) {
        keyDown[k] = keyRolling[k] = false;
        keyHeld[k] = 0;
        pitchHeld[k] = 0;
        polyPressure[k] = 0;
    }
    keysDown = 0;
    channelPressure = 0;
}

void ReefMarimba::allSoundOff() {
    allNotesOff();
    reverb.clear();
    for (auto &b : slapBuf) std::fill(b.begin(), b.end(), 0.f);
    for (auto &f : slapLP) f.clear();
    reverbMute = (int)(0.025 * sr);   // the 20 ms fades never reach the reverb
}

bool ReefMarimba::rollsOn() const { return !noRoll && roll.value > 1e-4f; }

void ReefMarimba::rollStroke(Roll &r) {
    const float dial = clamp01(roll.value), p = clamp01(r.pressure);
    // 9–13 Hz by the dial; pressure takes it to 16 Hz and the strokes from 0.55 to 0.95 of the velocity; motion
    // speeds it. The dial's first tenth fades the strokes in.
    const float base = kRollSlow + (kRollFast - kRollSlow) * dial;
    const float rate = (base + (kRollPressed - base) * p) * (1.f + 0.3f * (mMotion - 0.5f));
    const float strength = (kStroke + (kStrokePressed - kStroke) * p) * std::min(1.f, dial / 0.1f)
                           * (1.f + 0.05f * r.rng.bipolar());
    // The two mallets alternate; the other hand's goes first (the note's own strike was the first hand's).
    strikeBar(keyPitch[r.note], keyVel[r.note] * strength, (r.strokes & 1u) == 0u);
    ++r.strokes;
    const float interval = (float)sr / std::max(1.f, rate) * (1.f + kRollJitter * r.rng.bipolar());
    r.wait += std::max(1, (int)std::lround(interval));
}

void ReefMarimba::stepRolls() {
    const bool on = rollsOn();
    for (auto &r : rolls)
        if (r.active && (!on || !keyDown[r.note])) { r.active = false; keyRolling[r.note] = false; }
    if (on && keysDown > 0) {
        // Keys held long enough roll while a slot is free, the earliest pressed first; the others ring and decay.
        for (auto &r : rolls) {
            if (r.active) continue;
            int pick = -1;
            for (int k = 0; k < 128; ++k)
                if (keyDown[k] && !keyRolling[k] && keyHeld[k] >= holdSamples && (pick < 0 || keyOrder[k] < keyOrder[pick])) pick = k;
            if (pick < 0) break;
            r.active = true;
            r.note = pick;
            r.wait = 0;
            r.strokes = 0;
            r.pressure = pressureOf(pick);
            r.rng = FastRandom(barSeed(pick, 0x2011ULL));
            keyRolling[pick] = true;
        }
    }
    for (auto &r : rolls)
        if (r.active && r.wait <= 0) rollStroke(r);
}

void ReefMarimba::advanceRolls(int n) {
    if (keysDown > 0)
        for (int k = 0; k < 128; ++k)
            if (keyDown[k] && !keyRolling[k] && keyHeld[k] < holdSamples) keyHeld[k] = std::min(holdSamples, keyHeld[k] + n);
    const float a = 1.f - std::exp(-(float)n / (0.04f * (float)sr));
    for (auto &r : rolls) {
        if (!r.active) continue;
        r.wait -= n;
        r.pressure += (pressureOf(r.note) - r.pressure) * a;
    }
}

int ReefMarimba::samplesToNextRollEvent() const {
    int next = kSub;
    for (const auto &r : rolls) if (r.active) next = std::min(next, std::max(1, r.wait));
    if (keysDown > 0 && rollsOn()) {
        bool free = false;
        for (const auto &r : rolls) free = free || !r.active;
        if (free)
            for (int k = 0; k < 128; ++k)
                if (keyDown[k] && !keyRolling[k]) next = std::min(next, std::max(1, holdSamples - keyHeld[k]));
    }
    return next;
}

void ReefMarimba::render(float *left, float *right, int frames) {
    int pos = 0;
    while (pos < frames) {
        // Roll strokes land on the sample: each inner block ends where the next one is due.
        stepRolls();
        const int n = std::min(frames - pos, samplesToNextRollEvent());
        processBlock(left + pos, right + pos, n);
        advanceRolls(n);
        pos += n;
    }
}

void ReefMarimba::housekeeping() {
    for (auto &v : voices) {
        if (!v.active || v.fading) continue;
        const float steelE = v.steelOn ? v.steel.energy() : 0.f;
        if (v.steelOn && steelE < 1e-9f * std::max(v.ref, 1e-12f)) { v.steelOn = false; v.steel.clear(); }
        v.level = v.wood.energy() + v.steelNow * v.steelNow * steelE;
        if (v.level < 1e-9f * v.ref && !v.wood.clicking()) v.active = false;
    }
}

void ReefMarimba::processBlock(float *left, float *right, int n) {
    const float fsr = (float)sr;
    for (int t = 0; t < n; ++t) {
        fine.next(); mallet.next(); strike.next(); tube.next(); roll.next(); steel.next(); space.next(); width.next();
    }
    if (blockCount % 4 == 0) {
        const bool landed = std::fabs(fine.value - fine.target) < 0.01f && std::fabs(fine.target - appliedCents) > 1e-4f;
        if (landed || std::fabs(fine.value - appliedCents) > 0.1f) {
            appliedCents = landed ? fine.target : fine.value;
            fineRatio = std::exp2(appliedCents / 1200.f);
            for (auto &v : voices) if (v.active) { v.wood.setFine(fineRatio); v.steel.setFine(fineRatio); }
        }
    }
    if (std::fabs(width.value - appliedWidth) > 1e-4f) {
        appliedWidth = width.value;
        for (auto &v : voices) if (v.active) placeVoice(v);
    }
    const float sv = barOnly ? 0.f : clamp01(space.value + 0.6f * (mSpace - 0.5f));
    if (std::fabs(sv - appliedSpace) > 2e-3f) {
        appliedSpace = sv;
        // Open air over the lagoon: a small, short space (0.6–1.5 s) and the slap off the water.
        reverb.setDecay(0.6f + 0.9f * sv);
        reverb.configure(0.15f + 0.30f * sv, 0.35f, 12.f, 0.f);
        wet.setTarget(sv > 0.f ? kWetMax * std::pow(sv, 0.8f) : 0.f);
        slapGain.setTarget(kSlapMax * sv);
    }

    float dryL[kSub] = {}, dryR[kSub] = {};
    if (!idle) {
        const float tubeLevel = barOnly ? 0.f : kTubeGain * clamp01(tube.value + 0.4f * (mWarmth - 0.5f));
        const float steelTarget = barOnly ? 0.f : kSteelGain * clamp01(steel.value + 0.4f * (mBright - 0.5f));
        bool any = false;
        for (auto &v : voices) {
            if (!v.active) continue;
            any = true;
            float x[kSub] = {};
            v.wood.tubeLevel(tubeLevel);
            v.wood.render(x, n);
            if (v.steelOn) {
                float s[kSub] = {};
                v.steel.render(s, n);
                const float g0 = v.steelNow, dg = (steelTarget - g0) / (float)n;
                for (int t = 0; t < n; ++t) x[t] += (g0 + dg * (float)(t + 1)) * s[t];
            }
            v.steelNow = steelTarget;
            if (v.fading) {
                float g = v.fadeGain;
                for (int t = 0; t < n; ++t) { x[t] *= g; g = std::max(0.f, g - v.fadeStep); }
                v.fadeGain = g;
                if (g <= 0.f) v.active = false;
            }
            for (int t = 0; t < n; ++t) { dryL[t] += x[t] * v.gl; dryR[t] += x[t] * v.gr; }
        }
        // The slap off the water, 6 ms behind and a little darker.
        float peakAbs = 0;
        for (int t = 0; t < n; ++t) {
            const float g = slapGain.next();
            float *io[2] = {&dryL[t], &dryR[t]};
            for (int c = 0; c < 2; ++c) {
                const float in = *io[c], d = slapBuf[c][(size_t)slapPos];
                slapBuf[c][(size_t)slapPos] = in;
                *io[c] = in + g * slapLP[c].process(d);
                peakAbs = std::max(peakAbs, std::fabs(*io[c]));
            }
            if (++slapPos == slapLen) slapPos = 0;
        }
        if (!any && peakAbs < 1e-6f) {
            idleSamples += n;
            if (idleSamples >= (int)(0.25f * fsr)) {
                idle = true;
                idleSamples = 0;
                for (auto &b : slapBuf) std::fill(b.begin(), b.end(), 0.f);
                for (auto &f : slapLP) f.clear();
            }
        } else {
            idleSamples = 0;
        }
    } else {
        for (int t = 0; t < n; ++t) slapGain.next();
    }

    float revL[kSub] = {}, revR[kSub] = {};
    if (wet.target > 0.f || wet.value > 1e-5f) {
        if (reverbMute > 0) {
            const float silence[kSub] = {};
            reverb.process(silence, silence, revL, revR, n);
            reverbMute -= n;
        } else {
            reverb.process(dryL, dryR, revL, revR, n);
        }
        reverbLive = true;
    } else if (reverbLive) {
        reverb.clear();
        reverbLive = false;
    }
    for (int t = 0; t < n; ++t) {
        const float w = wet.next();
        float l = kMaster * (dryL[t] + w * revL[t]), r = kMaster * (dryR[t] + w * revR[t]);
        limiter.process(l, r);
        left[t] = softLimit(l);
        right[t] = softLimit(r);
    }
    if (++blockCount % 4 == 0) housekeeping();
}

} // namespace isd
