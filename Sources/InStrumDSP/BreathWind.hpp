// The breath-wind core: one voice of a jet-driven flute, light enough for eight at once. Header-only; the bore is
// sized once (prepare(), from an engine's constructor) and nothing allocates while playing.
//
// How it sounds. A breath source (white noise through a 1–4 kHz band, shaped by the breath envelope) blows across
// a bore. The bore is a waveguide one period long, read at a continuous length (3rd-order Lagrange), so bends glide
// without a retrigger, closed into a loop through the jet and the open end:
//
//     bore ──► jet (a band-pass at the note) ──► × gain ──► soft cubic ──► open end (low-pass) ──┬──► bore
//                         breath turbulence ──────────────────┘                                  └──► radiation ──► tone
//
// The jet's band-pass hears the note's own mode, so the bore never jumps an octave. The soft cubic, offset like a
// jet striking off the edge, locks the oscillation and gives it the even harmonics a flute has; how far it swings
// sets how rich the tone is. The open end's low-pass is the reflection filter: lower is darker (a player's meri),
// higher brighter (kari). The bore is shortened by that filter's phase delay at the note, so the tone is in tune at
// any cutoff (the band-pass has no phase at its centre). The radiation stage (a first-order high-pass, its corner
// half the note … four times it, normalised at the note) tilts the tone up the way an open end radiates its upper
// harmonics, and keeps DC (the jet's offset makes some) out of the tone; a player's face baffles it.
//
// A gentle level control (the jet's gain follows the swing the breath asks for, between minGain and maxGain times
// the oscillation's threshold) brings the tone in as the breath rises past the threshold, holds it steady, lets it
// go as the breath falls, and never lets the self-oscillation run away (the cubic saturates at ±2/3 besides). While
// the swing is far from what is asked the jet listens loosely (a low Q: the tone grows and fades quickly, even on
// low notes); once it is there, tightly (a high Q: steady, in tune). Neither moves the pitch.
//
// Two outputs per voice: the tone (the locked oscillation) and the air (the un-locked breath noise). Below the
// threshold breath the bore only rings with air, so a note begins as air and becomes tone, and soft notes (a low
// breath) are mostly air. The jet's offset pulls the pitch a hair flat as it swings; the shape's pullCents puts it
// back (measured for the shape: under 1.5 cents at full swing for the defaults).
//
// API, per voice (see ZenShakuhachi for a whole instrument):
//   Shape                       the instrument's constants: the jet's selectivity (loose, locked) and offset, its
//                               swing at full tone, the breath threshold and tone curve, the breath band, the
//                               turbulence, the level control's range. Purer (an ocarina): less offset and swing;
//                               breathier (a pan flute): more turbulence and a higher threshold.
//   prepare(sr, lowestHz, s)    once, at construction: sizes the bore for the lowest pitch it will be asked for.
//   start(seed)                 a new note: clears the bore (the breath starts from 0).
//   Control                     per block: hz (bends included), breath 0…1 at the block's end (ramped inside),
//                               reflectionHz, drive (× the shape's swing), offset (× the jet's offset), radiation
//                               0…1, turbulence (× the shape's), airShift (× the breath band's centre).
//   render(c, n, tone, air)     adds n ≤ 64 samples of tone and air (the air already shaped by the breath).
//   swing(), breath()           the jet's current swing (how much tone is sounding) and the breath.
//   toneAmount(shape, breath)   how much of the full tone a breath asks for (0 below the threshold).
#pragma once
#include "DSPCommon.hpp"
#include <algorithm>
#include <cmath>
#include <vector>

namespace isd {

class BreathWind {
public:
    struct Shape {
        float jetQLocked = 10.f;   // the jet's selectivity once the tone is steady: higher is steadier and purer
        float jetQLoose = 3.f;     // and while it grows or fades: lower is quicker
        float jetOffset = 0.6f;    // the jet's offset from the edge (0 centred): even harmonics
        float swing = 0.95f;       // the jet's swing (the cubic's input amplitude) at full tone: richness
        float threshold = 0.25f;   // breath below this sounds air only
        float toneCurve = 1.5f;    // the tone follows ((breath − threshold) / (1 − threshold)) to this power
        float airHz = 2000.f, airQ = 0.667f;   // the breath band (1–4 kHz)
        float turbulence = 0.12f;  // breath noise into the jet at full breath (pitch and level jitter)
        float minGain = 0.5f, maxGain = 2.5f;  // the level control's range, × the oscillation's threshold
        float pullCents = 1.2f;    // the jet's flat pull at full swing (measured), put back in proportion
    };

