// The modal mallet core: a struck bar as up to eight decaying modes, a mallet whose contact time shapes each
// strike's spectrum, strike-point gains from a free-free bar's bending modes, an optional tube resonance and a
// 1 ms contact click. Header-only; nothing allocates. Reef Marimba is its first instrument; Canopy Marimba, Motel
// Vibes, Hammock Pan, Thumb Kalimba, Star Glock, Ombak Bells and Harbour Chimes can reuse it.
//
// API (namespace isd):
//   modal::malletSpectrum(hz, tau)   The spectrum |P(f)| of a half-sine force pulse lasting `tau` seconds,
//                                    normalised to 1 as f → 0: |cos(π f τ)| / |1 − (2 f τ)²|, with the limit π/4
//                                    where 2fτ = 1. A soft mallet (long τ) barely reaches the upper modes.
//   modal::barShape(mode, position)  Bending mode 0, 1 or 2 of a free-free bar at `position` 0 (the centre) … 1 (the
//                                    end), each normalised to its largest swing: tabulated at 9 points for a bar
//                                    undercut to 1 : 3.99 : 10 and interpolated. The second (mode 1) has a node
//                                    at the centre, so a centre strike leaves the double octave silent.
//   ModalBar<N>                      One bar of up to N (4 or 8) modes, each a recursive complex oscillator
//                                    (a decaying phasor, 4 multiplies a sample):
//     setup(sr, f0, modes, count, seed)   The recipe, one Mode per mode: its ratio to f0, its T60 in seconds, its
//                                         gain, and `shape` (0…2: the bending mode whose strike-point gain it takes;
//                                         −1: none). Clears the bar. Modes above 0.45 × sr stay silent. `seed`
//                                         seeds the click's noise, so a bar sounds the same every time.
//     setTube(share, coupling)            A closed tube tuned to f0: a two-pole resonance fed by mode 0 (peak gain
//                                         1, in phase at f0) that rings `share` × as long as mode 0 (0 removes it).
//                                         Coupling the tube shortens mode 0's T60 by the fraction `coupling` (a
//                                         marimba's: share 0.6 and coupling 0.15 with the full tube).
//     tubeLevel(level, snap)              The tube's output gain: live, ramped over the next render (or at once).
//     strike(amplitude, tau, position, click, weight)
//                                         Adds a strike to the running modes, so a ringing bar is never reset (a
//                                         re-strike or a roll builds on it): mode k gains amplitude × gain ×
//                                         barShape(shape, position) × malletSpectrum(f_k, tau) (× weight[k] if
//                                         given). `click` > 0 adds a 1 ms burst of noise, low-passed where the same
//                                         spectrum falls (0.59 / τ, its −3 dB point), at about that RMS level.
//     setFine(ratio)                      Retunes every mode and the tube by `ratio`, phase-continuously.
//     damp(t60)                           Shortens every mode that rings longer than `t60` (a damper, a hand).
//     render(out, n)                      Adds the next n samples into `out`.
//     energy(), clicking()                What is still ringing (for stealing and pruning); the click in progress.
// Cost: N × 4 multiplies a sample for the modes, 5 more for the tube.
#pragma once
#include "DSPCommon.hpp"
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>

namespace isd {

namespace modal {

/// |P(f)| of a half-sine force pulse of contact time `tau` seconds, 1 as f → 0.
inline float malletSpectrum(float hz, float tau) {
    const float x = 2.f * std::fabs(hz) * std::max(tau, 0.f);
    // cos(πx/2) and 1 − x² both vanish at x = 1: their ratio there tends to (π/2) / (1 + x).
    if (std::fabs(1.f - x) < 1e-3f) return 0.5f * kPi / (1.f + x);
    return std::fabs(std::cos(0.5f * kPi * x)) / std::fabs(1.f - x * x);
}

/// The first three free-free bending modes of a bar undercut to 1 : 3.99 : 10 (a flat-bottomed parabolic
/// cut 57% deep over the middle 49% of its length, solved as an Euler–Bernoulli beam), from the centre (0) to the
/// end (1) in eighths, each normalised to its largest swing. Nodes: mode 0 at 0.59 (20% of the length from the end,
/// where the cord runs); mode 1 at the centre and 0.72; mode 2 at 0.27 and 0.79.
constexpr float kBarShape[3][9] = {
    {1.0000f, 0.9384f, 0.7591f, 0.5023f, 0.2189f, -0.0718f, -0.3665f, -0.6632f, -0.9606f},
    {0.0000f, 0.6551f, 0.9863f, 0.9168f, 0.6482f, 0.3075f, -0.0796f, -0.4934f, -0.9163f},
    {1.0000f, 0.6876f, 0.0608f, -0.3229f, -0.4003f, -0.3114f, -0.0891f, 0.2209f, 0.5628f},
};

/// Bending mode `mode` (0…2) at `position` 0 (centre) … 1 (end), interpolated; 1 for any other mode.
inline float barShape(int mode, float position) {
    if (mode < 0 || mode > 2) return 1.f;
    const float p = clamp01(position) * 8.f;
    const int i = std::min(7, (int)p);
    const float f = p - (float)i;
    return kBarShape[mode][i] + f * (kBarShape[mode][i + 1] - kBarShape[mode][i]);
}

} // namespace modal

template <int N>
struct ModalBar {
    static_assert(N == 4 || N == 8, "a bar has 4 or 8 mode lanes");

