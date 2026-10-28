// Tape and lo-fi helpers shared by the built-in instruments: wow and flutter, tape saturation with hiss,
// band-limited saws and a state-variable filter. Header-only; everything is sized in prepare() and
// nothing allocates while rendering.
#pragma once
#include "DSPCommon.hpp"
#include <algorithm>
#include <vector>

namespace isd {

/// Rational tanh (Padé), exact ±1 beyond ±3.
inline float softSat(float x) {
    if (x > 3.f) return 1.f;
    if (x < -3.f) return -1.f;
    float x2 = x * x;
    return x * (27.f + x2) / (27.f + 9.f * x2);
}

/// Cubic B-spline BLEP residual at distance d (0…2 samples) from a unit step.
inline float blepResidual4(float d) {
    if (d < 1.f) {
        float d2 = d * d;
        return (1.f / 24.f) + (1.f / 6.f) * (2.75f - 4.f * d + 2.f * d2 * d - 0.75f * d2 * d2);
    }
    float e = 2.f - d;
    e *= e;
    return e * e * (1.f / 24.f);
}

/// Band-limited saw (−1…1) at phase p with per-sample increment dt (< 0.25).
inline float blepSaw(float p, float dt) {
    float v = 2.f * p - 1.f;
    if (p < 2.f * dt) v += 2.f * blepResidual4(p / dt);
    else if (p > 1.f - 2.f * dt) v -= 2.f * blepResidual4((1.f - p) / dt);
    return v;
}

/// Topology-preserving state-variable filter (Simper). Set once per block, run per sample.
struct SVF {
    float ic1 = 0, ic2 = 0, a1 = 1, a2 = 0, a3 = 0, k = 1.414f;
    void set(float hz, float q, float sr) {
        const float g = std::tan(kPi * std::clamp(hz, 10.f, 0.45f * sr) / sr);
        k = 1.f / q;
        a1 = 1.f / (1.f + g * (g + k)); a2 = g * a1; a3 = g * a2;
    }
    float lowpass(float v0) {
        const float v3 = v0 - ic2, v1 = a1 * ic1 + a2 * v3, v2 = ic2 + a2 * ic1 + a3 * v3;
        ic1 = 2.f * v1 - ic1; ic2 = 2.f * v2 - ic2;
        return v2;
    }
    void clear() { ic1 = ic2 = 0; }
};

/// Wow (a slow, wandering sway) and flutter (a fast shimmer) as one modulated stereo delay line.
/// A delay swinging ±D seconds at f Hz swings the pitch by ±2πfD, so D = (2^(cents/1200) − 1) / (2πf).
struct TapeDelay {
    static constexpr float kBaseSeconds = 0.006f;
    static constexpr float kFlutterHz = 8.3f;

    void prepare(double sampleRate) {
        sr = sampleRate;
        len = (int)(0.025 * sr) + 8;
        for (auto &b : buf) b.assign((size_t)len, 0.f);
        w = 0;
        base = (float)(kBaseSeconds * sr);
    }
    void setDepth(float wowCentsNow, float flutterCentsNow) { wowCents = wowCentsNow; flutterCents = flutterCentsNow; }
    void clear() { for (auto &b : buf) std::fill(b.begin(), b.end(), 0.f); }

    void process(float &l, float &r) {
        // The wow's rate wanders between about 0.45 and 0.75 Hz over 23 s; its depth in cents stays put.
        wander += 1.0 / (23.0 * sr); if (wander >= 1.0) wander -= 1.0;
        const double f = 0.6 + 0.15 * std::sin(2.0 * M_PI * wander);
        wowPh += f / sr; if (wowPh >= 1.0) wowPh -= 1.0;
        flPh += kFlutterHz / sr; if (flPh >= 1.0) flPh -= 1.0;
        const double dWow = (std::exp2(wowCents / 1200.0) - 1.0) / (2.0 * M_PI * f) * sr;
        const double dFl = (std::exp2(flutterCents / 1200.0) - 1.0) / (2.0 * M_PI * kFlutterHz) * sr;
        const float d = base + (float)(dWow * std::sin(2.0 * M_PI * wowPh) + dFl * std::sin(2.0 * M_PI * flPh));
        buf[0][(size_t)w] = l; buf[1][(size_t)w] = r;
        l = read(0, d); r = read(1, d);
        if (++w == len) w = 0;
    }

private:
    float read(int c, float d) const {
        const float whole = std::floor(d), t = d - whole;
        int i0 = w - (int)whole; while (i0 < 0) i0 += len;
        auto at = [&](int i) { while (i < 0) i += len; while (i >= len) i -= len; return buf[c][(size_t)i]; };
        const float xm1 = at(i0 + 1), x0 = at(i0), x1 = at(i0 - 1), x2 = at(i0 - 2);
        // Hermite (Catmull-Rom) between x0 and x1.
        const float c1 = 0.5f * (x1 - xm1), c2 = xm1 - 2.5f * x0 + 2.f * x1 - 0.5f * x2, c3 = 0.5f * (x2 - xm1) + 1.5f * (x0 - x1);
        return ((c3 * t + c2) * t + c1) * t + x0;
    }

    double sr = 48000, wander = 0, wowPh = 0, flPh = 0;
    std::vector<float> buf[2];
    int w = 0, len = 1;
    float base = 0, wowCents = 0, flutterCents = 0;
};

/// The tape's colour: a warm low bump, soft saturation, a top that rolls off with age, and hiss that only
/// breathes while something is playing.
struct TapeSaturator {
    void prepare(double sampleRate) {
        sr = sampleRate;
        gateRelease = (float)std::exp(-1.0 / (0.15 * sr));
        applied = -1;
        setAge(0);
    }
    void setAge(float a) {
        if (std::fabs(a - applied) < 1e-3f) return;
        applied = a;
        const double cutoff = 16000.0 * std::pow(6000.0 / 16000.0, (double)a);
        for (int c = 0; c < 2; ++c) {
            bump[c].setPeak(100.0, 0.7, 2.5 * a, sr);
            top[c].setLowpass(std::min(cutoff, 0.45 * sr), 0.6, sr);
        }
        drive = 1.f + 2.5f * a;
        hiss = a * 0.0005f;   // −66 dBFS at age 1
    }
    void process(float &l, float &r) {
        const float level = std::fmax(std::fabs(l), std::fabs(r));
        gate = level > gate ? level : gate * gateRelease;
        const float h = hiss * std::fmin(1.f, gate * 200.f);
        float *io[2] = {&l, &r};
        for (int c = 0; c < 2; ++c) {
            float x = bump[c].process(*io[c]);
            x = softSat(x * drive) / drive;
            x += h * hissTone[c].process(rng.bipolar());
            *io[c] = top[c].process(x);
        }
    }
    void clear() { for (int c = 0; c < 2; ++c) { bump[c].clear(); top[c].clear(); hissTone[c].clear(); } gate = 0; }

    TapeSaturator() { for (auto &t : hissTone) t.a = 0.3f; }

private:
    double sr = 48000;
    Biquad bump[2], top[2];
    OnePole hissTone[2];
    FastRandom rng{0x7A9E5EEDULL};
    float drive = 1, hiss = 0, gate = 0, gateRelease = 0, applied = -1;
};

} // namespace isd