    struct Control {
        float hz = 440.f;            // the sounding pitch, bends included
        float breath = 0.f;          // 0…1 at the end of this block (ramped from the last block's)
        float reflectionHz = 5000.f; // the open end's low-pass
        float drive = 1.f;           // × the shape's swing (meri softens the jet)
        float offset = 1.f;          // × the shape's jet offset (meri turns the jet into the bore: fewer even harmonics)
        float radiation = 1.f;       // 0 the bore's own wave … 1 radiated (+6 dB per octave up to four times the note)
        float turbulence = 1.f;      // × the shape's turbulence (0 for a clean tone)
        float airShift = 1.f;        // × the breath band's centre (meri muffles the breath)
    };

    static float toneAmount(const Shape &s, float breath) {
        const float x = clamp01((breath - s.threshold) / (1.f - s.threshold));
        return x > 0.f ? std::pow(x, s.toneCurve) : 0.f;
    }

    void prepare(double sampleRate, float lowestHz, const Shape &s) {
        sr = sampleRate;
        shape = s;
        minHz = std::max(20.f, lowestHz);
        maxHz = (float)(0.2 * sr);
        int need = (int)std::ceil(sr / minHz) + 8, size = 64;
        while (size < need) size <<= 1;
        bore.assign((size_t)size, 0.f);
        mask = size - 1;
        lnMin = std::log(shape.minGain);
        lnMax = std::log(shape.maxGain);
    }

    /// A new note: the bore is cleared; the jet is seeded once the breath first passes the threshold.
    void start(uint64_t seed) {
        rng = FastRandom(seed);
        std::fill(bore.begin(), bore.end(), 0.f);
        w = 0;
        jet.clear(); refl.clear(); airBP.clear();
        reflHz = -1; airHzNow = -1;
        env = 0; integ = 0; lnc = lnMin; radX = radY = 0;
        breathNow = 0;
        seeded = false; first = true;
    }

    /// Adds n samples (n ≤ 64) of tone and air.
    void render(const Control &c, int n, float *tone, float *air) {
        const float fs = (float)sr;
        const float b1 = clamp01(c.breath);
        const float want = shape.swing * std::max(0.f, c.drive) * toneAmount(shape, b1);
        const float offset = std::clamp(shape.jetOffset * c.offset, 0.f, 0.9f);
        const float offsetOut = cubic(offset), offsetSlope = 1.f - offset * offset;
        // The jet's flat pull grows with its swing and offset; put it back.
        const float sw = shape.swing > 0.f ? std::min(1.5f, want / shape.swing) : 0.f;
        const float pull = shape.jetOffset > 0.f ? offset / shape.jetOffset : 0.f;
        const float hz = std::clamp(c.hz * std::exp2(shape.pullCents * pull * sw * std::sqrt(sw) / 1200.f), minHz, maxHz);
        const double w0 = 2.0 * M_PI * hz / sr;
        // The open end, and its response at the note: the bore is shortened by its phase delay.
        const float rhz = std::clamp(c.reflectionHz, 300.f, 0.4f * fs);
        if (std::fabs(rhz - reflHz) > 0.25f) { reflHz = rhz; refl.setLowpass(rhz, 0.7071, sr); }
        float mag = 1, tau = 0;
        response(refl, w0, mag, tau);
        const float period = fs / hz;
        const float targetD = std::max(2.f, period - tau);
        // The breath band (muffled under meri).
        const float ahz = std::clamp(shape.airHz * c.airShift, 200.f, 0.4f * fs);
        if (std::fabs(ahz - airHzNow) > 1.f) { airHzNow = ahz; airBP.setBandpass(ahz, shape.airQ, sr); }

        // Level control: the jet's swing against the swing this breath asks for (none below the threshold).
        const float have = gNow * std::sqrt(2.f * env);
        const float err = std::log((want + 1e-5f) / (have + 1e-5f));
        const float cycles = (float)n / period;
        if (std::fabs(err) < 0.5f) integ = std::clamp(integ + kI * err * cycles, -0.1f, lnMax);
        lnc = std::clamp(integ + kP * err, lnMin, lnMax);
        // The jet listens tightly once the swing is where the breath wants it, loosely while it travels.
        const float lock = std::exp(-err * err * 4.f);
        jet.setBandpass(hz, shape.jetQLoose + (shape.jetQLocked - shape.jetQLoose) * lock, sr);
        const float gTarget = std::exp(lnc) / (offsetSlope * mag);
        // Radiation: a one-pole high-pass, a (y + x − x′), with its corner at 0.5…4 × the note and unity gain at the note.
        const float corner = hz * (0.5f + 3.5f * clamp01(c.radiation));
        const float radA = std::exp(-kTwoPi * std::min(corner, 0.45f * fs) / fs);
        const double pr = 1.0 - radA * std::cos(w0), pi = radA * std::sin(w0);
        const float radG = (float)(std::sqrt(pr * pr + pi * pi) / (radA * 2.0 * std::sin(0.5 * w0)));

        if (first) { dNow = targetD; gNow = gTarget; first = false; }
        // The first breath past the threshold: one period of the note in the bore, for the jet to lock onto.
        if (!seeded && want > 0.f) {
            seeded = true;
            const int len = std::min(mask - 4, (int)targetD);
            for (int k = 0; k < len; ++k) bore[(size_t)((w - len + k) & mask)] += kSeed * (float)std::sin(w0 * k);
        }
        const float inv = 1.f / (float)n;
        const float dD = (targetD - dNow) * inv, dG = (gTarget - gNow) * inv, dB = (b1 - breathNow) * inv;
        const float envA = 1.f - std::exp(-1.f / (2.f * period));
        const float turb = shape.turbulence * std::max(0.f, c.turbulence);

        float d = dNow, g = gNow, b = breathNow, e = env, hx = radX, hy = radY;
        for (int t = 0; t < n; ++t) {
            d += dD; g += dG; b += dB;
            const float br = airBP.process(rng.bipolar()) * b;
            const float s = jet.process(read(d));
            e += (s * s - e) * envA;
            const float r = refl.process(cubic(g * s + turb * br + offset) - offsetOut);
            bore[(size_t)w] = r;
            w = (w + 1) & mask;
            hy = radA * (hy + r - hx);   // y[n] = a (y[n−1] + x[n] − x[n−1])
            hx = r;
            tone[t] += radG * hy;
            air[t] += br;
        }
        dNow = targetD; gNow = gTarget; breathNow = b1; env = e; radX = hx; radY = hy;
    }