    struct Mode {
        float ratio = 0, t60 = 1, gain = 0;
        int shape = -1;
    };

    void setup(double sampleRate, float fundamentalHz, const Mode *modes, int count, uint64_t seed = 1) {
        sr = sampleRate;
        f0 = fundamentalHz;
        fine = 1.f;
        const double nyquist = 0.45 * sr;
        for (int k = 0; k < N; ++k) {
            const bool used = k < count && modes[k].gain != 0.f && modes[k].ratio > 0.f;
            const double hz = used ? (double)f0 * (double)modes[k].ratio : 0.0;
            freq[k] = (float)hz;
            gain[k] = used && hz < nyquist ? modes[k].gain : 0.f;
            shape[k] = used ? modes[k].shape : -1;
            t60[k] = std::max(used ? modes[k].t60 : 1.f, 1e-3f);
            radius[k] = gain[k] != 0.f ? decay(t60[k]) : 0.f;
            re[k] = im[k] = 0.f;
        }
        hasTube = false;
        tubeNow = tubeTarget = 0.f;
        tr = ti = 0.f;
        clickLeft = 0;
        clickLP.clear();
        noise = FastRandom(seed ? seed : 1);
        retune();
    }

    void setTube(float share, float coupling = 0.f) {
        hasTube = share > 0.f;
        tr = ti = 0.f;
        const float coupled = t60[0] * (1.f - clamp01(coupling));
        if (gain[0] != 0.f) radius[0] = decay(coupled);
        tubeRadius = hasTube ? decay(share * coupled) : 0.f;
        retune();
    }

    void tubeLevel(float level, bool snap = false) {
        tubeTarget = hasTube ? std::max(0.f, level) : 0.f;
        if (snap) tubeNow = tubeTarget;
    }

    void setFine(float ratio) {
        fine = ratio;
        retune();
    }

    void strike(float amplitude, float tau, float position, float click = 0.f, const float *weight = nullptr) {
        for (int k = 0; k < N; ++k) {
            if (gain[k] == 0.f) continue;
            float g = amplitude * gain[k] * modal::barShape(shape[k], position) * modal::malletSpectrum(freq[k] * fine, tau);
            if (weight) g *= weight[k];
            re[k] += g;   // an impulse: a sine starting from the bar's present state, so nothing jumps
        }
        if (click > 0.f) {
            clickLen = std::max(1, (int)(0.001 * sr));
            clickLeft = clickLen;
            const float fc = std::min(0.59f / std::max(tau, 1e-5f), 0.45f * (float)sr);
            clickLP.clear();
            clickLP.setLowpass(fc, 0.7071, sr);
            // Unit-RMS noise through the low-pass keeps about 2fc/sr of its power: make the burst's RMS `click`.
            clickAmp = click * 1.7320508f / std::sqrt(std::min(1.f, 2.f * fc / (float)sr));
        }
    }

    void damp(float seconds) {
        const float rd = decay(seconds);
        for (int k = 0; k < N; ++k)
            if (radius[k] > rd) { const float s = rd / radius[k]; cr[k] *= s; ci[k] *= s; radius[k] = rd; t60[k] = seconds; }
    }

