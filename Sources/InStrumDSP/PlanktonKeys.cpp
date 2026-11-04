#include "PlanktonKeys.hpp"
#include "include/InStrumDSP.h"
#include <algorithm>

namespace isd {

namespace {

// Level and tone calibration (see docs/superpowers/briefs/plankton-keys.md).
constexpr float kGain = 0.13f;          // a voice's level at velocity 127
constexpr float kMaster = 0.70f;        // one loudness with the other built-ins: a mezzo-forte chord within 3 dB of Felt Glass
constexpr float kBarLevel = 0.85f;      // the tone bar sits a little under the tine's fundamental
constexpr float kBarMakeUp = 1.25f;     // so at the default Tine (0.55) the bar still sits just under the fundamental
constexpr float kBarDecay = 3.0f;       // and rings this many times longer
constexpr float kTineT60A3 = 3.6f;      // the tine fundamental's T60 on A3 (the bar's sets the −40 dB time)
constexpr float kBias = 0.45f;          // the pickup's asymmetry (a tine swings closer on one side)
constexpr float kThumpGain = 0.35f;     // hammer thump at velocity 127, against the voice level
constexpr float kClickGain = 0.10f;     // release click (the damper landing), against the voice level
constexpr float kSparkGain = 1.0f;      // a spark at Sparkle 1, against the voice level
constexpr float kWetMax = 0.50f;
constexpr float kDriveFloor = 0.15f, kDriveMax = 22.f;   // pickup drive: floor (pure) + max × Bark × velocity⁶
const float kSparkRatio[3] = {5.f, 7.f, 9.f};

inline float midiHz(float m) { return 440.f * std::exp2((m - 69.f) / 12.f); }
inline float decayR(float t60, double sr) { return (float)std::pow(10.0, -3.0 / ((double)t60 * sr)); }

/// The pickup's soft saturator: x / sqrt(1 + x²), odd, smooth everywhere (no corner to spray highs), ±1 at ±∞.
inline float sat(float x) { return x / std::sqrt(1.f + x * x); }

/// The tine's fundamental T60 (s): kTineT60A3 on A3, shorter up top, a little shorter in the deep bass.
inline float tineT60(int pitch) {
    const float t = kTineT60A3 * std::exp2(-(float)(pitch - 57) / 20.f);
    return std::clamp(pitch < 40 ? t * (1.f - 0.02f * (float)(40 - pitch)) : t, 0.5f, 9.f);
}

} // namespace

void PlanktonKeys::Burst::start(float seconds, float hz, float q, float rms, double sampleRate) {
    const float fsr = (float)sampleRate;
    left = std::max(1, (int)(seconds * fsr)); age = 0; attack = std::max(1, (int)(0.0005f * fsr));
    const float keep = 0.577f * std::sqrt(kPi * std::min(hz, 0.4f * fsr) / (q * fsr));
    amp = rms / std::max(keep, 1e-4f);
    decay = std::exp(-1.f / (seconds / 3.f * fsr));
    bp.clear();
    bp.setBandpass(std::min(hz, 0.45f * fsr), q, sampleRate);
}

PlanktonKeys::PlanktonKeys(double sampleRate)
    : sr(sampleRate), rng(0x91A4C70B5EEDULL), noise(0xC11C4ULL), reverb(sampleRate, kSub) {
    limiter.init(sr);
    fine.init(sr); tine.init(sr); bark.init(sr); sparkle.init(sr); tremolo.init(sr); phase.init(sr);
    space.init(sr); width.init(sr); wet.init(sr);
    fine.snap(0); tine.snap(0.55f); bark.snap(0.40f); sparkle.snap(0.50f); tremolo.snap(0.35f); phase.snap(0.20f);
    space.snap(0.50f); width.snap(0.55f); wet.snap(0);
}

void PlanktonKeys::setParam(int address, float value, bool snap) {
    auto set = [&](Smoothed &s) { if (snap) s.snap(value); else s.setTarget(value); };
    switch (address) {
    case ISD_P_FINE_TUNE: set(fine); break;
    case ISD_P_TRANSPOSE: pTranspose = value; break;
    case ISD_P_TINE: set(tine); break;
    case ISD_P_BARK: set(bark); break;
    case ISD_P_SPARKLE: set(sparkle); break;
    case ISD_P_TREMOLO: set(tremolo); break;
    case ISD_P_PHASE: set(phase); break;
    case ISD_P_SPACE: set(space); break;
    case ISD_P_WIDTH: set(width); break;
    case ISD_P_MOOD_ENERGY: mEnergy = value; break;
    case ISD_P_MOOD_WARMTH: mWarmth = value; break;
    case ISD_P_MOOD_BRIGHTNESS: mBright = value; break;
    case ISD_P_MOOD_SPACE: mSpace = value; break;
    case ISD_P_MOOD_MOTION: mMotion = value; break;
    case ISD_P_DEBUG_NO_SPARKLE: noSparkle = value >= 0.5f; break;
    case ISD_P_DEBUG_NO_TREMOLO: noTremolo = value >= 0.5f; break;
    default: break;
    }
}

int PlanktonKeys::activeVoices() const {
    int n = 0;
    for (const auto &v : voices) if (v.active) ++n;
    return n;
}

PlanktonKeys::Voice &PlanktonKeys::allocate() {
    int sounding = 0;
    Voice *quietest = nullptr;
    for (auto &v : voices) {
        if (!v.active || v.fading) continue;
        ++sounding;
        if (!quietest || v.level < quietest->level) quietest = &v;
    }
    if (sounding >= kPolyphony && quietest) beginFade(*quietest);
    for (auto &v : voices) if (!v.active) return v;
    Voice *best = nullptr;
    for (auto &v : voices) if (v.fading && (!best || v.fadeGain < best->fadeGain)) best = &v;
    if (!best) best = &voices[0];
    best->active = false;
    return *best;
}

void PlanktonKeys::beginFade(Voice &v) {
    if (v.fading) return;
    v.fading = true;
    v.fadeStep = 1.f / (0.02f * (float)sr);
}

void PlanktonKeys::retune(Voice &v) {
    const float fsr = (float)sr;
    for (int k = 0; k < kPartials; ++k) {
        const float w = kTwoPi * std::min(v.hz[k] * fineRatio, 0.45f * fsr) / fsr;
        v.cr[k] = v.dr[k] * std::cos(w); v.ci[k] = v.dr[k] * std::sin(w);
    }
}

void PlanktonKeys::startVoice(Voice &v, int note, int velocity) {
    const float fsr = (float)sr;
    const int pitch = std::clamp(note + (int)std::lround(pTranspose), 0, 127);
    const float vel = (float)std::clamp(velocity, 1, 127) / 127.f;
    const float f0 = midiHz((float)pitch);
    v = Voice{};
    v.active = true; v.keyDown = true;
    v.note = note; v.pitch = pitch; v.age = ++noteCounter;
    v.amp = kGain * (0.12f + 0.88f * std::pow(vel, 1.4f));
    // The pickup's drive: soft notes stay pure, hard notes bark (Bark and the mood's energy scale it).
    const float barkNow = clamp01(bark.value) * (1.f + 0.6f * (clamp01(mEnergy) - 0.5f));
    const float v2 = vel * vel;
    v.velDrive = v2 * v2 * v2;
    v.drive = kDriveFloor + kDriveMax * barkNow * v.velDrive;
    // Partials: the fundamental exactly in tune; the second and third stretched a little (more up the keyboard).
    const float inh = 1.002f + 0.006f * clamp01((float)(pitch - 21) / 87.f);
    const float T = tineT60(pitch);
    const float a2 = 0.6f + 0.2f * vel, a3 = 0.35f * (0.25f + 0.75f * vel);
    v.hz[0] = f0;                 v.re[0] = 1.f;       v.dr[0] = decayR(T, sr);
    v.hz[1] = 2.f * f0 * inh;     v.re[1] = a2;        v.dr[1] = decayR(0.8f * T, sr);
    v.hz[2] = 3.f * f0 * inh * inh; v.re[2] = a3;      v.dr[2] = decayR(std::min(1.2f, 0.3f * T), sr);
    v.hz[3] = f0;                 v.re[3] = kBarLevel; v.dr[3] = decayR(std::min(kBarDecay * T, 20.f), sr);
    for (int k = 1; k < 3; ++k) if (v.hz[k] > 0.45f * fsr) v.re[k] = 0.f;
    retune(v);
    v.ref = 1.f + kBarLevel * kBarLevel;
    v.level = v.amp * v.amp * v.ref;
    // The hammer's thump: one soft low cycle-ish, 10 ms, by velocity.
    v.thumpLen = std::max(1, (int)(0.010f * fsr));
    v.thumpW = kTwoPi * std::clamp(0.5f * f0, 40.f, 120.f) / fsr;
    v.thumpAmp = kThumpGain * v.amp * vel * vel;
    // Place in the stereo field by pitch (Width scales it live).
    v.pan = std::clamp((float)(pitch - 64) / 36.f, -1.f, 1.f);
    idle = false; idleSamples = 0;
    spawnSparks(v);
}

void PlanktonKeys::spawnSparks(const Voice &v) {
    if (noSparkle) return;
    const float s = clamp01(sparkle.value) * (1.f + 0.6f * (clamp01(mEnergy) - 0.5f));
    if (s <= 0.005f) return;
    const float fsr = (float)sr, f0 = midiHz((float)v.pitch) * fineRatio;
    const int count = std::min(5, 2 + (int)(3.f * clamp01(s) + 0.5f * rng.uniform()));
    const float spread = 0.4f + 0.6f * clamp01(width.value);
    for (int i = 0; i < count; ++i) {
        const float hz = f0 * kSparkRatio[(int)(rng.uniform() * 2.999f)] * std::exp2(25.f * rng.bipolar() / 1200.f);
        // Stratified delays across 15–90 ms, so the sparks land one after another.
        const float delay = 0.015f + (0.075f / (float)count) * ((float)i + 0.15f + 0.7f * rng.uniform());
        // Early sparks ring short and later ones longer, so each lands clear of the last (a wake that lingers).
        const float t60 = 0.06f + 0.19f * ((float)i + rng.uniform()) / (float)count;
        const float amp = kSparkGain * v.amp * clamp01(s) * (0.6f + 0.4f * rng.uniform());
        const float pan = spread * rng.bipolar();
        if (hz > 0.45f * fsr) continue;
        Spark *slot = nullptr;
        for (auto &k : sparks) if (!k.active) { slot = &k; break; }
        if (!slot) return;   // the pool is full: this note throws fewer
        Spark &k = *slot;
        k = Spark{};
        k.active = true;
        k.wait = (int)(delay * fsr);
        k.attack = std::max(1, (int)(0.0015f * fsr));
        const float d = decayR(t60, sr), w = kTwoPi * hz / fsr;
        k.cr = d * std::cos(w); k.ci = d * std::sin(w);
        k.re = amp; k.im = 0;
        const float th = (pan + 1.f) * kPi / 4.f;
        k.gl = std::cos(th); k.gr = std::sin(th);
        k.floor = amp * amp * 1e-8f;
    }
}

void PlanktonKeys::damp(Voice &v) {
    if (v.damped) return;
    v.damped = true;
    const float rd = decayR(0.08f, sr);
    for (int k = 0; k < kPartials; ++k) if (v.dr[k] > rd) { const float s = rd / v.dr[k]; v.cr[k] *= s; v.ci[k] *= s; v.dr[k] = rd; }
    // The damper landing: a short bright click, louder for a note still ringing hard.
    const float ringing = std::sqrt(std::max(0.f, v.level)) / std::max(1e-9f, v.amp * std::sqrt(v.ref));
    v.click.start(0.004f, 3500.f, 1.4f, kClickGain * v.amp * (0.3f + 0.7f * clamp01(ringing)), sr);
}

void PlanktonKeys::noteOn(int note, int velocity) {
    if (velocity <= 0) { noteOff(note); return; }
    note &= 127;
    // The same tine struck again: its old voice gives way (20 ms) to the new strike.
    for (auto &v : voices) if (v.active && !v.fading && v.note == note) beginFade(v);
    startVoice(allocate(), note, velocity);
}

void PlanktonKeys::noteOff(int note) {
    note &= 127;
    for (auto &v : voices)
        if (v.active && !v.fading && v.note == note && v.keyDown) { v.keyDown = false; if (!sustain) damp(v); }
}

void PlanktonKeys::setSustain(bool down) {
    if (down == sustain) return;
    sustain = down;
    if (!down) for (auto &v : voices) if (v.active && !v.fading && !v.keyDown) damp(v);
}

void PlanktonKeys::allNotesOff() {
    for (auto &v : voices) if (v.active) beginFade(v);
    const float step = 1.f / (0.02f * (float)sr);
    for (auto &k : sparks) {
        if (!k.active) continue;
        if (k.wait > 0) { k.active = false; continue; }   // sparks not yet thrown never come
        k.fading = true; k.fadeStep = step;
    }
}

void PlanktonKeys::allSoundOff() {
    allNotesOff();
    reverb.clear();
    for (auto &c : apX) for (auto &x : c) x = 0;
    for (auto &c : apY) for (auto &y : c) y = 0;
}

void PlanktonKeys::render(float *left, float *right, int frames) {
    int pos = 0;
    while (pos < frames) {
        const int n = std::min(kSub, frames - pos);
        processBlock(left + pos, right + pos, n);
        pos += n;
    }
}

void PlanktonKeys::renderVoice(Voice &v, float *outL, float *outR, int n, float tineW, float barW, float panScale) {
    // The pickup reads the tine (normalised so a unit swing gives a unit output at any drive); the tone bar
    // couples in clean, under it.
    const float d = v.drive, c = kBias, tc = sat(c);
    const float norm = 1.f / std::max(1e-4f, sat(d + c) - tc);
    const float wT = tineW * v.amp * norm, wB = barW * v.amp * kBarMakeUp;
    const float p = std::clamp(panScale * v.pan, -1.f, 1.f), th = (p + 1.f) * kPi / 4.f;
    const float gl = std::cos(th), gr = std::sin(th);
    const float dcK = 1.f - std::exp(-kTwoPi * 12.f / (float)sr);
    float re0 = v.re[0], im0 = v.im[0], re1 = v.re[1], im1 = v.im[1], re2 = v.re[2], im2 = v.im[2], re3 = v.re[3], im3 = v.im[3];
    const float c0 = v.cr[0], s0 = v.ci[0], c1 = v.cr[1], s1 = v.ci[1], c2 = v.cr[2], s2 = v.ci[2], c3 = v.cr[3], s3 = v.ci[3];
    float dcZ = v.dcZ, fade = v.fadeGain;
    for (int t = 0; t < n; ++t) {
        float a, b;
        a = re0 * c0 - im0 * s0; b = re0 * s0 + im0 * c0; re0 = a; im0 = b;
        a = re1 * c1 - im1 * s1; b = re1 * s1 + im1 * c1; re1 = a; im1 = b;
        a = re2 * c2 - im2 * s2; b = re2 * s2 + im2 * c2; re2 = a; im2 = b;
        a = re3 * c3 - im3 * s3; b = re3 * s3 + im3 * c3; re3 = a; im3 = b;
        float y = sat(d * (im0 + im1 + im2) + c) - tc;
        dcZ += dcK * (y - dcZ);
        y = wT * (y - dcZ) + wB * im3;
        if (v.thumpPos < v.thumpLen) {
            const float ph = (float)v.thumpPos, win = std::sin(kPi * ph / (float)v.thumpLen);
            y += v.thumpAmp * win * win * std::sin(v.thumpW * ph);
            ++v.thumpPos;
        }
        y += v.click.next(noise);
        if (v.fading) { y *= fade; fade = std::max(0.f, fade - v.fadeStep); }
        outL[t] += y * gl;
        outR[t] += y * gr;
    }
    v.re[0] = re0; v.im[0] = im0; v.re[1] = re1; v.im[1] = im1; v.re[2] = re2; v.im[2] = im2; v.re[3] = re3; v.im[3] = im3;
    v.dcZ = dcZ; v.fadeGain = fade;
    if (v.fading && fade <= 0.f) v.active = false;
}

void PlanktonKeys::renderSparks(float *outL, float *outR, int n) {
    for (auto &k : sparks) {
        if (!k.active) continue;
        int t = 0;
        if (k.wait > 0) {
            if (k.wait >= n) { k.wait -= n; continue; }
            t = k.wait;
            k.wait = 0;
        }
        float re = k.re, im = k.im, fade = k.fadeGain;
        for (; t < n; ++t) {
            const float a = re * k.cr - im * k.ci, b = re * k.ci + im * k.cr;
            re = a; im = b;
            float y = im;
            if (k.age < k.attack) { y *= (float)k.age / (float)k.attack; ++k.age; }
            if (k.fading) { y *= fade; fade = std::max(0.f, fade - k.fadeStep); }
            outL[t] += y * k.gl;
            outR[t] += y * k.gr;
        }
        k.re = re; k.im = im; k.fadeGain = fade;
        if ((k.fading && fade <= 0.f) || re * re + im * im < k.floor) k.active = false;
    }
}

void PlanktonKeys::phaser(float *l, float *r, int n) {
    const float m = clamp01(phase.value);
    const float rate = 0.1f + 0.2f * m;
    const double ph0 = phasePhase;
    phasePhase += (double)rate * (double)n / sr;
    if (phasePhase >= 1.0) phasePhase -= 1.0;
    float *io[2] = {l, r};
    for (int ch = 0; ch < 2; ++ch) {
        // The two sides sweep a quarter cycle apart, 300 Hz – 3 kHz.
        const float lfo = 0.5f + 0.5f * std::sin(kTwoPi * (float)(ph0 + 0.25 * ch));
        const float fc = 300.f * std::exp2(3.32f * lfo);
        const float tn = std::tan(kPi * fc / (float)sr), a = (tn - 1.f) / (tn + 1.f);
        const float a0 = apA[ch], da = (a - a0) / (float)n;
        float ac = a0;
        for (int t = 0; t < n; ++t) {
            ac += da;
            float x = io[ch][t];
            const float dry = x;
            for (int s = 0; s < 4; ++s) {
                const float y = ac * x + apX[ch][s] - ac * apY[ch][s];
                apX[ch][s] = x; apY[ch][s] = y;
                x = y;
            }
            io[ch][t] = dry * (1.f - 0.5f * m) + x * 0.5f * m;
        }
        apA[ch] = a;
    }
}

void PlanktonKeys::housekeeping() {
    for (auto &v : voices) {
        if (!v.active) continue;
        float e = 0;
        for (int k = 0; k < kPartials; ++k) e += v.re[k] * v.re[k] + v.im[k] * v.im[k];
        v.level = v.amp * v.amp * e;
        if (e < 1e-9f * v.ref && v.click.left <= 0 && v.thumpPos >= v.thumpLen) v.active = false;
    }
}

void PlanktonKeys::processBlock(float *left, float *right, int n) {
    const float fsr = (float)sr;
    for (int t = 0; t < n; ++t) {
        fine.next(); tine.next(); bark.next(); sparkle.next(); tremolo.next(); phase.next(); space.next(); width.next();
    }
    if (blockCount % 4 == 0) {
        const bool landed = std::fabs(fine.value - fine.target) < 0.01f && std::fabs(fine.target - appliedCents) > 1e-4f;
        if (landed || std::fabs(fine.value - appliedCents) > 0.1f) {
            appliedCents = landed ? fine.target : fine.value;
            fineRatio = std::exp2(appliedCents / 1200.f);
            for (auto &v : voices) if (v.active) retune(v);
        }
    }
    if (std::fabs(mBright - appliedBright) > 1e-3f) {
        appliedBright = mBright;
        for (auto &h : highShelf) h.setHighShelf(3500.0, 8.0 * (clamp01(mBright) - 0.5), sr);
    }
    const float sv = clamp01(space.value + 0.6f * (mSpace - 0.5f));
    if (std::fabs(sv - appliedSpace) > 2e-3f) {
        appliedSpace = sv;
        reverb.configure(0.2f + 0.6f * sv, 0.45f, 18.f, 0.08f);
        wet.setTarget(sv > 0.f ? kWetMax * std::pow(sv, 0.8f) : 0.f);
    }

    float dryL[kSub] = {}, dryR[kSub] = {};
    if (!idle) {
        // Tine against tone bar (warmth leans toward the bar), equal power.
        const float tv = clamp01(tine.value - 0.4f * (clamp01(mWarmth) - 0.5f));
        const float tineW = std::sin(0.5f * kPi * tv), barW = std::cos(0.5f * kPi * tv);
        const float panScale = 0.8f * clamp01(width.value);
        const float barkNow = clamp01(bark.value) * (1.f + 0.6f * (clamp01(mEnergy) - 0.5f));
        bool any = false;
        for (auto &v : voices) {
            if (!v.active) continue;
            any = true;
            // Bark follows the dial live; each voice keeps its velocity's share.
            v.drive = kDriveFloor + kDriveMax * barkNow * v.velDrive;
            renderVoice(v, dryL, dryR, n, tineW, barW, panScale);
        }
        for (auto &k : sparks) if (k.active) { any = true; break; }
        renderSparks(dryL, dryR, n);
        phaser(dryL, dryR, n);
        // Tremolo: an equal-power pan sway between the sides.
        const float rateT = clamp01(tremolo.value);
        const float rate = (2.f + 5.4f * rateT - 0.4f * rateT * rateT) * (1.f + 0.6f * (clamp01(mMotion) - 0.5f));
        const float depth = noTremolo ? 0.f : 0.9f * rateT;
        tremPhase += (double)rate * (double)n / sr;
        if (tremPhase >= 1.0) tremPhase -= 1.0;
        const float sw = depth * std::sin(kTwoPi * (float)tremPhase);
        const float gL = std::sqrt(1.f + sw), gR = std::sqrt(1.f - sw);
        float peakAbs = 0;
        for (int t = 0; t < n; ++t) {
            const float f = (float)(t + 1) / (float)n;
            const float l = dryL[t] * (tremGL + (gL - tremGL) * f), r = dryR[t] * (tremGR + (gR - tremGR) * f);
            dryL[t] = highShelf[0].process(l);
            dryR[t] = highShelf[1].process(r);
            peakAbs = std::max(peakAbs, std::max(std::fabs(dryL[t]), std::fabs(dryR[t])));
        }
        tremGL = gL; tremGR = gR;
        if (!any && peakAbs < 1e-6f) {
            idleSamples += n;
            if (idleSamples >= (int)(0.25f * fsr)) {
                idle = true;
                idleSamples = 0;
                for (auto &h : highShelf) h.clear();
                for (auto &c : apX) for (auto &x : c) x = 0;
                for (auto &c : apY) for (auto &y : c) y = 0;
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