    /// The jet's current swing: how much tone is sounding.
    float swing() const { return gNow * std::sqrt(2.f * env); }
    float breath() const { return breathNow; }

private:
    /// x − x³/3 within ±1, ±2/3 beyond: a smooth (C1) saturation.
    static float cubic(float x) {
        if (x >= 1.f) return 2.f / 3.f;
        if (x <= -1.f) return -2.f / 3.f;
        return x - x * x * x * (1.f / 3.f);
    }

    /// A biquad's gain and phase delay (samples) at ω.
    static void response(const Biquad &f, double w0, float &mag, float &tau) {
        const double c1 = std::cos(w0), s1 = std::sin(w0), c2 = std::cos(2 * w0), s2 = std::sin(2 * w0);
        const double nr = f.b0 + f.b1 * c1 + f.b2 * c2, ni = -(f.b1 * s1 + f.b2 * s2);
        const double dr = 1.0 + f.a1 * c1 + f.a2 * c2, di = -(f.a1 * s1 + f.a2 * s2);
        const double den = dr * dr + di * di, hr = (nr * dr + ni * di) / den, hi = (ni * dr - nr * di) / den;
        mag = (float)std::sqrt(hr * hr + hi * hi);
        tau = (float)(-std::atan2(hi, hr) / w0);
    }

    /// The bore at a continuous delay d ≥ 2 samples (the last sample written is at delay 1): Lagrange, 3rd order.
    float read(float d) const {
        const int i = (int)d - 1;
        const float f = d - (float)i, f1 = f - 1.f, f2 = f - 2.f, f3 = f - 3.f;
        const float h0 = -f1 * f2 * f3 * (1.f / 6.f), h1 = f * f2 * f3 * 0.5f;
        const float h2 = -f * f1 * f3 * 0.5f, h3 = f * f1 * f2 * (1.f / 6.f);
        const int p = w - i;
        return h0 * bore[(size_t)(p & mask)] + h1 * bore[(size_t)((p - 1) & mask)]
             + h2 * bore[(size_t)((p - 2) & mask)] + h3 * bore[(size_t)((p - 3) & mask)];
    }

    static constexpr float kP = 0.4f;     // the level control's proportional part (per error in log swing)
    static constexpr float kI = 0.03f;    // and its slow trim, per cycle
    static constexpr float kSeed = 0.02f; // the period of the note the jet first locks onto

    double sr = 48000;
    Shape shape;
    std::vector<float> bore;
    int mask = 63, w = 0;
    Biquad jet, refl, airBP;
    FastRandom rng;
    float minHz = 20, maxHz = 9600;
    float reflHz = -1, airHzNow = -1;
    float env = 0, integ = 0, lnc = 0, lnMin = 0, lnMax = 0;
    float dNow = 2, gNow = 0, breathNow = 0, radX = 0, radY = 0;
    bool seeded = false, first = true;
};

} // namespace isd