    void render(float *out, int n) {
        // Four modes to a vector (SSE on Intel, NEON on arm64), summed in a fixed order.
        constexpr int C = N / 4;
        Lane r[C], i[C], c[C], s[C];
        for (int k = 0; k < C; ++k) {
            std::memcpy(&r[k], re + 4 * k, sizeof(Lane)); std::memcpy(&i[k], im + 4 * k, sizeof(Lane));
            std::memcpy(&c[k], cr + 4 * k, sizeof(Lane)); std::memcpy(&s[k], ci + 4 * k, sizeof(Lane));
        }
        const bool tube = hasTube && (tubeNow > 0.f || tubeTarget > 0.f);
        if (!tube) {
            for (int t = 0; t < n; ++t) {
                Lane sum = r[0] * s[0] + i[0] * c[0];
                r[0] = r[0] * c[0] - i[0] * s[0]; i[0] = sum;
                for (int k = 1; k < C; ++k) {
                    const Lane b = r[k] * s[k] + i[k] * c[k];
                    r[k] = r[k] * c[k] - i[k] * s[k]; i[k] = b;
                    sum += b;
                }
                out[t] += (sum[0] + sum[2]) + (sum[1] + sum[3]);
            }
            tr = ti = 0.f;
            tubeNow = 0.f;
        } else {
            float zr = tr, zi = ti, g = tubeNow;
            const float dg = (tubeTarget - tubeNow) / (float)std::max(1, n);
            for (int t = 0; t < n; ++t) {
                Lane sum = r[0] * s[0] + i[0] * c[0];
                r[0] = r[0] * c[0] - i[0] * s[0]; i[0] = sum;
                for (int k = 1; k < C; ++k) {
                    const Lane b = r[k] * s[k] + i[k] * c[k];
                    r[k] = r[k] * c[k] - i[k] * s[k]; i[k] = b;
                    sum += b;
                }
                // The tube: a complex one-pole at f0 driven by mode 0; its real part is the two-pole resonance.
                const float a = zr * tcr - zi * tci + tb * i[0][0], b = zr * tci + zi * tcr;
                zr = a; zi = b;
                g += dg;
                out[t] += ((sum[0] + sum[2]) + (sum[1] + sum[3])) + g * zr;
            }
            tr = zr; ti = zi; tubeNow = tubeTarget;
        }
        for (int k = 0; k < C; ++k) { std::memcpy(re + 4 * k, &r[k], sizeof(Lane)); std::memcpy(im + 4 * k, &i[k], sizeof(Lane)); }
        if (clickLeft > 0) {
            const int m = std::min(n, clickLeft);
            for (int t = 0; t < m; ++t) {
                const int age = clickLen - clickLeft;
                const float w = std::sin(kPi * ((float)age + 0.5f) / (float)clickLen);
                out[t] += clickLP.process(noise.bipolar() * clickAmp * w * w);
                --clickLeft;
            }
        }
    }

    float energy() const {
        float e = 0.f;
        for (int k = 0; k < N; ++k) e += re[k] * re[k] + im[k] * im[k];
        if (hasTube) e += tubeNow * tubeNow * (tr * tr + ti * ti);
        return e;
    }

    bool clicking() const { return clickLeft > 0; }

    void clear() {
        for (int k = 0; k < N; ++k) re[k] = im[k] = 0.f;
        tr = ti = 0.f;
        clickLeft = 0;
        clickLP.clear();
    }

private:
    typedef float Lane __attribute__((vector_size(16)));

    /// The per-sample decay that takes `seconds` to fall 60 dB.
    float decay(float seconds) const { return (float)std::pow(10.0, -3.0 / ((double)std::max(seconds, 1e-3f) * sr)); }

    void retune() {
        const double nyquist = 0.45 * sr;
        for (int k = 0; k < N; ++k) {
            if (gain[k] == 0.f) { cr[k] = ci[k] = 0.f; continue; }
            const double w = 2.0 * M_PI * std::min((double)freq[k] * fine, nyquist) / sr;
            cr[k] = radius[k] * (float)std::cos(w);
            ci[k] = radius[k] * (float)std::sin(w);
        }
        if (hasTube) {
            const double w = 2.0 * M_PI * std::min((double)f0 * fine, nyquist) / sr;
            tcr = tubeRadius * (float)std::cos(w);
            tci = tubeRadius * (float)std::sin(w);
            // Driven at f0 the one-pole's gain is tb / (1 − r) for the half of a real input at +f0: peak gain 1.
            tb = 2.f * (1.f - tubeRadius);
        }
    }

    double sr = 48000.0;
    float f0 = 0.f, fine = 1.f;
    float freq[N] = {}, t60[N] = {}, radius[N] = {}, gain[N] = {};
    int shape[N] = {};
    alignas(16) float re[N] = {}, im[N] = {}, cr[N] = {}, ci[N] = {};
    // The tube.
    bool hasTube = false;
    float tubeRadius = 0.f, tcr = 0.f, tci = 0.f, tb = 0.f, tr = 0.f, ti = 0.f, tubeNow = 0.f, tubeTarget = 0.f;
    // The click.
    int clickLeft = 0, clickLen = 1;
    float clickAmp = 0.f;
    Biquad clickLP;
    FastRandom noise;
};

} // namespace isd
