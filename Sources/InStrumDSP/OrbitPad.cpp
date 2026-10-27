#include "OrbitPad.hpp"
#include "include/InStrumDSP.h"
#include <algorithm>

namespace isd {

namespace {

// Level and tone calibration (see docs/superpowers/briefs/orbit-pad.md).
constexpr float kSawGain = 0.20f;        // each of the five Layer A saws
constexpr float kPulseGain = 0.045f;      // each of the three Layer B pulses (peak-to-peak 2)
constexpr float kSubGain = 0.065f;        // sine sub, two octaves down
constexpr float kMaster = 0.38f;
constexpr float kWetMax = 0.48f;        // reverb return at full Space: wet share of a held chord ≈ 48% at default, 70% at full
constexpr float kCutStart = 450.f;       // bloom start: kCutStart·2^(2·brightness') Hz
constexpr float kCutEnd = 2400.f;         // bloom end: kCutEnd·2^(4·brightness'·velocity) Hz
constexpr float kKeyTrack = 0.5f;        // cutoff follows the note: × (f0 / 261.63 Hz)^kKeyTrack
constexpr float kMaxCutoff = 16000.f;    // keeps BLEP residue out of the audible band
constexpr float kWalkTau = 1.5f;         // seconds: the drift's random walk wanders back on this scale
constexpr float kWalkLowpass = 0.3f;     // Hz: and never moves faster than this

const float kSawPos[OrbitPad::kSaws] = {-1.f, -0.4f, 0.f, 0.4f, 1.f};   // unison positions × spread
const float kPulsePos[OrbitPad::kPulses] = {-0.5f, 0.f, 0.5f};
const float kChorusMs[2][3] = {{7.0f, 10.5f, 14.0f}, {8.0f, 11.5f, 13.0f}};
const float kChorusRate[3] = {0.17f, 0.23f, 0.31f};
constexpr float kChorusDry = 0.8f, kChorusTap = 0.3f;

inline float midiHz(float m) { return 440.f * std::exp2((m - 69.f) / 12.f); }

/// Cubic B-spline BLEP residual at distance d (0…2 samples) from a unit step (odd-symmetric about the step).
inline float blepResidual(float d) {
    if (d < 1.f) {
        float d2 = d * d;
        return (1.f / 24.f) + (1.f / 6.f) * (2.75f - 4.f * d + 2.f * d2 * d - 0.75f * d2 * d2);
    }
    float e = 2.f - d;
    e *= e;
    return e * e * (1.f / 24.f);
}

/// Band-limited saw (−1…1, falling edge at the wrap) at phase p with per-sample increment dt (< 0.25).
inline float saw(float p, float dt) {
    float v = 2.f * p - 1.f;
    if (p < 2.f * dt) v += 2.f * blepResidual(p / dt);
    else if (p > 1.f - 2.f * dt) v -= 2.f * blepResidual((1.f - p) / dt);
    return v;
}

/// Rational tanh (Padé), exact ±1 beyond ±3.
inline float satur(float x) {
    if (x > 3.f) return 1.f;
    if (x < -3.f) return -1.f;
    float x2 = x * x;
    return x * (27.f + x2) / (27.f + 9.f * x2);
}

inline float smoothstep(float x) { x = clamp01(x); return x * x * (3.f - 2.f * x); }

} // namespace

OrbitPad::OrbitPad(double sampleRate) : sr(sampleRate), rng(0x0B17BAD5EEDULL), reverb(sampleRate, kSub) {
    limiter.init(sr);
    fine.init(sr); bloom.init(sr); drift.init(sr); motion.init(sr); shimmer.init(sr);
    brightness.init(sr); space.init(sr); wet.init(sr);
    fine.snap(0); bloom.snap(0.55f); drift.snap(0.40f); motion.snap(0.45f); shimmer.snap(0.25f);
    brightness.snap(0.50f); space.snap(0.55f); wet.snap(0);
    chorusLen = (int)(0.02 * sr) + 8;
    for (auto &b : chorusBuf) b.assign((size_t)chorusLen, 0.f);
}

void OrbitPad::setParam(int address, float value, bool snap) {
    auto set = [&](Smoothed &s) { if (snap) s.snap(value); else s.setTarget(value); };
    switch (address) {
    case ISD_P_FINE_TUNE: set(fine); break;
    case ISD_P_TRANSPOSE: pTranspose = value; break;
    case ISD_P_SPACE: set(space); break;
    case ISD_P_BLOOM: set(bloom); break;
    case ISD_P_DRIFT: set(drift); break;
    case ISD_P_MOTION: set(motion); break;
    case ISD_P_SHIMMER: set(shimmer); break;
    case ISD_P_BRIGHTNESS: set(brightness); break;
    case ISD_P_MOOD_ENERGY: mEnergy = value; break;
    case ISD_P_MOOD_WARMTH: mWarmth = value; break;
    case ISD_P_MOOD_BRIGHTNESS: mBright = value; break;
    case ISD_P_MOOD_SPACE: mSpace = value; break;
    case ISD_P_MOOD_MOTION: mMotion = value; break;
    case ISD_P_DEBUG_LAYER_A_ONLY: debugLayerA = value >= 0.5f; break;
    default: break;
    }
}

int OrbitPad::activeVoices() const {
    int n = 0;
    for (const auto &v : voices) if (v.active) ++n;
    return n;
}

OrbitPad::Voice &OrbitPad::allocate() {
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

void OrbitPad::beginFade(Voice &v) {
    if (v.fading) return;
    v.fading = true;
    v.fadeStep = 1.f / (0.02f * (float)sr);
}

void OrbitPad::release(Voice &v) {
    v.releasing = true;
    v.attackPos = v.attackLen;
}

void OrbitPad::startVoice(Voice &v, int note, int velocity) {
    const float bloomNow = clamp01(bloom.value - 0.6f * (mEnergy - 0.5f));
    v = Voice{};
    v.active = true;
    v.keyDown = true;
    v.note = note;
    v.age = ++noteCounter;
    v.pitch = std::clamp((float)note + pTranspose, 0.f, 127.f);
    v.vel = (float)velocity / 127.f;
    v.gain = std::pow(0.35f + 0.65f * v.vel, 1.3f);
    v.keyTrack = std::pow(midiHz(v.pitch) / 261.63f, kKeyTrack);
    // Octave-down pulses thin out in the bass; the sub never goes below 20 Hz.
    v.layerB = 0.4f + 0.6f * smoothstep((v.pitch - 36.f) / 18.f);
    v.subKey = smoothstep((v.pitch - 40.f) / 12.f);
    for (int k = 0; k < kOsc; ++k) {
        v.phase[k] = rng.uniform();
        v.walk[k] = 0.5f * (rng.bipolar() + rng.bipolar() + rng.bipolar());
        v.walkLP[k] = v.walk[k];
    }
    for (int k = 0; k < kPulses; ++k) { v.pwPhase[k] = rng.uniform(); v.pwRate[k] = 0.07f + 0.1f * rng.uniform(); }
    for (int k = 0; k < 3; ++k) { v.lfoPhase[k] = rng.uniform(); v.lfoRate[k] = 0.05f + 0.2f * rng.uniform(); }
    v.attackLen = std::max(1, (int)((0.4f + 1.6f * bloomNow) * (float)sr));
    const float start = kCutStart * std::exp2(2.f * brightNow) * v.keyTrack;
    v.g = std::tan(kPi * std::clamp(start, 20.f, std::min(kMaxCutoff, 0.35f * (float)sr)) / (float)sr);
    idle = false;
}

void OrbitPad::noteOn(int note, int velocity) {
    if (velocity <= 0) { noteOff(note); return; }
    startVoice(allocate(), note, velocity);
}

void OrbitPad::noteOff(int note) {
    for (auto &v : voices)
        if (v.active && !v.fading && v.note == note && v.keyDown) { v.keyDown = false; if (!sustain) release(v); }
}

void OrbitPad::setSustain(bool down) {
    if (down == sustain) return;
    sustain = down;
    if (!down)
        for (auto &v : voices) if (v.active && !v.fading && !v.keyDown && !v.releasing) release(v);
}

void OrbitPad::allNotesOff() {
    for (auto &v : voices) if (v.active) beginFade(v);
}

void OrbitPad::allSoundOff() {
    allNotesOff();
    reverb.clear();
    for (auto &b : chorusBuf) std::fill(b.begin(), b.end(), 0.f);
}

void OrbitPad::render(float *left, float *right, int frames) {
    int pos = 0;
    while (pos < frames) {
        int n = std::min(kSub, frames - pos);
        processBlock(left + pos, right + pos, n);
        pos += n;
    }
}

void OrbitPad::renderVoice(Voice &v, float *outL, float *outR, int n) {
    const float fsr = (float)sr, dtb = (float)n / fsr;
    const bool full = !debugLayerA;
    // Slow random walks (one per oscillator) and the voice's own motion LFOs.
    if (full) {
        const float a = dtb / kWalkTau, kick = std::sqrt(2.f * a) * 0.5f;
        const float lp = 1.f - std::exp(-kTwoPi * kWalkLowpass * dtb);
        for (int k = 0; k < kOsc; ++k) {
            float gauss = rng.bipolar() + rng.bipolar() + rng.bipolar();
            v.walk[k] += -v.walk[k] * a + kick * gauss;
            v.walkLP[k] += (v.walk[k] - v.walkLP[k]) * lp;
        }
    }
    float lfo[3];
    for (int k = 0; k < 3; ++k) {
        v.lfoPhase[k] += v.lfoRate[k] * dtb;
        if (v.lfoPhase[k] >= 1.f) v.lfoPhase[k] -= 1.f;
        lfo[k] = std::sin(kTwoPi * v.lfoPhase[k]);
    }
    // Oscillator increments for this block.
    const float base = midiHz(v.pitch), fineC = fine.value;
    const float spread = spreadCents + 3.f * motionAmt * lfo[2];
    float inc[kOsc], pw[kPulses];
    for (int k = 0; k < kOsc; ++k) {
        const bool pulse = k >= kSaws;
        const float pos = pulse ? kPulsePos[k - kSaws] : kSawPos[k];
        const float cents = full ? pos * spread + driftCents * satur(v.walkLP[k]) + fineC : fineC;
        inc[k] = std::min(0.24f, (pulse ? 0.5f : 1.f) * base * std::exp2(cents / 1200.f) / fsr);
    }
    for (int k = 0; k < kPulses; ++k) {
        v.pwPhase[k] += v.pwRate[k] * dtb;
        if (v.pwPhase[k] >= 1.f) v.pwPhase[k] -= 1.f;
        pw[k] = 0.425f + 0.075f * std::sin(kTwoPi * v.pwPhase[k]);
    }
    const float subW = kTwoPi * std::min(0.24f, 0.25f * base * std::exp2((driftCents * satur(v.walkLP[kSaws + 1]) + fineC) / 1200.f) / fsr);
    const float subCr = std::cos(subW), subCi = std::sin(subW);
    {   // keep the sub's rotator on the unit circle
        float m = 1.5f - 0.5f * (v.subC * v.subC + v.subS * v.subS);
        v.subC *= m; v.subS *= m;
    }
    // Bloom: the filter opens while the note is held and closes again as it drifts away.
    if (!v.releasing) v.bloomX = std::min(1.f, v.bloomX + bloomRate);
    else v.bloomX *= closeCoef;
    const float p = smoothstep(v.bloomX);
    const float logS = std::log2(kCutStart) + 2.f * brightNow;
    const float logE = std::max(logS, std::log2(kCutEnd) + 4.f * brightNow * v.vel);
    float fc = std::exp2(logS + (logE - logS) * p) * v.keyTrack * (1.f + 0.2f * motionAmt * lfo[0]);
    fc = std::clamp(fc, 20.f, std::min(kMaxCutoff, 0.35f * fsr));
    const float g1 = std::tan(kPi * fc / fsr), dg = (g1 - v.g) / (float)n;
    // Amplitude envelope: raised-cosine attack, exponential release.
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
    // Pan: a little spread across the keyboard plus slow motion.
    const float pan = std::clamp(std::clamp(0.15f * (v.pitch - 64.f) / 24.f, -0.15f, 0.15f) + 0.4f * motionAmt * lfo[1], -1.f, 1.f);
    const float th = (pan + 1.f) * kPi / 4.f, gl = std::cos(th) * v.gain, gr = std::sin(th) * v.gain;
    const float k = resonance, comp = 1.f + k;
    // The sub crossfades (80 ms) onto whichever held note is lowest, so chords keep one clear low end.
    const float subStart = v.subMix;
    v.subMix += (v.subTarget - v.subMix) * (1.f - std::exp(-(float)n / (0.08f * fsr)));
    const float subGain0 = kSubGain * v.subKey * subStart, dSub = kSubGain * v.subKey * (v.subMix - subStart) / (float)n;
    const float pulseGain = kPulseGain * v.layerB;

    double ph[kOsc];
    for (int i = 0; i < kOsc; ++i) ph[i] = v.phase[i];
    float s0 = v.s[0], s1 = v.s[1], s2 = v.s[2], s3 = v.s[3], g = v.g, env = v.env, fade = v.fadeGain;
    float subC = v.subC, subS = v.subS, subGain = subGain0;
    for (int t = 0; t < n; ++t) {
        float x;
        if (full) {
            float a = 0;
            for (int i = 0; i < kSaws; ++i) {
                a += saw((float)ph[i], inc[i]);
                ph[i] += inc[i]; if (ph[i] >= 1.0) ph[i] -= 1.0;
            }
            float b = 0;
            for (int i = 0; i < kPulses; ++i) {
                const int o = kSaws + i;
                float p1 = (float)ph[o], p2 = p1 + pw[i];
                if (p2 >= 1.f) p2 -= 1.f;
                b += saw(p1, inc[o]) - saw(p2, inc[o]);
                ph[o] += inc[o]; if (ph[o] >= 1.0) ph[o] -= 1.0;
            }
            float nc = subC * subCr - subS * subCi, ns = subC * subCi + subS * subCr;
            subC = nc; subS = ns;
            subGain += dSub;
            x = kSawGain * a + pulseGain * b + subGain * ns;
        } else {
            x = kSawGain * saw((float)ph[2], inc[2]);
            ph[2] += inc[2]; if (ph[2] >= 1.0) ph[2] -= 1.0;
        }
        // Zero-delay-feedback ladder: solve the linear loop, saturate the feedback.
        g += dg;
        const float G = g / (1.f + g), Gm = 1.f - G, G2 = G * G, G4 = G2 * G2;
        const float sigma = Gm * (G2 * G * s0 + G2 * s1 + G * s2 + s3);
        const float xin = comp * x;
        const float y4lin = (G4 * xin + sigma) / (1.f + k * G4);
        const float u = xin - k * satur(y4lin);
        float vv = (u - s0) * G; float y1 = vv + s0; s0 = y1 + vv;
        vv = (y1 - s1) * G; float y2 = vv + s1; s1 = y2 + vv;
        vv = (y2 - s2) * G; float y3 = vv + s2; s2 = y3 + vv;
        vv = (y3 - s3) * G; float y4 = vv + s3; s3 = y4 + vv;
        env = env * relC + denv;
        float out = y4 * env;
        if (v.fading) { out *= fade; fade = std::max(0.f, fade - v.fadeStep); }
        outL[t] += out * gl;
        outR[t] += out * gr;
    }
    for (int i = 0; i < kOsc; ++i) v.phase[i] = ph[i];
    v.s[0] = s0; v.s[1] = s1; v.s[2] = s2; v.s[3] = s3; v.g = g1; v.env = env; v.fadeGain = fade;
    v.subC = subC; v.subS = subS;
    if (v.fading && fade <= 0.f) v.active = false;
}

void OrbitPad::chorus(float *l, float *r, int n) {
    const float fsr = (float)sr, dtb = (float)n / fsr;
    const float depth = (0.25f + 1.25f * motionAmt) * 0.001f * fsr;
    float d0[2][3], d1[2][3];
    for (int k = 0; k < 3; ++k) {
        const float ph0 = chorusPh[k];
        chorusPh[k] += kChorusRate[k] * dtb;
        if (chorusPh[k] >= 1.f) chorusPh[k] -= 1.f;
        for (int c = 0; c < 2; ++c) {
            const float offset = (float)k / 3.f + 0.25f * (float)c;
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
            for (int k = 0; k < 3; ++k) {
                const float d = d0[c][k] + (d1[c][k] - d0[c][k]) * f;
                const float whole = std::floor(d), frac = d - whole;
                int i0 = chorusW - (int)whole; if (i0 < 0) i0 += chorusLen;
                int i1 = i0 - 1; if (i1 < 0) i1 += chorusLen;
                taps += buf[i0] + frac * (buf[i1] - buf[i0]);
            }
            io[c][t] = kChorusDry * io[c][t] + kChorusTap * taps;
        }
        if (++chorusW == chorusLen) chorusW = 0;
    }
}

void OrbitPad::chooseSubVoice() {
    Voice *lowest = nullptr;
    for (auto &v : voices) {
        if (!v.active || v.fading || v.releasing) continue;
        if (!lowest || v.pitch < lowest->pitch || (v.pitch == lowest->pitch && v.age > lowest->age)) lowest = &v;
    }
    if (!lowest) return;   // only releasing notes: each keeps the sub it had
    for (auto &v : voices) if (v.active) v.subTarget = &v == lowest ? 1.f : 0.f;
}

void OrbitPad::housekeeping() {
    for (auto &v : voices)
        if (v.active && v.releasing && !v.fading && v.env < 1e-5f) v.active = false;
}

void OrbitPad::processBlock(float *left, float *right, int n) {
    const float fsr = (float)sr;
    for (int t = 0; t < n; ++t) {
        fine.next(); bloom.next(); drift.next(); motion.next(); shimmer.next(); brightness.next(); space.next();
    }
    // Dials with the mood underneath them.
    const float bloomNow = clamp01(bloom.value - 0.6f * (mEnergy - 0.5f));
    bloomRate = (float)n / ((1.f + 5.f * bloomNow) * fsr);
    const float releaseT60 = 2.f + 6.f * (1.f - clamp01(mEnergy));
    releaseCoef = std::pow(10.f, -3.f / (releaseT60 * fsr));
    closeCoef = std::exp(-(float)n / (releaseT60 / 3.f * fsr));
    const float driftNow = clamp01(drift.value + 0.3f * (mMotion - 0.5f));
    spreadCents = debugLayerA ? 0.f : 3.f + 22.f * driftNow;
    driftCents = debugLayerA ? 0.f : 1.f + 4.f * driftNow;
    motionAmt = debugLayerA ? 0.f : clamp01(motion.value + 0.6f * (mMotion - 0.5f));
    brightNow = clamp01(brightness.value + 0.4f * (mBright - 0.5f));
    resonance = 0.8f + 0.6f * (mBright - 0.5f);
    if (std::fabs(mWarmth - appliedWarmth) > 1e-3f) {
        appliedWarmth = mWarmth;
        for (int c = 0; c < 2; ++c) {
            highShelf[c].setHighShelf(2500.0, -8.0 * (mWarmth - 0.5), sr);
            lowShelf[c].setLowShelf(180.0, 4.0 * (mWarmth - 0.5), sr);
        }
    }
    const float sv = clamp01(space.value + 0.6f * (mSpace - 0.5f));
    if (std::fabs(sv - appliedSpace) > 2e-3f || std::fabs(shimmer.value - appliedShimmer) > 2e-3f) {
        appliedSpace = sv;
        appliedShimmer = shimmer.value;
        reverb.configure(0.15f + 0.65f * sv, 0.45f, 20.f, shimmer.value);
        wet.setTarget(sv > 0.f ? kWetMax * std::pow(sv, 0.77f) : 0.f);
    }

    float dryL[kSub] = {}, dryR[kSub] = {};
    if (!idle) {
        chooseSubVoice();
        bool anyVoice = false;
        for (auto &v : voices) {
            if (!v.active) continue;
            anyVoice = true;
            renderVoice(v, dryL, dryR, n);
        }
        if (!debugLayerA) chorus(dryL, dryR, n);
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
