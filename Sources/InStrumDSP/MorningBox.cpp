#include "MorningBox.hpp"
#include "include/InStrumDSP.h"
#include <algorithm>
#include <cstring>

namespace isd {

namespace {

// Level calibration (see docs/superpowers/briefs/morning-box.md).
constexpr float kBoxGain = 0.13f;
constexpr float kWallGain = 0.10f;
constexpr float kMaster = 1.0f;

/// Celesta bars (free-free bar modes over a tuned resonator) and a music box's plucked cantilever tines.
const float kBarRatio[3] = {2.76f, 5.40f, 8.93f};
const float kBarAmp[3] = {0.42f, 0.14f, 0.07f};
/// Unison voices' detune (× spread) and place in the stereo field (× width): pairs, so the cluster stays centred.
const float kDetune[MorningBox::kUnison] = {-0.5f, 0.5f, -0.25f, 0.25f, -1.0f, 1.0f};
const float kPan[MorningBox::kUnison] = {-0.35f, 0.35f, -0.7f, 0.7f, -1.0f, 1.0f};

inline float polyBlep(float t, float dt) {
    if (t < dt) { t /= dt; return t + t - t * t - 1.f; }
    if (t > 1.f - dt) { t = (t - 1.f) / dt; return t * t + t + t + 1.f; }
    return 0.f;
}

/// A band-limited saw from a phase in [0, 1) advancing by `dt`.
inline float sawStep(double &phase, float dt) {
    const float t = (float)phase;
    float y = 2.f * t - 1.f - polyBlep(t, dt);
    phase += dt;
    if (phase >= 1.0) phase -= 1.0;
    return y;
}

inline float fract(float x) { return x - std::floor(x); }

} // namespace

void MorningBox::Burst::start(float seconds, float hz, float q, float rms, double sampleRate) {
    const float fsr = (float)sampleRate;
    left = std::max(1, (int)(seconds * fsr)); age = 0; attack = std::max(1, (int)(0.0005f * fsr));
    const float keep = 0.577f * std::sqrt(kPi * std::min(hz, 0.4f * fsr) / (q * fsr)) * 0.8f;
    amp = rms / std::max(keep, 1e-4f);
    decay = std::exp(-1.f / (seconds / 3.f * fsr));
    bp.setBandpass(std::min(hz, 0.45f * fsr), q, sampleRate);
}

MorningBox::MorningBox(double sampleRate) : sr(sampleRate), rng(0xB0C5A11EULL), reverb(sampleRate, kSub) {
    limiter.init(sr);
    fine.init(sr); bloom.init(sr); build.init(sr); haze.init(sr); space.init(sr); wet.init(sr);
    fine.snap(0); bloom.snap(0.4f); build.snap(0.5f); haze.snap(0.35f); space.snap(0.5f); wet.snap(0);
    hazeLen = (int)(0.03 * sr) + 4;
    for (auto &b : hazeBuf) b.assign((size_t)hazeLen, 0.f);
}

void MorningBox::setParam(int address, float value, bool snap) {
    auto set = [&](Smoothed &s) { if (snap) s.snap(value); else s.setTarget(value); };
    switch (address) {
    case ISD_P_FINE_TUNE: set(fine); break;
    case ISD_P_TRANSPOSE: pTranspose = value; break;
    case ISD_P_BARS: pBars = value; break;
    case ISD_P_BOX: pBox = value; break;
    case ISD_P_BLOOM: set(bloom); break;
    case ISD_P_BUILD: set(build); break;
    case ISD_P_HAZE: set(haze); break;
    case ISD_P_SPACE: set(space); break;
    case ISD_P_WIDTH: pWidth = value; break;
    case ISD_P_MOOD_ENERGY: mEnergy = value; break;
    case ISD_P_MOOD_WARMTH: mWarmth = value; break;
    case ISD_P_MOOD_BRIGHTNESS: mBright = value; break;
    case ISD_P_MOOD_SPACE: mSpace = value; break;
    case ISD_P_MOOD_MOTION: mMotion = value; break;
    case ISD_P_DEBUG_BOX_ONLY: boxOnly = value > 0.5f; break;
    case ISD_P_DEBUG_WALL_ONLY: wallOnly = value > 0.5f; break;
    default: break;
    }
}

int MorningBox::activeVoices() const {
    int n = 0;
    for (const auto &v : box) n += v.active ? 1 : 0;
    for (const auto &v : wall) n += v.active ? 1 : 0;
    return n;
}

int MorningBox::debugCount(int which) const {
    if (which == ISD_DEBUG_BUILD_PERMILLE) return (int)std::lround(1000.f * buildLevel);
    if (which == ISD_DEBUG_WALL_UNISON) return (int)std::lround(2.f + 4.f * buildLevel);
    return 0;
}

MorningBox::BoxVoice &MorningBox::allocateBox() {
    int sounding = 0;
    BoxVoice *quietest = nullptr;
    for (auto &v : box) {
        if (!v.active || v.fading) continue;
        ++sounding;
        if (!quietest || v.level < quietest->level) quietest = &v;
    }
    if (sounding >= kBoxPolyphony && quietest) { quietest->fading = true; quietest->fadeStep = 1.f / (0.02f * (float)sr); }
    for (auto &v : box) if (!v.active) return v;
    BoxVoice *best = nullptr;
    for (auto &v : box) if (v.fading && (!best || v.fadeGain < best->fadeGain)) best = &v;
    if (!best) best = &box[0];
    best->active = false;
    return *best;
}

MorningBox::WallVoice &MorningBox::allocateWall() {
    int sounding = 0;
    WallVoice *victim = nullptr;
    // Released voices go first (quietest first); then notes the pedal is holding, then held keys (oldest first).
    // Never the newest note: under the pedal it's still swelling in and would always be the quietest.
    auto rank = [](const WallVoice &v) { return v.released ? 0 : (v.keyDown ? 2 : 1); };
    for (auto &v : wall) {
        if (!v.active || v.fading) continue;
        ++sounding;
        if (!victim) { victim = &v; continue; }
        const int a = rank(v), b = rank(*victim);
        if (a != b) { if (a < b) victim = &v; continue; }
        if (a == 0 ? v.env < victim->env : v.born < victim->born) victim = &v;
    }
    if (sounding >= kWallPolyphony && victim) { victim->fading = true; victim->fadeStep = 1.f / (0.02f * (float)sr); }
    for (auto &v : wall) if (!v.active) return v;
    WallVoice *best = nullptr;
    for (auto &v : wall) if (v.fading && (!best || v.fadeGain < best->fadeGain)) best = &v;
    if (!best) best = &wall[0];
    best->active = false;
    return *best;
}

void MorningBox::noteOn(int note, int velocity) {
    if (velocity <= 0) { noteOff(note); return; }
    note &= 127;
    idle = false; idleSamples = 0;
    noteRate += 1.f;
    const int pitch = std::clamp(note + (int)std::lround(pTranspose), 0, 127);
    for (auto &v : box)
        if (v.active && !v.fading && v.note == note && v.keyDown) { v.keyDown = false; if (!sustain) dampBox(v); }
    for (auto &v : wall)
        if (v.active && !v.fading && v.note == note && v.keyDown) { v.keyDown = false; if (!sustain) releaseWall(v); }
    if (!wallOnly) startBox(allocateBox(), note, pitch, velocity);
    if (!boxOnly) {
        // The same note struck again while its wall is still sounding (the pedal, or its release) swells that voice
        // again instead of stacking another.
        WallVoice *again = nullptr;
        for (auto &v : wall)
            if (v.active && !v.fading && v.note == note && v.pitch == pitch && !v.keyDown && (!again || v.env > again->env)) again = &v;
        if (again) {
            const float vp = (float)std::clamp(velocity, 1, 127) / 127.f;
            again->keyDown = true; again->released = false;
            again->velocity = std::max(again->velocity, vp);
            again->born = ++wallStamp;
        } else {
            startWall(allocateWall(), note, pitch, velocity);
        }
    }
}

void MorningBox::startBox(BoxVoice &v, int note, int pitch, int velocity) {
    const float fsr = (float)sr, nyq = 0.45f * fsr;
    const float vp = (float)std::clamp(velocity, 1, 127) / 127.f;
    const float hard = clamp01((0.3f + 0.7f * clamp01(pBars)) * (0.4f + 0.6f * vp) + 0.2f * (mBright - 0.5f));
    const float b = clamp01(pBox), f0 = midiHz((float)pitch);
    const float A = std::pow(vp, 1.4f);
    // The resonator lengthens the bar's fundamental; a tine rings longer still.
    const float Tb = std::clamp(4.5f * std::exp2(-(float)(pitch - 61) / 24.f), 0.8f, 7.f);
    const float Tc = std::clamp(12.0f * std::exp2(-(float)(pitch - 61) / 36.f), 2.f, 12.f);

    v.active = true; v.keyDown = true; v.damped = false; v.fading = false;
    v.note = note; v.pitch = pitch; v.fadeGain = 1; v.fadeStep = 0;
    v.modes.clear();
    int k = 0;
    float energy = 0;
    auto add = [&](float hz, float a, float t60) {
        if (hz > nyq || a <= 0.f || k >= 8) return;
        const float ph = kTwoPi * fract(0.618034f * (float)(k + 1) + 0.29f * (float)pitch);
        v.modes.hz[k] = hz; v.modes.re[k] = a * std::cos(ph); v.modes.im[k] = a * std::sin(ph); v.modes.dr[k] = decayR(t60, sr);
        energy += a * a; ++k;
    };
    const float shape = 0.3f + 0.7f * hard;
    add(f0, 1.f - b, Tb);
    for (int i = 0; i < 3; ++i) add(f0 * kBarRatio[i], (1.f - b) * kBarAmp[i] * std::pow(shape, (float)(i + 1)), Tb / std::pow(kBarRatio[i], 2.6f));
    add(f0 * std::exp2(-1.5f / 1200.f), 0.55f * b, Tc);
    add(f0 * std::exp2(1.5f / 1200.f), 0.45f * b, 0.9f * Tc);
    add(f0 * 6.27f, 0.30f * b * shape, Tc / std::pow(6.27f, 1.3f));
    add(f0 * 17.55f, 0.12f * b * shape * shape, Tc / std::pow(17.55f, 1.3f));
    const float norm = energy > 0 ? A * kBoxGain / std::sqrt(energy) : 0.f;
    v.ref = 0;
    for (int i = 0; i < k; ++i) { v.modes.re[i] *= norm; v.modes.im[i] *= norm; v.ref += v.modes.re[i] * v.modes.re[i] + v.modes.im[i] * v.modes.im[i]; }
    v.modes.setUsed(k);
    v.modes.retune(fineRatio, sr, 8);
    v.level = v.ref;
    // The felt hammer's tick (or the comb's pluck): a few milliseconds of bright noise.
    const float rms = std::sqrt(0.5f * v.ref) * (0.5f + 1.2f * hard);
    v.tick.bp.clear();
    v.tick.start(0.004f, 3000.f + 2000.f * b, 1.2f, rms, sr);
    const float pan = std::clamp(clamp01(pWidth) * (float)(pitch - 66) / 40.f, -1.f, 1.f), th = (pan + 1.f) * kPi / 4.f;
    v.panL = std::cos(th); v.panR = std::sin(th);
    (void)fsr;
}

void MorningBox::startWall(WallVoice &v, int note, int pitch, int velocity) {
    const float vp = (float)std::clamp(velocity, 1, 127) / 127.f;
    v.active = true; v.keyDown = true; v.released = false; v.fading = false;
    v.note = note; v.pitch = pitch; v.velocity = vp; v.born = ++wallStamp;
    v.env = 0; v.fadeGain = 1; v.fadeStep = 0;
    const float attack = 1.2f - 0.8f * vp;   // 0.4–1.2 s: harder notes bloom sooner
    v.attackK = 1.f - std::exp(-1.f / (attack / 3.f * (float)sr));
    for (int i = 0; i <= kUnison; ++i) v.phase[i] = fract(0.618034f * (float)(i + 1) + 0.37f * (float)pitch);
    v.sub = 0; v.shimmer = 0;
    for (auto &ch : v.s) for (auto &x : ch) x = 0;
}

void MorningBox::dampBox(BoxVoice &v) {
    if (v.damped) return;
    v.damped = true;
    v.modes.damp(decayR(0.08f, sr));
}

void MorningBox::releaseWall(WallVoice &v) { v.released = true; }

void MorningBox::noteOff(int note) {
    note &= 127;
    for (auto &v : box)
        if (v.active && !v.fading && v.note == note && v.keyDown) { v.keyDown = false; if (!sustain) dampBox(v); }
    for (auto &v : wall)
        if (v.active && !v.fading && v.note == note && v.keyDown) { v.keyDown = false; if (!sustain) releaseWall(v); }
}

void MorningBox::setSustain(bool down) {
    if (down == sustain) return;
    sustain = down;
    if (!down) {
        for (auto &v : box) if (v.active && !v.fading && !v.keyDown) dampBox(v);
        for (auto &v : wall) if (v.active && !v.fading && !v.keyDown) releaseWall(v);
    }
}

void MorningBox::allNotesOff() {
    const float step = 1.f / (0.02f * (float)sr);
    for (auto &v : box) if (v.active && !v.fading) { v.fading = true; v.fadeStep = step; }
    for (auto &v : wall) if (v.active && !v.fading) { v.fading = true; v.fadeStep = step; }
}

void MorningBox::allSoundOff() {
    allNotesOff();
    reverb.clear();
    for (auto &b : hazeBuf) std::fill(b.begin(), b.end(), 0.f);
}

void MorningBox::retune() {
    for (auto &v : box) if (v.active) v.modes.retune(fineRatio, sr);
}

/// The wall grows toward the build ceiling while you play (τ 20–40 s) and thins out in silence (τ 12 s).
void MorningBox::stepBuild(int n) {
    const float dt = (float)n / (float)sr;
    int held = 0;
    for (const auto &v : wall) held += (v.active && !v.released && !v.fading) ? 1 : 0;
    noteRate *= std::exp(-dt / 2.f);
    const float activity = std::min(1.f, (float)held / 4.f + (noteRate / 2.f) / 3.f);
    const float ceiling = clamp01(build.value);
    const float target = ceiling * activity;
    if (target > buildLevel) {
        const float tau = (40.f - 20.f * ceiling) * (1.f - 0.6f * std::max(0.f, mEnergy - 0.5f));
        buildLevel += (target - buildLevel) * (1.f - std::exp(-dt / tau));
    } else {
        buildLevel += (target - buildLevel) * (1.f - std::exp(-dt / 12.f));
    }
    buildLevel = std::clamp(buildLevel, 0.f, ceiling);
}

void MorningBox::render(float *left, float *right, int frames) {
    int pos = 0;
    while (pos < frames) {
        int n = std::min(kSub, frames - pos);
        processBlock(left + pos, right + pos, n);
        pos += n;
    }
}

void MorningBox::housekeeping() {
    for (auto &v : box) {
        if (!v.active) continue;
        const float e = v.modes.energyAndPrune(std::max(1e-8f * v.ref, 1e-14f));
        v.level = e;
        if (e <= 0 && v.tick.left <= 0) v.active = false;
    }
}

void MorningBox::processBlock(float *left, float *right, int n) {
    const float fsr = (float)sr;
    for (int t = 0; t < n; ++t) { fine.next(); build.next(); haze.next(); space.next(); }
    if (blockCount % 4 == 0) {
        const bool landed = std::fabs(fine.value - fine.target) < 0.01f && std::fabs(fine.target - appliedCents) > 1e-4f;
        if (landed || std::fabs(fine.value - appliedCents) > 0.1f) {
            appliedCents = landed ? fine.target : fine.value;
            fineRatio = std::exp2(appliedCents / 1200.f);
            retune();
        }
    }
    stepBuild(n);
    const float B = buildLevel;
    const float bx = clamp01(pBox);
    if (std::fabs(bx - appliedBox) > 1e-3f) {
        appliedBox = bx;
        for (int c = 0; c < 2; ++c) { boxBody[0][c].setPeak(400.0, 1.2, 4.0 * bx, sr); boxBody[1][c].setPeak(800.0, 1.4, 3.0 * bx, sr); }
    }
    const float hz = clamp01(haze.value), hv = clamp01(hz + 0.4f * (mWarmth - 0.5f) * hz);
    if (std::fabs(hv - appliedHaze) > 1e-3f) {
        appliedHaze = hv;
        for (int c = 0; c < 2; ++c) hazeShelf[c].setHighShelf(6000.0, -3.0 * hv - 1.0 * clamp01(mWarmth - 0.5f), sr);
    }
    const float sv = clamp01(space.value + 0.6f * (mSpace - 0.5f));
    if (std::fabs(sv - appliedSpace) > 2e-3f) {
        appliedSpace = sv;
        reverb.configure(0.3f + 0.4f * sv, 0.5f, 14.f, 0.05f);
        wet.setTarget(0.55f * sv);
    }

    float dryL[kSub] = {}, dryR[kSub] = {};
    if (!idle) {
        bool any = false;
        // The box.
        float bL[kSub] = {}, bR[kSub] = {};
        for (auto &v : box) {
            if (!v.active) continue;
            any = true;
            v8 lane[kSub];
            float vs[kSub];
            for (int t = 0; t < n; ++t) lane[t] = v8{};
            v.modes.render(lane, n);
            for (int t = 0; t < n; ++t) vs[t] = hsum(lane[t]) + v.tick.next(rng);
            if (v.fading) {
                for (int t = 0; t < n; ++t) { vs[t] *= v.fadeGain; v.fadeGain = std::max(0.f, v.fadeGain - v.fadeStep); }
                if (v.fadeGain <= 0.f) v.active = false;
            }
            for (int t = 0; t < n; ++t) { bL[t] += vs[t] * v.panL; bR[t] += vs[t] * v.panR; }
        }
        for (int t = 0; t < n; ++t) {
            float l = bL[t], r = bR[t];
            for (int k = 0; k < 2; ++k) { l = boxBody[k][0].process(l); r = boxBody[k][1].process(r); }
            dryL[t] += l; dryR[t] += r;
        }

        // The wall.
        const float u = 2.f + 4.f * B, spread = 6.f + 6.f * B, panSpread = clamp01(pWidth) * (0.3f + 0.4f * B);
        float g[kUnison], gl[kUnison], gr[kUnison], gNorm = 0;
        for (int i = 0; i < kUnison; ++i) {
            g[i] = i < 2 ? 1.f : clamp01(u - (float)i);
            gNorm += g[i] * g[i];
            const float th = (std::clamp(kPan[i] * panSpread, -1.f, 1.f) + 1.f) * kPi / 4.f;
            gl[i] = std::cos(th); gr[i] = std::sin(th);
        }
        gNorm = 1.f / std::sqrt(gNorm);
        const float octave = 0.5f * B, shimmerGain = 0.3f * B * B, relK = std::exp(-1.f / (0.33f * fsr));
        const float level = kWallGain * bloom.value;
        for (int t = 0; t < n; ++t) bloom.next();
        for (auto &v : wall) {
            if (!v.active) continue;
            any = true;
            const float f = midiHz((float)v.pitch) * fineRatio;
            float fc = 650.f * std::exp2(1.6f * v.velocity) * (1.f + 2.f * B) * std::pow(f / 261.63f, 0.3f) * std::exp2(-(mWarmth - 0.5f));
            fc = std::clamp(fc, 80.f, std::min(16000.f, 0.4f * fsr));
            const float gg = std::tan(kPi * fc / fsr), G = gg / (1.f + gg);
            float dt[kUnison];
            for (int i = 0; i < kUnison; ++i) dt[i] = f * std::exp2(kDetune[i] * spread / 1200.f) / fsr;
            const float dtOct = 2.f * f / fsr, dtSub = f / fsr, dtShim = 3.f * f / fsr;
            const float amp = level * (0.4f + 0.6f * v.velocity);
            for (int t = 0; t < n; ++t) {
                if (v.released) v.env *= relK; else v.env += (1.f - v.env) * v.attackK;
                float l = 0, r = 0;
                for (int i = 0; i < kUnison; ++i) {
                    if (g[i] <= 0.f) { v.phase[i] += dt[i]; if (v.phase[i] >= 1.0) v.phase[i] -= 1.0; continue; }
                    const float s = sawStep(v.phase[i], dt[i]) * g[i];
                    l += s * gl[i]; r += s * gr[i];
                }
                l *= gNorm; r *= gNorm;
                const float o = octave > 0.f ? octave * sawStep(v.phase[kUnison], dtOct) : 0.f;
                if (octave <= 0.f) { v.phase[kUnison] += dtOct; if (v.phase[kUnison] >= 1.0) v.phase[kUnison] -= 1.0; }
                v.sub += dtSub; if (v.sub >= 1.0) v.sub -= 1.0;
                v.shimmer += dtShim; if (v.shimmer >= 1.0) v.shimmer -= 1.0;
                const float c = 0.35f * std::sin(kTwoPi * (float)v.sub) + shimmerGain * std::sin(kTwoPi * (float)v.shimmer) + 0.7071f * o;
                float in[2] = {l + c, r + c};
                for (int ch = 0; ch < 2; ++ch) {
                    float x = in[ch];
                    for (int k = 0; k < 4; ++k) {
                        const float w = (x - v.s[ch][k]) * G, y = w + v.s[ch][k];
                        v.s[ch][k] = y + w;
                        x = y;
                    }
                    in[ch] = x;
                }
                float gain = v.env * amp;
                if (v.fading) { gain *= v.fadeGain; v.fadeGain = std::max(0.f, v.fadeGain - v.fadeStep); }
                dryL[t] += in[0] * gain; dryR[t] += in[1] * gain;
            }
            if ((v.fading && v.fadeGain <= 0.f) || (v.released && v.env < 1e-4f)) v.active = false;
        }

        // Haze: a soft tape wow on the whole, a slow two-voice chorus, gentle saturation and a softer top.
        const float depth = 0.006f * hz * (0.5f + clamp01(mMotion)), wowD = 0.00055f * hz;
        float peakAbs = 0;
        for (int t = 0; t < n; ++t) {
            lfo1 += 0.31 / sr; if (lfo1 >= 1.0) lfo1 -= 1.0;
            lfo2 += 0.47 / sr; if (lfo2 >= 1.0) lfo2 -= 1.0;
            wowPhase += 0.5 / sr; if (wowPhase >= 1.0) wowPhase -= 1.0;
            const float wow = wowD * std::sin(kTwoPi * (float)wowPhase);
            const float d0 = (0.002f + wow) * fsr;
            const float d1 = (0.009f + depth * std::sin(kTwoPi * (float)lfo1) + wow) * fsr;
            const float d2 = (0.012f + depth * std::sin(kTwoPi * (float)lfo2 + 1.7f) + wow) * fsr;
            float out[2];
            const float in[2] = {dryL[t], dryR[t]};
            for (int ch = 0; ch < 2; ++ch) {
                hazeBuf[ch][(size_t)hazePos] = in[ch];
                auto tap = [&](float d) {
                    float rp = (float)hazePos - d;
                    while (rp < 0) rp += (float)hazeLen;
                    // A tiny negative position can round to exactly hazeLen once wrapped: keep the index inside.
                    int i0 = (int)rp;
                    float fr = rp - (float)i0;
                    if (i0 >= hazeLen) { i0 -= hazeLen; fr = 0.f; }
                    const int i1 = (i0 + 1) % hazeLen;
                    return hazeBuf[ch][(size_t)i0] * (1.f - fr) + hazeBuf[ch][(size_t)i1] * fr;
                };
                const float a = tap(d0), c1 = tap(ch == 0 ? d1 : d2), c2 = tap(ch == 0 ? d2 : d1);
                float y = a * (1.f - 0.35f * hz) + 0.45f * hz * (c1 + c2);
                const float drive = 1.f + 0.6f * hz;
                y = std::tanh(drive * y) / drive;
                out[ch] = hazeShelf[ch].process(y);
            }
            if (++hazePos == hazeLen) hazePos = 0;
            dryL[t] = out[0]; dryR[t] = out[1];
            peakAbs = std::max(peakAbs, std::max(std::fabs(out[0]), std::fabs(out[1])));
        }
        if (!any && peakAbs < 1e-6f) {
            idleSamples += n;
            if (idleSamples >= (int)(0.25f * fsr)) {
                idle = true;
                idleSamples = 0;
                for (auto &b : boxBody) { b[0].clear(); b[1].clear(); }
                for (auto &s : hazeShelf) s.clear();
                for (auto &b : hazeBuf) std::fill(b.begin(), b.end(), 0.f);
            }
        } else {
            idleSamples = 0;
        }
    } else {
        for (int t = 0; t < n; ++t) bloom.next();
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
        float w = wet.next();
        float l = kMaster * (dryL[t] + w * revL[t]), r = kMaster * (dryR[t] + w * revR[t]);
        limiter.process(l, r);
        left[t] = softLimit(l);
        right[t] = softLimit(r);
    }
    if (++blockCount % 4 == 0) housekeeping();
}

} // namespace isd
