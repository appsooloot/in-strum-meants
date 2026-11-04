// The plucked-string core: the strings of Tea House Koto, and of the harps and guitars after it. Header-only;
// nothing here allocates after construction (`PluckedString::allocate` is called from the engine's constructor).
//
// PluckedString — one string. A fractional-delay loop at the string's period (a 3rd-order Lagrange read, so the
//   length glides continuously and a bend or a vibrato never retriggers), a one-pole loss filter inside the loop
//   (its cutoff is the material: dark silk … bright steel; its gain gives the fundamental the note's T60) and a
//   first-order dispersion allpass (a little inharmonicity: the upper partials run slightly sharp). The loop is in
//   tune exactly: both filters' phase delays at the fundamental come off the delay line's length.
//   A pluck injects one period of a burst into the loop: the derivative of a plucked string's triangle (a box
//   `position` of the way along, minus its mean: a pick-position comb on an integrated impulse), so plucking near
//   the bridge brightens the upper partials while the fundamental keeps its level; the plectrum's hardness is a
//   two-pole low-pass on the burst, and a little differenced noise gives each pluck its own grain.
//     allocate(sr, lowestHz)      once, at construction: storage for the longest period that will be asked for
//     reset()                     a fresh, silent string
//     tune(hz, t60, cutoffHz, dispersion)
//                                 a new note: snaps the length (call before `pluck`). `t60` is the fundamental's
//                                 decay in seconds, `dispersion` the allpass coefficient's size (0 … 0.9)
//     pluck(position, amplitude, hardnessHz, noise, seed)
//                                 starts a pluck (it adds to whatever is ringing). `position` 0…1 from the
//                                 bridge; `amplitude` the fundamental's peak (negative: plucked the other way);
//                                 `hardnessHz` the plectrum's low-pass; `noise` 0…1 of grain
//     glide(hz, n)                the pitch at the end of the next `n` samples: the delay ramps there sample by
//                                 sample (bends, presses, vibrato), the decay stays the same in seconds
//     setDecay(t60)               a new decay for the fundamental without touching the pitch (damping, release)
//     render(out, n)              adds `n` samples into `out`
//     level / plucking()          a 60 ms peak follower of the output; whether a pluck's burst is still going in
// SympatheticBank<N> — open strings ringing in sympathy: up to N complex phasor resonators (each open string's first
//   partials), driven by a mono mix (an engine's voices at about −30 dB) and rung with a long decay, panned per
//   string. Unity gain at resonance, so only what the mix holds near an open string's partials rings it.
//     setString(k, hz, pan, partials, weights, t60, sr)   tune open string k (any time: phase-continuous)
//     setDrive(k, partials, gain) / quiet(k, partials)     a played string is that open string: gate it, still it
//     render(mono, l, r, n, inGain, outFrom, outTo)   drives with mono × inGain, adds the ring × out (ramped)
//     energy() / clear()
// ModalBody<N> — a small modal body: N band-pass resonators (the soundboard's low modes, constant 0 dB peaks
//   scaled by their levels) over the voices' mono sum, plus a thump (a damped low sine kicked on hard plucks).
//     setMode(k, hz, q, level, sr), setThump(hz, t60, sr), kick(amplitude), process(x) → the body's sound, clear()
#pragma once
#include "DSPCommon.hpp"
#include <algorithm>
#include <cmath>
#include <cstring>
#include <vector>

namespace isd {

struct PluckedString {
    std::vector<float> buf;
    int mask = 0, w = 0;
    double sr = 48000;
    float level = 0;             // peak follower of the output (60 ms), for stealing and pruning

    void allocate(double sampleRate, float lowestHz) {
        sr = sampleRate;
        const int need = (int)std::ceil(sr / (double)std::max(lowestHz, 1.f)) + 8;
        int size = 64;
        while (size < need) size <<= 1;
        buf.assign((size_t)size, 0.f);
        mask = size - 1;
        levelCoef = (float)std::exp(-1.0 / (0.06 * sr));
        reset();
    }

    void reset() {
        std::fill(buf.begin(), buf.end(), 0.f);
        w = 0;
        lossZ = apX = apY = 0.f;
        exPos = exEnd = exLen = exWidth = 0;
        exZ1 = exZ2 = exPrev = 0.f;
        level = 0.f;
        delayStep = 0.f;
    }

    void tune(float hz, float t60, float cutoffHz, float dispersion) {
        t60s = std::max(t60, 0.01f);
        const float fc = std::min(cutoffHz, 0.45f * (float)sr);
        lossA = std::exp(-kTwoPi * fc / (float)sr);
        apC = -std::clamp(dispersion, 0.f, 0.9f);
        filters(hz);
        delay = targetDelay(hz);
        delayStep = 0.f;
        hzNow = hz;
    }

