#include "PolarChoir.hpp"
#include "include/InStrumDSP.h"
#include <algorithm>

namespace isd {

namespace {

// Level and tone calibration (see docs/superpowers/briefs/polar-choir.md).
constexpr float kBreathGain = 3.0f;      // noise into the formants at Breath 1 (white, ±1)
constexpr float kAirGain = 0.05f;        // and a little wide air above them
constexpr float kGlassGain = 0.10f;      // the glass layer at Glass 1
constexpr float kMaster = 0.55f;
constexpr float kWetMax = 0.50f;         // reverb return at full Space
constexpr float kQLow = 6.f, kQHigh = 10.f;
constexpr float kKeyTrack = 0.2f;        // formants follow the note: × (f0 / 220 Hz)^kKeyTrack
constexpr float kDetuneCents = 6.f;      // the two saws sit ± this far apart
constexpr float kPressSeconds = 4.f, kEaseSeconds = 2.f;

/// Formant centres (Hz) of /u/ /o/ /a/ /e/ /i/: the Vowel dial walks along them.
const float kVowels[5][3] = {{325, 700, 2530}, {450, 800, 2830}, {700, 1220, 2600}, {530, 1850, 2500}, {270, 2290, 3010}};
/// And their levels (dB against F1), after the classic sung-vowel tables: /u/'s upper formants are faint, /a/'s strong.
const float kVowelDb[5][3] = {{0, -16, -30}, {0, -11, -24}, {0, -6, -22}, {0, -14, -15}, {0, -12, -20}};
/// Glass partials (× f0), their levels and the half-spacing (Hz) of each partial's beating pair.
const float kGlassRatio[PolarChoir::kGlass] = {1.f, 2.f, 3.f, 4.2f};
const float kGlassAmp[PolarChoir::kGlass] = {0.45f, 0.25f, 0.18f, 0.30f};
const float kGlassBeat[PolarChoir::kGlass] = {0.15f, 0.22f, 0.3f, 0.4f};
const float kChorusMs[2][2] = {{9.0f, 13.5f}, {10.5f, 12.0f}};
const float kChorusRate[2] = {0.19f, 0.27f};

inline float midiHz(float m) { return 440.f * std::exp2((m - 69.f) / 12.f); }

/// Cubic B-spline BLEP residual at distance d (0…2 samples) from a unit step (as Orbit Pad).
inline float blepResidual(float d) {
    if (d < 1.f) {
        float d2 = d * d;
        return (1.f / 24.f) + (1.f / 6.f) * (2.75f - 4.f * d + 2.f * d2 * d - 0.75f * d2 * d2);
    }
    float e = 2.f - d;
    e *= e;
    return e * e * (1.f / 24.f);
}

/// Band-limited saw (−1…1) at phase p with per-sample increment dt (< 0.25).
inline float saw(float p, float dt) {
    float v = 2.f * p - 1.f;
    if (p < 2.f * dt) v += 2.f * blepResidual(p / dt);
    else if (p > 1.f - 2.f * dt) v -= 2.f * blepResidual((1.f - p) / dt);
    return v;
}

inline float smoothstep(float x) { x = clamp01(x); return x * x * (3.f - 2.f * x); }

/// The formant set at a point (0…1) along u → o → a → e → i, interpolated in log frequency.
inline void vowelAt(float pos, float hz[3], float gain[3]) {
    const float x = clamp01(pos) * 4.f;
    const int i = std::min(3, (int)x);
    const float f = x - (float)i;
    for (int k = 0; k < 3; ++k) {
        hz[k] = kVowels[i][k] * std::exp2(f * std::log2(kVowels[i + 1][k] / kVowels[i][k]));
        gain[k] = std::pow(10.f, (kVowelDb[i][k] + f * (kVowelDb[i + 1][k] - kVowelDb[i][k])) / 20.f);
    }
}

} // namespace

PolarChoir::PolarChoir(double sampleRate) : sr(sampleRate), rng(0x90C4A1C401EULL), reverb(sampleRate, kSub) {
    limiter.init(sr);
    fine.init(sr); vowel.init(sr); breath.init(sr); glass.init(sr); swell.init(sr); shimmer.init(sr);
    space.init(sr); width.init(sr); wet.init(sr);
    fine.snap(0); vowel.snap(0.55f); breath.snap(0.35f); glass.snap(0.30f); swell.snap(0.55f); shimmer.snap(0.25f);
    space.snap(0.60f); width.snap(0.60f); wet.snap(0);
    chorusLen = (int)(0.02 * sr) + 8;
    for (auto &b : chorusBuf) b.assign((size_t)chorusLen, 0.f);
}

void PolarChoir::setParam(int address, float value, bool snap) {
    auto set = [&](Smoothed &s) { if (snap) s.snap(value); else s.setTarget(value); };
    switch (address) {
    case ISD_P_FINE_TUNE: set(fine); break;
    case ISD_P_TRANSPOSE: pTranspose = value; break;
    case ISD_P_VOWEL: set(vowel); break;
    case ISD_P_BREATH: set(breath); break;
    case ISD_P_GLASS: set(glass); break;
    case ISD_P_SWELL: set(swell); break;
    case ISD_P_SHIMMER: set(shimmer); break;
    case ISD_P_SPACE: set(space); break;
    case ISD_P_WIDTH: set(width); break;
    case ISD_P_MOOD_ENERGY: mEnergy = value; break;
    case ISD_P_MOOD_WARMTH: mWarmth = value; break;
    case ISD_P_MOOD_BRIGHTNESS: mBright = value; break;
    case ISD_P_MOOD_SPACE: mSpace = value; break;
    case ISD_P_MOOD_MOTION: mMotion = value; break;
    case ISD_P_DEBUG_VOICES_ONLY: voicesOnly = value >= 0.5f; break;
    default: break;
    }
}

int PolarChoir::activeVoices() const {
    int n = 0;
    for (const auto &v : voices) if (v.active) ++n;
    return n;
}

PolarChoir::Voice &PolarChoir::allocate() {
    int sounding = 0;
    Voice *victim = nullptr;
    for (auto &v : voices) {
        if (!v.active || v.fading) continue;
        ++sounding;
        // Released voices go first (quietest first); otherwise the oldest held note.
        if (!victim) { victim = &v; continue; }
        if (v.releasing != victim->releasing) { if (v.releasing) victim = &v; continue; }
        if (v.releasing ? v.env < victim->env : v.age < victim->age) victim = &v;
    }
    if (sounding >= kPolyphony && victim) beginFade(*victim);
    for (auto &v : voices) if (!v.active) return v;
    Voice *best = nullptr;
    for (auto &v : voices) if (v.fading && (!best || v.fadeGain < best->fadeGain)) best = &v;
    if (!best) best = &voices[0];
    best->active = false;
    return *best;
}

void PolarChoir::beginFade(Voice &v) {
    if (v.fading) return;
    v.fading = true;
    v.fadeStep = 1.f / (0.02f * (float)sr);
}

void PolarChoir::release(Voice &v) {
    v.releasing = true;
    v.attackPos = v.attackLen;   // the level holds where it got to, then decays
}

void PolarChoir::startVoice(Voice &v, int note, int velocity) {
    // From the dial itself: a note can arrive before the first block has run.
    const float swellAt = clamp01(swell.value - 0.6f * (mEnergy - 0.5f));
    v = Voice{};
    v.active = true;
    v.keyDown = true;
    v.note = note;
    v.age = ++noteCounter;
    v.pitch = std::clamp((float)note + pTranspose, 0.f, 127.f);
    const float vel = (float)velocity / 127.f;
    v.gain = std::pow(0.35f + 0.65f * vel, 1.3f);
    // A fixed place in the stereo field per note, scaled live by Width.
    v.pan = 0.75f * ((float)((note * 5) % 12) / 5.5f - 1.f);
    v.phase[0] = rng.uniform(); v.phase[1] = rng.uniform();
    v.driftPhase = rng.uniform(); v.driftRate = 0.05f + 0.07f * rng.uniform();
    v.breathPhase = rng.uniform(); v.breathRate = 0.2f + 0.2f * rng.uniform();
    for (int k = 0; k < kGlass; ++k)
        for (int j = 0; j < 2; ++j) { const float a = kTwoPi * rng.uniform(); v.glassC[k][j] = std::cos(a); v.glassS[k][j] = std::sin(a); }
    v.attackLen = std::max(1, (int)((0.3f + 2.7f * swellAt) * (float)sr));
    v.glassRate = 1.f / ((0.6f + 0.9f * swellAt) * (float)sr);
    idle = false;
}

void PolarChoir::noteOn(int note, int velocity) {
    if (velocity <= 0) { noteOff(note); return; }
    startVoice(allocate(), note, velocity);
}

void PolarChoir::noteOff(int note) {
    for (auto &v : voices)
        if (v.active && !v.fading && v.note == note && v.keyDown) { v.keyDown = false; if (!sustain) release(v); }
}

void PolarChoir::setSustain(bool down) {
    if (down == sustain) return;
    sustain = down;
    if (!down)
        for (auto &v : voices) if (v.active && !v.fading && !v.keyDown && !v.releasing) release(v);
}

void PolarChoir::allNotesOff() {
    for (auto &v : voices) if (v.active) beginFade(v);
}

void PolarChoir::allSoundOff() {
    allNotesOff();
    reverb.clear();
    for (auto &b : chorusBuf) std::fill(b.begin(), b.end(), 0.f);
}

void PolarChoir::render(float *left, float *right, int frames) {
    int pos = 0;
    while (pos < frames) {
        int n = std::min(kSub, frames - pos);
        processBlock(left + pos, right + pos, n);
        pos += n;
    }
}

void PolarChoir::renderVoice(Voice &v, float *outL, float *outR, int n) {
    const float fsr = (float)sr, dtb = (float)n / fsr;
    const bool full = !voicesOnly;
    const float base = midiHz(v.pitch) * std::exp2(fine.value / 1200.f);
    // The swell's press: rises over about 4 s while held, eases back over 2 s once released.
    if (full) {
        if (!v.releasing) v.pressX = std::min(1.f, v.pressX + pressUp * (float)n);
        else v.pressX = std::max(0.f, v.pressX - pressDown * (float)n);
    }
    const float press = smoothstep(v.pressX);
    // Formants: the Vowel dial plus this voice's slow drift, key-tracked, Q rising with the press.
    v.driftPhase += v.driftRate * dtb;
    if (v.driftPhase >= 1.f) v.driftPhase -= 1.f;
    const float pos = vowel.value + (full ? driftDepth * std::sin(kTwoPi * v.driftPhase) : 0.f);
    float fc[3], fg[3];
    vowelAt(pos, fc, fg);
    const float track = std::pow(base / 220.f, kKeyTrack), q = kQLow + (kQHigh - kQLow) * press;
    // A narrower band passes less: make most of that back up so the press reads as focus, not a fade.
    const float qComp = q / kQLow;
    for (int k = 0; k < 3; ++k) v.formant[k].setBandpass(std::min(fc[k] * track, 0.42f * fsr), q, sr);
    // Saws: two detuned (one in the voices-only test hook).
    float inc[2];
    inc[0] = std::min(0.24f, base * std::exp2(-kDetuneCents / 1200.f) / fsr);
    inc[1] = std::min(0.24f, base * std::exp2(kDetuneCents / 1200.f) / fsr);
    if (!full) inc[0] = std::min(0.24f, base / fsr);
    // Breath: noise through the same formants with a slow wander.
    v.breathPhase += v.breathRate * dtb;
    if (v.breathPhase >= 1.f) v.breathPhase -= 1.f;
    const float breathAmt = full ? breath.value * (0.75f + 0.25f * std::sin(kTwoPi * v.breathPhase)) : 0.f;
    // Glass: beating sine pairs with their own slow onset; silent above 0.45·sr.
    const float glassAmt = full ? glass.value * kGlassGain * smoothstep(v.glassX) : 0.f;
    if (full) v.glassX = std::min(1.f, v.glassX + v.glassRate * (float)n);
    float gCr[kGlass][2], gCi[kGlass][2], gAmp[kGlass];
    for (int k = 0; k < kGlass; ++k) {
        const float f = base * kGlassRatio[k];
        gAmp[k] = f < 0.45f * fsr ? glassAmt * kGlassAmp[k] : 0.f;
        for (int j = 0; j < 2; ++j) {
            const float w = kTwoPi * (f + (j ? kGlassBeat[k] : -kGlassBeat[k])) / fsr;
            gCr[k][j] = std::cos(w); gCi[k][j] = std::sin(w);
            float m = 1.5f - 0.5f * (v.glassC[k][j] * v.glassC[k][j] + v.glassS[k][j] * v.glassS[k][j]);
            v.glassC[k][j] *= m; v.glassS[k][j] *= m;
        }
    }
    const bool anyGlass = glassAmt > 1e-6f;
    // Envelope: raised-cosine attack, then hold; exponential release.
    float denv = 0;
    if (v.attackPos < v.attackLen) {
        int end = std::min(v.attackLen, v.attackPos + n);
        float target = 0.5f - 0.5f * std::cos(kPi * (float)end / (float)v.attackLen);
        denv = (target - v.env) / (float)n;
        v.attackPos = end;
    } else if (!v.releasing) {
        denv = (1.f - v.env) / (float)n;
    }
    const float relC = v.releasing ? releaseCoef : 1.f;
    // The press lifts the level (more at higher Swell) as the bow leans in.
    const float lift = 1.f - (0.35f + 0.3f * swellNow) * (1.f - press);
    const float p = std::clamp(width.value * v.pan, -1.f, 1.f), th = (p + 1.f) * kPi / 4.f;
    const float gl = std::cos(th) * v.gain, gr = std::sin(th) * v.gain;
    const float sawMix = full ? 0.5f : 1.f;

    double ph0 = v.phase[0], ph1 = v.phase[1];
    float env = v.env, fade = v.fadeGain, airZ = v.airZ;
    for (int t = 0; t < n; ++t) {
        float x = saw((float)ph0, inc[0]);
        ph0 += inc[0]; if (ph0 >= 1.0) ph0 -= 1.0;
        if (full) {
            x += saw((float)ph1, inc[1]);
            ph1 += inc[1]; if (ph1 >= 1.0) ph1 -= 1.0;
        }
        x *= sawMix;
        float air = 0;
        if (breathAmt > 0.f) {
            const float noise = rng.bipolar();
            x += kBreathGain * breathAmt * noise;
            airZ += 0.35f * (noise - airZ);
            air = kAirGain * breathAmt * (noise - airZ);   // a gentle high-passed hiss
        }
        float y = (fg[0] * v.formant[0].process(x) + fg[1] * v.formant[1].process(x) + fg[2] * v.formant[2].process(x)) * qComp + air;
        y *= lift;
        if (anyGlass) {
            float gs = 0;
            for (int k = 0; k < kGlass; ++k) {
                for (int j = 0; j < 2; ++j) {
                    const float c = v.glassC[k][j], s = v.glassS[k][j];
                    v.glassC[k][j] = c * gCr[k][j] - s * gCi[k][j];
                    v.glassS[k][j] = c * gCi[k][j] + s * gCr[k][j];
                    gs += gAmp[k] * v.glassS[k][j];
                }
            }
            y += gs;
        }
        env = env * relC + denv;
        float out = y * env;
        if (v.fading) { out *= fade; fade = std::max(0.f, fade - v.fadeStep); }
        outL[t] += out * gl;
        outR[t] += out * gr;
    }
    v.phase[0] = ph0; v.phase[1] = ph1; v.env = env; v.fadeGain = fade; v.airZ = airZ;
    if (v.fading && fade <= 0.f) v.active = false;
}

void PolarChoir::chorus(float *l, float *r, int n) {
    const float fsr = (float)sr, dtb = (float)n / fsr, w = clamp01(width.value);
    const float depth = (0.4f + 1.2f * clamp01(mMotion)) * 0.001f * fsr;
    const float dry = 1.f - 0.2f * w, tap = 0.32f * w;
    float d0[2][2], d1[2][2];
    for (int k = 0; k < 2; ++k) {
        const float ph0 = chorusPh[k];
        chorusPh[k] += kChorusRate[k] * dtb;
        if (chorusPh[k] >= 1.f) chorusPh[k] -= 1.f;
        for (int c = 0; c < 2; ++c) {
            const float offset = 0.5f * (float)k + 0.25f * (float)c;
            d0[c][k] = kChorusMs[c][k] * 0.001f * fsr + depth * std::sin(kTwoPi * (ph0 + offset));
            d1[c][k] = kChorusMs[c][k] * 0.001f * fsr + depth * std::sin(kTwoPi * (ph0 + kChorusRate[k] * dtb + offset));
        }
    }
    float *io[2] = {l, r};
    for (int t = 0; t < n; ++t) {
        const float f = (float)(t + 1) / (float)n;
        for (int c = 0; c < 2; ++c) {
            float *buf = chorusBuf[c].data();
            buf[chorusW] = io[c][t];
            float taps = 0;
            for (int k = 0; k < 2; ++k) {
                const float d = d0[c][k] + (d1[c][k] - d0[c][k]) * f;
                const float whole = std::floor(d), frac = d - whole;
                int i0 = chorusW - (int)whole; if (i0 < 0) i0 += chorusLen;
                int i1 = i0 - 1; if (i1 < 0) i1 += chorusLen;
                taps += buf[i0] + frac * (buf[i1] - buf[i0]);
            }
            io[c][t] = dry * io[c][t] + tap * taps;
        }
        if (++chorusW == chorusLen) chorusW = 0;
    }
}

void PolarChoir::housekeeping() {
    for (auto &v : voices)
        if (v.active && v.releasing && !v.fading && v.env < 1e-5f) v.active = false;
}

void PolarChoir::processBlock(float *left, float *right, int n) {
    const float fsr = (float)sr;
    for (int t = 0; t < n; ++t) {
        fine.next(); vowel.next(); breath.next(); glass.next(); swell.next(); shimmer.next(); space.next(); width.next();
    }
    // Dials with the mood underneath them: energy shortens the swell and the release.
    const float pace = 1.f - 0.6f * (clamp01(mEnergy) - 0.5f);
    swellNow = clamp01(swell.value - 0.6f * (mEnergy - 0.5f));
    const float releaseT60 = (1.5f + 3.5f * swellNow) * pace;
    releaseCoef = std::pow(10.f, -3.f / (releaseT60 * fsr));
    pressUp = 1.f / (kPressSeconds * pace * fsr);
    pressDown = 1.f / (kEaseSeconds * pace * fsr);
    driftDepth = 0.06f * (0.5f + clamp01(mMotion));
    if (std::fabs(mWarmth - appliedWarmth) > 1e-3f || std::fabs(mBright - appliedBright) > 1e-3f) {
        appliedWarmth = mWarmth; appliedBright = mBright;
        for (int c = 0; c < 2; ++c) {
            highShelf[c].setHighShelf(4000.0, 8.0 * (mBright - 0.5), sr);
            lowShelf[c].setLowShelf(200.0, 6.0 * (mWarmth - 0.5), sr);
        }
    }
    const float sv = clamp01(space.value + 0.6f * (mSpace - 0.5f));
    if (std::fabs(sv - appliedSpace) > 2e-3f || std::fabs(shimmer.value - appliedShimmer) > 2e-3f) {
        appliedSpace = sv;
        appliedShimmer = shimmer.value;
        reverb.configure(0.25f + 0.65f * sv, 0.4f, 25.f, shimmer.value);
        wet.setTarget(sv > 0.f ? kWetMax * std::pow(sv, 0.77f) : 0.f);
    }

    float dryL[kSub] = {}, dryR[kSub] = {};
    if (!idle) {
        bool anyVoice = false;
        for (auto &v : voices) {
            if (!v.active) continue;
            anyVoice = true;
            renderVoice(v, dryL, dryR, n);
        }
        if (!voicesOnly) chorus(dryL, dryR, n);
        float peakAbs = 0;
        for (int t = 0; t < n; ++t) {
            dryL[t] = highShelf[0].process(lowShelf[0].process(dryL[t]));
            dryR[t] = highShelf[1].process(lowShelf[1].process(dryR[t]));
            peakAbs = std::max(peakAbs, std::max(std::fabs(dryL[t]), std::fabs(dryR[t])));
        }
        if (!anyVoice && peakAbs < 1e-6f) {
            idleSamples += n;
            if (idleSamples >= (int)(0.25f * fsr)) {
                idle = true;
                idleSamples = 0;
                for (auto &b : chorusBuf) std::fill(b.begin(), b.end(), 0.f);
                for (int c = 0; c < 2; ++c) { highShelf[c].clear(); lowShelf[c].clear(); }
            }
        } else {
            idleSamples = 0;
        }
    }

    float revL[kSub] = {}, revR[kSub] = {};
    if (wet.target > 0.f || wet.value > 1e-5f) {
        reverb.process(dryL, dryR, revL, revR, n);
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