    void pluck(float position, float amplitude, float hardnessHz, float noise, uint64_t seed) {
        exLen = std::max(2, (int)std::lround((float)sr / hzNow));
        exWidth = std::clamp((int)std::lround(position * (float)exLen), 1, exLen - 1);
        const float b = (float)exWidth / (float)exLen;
        // The box's first harmonic is (hi − lo)·2·sin(πb)/π: scale so the fundamental is `amplitude`.
        const float s = amplitude * kPi / (2.f * std::max(std::sin(kPi * b), 1e-3f));
        exHi = s * (1.f - b);
        exLo = -s * b;
        exNoise = std::max(noise, 0.f) * amplitude;
        exK = 1.f - std::exp(-kTwoPi * std::min(hardnessHz, 0.45f * (float)sr) / (float)sr);
        exPos = 0;
        exEnd = exLen + std::max(64, (int)(14.f / exK));   // and the hardness filter's tail, until it has run out
        exPrev = 0.f;
        rng = FastRandom(seed);
    }

    void glide(float hz, int n) {
        if (n <= 0) return;
        if (std::fabs(hz - filterHz) > 0.005f * filterHz) filters(hz);
        delayStep = (targetDelay(hz) - delay) / (float)n;
        hzNow = hz;
    }

    void setDecay(float t60) { t60s = std::max(t60, 0.01f); filters(filterHz); }

    bool plucking() const { return exPos < exEnd; }
    float pitchHz() const { return hzNow; }

    void render(float *out, int n) {
        float *b = buf.data();
        const int m = mask;
        int wi = w;
        float d = delay, lz = lossZ, ax = apX, ay = apY, lv = level;
        const float step = delayStep, a = lossA, bLoss = 1.f - lossA, g = lossG, c = apC, lc = levelCoef;
        // Lagrange coefficients for a fractional part f: taps at i−1, i, i+1, i+2 samples ago.
        auto read = [&](float dd) {
            const float fl = std::floor(dd);
            const int i = (int)fl;
            const float f = dd - fl, fm1 = f - 1.f, fm2 = f - 2.f, fp1 = f + 1.f;
            const float h0 = -f * fm1 * fm2 * (1.f / 6.f), h1 = fp1 * fm1 * fm2 * 0.5f;
            const float h2 = -fp1 * f * fm2 * 0.5f, h3 = fp1 * f * fm1 * (1.f / 6.f);
            const int r0 = wi - i + 1;
            return h0 * b[r0 & m] + h1 * b[(r0 - 1) & m] + h2 * b[(r0 - 2) & m] + h3 * b[(r0 - 3) & m];
        };
        for (int t = 0; t < n; ++t) {
            d += step;
            const float y = read(d);
            const float ap = c * y + ax - c * ay;
            ax = y; ay = ap;
            lz = a * lz + bLoss * ap;
            float v = g * lz;
            if (exPos < exEnd) v += excitation();
            b[wi] = v;
            wi = (wi + 1) & m;
            out[t] += v;
            lv = std::max(std::fabs(v), lv * lc);
        }
        w = wi; delay = d; lossZ = lz; apX = ax; apY = ay; level = lv;
        delayStep = 0.f;   // a glide lasts one block; the next block's glide sets the next ramp
    }

private:
    float hzNow = 440, filterHz = 440, t60s = 1;
    float delay = 2, delayStep = 0, filterDelay = 0;
    float lossA = 0, lossG = 0, lossZ = 0;
    float apC = 0, apX = 0, apY = 0;
    float levelCoef = 0.9997f;
    int exPos = 0, exEnd = 0, exLen = 0, exWidth = 0;
    float exHi = 0, exLo = 0, exNoise = 0, exK = 1, exZ1 = 0, exZ2 = 0, exPrev = 0;
    FastRandom rng;

    /// The filters' phase delays at `hz` and the loop gain that gives the fundamental its T60 there.
    void filters(float hz) {
        hz = std::clamp(hz, 1.f, 0.45f * (float)sr);
        const float w0 = kTwoPi * hz / (float)sr, cw = std::cos(w0), sw = std::sin(w0);
        const float a = lossA, c = apC;
        const float mag = (1.f - a) / std::sqrt(std::max(1e-12f, 1.f - 2.f * a * cw + a * a));   // DC gain 1
        const float tauLoss = std::atan2(a * sw, 1.f - a * cw) / w0;
        const float tauAp = -(std::atan2(-sw, c + cw) - std::atan2(-c * sw, 1.f + c * cw)) / w0;
        filterDelay = tauLoss + tauAp;
        const float perPeriod = std::exp(-6.9077553f / (t60s * hz));   // 10^(−3 / (T60 · f0))
        lossG = std::min(perPeriod / std::max(mag, 1e-6f), 0.99995f);  // never above unity at DC
        filterHz = hz;
    }

    float targetDelay(float hz) const {
        const float d = (float)sr / std::max(hz, 1.f) - filterDelay;
        return std::clamp(d, 2.f, (float)(mask - 4));
    }

    inline float excitation() {
        float x = 0.f;
        if (exPos < exLen) {
            x = exPos < exWidth ? exHi : exLo;
            const float nz = rng.bipolar();
            x += exNoise * (nz - exPrev);   // differenced: its sum telescopes, so it adds no DC to the loop
            exPrev = nz;
        }
        exZ1 += exK * (x - exZ1);
        exZ2 += exK * (exZ1 - exZ2);
        ++exPos;
        return exZ2;
    }
};

template <int N>
struct SympatheticBank {
    float re[N] = {}, im[N] = {}, cr[N] = {}, ci[N] = {}, hz[N] = {}, rr[N] = {}, wl[N] = {}, wr[N] = {}, in[N] = {}, base[N] = {};
    int used = 0;

    /// Open string `k` (its partials take `partials` slots from k · partials): its pitch, its place (−1 left … +1
    /// right), the fundamental's T60 (upper partials ring shorter) and the partials' output weights.
    void setString(int k, float f0, float pan, int partials, const float *weights, float t60, double sr) {
        const float th = (std::clamp(pan, -1.f, 1.f) + 1.f) * kPi / 4.f, gl = std::cos(th), gr = std::sin(th);
        for (int p = 0; p < partials; ++p) {
            const int i = k * partials + p;
            if (i >= N) return;
            const float f = f0 * (float)(p + 1);
            const bool ok = f < 0.45f * (float)sr;
            const float t = t60 / std::sqrt((float)(p + 1));
            hz[i] = ok ? f : 0.f;
            rr[i] = ok ? std::exp(-6.9077553f / (t * (float)sr)) : 0.f;
            const float wv = ok ? kTwoPi * f / (float)sr : 0.f;
            cr[i] = rr[i] * std::cos(wv); ci[i] = rr[i] * std::sin(wv);
            base[i] = 1.f - rr[i];   // unity gain at resonance
            in[i] = base[i];
            wl[i] = weights[p] * gl; wr[i] = weights[p] * gr;
            used = std::max(used, i + 1);
        }
    }

    void clear() { for (int i = 0; i < N; ++i) re[i] = im[i] = 0.f; }

    /// How much of the mix reaches string `k` (0 while a voice is playing that very string: it is the string).
    void setDrive(int k, int partials, float gain) {
        for (int p = 0; p < partials; ++p) { const int i = k * partials + p; if (i < N) in[i] = base[i] * gain; }
    }

    /// Stops string `k` ringing (a pluck on that string takes its vibration over).
    void quiet(int k, int partials) {
        for (int p = 0; p < partials; ++p) { const int i = k * partials + p; if (i < N) re[i] = im[i] = 0.f; }
    }

    float energy() const {
        float e = 0;
        for (int i = 0; i < used; ++i) e += re[i] * re[i] + im[i] * im[i];
        return e;
    }

    /// Drives every resonator with `mono` × `inGain` and adds its ring into l/r × a gain ramped from `outFrom` to
    /// `outTo` across the block.
    void render(const float *mono, float *l, float *r, int n, float inGain, float outFrom, float outTo) {
        constexpr int kMax = 64;
        float x[kMax], ol[kMax], orr[kMax];
        n = std::min(n, kMax);
        for (int t = 0; t < n; ++t) { x[t] = mono[t] * inGain; ol[t] = orr[t] = 0.f; }
        for (int i = 0; i < used; ++i) {
            float a = re[i], b = im[i];
            const float c = cr[i], s = ci[i], g = in[i], gl = wl[i], gr = wr[i];
            for (int t = 0; t < n; ++t) {
                const float na = a * c - b * s + g * x[t], nb = a * s + b * c;
                a = na; b = nb;
                ol[t] += nb * gl; orr[t] += nb * gr;
            }
            re[i] = a; im[i] = b;
        }
        const float dg = (outTo - outFrom) / (float)n;
        float gain = outFrom;
        for (int t = 0; t < n; ++t) { gain += dg; l[t] += gain * ol[t]; r[t] += gain * orr[t]; }
    }
};

template <int N>
struct ModalBody {
    Biquad bp[N];
    float lv[N] = {};
    float thRe = 0, thIm = 0, thCr = 0, thCi = 0;

    void setMode(int k, float hz, float q, float level, double sr) {
        if (k < 0 || k >= N) return;
        bp[k].setBandpass(std::min(hz, 0.45f * (float)sr), q, sr);
        lv[k] = level;
    }

    void setThump(float hz, float t60, double sr) {
        const float r = std::exp(-6.9077553f / (t60 * (float)sr)), wv = kTwoPi * hz / (float)sr;
        thCr = r * std::cos(wv); thCi = r * std::sin(wv);
    }

    /// A hard pluck knocks the body: a low damped sine starting from zero (no step).
    void kick(float amplitude) { thRe += amplitude; }

    float process(float x) {
        float y = 0;
        for (int k = 0; k < N; ++k) y += lv[k] * bp[k].process(x);
        const float a = thRe * thCr - thIm * thCi, b = thRe * thCi + thIm * thCr;
        thRe = a; thIm = b;
        return y + b;
    }

    bool thumping() const { return thRe * thRe + thIm * thIm > 1e-14f; }

    void clear() {
        for (auto &f : bp) f.clear();
        thRe = thIm = 0.f;
    }
};

} // namespace isd
