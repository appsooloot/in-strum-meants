#include "Ambience.hpp"
#include <algorithm>
#include <cmath>

namespace isd {

namespace amb {

constexpr float kRampSeconds = 2.5f;

// Level calibration: continuous sources sit near −24 dBFS RMS at level 1 (closeness 0.5, room included);
// rare events (owl, chime, ticks) are set by ear-safe peak levels. See AmbienceTests.
const float kGain[ISD_AMB_COUNT] = {
    /* water */ 0.475f, /* crickets */ 0.50f, /* breeze */ 0.427f, /* owl */ 0.05f, /* rain on water */ 0.617f, /* rain on glass */ 0.708f,
    /* dawn chorus */ 0.60f, /* ship hum */ 0.0845f, /* air flow */ 0.363f, /* chime */ 0.0525f, /* hull ticks */ 0.15f, /* wind */ 0.257f,
    /* surf */ 0.54f, /* palms */ 0.92f, /* gulls */ 0.06f, /* road */ 0.19f, /* engine */ 0.36f, /* window wind */ 0.61f, /* passing car */ 0.30f,
};

/// sin(2πx) for x in cycles (any value). 9th-order odd polynomial after folding: error ≈ 2e-6.
inline float sin2pi(float x) {
    x -= std::floor(x);
    x -= 0.5f;
    float y = x > 0.25f ? 0.5f - x : (x < -0.25f ? -0.5f - x : x);
    float z = y * kTwoPi, z2 = z * z;
    float s = z * (1.f + z2 * (-1.f / 6.f + z2 * (1.f / 120.f + z2 * (-1.f / 5040.f + z2 * (1.f / 362880.f)))));
    return -s;
}

/// Topology-preserving state-variable filter (safe to retune while it rings). Band output has unity peak gain.
struct SVF {
    float ic1 = 0, ic2 = 0, a1 = 1, a2 = 0, a3 = 0, k = 1;
    void set(float hz, float q, float sr) {
        float g = std::tan(kPi * std::clamp(hz, 10.f, 0.45f * sr) / sr);
        k = 1.f / q;
        a1 = 1.f / (1.f + g * (g + k)); a2 = g * a1; a3 = g * a2;
    }
    inline void tick(float x, float &lp, float &bp, float &hp) {
        float v3 = x - ic2, v1 = a1 * ic1 + a2 * v3, v2 = ic2 + a2 * ic1 + a3 * v3;
        ic1 = 2.f * v1 - ic1; ic2 = 2.f * v2 - ic2;
        lp = v2; bp = k * v1; hp = x - k * v1 - v2;
    }
    inline float low(float x) { float l, b, h; tick(x, l, b, h); return l; }
    inline float band(float x) { float l, b, h; tick(x, l, b, h); return b; }
    inline float high(float x) { float l, b, h; tick(x, l, b, h); return h; }
    void clear() { ic1 = ic2 = 0; }
};

/// Paul Kellet's economy pink filter on white input.
struct Pink {
    float b0 = 0, b1 = 0, b2 = 0;
    inline float next(float w) {
        b0 = 0.99765f * b0 + w * 0.0990460f; b1 = 0.96300f * b1 + w * 0.2965164f; b2 = 0.57000f * b2 + w * 1.0526913f;
        return (b0 + b1 + b2 + w * 0.1848f) * 0.25f;
    }
};

/// Leaky integrator: brown-ish noise.
struct Brown { float y = 0; inline float next(float w) { y = 0.997f * y + 0.03f * w; return y; } };

/// A smooth random value in 0…1 that wanders to a new target every `seconds`.
struct Wander {
    float a = 0.5f, b = 0.5f, t = 1;
    float next(FastRandom &r, float dt, float seconds) {
        t += dt / seconds;
        if (t >= 1.f) { t -= std::floor(t); a = b; b = r.uniform(); }
        float s = t * t * (3.f - 2.f * t);
        return a + (b - a) * s;
    }
};

/// A decaying complex phasor (one sine partial).
struct Partial {
    float re = 0, im = 0, cr = 1, ci = 0, mag = 0;
    void start(float hz, float t60, float amp, float sr) {
        float r = t60 > 0 ? std::pow(10.f, -3.f / (t60 * sr)) : 1.f, w = kTwoPi * hz / sr;
        cr = r * std::cos(w); ci = r * std::sin(w); re = 0; im = amp; mag = amp;
    }
    inline float next() { float nr = re * cr - im * ci, ni = re * ci + im * cr; re = nr; im = ni; return ni; }
    float energy() const { return re * re + im * im; }
    /// For undamped partials: pull rounding drift back to the starting amplitude.
    void renorm() { float m = std::sqrt(energy()); if (m > 0) { float s = mag / m; re *= s; im *= s; } }
};

inline void panGains(float pan, float &gl, float &gr) {
    float th = (std::clamp(pan, -1.f, 1.f) + 1.f) * kPi / 4.f;
    gl = std::cos(th); gr = std::sin(th);
}

inline float expRand(FastRandom &r) { return -std::log(std::max(1e-6f, r.uniform())); }

// ---------------------------------------------------------------- Water lapping
class Water final : public AmbienceSource {
    FastRandom rng;
    Pink pinkL, pinkR, pinkBody, pinkFL, pinkFR;
    SVF sloshL, sloshR, foamL, foamR, body, topL, topR;
    struct Wave { bool on = false; float t = 0, rise = 1, fall = 2, amp = 1; } waves[4];
    float nextWave = 0, nextPlip = 0, env = 0;
    struct Plip { bool on = false; float ph = 0, f = 1000, t = 0, dur = 0.03f, amp = 0, gl = 0.7f, gr = 0.7f; } plips[8];

public:
    explicit Water(uint64_t seed) : rng(seed) { direct = 1.f; send = 0.5f; }
    void wake(const AmbienceContext &) override { nextWave = 0.1f; nextPlip = 0.4f + rng.uniform(); }
    void render(float *l, float *r, int n, const AmbienceContext &c) override {
        const float dt = (float)n / c.sr;
        if ((nextWave -= dt) <= 0) {
            for (auto &w : waves) if (!w.on) { w = {true, 0, 0.5f + 0.6f * rng.uniform(), 1.2f + 1.4f * rng.uniform(), 0.6f + 0.4f * rng.uniform()}; break; }
            nextWave = 1.8f + 2.7f * rng.uniform();
        }
        float target = 0;
        for (auto &w : waves) {
            if (!w.on) continue;
            w.t += dt;
            float v;
            if (w.t < w.rise) { float s = std::sin(0.5f * kPi * w.t / w.rise); v = s * s; }
            else if (w.t < w.rise + w.fall) v = 0.5f + 0.5f * std::cos(kPi * (w.t - w.rise) / w.fall);
            else { w.on = false; v = 0; }
            target += w.amp * v;
        }
        target = std::min(1.2f, target);
        sloshL.set(300.f + 800.f * target, 0.8f, c.sr); sloshR.set(320.f + 760.f * target, 0.8f, c.sr);
        foamL.set(1200.f, 1.5f, c.sr); foamR.set(1300.f, 1.5f, c.sr); body.set(180.f, 0.7f, c.sr);
        topL.set(2500.f, 0.7f, c.sr); topR.set(2500.f, 0.7f, c.sr);   // a calm lake doesn't hiss
        if ((nextPlip -= dt) <= 0) {
            for (auto &p : plips) if (!p.on) {
                p.on = true; p.ph = 0; p.t = 0; p.f = 600.f * std::pow(3.f, rng.uniform()); p.dur = 0.015f + 0.025f * rng.uniform();
                p.amp = 0.08f + 0.17f * rng.uniform(); panGains(0.6f * rng.bipolar(), p.gl, p.gr);
                break;
            }
            nextPlip = (0.3f + 2.2f * rng.uniform()) / c.density;
        }
        const float de = (target - env) / (float)n;
        for (int t = 0; t < n; ++t) {
            env += de;
            const float wl = rng.bipolar(), wr = rng.bipolar();
            const float a = 0.25f + 0.75f * env, foam = 0.3f * env * env;
            const float b = 0.2f * body.low(pinkBody.next(rng.bipolar()));
            l[t] += topL.low(a * sloshL.band(pinkL.next(wl)) + 2.f * foam * foamL.band(pinkFL.next(wl))) + b;
            r[t] += topR.low(a * sloshR.band(pinkR.next(wr)) + 2.f * foam * foamR.band(pinkFR.next(wr))) + b;
        }
        for (auto &p : plips) {
            if (!p.on) continue;
            const float invSr = 1.f / c.sr, decay = std::pow(0.01f, invSr / p.dur);
            for (int t = 0; t < n; ++t) {
                const float u = p.t / p.dur, att = std::min(1.f, p.t * 333.f);
                const float x = p.amp * att * sin2pi(p.ph);
                p.ph += p.f * (1.f + 0.5f * u) * invSr;
                p.amp *= decay;
                p.t += invSr;
                l[t] += x * p.gl; r[t] += x * p.gr;
            }
            if (p.t > 3.f * p.dur) p.on = false;
        }
    }
};

// ---------------------------------------------------------------- Crickets
class Crickets final : public AmbienceSource {
    FastRandom rng;
    static constexpr float kPulse = 0.018f, kPeriod = 0.032f;
    struct Chirper {
        float f = 4600, gl = 0.7f, gr = 0.7f, gain = 1, period = 0.7f, ph = 0;
        int pulses = 4, chirpsLeft = 10;
        float next = 0, t = -1;   // t ≥ 0 while chirping
    } ch[5];

public:
    explicit Crickets(uint64_t seed) : rng(seed) {
        direct = 1.f; send = 0.4f;
        const float pans[5] = {-0.8f, -0.35f, 0.1f, 0.5f, 0.85f};
        for (int i = 0; i < 5; ++i) {
            auto &c = ch[i];
            c.f = 4200.f + 1000.f * rng.uniform();
            panGains(pans[i], c.gl, c.gr);
            c.gain = 0.5f + 0.5f * rng.uniform();
            c.period = 0.55f + 0.35f * rng.uniform();
            c.pulses = 3 + (int)(rng.uniform() * 2.99f);
        }
    }
    void wake(const AmbienceContext &) override {
        for (auto &c : ch) { c.next = 0.1f + c.period * rng.uniform(); c.t = -1; c.chirpsLeft = 8 + (int)(12 * rng.uniform()); }
    }
    void render(float *l, float *r, int n, const AmbienceContext &cx) override {
        const float dt = (float)n / cx.sr, invSr = 1.f / cx.sr, rate = cx.density * (1.f - 0.4f * cx.cool);
        for (auto &c : ch) {
            if (c.t < 0) {
                if ((c.next -= dt) > 0) continue;
                c.t = 0; c.ph = 0;
                if (--c.chirpsLeft <= 0) { c.chirpsLeft = 8 + (int)(12 * rng.uniform()); c.next = 1.5f + 3.5f * rng.uniform(); }
                else c.next = c.period * (0.92f + 0.16f * rng.uniform()) / rate;
                c.next -= dt;
            }
            const float len = (float)c.pulses * kPeriod;
            for (int t = 0; t < n && c.t < len; ++t) {
                const int k = (int)(c.t / kPeriod);
                const float u = (c.t - (float)k * kPeriod) / kPulse;
                if (u < 1.f) {
                    float e = std::sin(kPi * u); e *= e;
                    const float x = c.gain * e * (sin2pi(c.ph) + 0.12f * sin2pi(2.f * c.ph));
                    l[t] += x * c.gl; r[t] += x * c.gr;
                    c.ph += c.f * (1.f - 0.02f * u) * invSr;
                }
                c.t += invSr;
            }
            if (c.t >= len) c.t = -1;
        }
    }
};

// ---------------------------------------------------------------- Breeze
class Breeze final : public AmbienceSource {
    FastRandom rng;
    Pink pinkL, pinkR;
    SVF bl, br, rhl, rhr, rll, rlr;
    Wander centre, amp, rustle;
    float a = 0.8f, ru = 0;

public:
    explicit Breeze(uint64_t seed) : rng(seed) { direct = 1.f; send = 0.3f; }
    void render(float *l, float *r, int n, const AmbienceContext &c) override {
        const float dt = (float)n / c.sr;
        const float cf = 350.f + 750.f * centre.next(rng, dt, 6.f);
        const float a1 = 0.6f + 0.4f * amp.next(rng, dt, 8.f), ru1 = 0.15f * a1 * a1 * rustle.next(rng, dt, 4.f);
        bl.set(cf, 0.6f, c.sr); br.set(cf * 1.07f, 0.6f, c.sr);
        rhl.set(2000.f, 0.7f, c.sr); rhr.set(2100.f, 0.7f, c.sr); rll.set(5000.f, 0.7f, c.sr); rlr.set(5200.f, 0.7f, c.sr);
        const float da = (a1 - a) / (float)n, dr = (ru1 - ru) / (float)n;
        for (int t = 0; t < n; ++t) {
            a += da; ru += dr;
            const float wl = rng.bipolar(), wr = rng.bipolar();
            l[t] += a * bl.band(pinkL.next(wl)) + ru * rll.low(rhl.high(wl));
            r[t] += a * br.band(pinkR.next(wr)) + ru * rlr.low(rhr.high(wr));
        }
    }
};

// ---------------------------------------------------------------- Wind (with gusts)
class Wind final : public AmbienceSource {
    FastRandom rng;
    Pink pinkL, pinkR, pinkW;
    Brown brownL, brownR;
    SVF bl, br, whistle;
    Wander drift, tone;
    struct Gust { bool on = false; float t = 0, rise = 1, fall = 3, amp = 1; } gusts[3];
    float nextGust = 0, g = 0;

public:
    explicit Wind(uint64_t seed) : rng(seed) { direct = 1.f; send = 0.3f; }
    void wake(const AmbienceContext &) override { nextGust = 1.f + 3.f * rng.uniform(); }
    void render(float *l, float *r, int n, const AmbienceContext &c) override {
        const float dt = (float)n / c.sr;
        if ((nextGust -= dt) <= 0) {
            for (auto &q : gusts) if (!q.on) { q = {true, 0, 1.f + rng.uniform(), 2.f + 2.f * rng.uniform(), 0.5f + 0.5f * rng.uniform()}; break; }
            nextGust = (4.f + 8.f * rng.uniform()) / c.density;
        }
        float target = 0;
        for (auto &q : gusts) {
            if (!q.on) continue;
            q.t += dt;
            float v;
            if (q.t < q.rise) { float s = std::sin(0.5f * kPi * q.t / q.rise); v = s * s; }
            else if (q.t < q.rise + q.fall) v = 0.5f + 0.5f * std::cos(kPi * (q.t - q.rise) / q.fall);
            else { q.on = false; v = 0; }
            target += q.amp * v;
        }
        target = std::min(1.f, target);
        const float cf = (180.f + 100.f * drift.next(rng, dt, 7.f)) * (1.f + 0.8f * target);
        bl.set(cf, 0.9f, c.sr); br.set(cf * 1.08f, 0.9f, c.sr);
        whistle.set(700.f + 400.f * tone.next(rng, dt, 5.f), 12.f, c.sr);
        const float dg = (target - g) / (float)n;
        for (int t = 0; t < n; ++t) {
            g += dg;
            const float a = 0.4f + 0.9f * g, wh = 0.25f * g * g;
            const float wl = rng.bipolar(), wr = rng.bipolar();
            const float w = wh * whistle.band(pinkW.next(rng.bipolar()));
            l[t] += a * bl.band(brownL.next(wl) * 4.f + pinkL.next(wl)) + w;
            r[t] += a * br.band(brownR.next(wr) * 4.f + pinkR.next(wr)) + w;
        }
    }
};

// ---------------------------------------------------------------- Owl (distant two-note call)
class Owl final : public AmbienceSource {
    FastRandom rng;
    SVF breath, distance;
    float next = 0, t = -1, base = 380, ph = 0, gl = 0.7f, gr = 0.7f;
    static constexpr float kStart2 = 0.72f, kDur1 = 0.42f, kDur2 = 0.6f;

public:
    explicit Owl(uint64_t seed) : rng(seed) { direct = 0.35f; send = 1.f; }
    void wake(const AmbienceContext &) override { next = 10.f + 30.f * rng.uniform(); t = -1; }
    void render(float *l, float *r, int n, const AmbienceContext &c) override {
        const float dt = (float)n / c.sr, invSr = 1.f / c.sr;
        if (t < 0) {
            if ((next -= dt) > 0) return;
            t = 0; ph = 0; base = 360.f + 40.f * rng.uniform();
            panGains(0.4f * rng.bipolar(), gl, gr);
            next = (54.f + 72.f * rng.uniform()) / c.density;
            breath.set(base, 6.f, c.sr); distance.set(1500.f, 0.7f, c.sr);
        }
        for (int s = 0; s < n && t >= 0; ++s) {
            float f = 0, env = 0, vib = 0, tn = 0, dur = 1;
            if (t < kDur1) { tn = t; dur = kDur1; f = base; vib = 0.004f; }
            else if (t >= kStart2 && t < kStart2 + kDur2) { tn = t - kStart2; dur = kDur2; f = base * 0.895f; vib = 0.012f; }
            if (f > 0) {
                env = std::min(1.f, tn / 0.06f);
                env = env * env * (3.f - 2.f * env);
                const float rel = (dur - tn) / 0.15f;
                if (rel < 1.f) env *= rel * rel * (3.f - 2.f * rel);
                const float freq = f * (1.f - 0.03f * tn / dur) * (1.f + vib * sin2pi(5.5f * tn));
                ph += freq * invSr;
                const float tone = sin2pi(ph) + 0.12f * sin2pi(2.f * ph) + 0.04f * sin2pi(3.f * ph);
                const float x = distance.low(env * (tone + 0.6f * breath.band(rng.bipolar())));
                l[s] += x * gl; r[s] += x * gr;
            } else {
                const float x = distance.low(0.f);
                l[s] += x * gl; r[s] += x * gr;
            }
            t += invSr;
            if (t > kStart2 + kDur2 + 0.05f) t = -1;
        }
    }
};

// ---------------------------------------------------------------- Rain (on water or on glass)
class Rain final : public AmbienceSource {
    FastRandom rng;
    bool glass;
    struct Res { SVF f; float gl = 0.7f, gr = 0.7f; int life = 0; } res[8];
    int nextRes = 0;
    SVF bedAL, bedAR, bedBL, bedBR;
    Wander swell;
    float a = 1, dropRate;

public:
    Rain(uint64_t seed, bool onGlass, float sr) : rng(seed), glass(onGlass) {
        direct = 1.f; send = 0.4f;
        dropRate = onGlass ? 220.f : 350.f;
        if (glass) { bedAL.set(1800.f, 0.6f, sr); bedAR.set(1900.f, 0.6f, sr); bedBL.set(9000.f, 0.7f, sr); bedBR.set(9200.f, 0.7f, sr); }
        else { bedAL.set(1600.f, 0.5f, sr); bedAR.set(1700.f, 0.5f, sr); bedBL.set(6000.f, 0.7f, sr); bedBR.set(6200.f, 0.7f, sr); }
    }
    void render(float *l, float *r, int n, const AmbienceContext &c) override {
        const float dt = (float)n / c.sr, p = dropRate * c.density / c.sr;
        const float a1 = 0.85f + 0.3f * swell.next(rng, dt, 5.f), da = (a1 - a) / (float)n;
        const int ring = (int)(0.06f * c.sr);
        for (int t = 0; t < n; ++t) {
            a += da;
            const float wl = rng.bipolar(), wr = rng.bipolar();
            float il = 0, ir = 0;
            if (rng.uniform() < p) {
                const float amp = 0.2f + 0.8f * rng.uniform() * rng.uniform();
                float pl, pr;
                panGains(0.9f * rng.bipolar(), pl, pr);
                il = 3.f * amp * pl; ir = 3.f * amp * pr;   // the splash itself, through the bed filters
                if (glass || rng.uniform() < 0.35f) {
                    Res &q = res[nextRes]; nextRes = (nextRes + 1) & 7;
                    const float f = glass ? 2500.f * std::pow(2.8f, rng.uniform()) : 900.f * std::pow(3.9f, rng.uniform());
                    q.f.set(f, glass ? 8.f : 25.f, c.sr);
                    q.gl = pl * amp; q.gr = pr * amp; q.life = ring;
                    float lo, bp, hi; q.f.tick(glass ? 6.f : 12.f, lo, bp, hi);
                }
            }
            float yl = 0, yr = 0;
            for (auto &q : res) {
                if (q.life <= 0) continue;
                --q.life;
                const float y = q.f.band(0.f);
                yl += y * q.gl; yr += y * q.gr;
            }
            const float bl = bedBL.low(glass ? bedAL.high(0.35f * wl + il) : bedAL.band(0.5f * wl + il));
            const float br = bedBR.low(glass ? bedAR.high(0.35f * wr + ir) : bedAR.band(0.5f * wr + ir));
            l[t] += a * bl + yl;
            r[t] += a * br + yr;
        }
    }
};

// ---------------------------------------------------------------- Dawn chorus
class DawnChorus final : public AmbienceSource {
    FastRandom rng;
    struct Syllable { float start, dur, f0, f1, fmRate, fmDepth, amp; };
    struct Bird {
        int type = 0, count = 0, cur = 0;
        Syllable s[12];
        float t = -1, next = 0, ph = 0, gl = 0.7f, gr = 0.7f, gain = 1;
    } birds[4];

    void phrase(Bird &b) {
        float at = 0;
        const float u = rng.uniform();
        switch (b.type) {
        case 0: {   // whistle: two to four gliding notes
            b.count = 2 + (int)(u * 2.99f);
            for (int i = 0; i < b.count; ++i) {
                const float d = 0.12f + 0.13f * rng.uniform(), f0 = 2600.f + 1000.f * rng.uniform();
                b.s[i] = {at, d, f0, f0 * (0.85f + 0.4f * rng.uniform()), 0, 0, 0.8f + 0.2f * rng.uniform()};
                at += d + 0.06f + 0.09f * rng.uniform();
            }
            break;
        }
        case 1: {   // trill
            b.count = 6 + (int)(u * 6.99f);
            const float f0 = 4200.f + 800.f * rng.uniform();
            for (int i = 0; i < b.count; ++i) { b.s[i] = {at, 0.035f, f0, f0 * 0.8f, 0, 0, 0.7f + 0.3f * (float)(i % 2)}; at += 0.06f; }
            break;
        }
        case 2: {   // warble
            b.count = 1;
            const float f0 = 3200.f + 1000.f * rng.uniform();
            b.s[0] = {0, 0.6f + 0.5f * u, f0, f0 * 1.05f, 22.f + 16.f * rng.uniform(), 250.f + 200.f * rng.uniform(), 0.7f};
            break;
        }
        default: {  // chips
            b.count = 3 + (int)(u * 2.99f);
            const float f0 = 5000.f + 1000.f * rng.uniform();
            for (int i = 0; i < b.count; ++i) { b.s[i] = {at, 0.02f, f0, f0 * 0.9f, 0, 0, 0.6f}; at += 0.11f + 0.04f * rng.uniform(); }
            break;
        }
        }
        b.cur = 0; b.t = 0; b.ph = 0;
    }

public:
    explicit DawnChorus(uint64_t seed) : rng(seed) {
        direct = 0.9f; send = 0.6f;
        const float pans[4] = {-0.7f, -0.2f, 0.3f, 0.75f};
        for (int i = 0; i < 4; ++i) { birds[i].type = i; panGains(pans[i], birds[i].gl, birds[i].gr); birds[i].gain = 0.5f + 0.5f * rng.uniform(); }
    }
    void wake(const AmbienceContext &) override { for (auto &b : birds) { b.t = -1; b.next = 0.1f + 1.5f * rng.uniform(); } }
    void render(float *l, float *r, int n, const AmbienceContext &c) override {
        const float dt = (float)n / c.sr, invSr = 1.f / c.sr;
        for (auto &b : birds) {
            if (b.t < 0) {
                if ((b.next -= dt) > 0) continue;
                phrase(b);
                b.next = (2.5f + 4.5f * rng.uniform()) / c.density;
            }
            for (int t = 0; t < n && b.t >= 0; ++t) {
                while (b.cur < b.count && b.t > b.s[b.cur].start + b.s[b.cur].dur) ++b.cur;
                if (b.cur >= b.count) { b.t = -1; break; }
                const Syllable &s = b.s[b.cur];
                if (b.t >= s.start) {
                    const float u = (b.t - s.start) / s.dur, env = std::sin(kPi * u);
                    const float f = s.f0 + (s.f1 - s.f0) * u + s.fmDepth * sin2pi(s.fmRate * (b.t - s.start));
                    b.ph += f * invSr;
                    const float x = b.gain * s.amp * env * env * sin2pi(b.ph);
                    l[t] += x * b.gl; r[t] += x * b.gr;
                }
                b.t += invSr;
            }
        }
    }
};

// ---------------------------------------------------------------- Ship hum
class ShipHum final : public AmbienceSource {
    FastRandom rng;
    Partial tones[2][6];
    Brown brownL, brownR;
    SVF lowL, lowR;
    Wander level;
    float a = 1;
    int renorm = 0;

public:
    ShipHum(uint64_t seed, float sr) : rng(seed) {
        direct = 1.f; send = 0.15f;
        const float f[3] = {40.f, 80.f, 120.f}, amp[3] = {1.f, 0.6f, 0.35f};
        for (int c = 0; c < 2; ++c)
            for (int h = 0; h < 3; ++h) {
                tones[c][2 * h].start(f[h], 0, amp[h], sr);
                tones[c][2 * h + 1].start(f[h] + 0.1f + 0.2f * rng.uniform(), 0, 0.45f * amp[h], sr);   // gentle beating
            }
        lowL.set(200.f, 0.7f, sr); lowR.set(200.f, 0.7f, sr);
    }
    void render(float *l, float *r, int n, const AmbienceContext &c) override {
        const float dt = (float)n / c.sr, a1 = 0.89f + 0.22f * level.next(rng, dt, 9.f), da = (a1 - a) / (float)n;
        for (int t = 0; t < n; ++t) {
            a += da;
            float hl = 0, hr = 0;
            for (int k = 0; k < 6; ++k) { hl += tones[0][k].next(); hr += tones[1][k].next(); }
            l[t] += a * (hl + 0.35f * lowL.low(brownL.next(rng.bipolar())));
            r[t] += a * (hr + 0.35f * lowR.low(brownR.next(rng.bipolar())));
        }
        if (++renorm >= 64) {   // keep the undamped phasors at their amplitude
            renorm = 0;
            for (auto &ch : tones) for (auto &p : ch) p.renorm();
        }
    }
};

// ---------------------------------------------------------------- Air flow
class AirFlow final : public AmbienceSource {
    FastRandom rng;
    SVF hl, hr, ll, lr;
    Wander level;
    float a = 1;

public:
    AirFlow(uint64_t seed, float sr) : rng(seed) {
        direct = 1.f; send = 0.2f;
        hl.set(300.f, 0.7f, sr); hr.set(310.f, 0.7f, sr); ll.set(3000.f, 0.7f, sr); lr.set(2900.f, 0.7f, sr);
    }
    void render(float *l, float *r, int n, const AmbienceContext &c) override {
        const float dt = (float)n / c.sr, a1 = 0.92f + 0.16f * level.next(rng, dt, 7.f), da = (a1 - a) / (float)n;
        for (int t = 0; t < n; ++t) {
            a += da;
            l[t] += a * ll.low(hl.high(rng.bipolar()));
            r[t] += a * lr.low(hr.high(rng.bipolar()));
        }
    }
};

// ---------------------------------------------------------------- Chime (a rare soft bell on the Glass partials)
class Chime final : public AmbienceSource {
    FastRandom rng;
    static constexpr float kRatio[6] = {1.f, 2.32f, 4.25f, 6.63f, 9.38f, 12.5f};
    static constexpr float kAmp[6] = {1.f, 0.55f, 0.35f, 0.22f, 0.14f, 0.09f};
    static constexpr float kNotes[6] = {622.25f, 698.46f, 783.99f, 932.33f, 1046.5f, 1244.5f};   // E♭ major pentatonic
    struct Bell { bool on = false; Partial p[6]; float gl = 0.7f, gr = 0.7f; int attack = 0, attackLen = 1; int check = 0; } bells[4];
    float next = 0, second = -1;

    void strike(const AmbienceContext &c) {
        for (auto &b : bells) {
            if (b.on) continue;
            const float f0 = kNotes[(int)(rng.uniform() * 5.99f)], v = 0.6f + 0.4f * rng.uniform();
            for (int i = 0; i < 6; ++i)
                b.p[i].start(f0 * kRatio[i] * std::exp2((2.f * rng.bipolar()) / 1200.f), 6.f / (1.f + 0.6f * (float)i), v * kAmp[i], c.sr);
            panGains(0.5f * rng.bipolar(), b.gl, b.gr);
            b.on = true; b.attack = 0; b.attackLen = (int)((0.002f + 0.002f * rng.uniform()) * c.sr);
            return;
        }
    }

public:
    explicit Chime(uint64_t seed) : rng(seed) { direct = 0.8f; send = 0.8f; }
    void wake(const AmbienceContext &) override { next = 15.f + 35.f * rng.uniform(); second = -1; }
    void render(float *l, float *r, int n, const AmbienceContext &c) override {
        const float dt = (float)n / c.sr;
        if ((next -= dt) <= 0) {
            strike(c);
            next = (80.f + 80.f * rng.uniform()) / c.density;
            if (rng.uniform() < 0.3f) second = 0.3f + 0.5f * rng.uniform();
        }
        if (second >= 0 && (second -= dt) < 0) strike(c);
        for (auto &b : bells) {
            if (!b.on) continue;
            for (int t = 0; t < n; ++t) {
                float x = 0;
                for (auto &p : b.p) x += p.next();
                if (b.attack < b.attackLen) { const float u = (float)b.attack++ / (float)b.attackLen; x *= u * u * (3.f - 2.f * u); }
                l[t] += x * b.gl; r[t] += x * b.gr;
            }
            if (++b.check >= 16) {
                b.check = 0;
                float e = 0;
                for (auto &p : b.p) e += p.energy();
                if (e < 1e-10f) b.on = false;
            }
        }
    }
};

// ---------------------------------------------------------------- Hull ticks
class HullTicks final : public AmbienceSource {
    FastRandom rng;
    struct Tick { bool on = false; Partial a, b; float gl = 0.7f, gr = 0.7f; int left = 0; } ticks[4];
    float next = 0, cluster[2] = {-1, -1};

    void tick(const AmbienceContext &c) {
        for (auto &k : ticks) {
            if (k.on) continue;
            const float f = 1800.f + 2700.f * rng.uniform(), t60 = 0.004f + 0.004f * rng.uniform(), amp = 0.5f + 0.5f * rng.uniform();
            k.a.start(f, t60, amp, c.sr);
            k.b.start(f * 2.7f, t60 * 0.6f, 0.4f * amp, c.sr);
            panGains(0.8f * rng.bipolar(), k.gl, k.gr);
            k.on = true; k.left = (int)(t60 * 1.5f * c.sr) + 1;
            return;
        }
    }

public:
    explicit HullTicks(uint64_t seed) : rng(seed) { direct = 0.9f; send = 0.7f; }
    void wake(const AmbienceContext &) override { next = 3.f + 12.f * rng.uniform(); cluster[0] = cluster[1] = -1; }
    void render(float *l, float *r, int n, const AmbienceContext &c) override {
        const float dt = (float)n / c.sr;
        if ((next -= dt) <= 0) {
            tick(c);
            next = (6.f + 19.f * rng.uniform()) / c.density;
            if (rng.uniform() < 0.4f) {
                cluster[0] = 0.08f + 0.22f * rng.uniform();
                cluster[1] = rng.uniform() < 0.5f ? cluster[0] + 0.08f + 0.22f * rng.uniform() : -1;
            }
        }
        for (auto &q : cluster) if (q >= 0 && (q -= dt) < 0) tick(c);
        for (auto &k : ticks) {
            if (!k.on) continue;
            for (int t = 0; t < n && k.left > 0; ++t, --k.left) {
                const float x = k.a.next() + k.b.next();
                l[t] += x * k.gl; r[t] += x * k.gr;
            }
            if (k.left <= 0) k.on = false;
        }
    }
};


// ---------------------------------------------------------------- Surf (waves breaking on the shore)
class Surf final : public AmbienceSource {
    FastRandom rng;
    Pink pinkL, pinkR;
    SVF bedL, bedR, farL, farR, lowCutL, lowCutR;
    float bed = 0.25f, farApplied = -1;
    struct Break {
        bool on = false;
        float t = 0, s = 1, k = 1, thumpPh = 0, gl = 0.7f, gr = 0.7f;
        Pink pl, pr;
        SVF crashL, crashR, washL, washR, fizzL, fizzR;
    } breaks[4];

public:
    explicit Surf(uint64_t seed) : rng(seed) { direct = 1.f; send = 0.4f; }
    void trigger(float strength, float distance) {
        Break *b = nullptr;
        for (auto &x : breaks) if (!x.on) { b = &x; break; }
        if (!b) { b = &breaks[0]; for (auto &x : breaks) if (x.t > b->t) b = &x; }   // the oldest makes room
        b->on = true; b->t = 0; b->s = std::clamp(strength, 0.05f, 1.f); b->k = 1.f + 0.8f * distance; b->thumpPh = 0;
        panGains(0.5f * rng.bipolar(), b->gl, b->gr);
    }
    void render(float *l, float *r, int n, const AmbienceContext &c) override {
        const float fsr = c.sr, dt = (float)n / fsr, invSr = 1.f / fsr, d = c.surfDistance;
        // The bed swells after each wave and settles between them.
        float lively = 0;
        for (auto &b : breaks) if (b.on) lively += b.s * std::exp(-b.t / (2.5f * b.k));
        const float bedTarget = 0.25f + 0.5f * std::min(1.f, lively);
        bed += (bedTarget - bed) * (1.f - std::exp(-dt / 0.8f));
        bedL.set(450.f + 500.f * bed, 0.7f, fsr); bedR.set(480.f + 480.f * bed, 0.7f, fsr);
        if (std::fabs(d - farApplied) > 1e-3f) {
            farApplied = d;
            const float cut = std::exp(std::log(14000.f) * (1.f - d) + std::log(550.f) * d);
            farL.set(cut, 0.7f, fsr); farR.set(cut, 0.7f, fsr);
            lowCutL.set(55.f, 0.7f, fsr); lowCutR.set(55.f, 0.7f, fsr);
        }
        float bl[64], br[64];
        const int m = std::min(n, 64);
        for (int t = 0; t < m; ++t) {
            bl[t] = 0.6f * bed * bedL.low(pinkL.next(rng.bipolar()));
            br[t] = 0.6f * bed * bedR.low(pinkR.next(rng.bipolar()));
        }
        const float fizzKeep = 1.f - 0.85f * d;
        for (auto &b : breaks) {
            if (!b.on) continue;
            const float k = b.k, s = b.s;
            // Crash: a noise burst whose top falls from 2 kHz to 400 Hz over the first half second, and a thump.
            const float crashCut = 400.f + 1600.f * std::exp(-b.t / (0.25f * k));
            b.crashL.set(crashCut, 0.8f, fsr); b.crashR.set(crashCut * 1.05f, 0.8f, fsr);
            b.washL.set(4500.f, 0.7f, fsr); b.washR.set(4800.f, 0.7f, fsr);
            b.fizzL.set(6500.f, 1.5f, fsr); b.fizzR.set(7000.f, 1.5f, fsr);
            const float crashTau = 0.45f * k * (0.6f + 0.8f * s);
            for (int t = 0; t < m; ++t) {
                const float tt = b.t + (float)t * invSr;
                const float crash = s * (tt < 0.03f * k ? tt / (0.03f * k) : std::exp(-(tt - 0.03f * k) / crashTau));
                const float thump = tt < 0.6f * k ? 0.6f * s * std::exp(-tt / (0.12f * k)) * sin2pi(b.thumpPh) : 0.f;
                b.thumpPh += 70.f * invSr;
                // Wash: a bright fizz sliding up the sand, then thinning out.
                const float u = tt - 0.3f * k;
                float wash = 0;
                if (u > 0) {
                    const float up = std::min(1.f, u / (1.5f * k));
                    wash = 0.6f * s * fizzKeep * up * up * (3.f - 2.f * up) * std::max(0.f, u < 1.5f * k ? 1.f : 1.f - (u - 1.5f * k) / (1.5f * k));
                }
                // Backwash: the sand's grains draining back, thinning over three seconds.
                const float v = tt - 2.5f * k;
                float grainL = 0, grainR = 0;
                if (v > 0 && v < 3.f * k) {
                    const float p = 0.06f * (1.f - v / (3.f * k));
                    if (rng.uniform() < p) grainL = rng.bipolar();
                    if (rng.uniform() < p) grainR = rng.bipolar();
                }
                const float wl = rng.bipolar(), wr = rng.bipolar();
                const float xl = crash * b.crashL.low(b.pl.next(wl)) * 1.6f + thump
                               + wash * b.washL.band(wl) + 0.35f * s * fizzKeep * b.fizzL.band(grainL);
                const float xr = crash * b.crashR.low(b.pr.next(wr)) * 1.6f + thump
                               + wash * b.washR.band(wr) + 0.35f * s * fizzKeep * b.fizzR.band(grainR);
                bl[t] += xl * b.gl * 1.41f;
                br[t] += xr * b.gr * 1.41f;
            }
            b.t += (float)m * invSr;
            if (b.t > 6.f * k) b.on = false;
        }
        // Below the surf's own thump there's only rumble the ear doesn't place as sea.
        for (int t = 0; t < m; ++t) { l[t] += farL.low(lowCutL.high(bl[t])); r[t] += farR.low(lowCutR.high(br[t])); }
    }
};

// ---------------------------------------------------------------- Palm fronds
class Palms final : public AmbienceSource {
    FastRandom rng;
    Wander gust;
    SVF bedL, bedR;
    struct Grain { bool on = false; float t = 0, dur = 0.01f, amp = 0, gl = 0.7f, gr = 0.7f; SVF bp; } grains[24];
    float nextGrain = 0;

public:
    explicit Palms(uint64_t seed) : rng(seed) { direct = 1.f; send = 0.35f; }
    void render(float *l, float *r, int n, const AmbienceContext &c) override {
        const float fsr = c.sr, dt = (float)n / fsr, invSr = 1.f / fsr;
        const float g = gust.next(rng, dt, 2.5f);
        bedL.set(3200.f, 0.8f, fsr); bedR.set(3500.f, 0.8f, fsr);
        const float bedAmp = 0.12f + 0.3f * g;
        for (int t = 0; t < n; ++t) { l[t] += bedAmp * bedL.band(rng.bipolar()); r[t] += bedAmp * bedR.band(rng.bipolar()); }
        // Clatter: dry fronds knocking, more of them in each gust.
        if ((nextGrain -= dt) <= 0) {
            for (auto &q : grains) if (!q.on) {
                q.on = true; q.t = 0; q.dur = 0.005f + 0.025f * rng.uniform(); q.amp = (0.3f + 0.7f * rng.uniform()) * (0.4f + 0.6f * g);
                q.bp.set(2000.f + 4000.f * rng.uniform(), 2.f, fsr); panGains(0.8f * rng.bipolar(), q.gl, q.gr);
                break;
            }
            nextGrain = expRand(rng) / (40.f * (0.3f + 0.7f * g) * c.density);
        }
        for (auto &q : grains) {
            if (!q.on) continue;
            for (int t = 0; t < n; ++t) {
                const float e = q.amp * std::exp(-q.t / q.dur);
                const float x = e * q.bp.band(rng.bipolar());
                l[t] += x * q.gl; r[t] += x * q.gr;
                q.t += invSr;
            }
            if (q.t > 6.f * q.dur) q.on = false;
        }
    }
};

// ---------------------------------------------------------------- Gulls (rare and distant)
class Gulls final : public AmbienceSource {
    FastRandom rng;
    SVF formantL, formantR, topL, topR;
    float nextCall = 3;
    struct Cry { bool on = false; float t = -1, dur = 0.4f, f1 = 1300, ph = 0, amp = 0.6f, gl = 0.7f, gr = 0.7f, rough = 0; } cries[4];

public:
    explicit Gulls(uint64_t seed) : rng(seed) { direct = 0.6f; send = 0.9f; }
    void wake(const AmbienceContext &) override { nextCall = 2.f + 4.f * rng.uniform(); }
    void render(float *l, float *r, int n, const AmbienceContext &c) override {
        const float fsr = c.sr, dt = (float)n / fsr, invSr = 1.f / fsr;
        formantL.set(1600.f, 2.f, fsr); formantR.set(1650.f, 2.f, fsr); topL.set(4000.f, 0.7f, fsr); topR.set(4000.f, 0.7f, fsr);
        if ((nextCall -= dt) <= 0) {
            const int count = 2 + (int)(rng.uniform() * 2.99f);
            float pan = 0.7f * rng.bipolar(), at = 0;
            const float f1 = 1100.f + 400.f * rng.uniform();
            for (int i = 0; i < count && i < 4; ++i) {
                Cry &q = cries[i];
                q.on = true; q.t = -at; q.dur = 0.35f + 0.15f * rng.uniform(); q.f1 = f1 * (0.95f + 0.1f * rng.uniform());
                q.ph = 0; q.amp = (0.5f + 0.5f * rng.uniform()) * (i == 0 ? 1.f : 0.8f); q.rough = rng.uniform();
                panGains(pan, q.gl, q.gr);
                at += 0.45f + 0.25f * rng.uniform();
            }
            nextCall = (8.f + 17.f * rng.uniform()) / c.density;
        }
        for (auto &q : cries) {
            if (!q.on) continue;
            for (int t = 0; t < n; ++t) {
                q.t += invSr;
                if (q.t < 0) continue;
                if (q.t > q.dur) { q.on = false; break; }
                const float u = q.t / q.dur;
                const float env = std::min(1.f, q.t / 0.03f) * std::min(1.f, (q.dur - q.t) / 0.08f);
                const float f = q.f1 * (1.f - 0.45f * u * u) * (1.f + 0.03f * sin2pi(25.f * q.t + q.rough));
                q.ph += f * invSr;
                const float x = sin2pi(q.ph) + 0.5f * sin2pi(2.f * q.ph) + 0.3f * sin2pi(3.f * q.ph) + 0.2f * sin2pi(4.f * q.ph);
                const float y = q.amp * env * x;
                l[t] += topL.low(formantL.band(y * q.gl));
                r[t] += topR.low(formantR.band(y * q.gr));
            }
        }
    }
};

// ---------------------------------------------------------------- Road (tyres and expansion joints)
class Road final : public AmbienceSource {
    FastRandom rng;
    Pink pinkL, pinkR;
    Brown brown;
    SVF lpL, lpR, rumble, thumpLP;
    float toJoint = 12, thumpT = 10, thumpGap = 0.1f, thumpPh = 0, thumpAmp = 0;

public:
    explicit Road(uint64_t seed) : rng(seed) { direct = 1.f; send = 0.2f; }
    void render(float *l, float *r, int n, const AmbienceContext &c) override {
        const float fsr = c.sr, dt = (float)n / fsr, invSr = 1.f / fsr, sp = c.speed;
        const float v = 8.f + 22.f * sp;   // metres per second (about 30–110 km/h)
        lpL.set(300.f + 900.f * sp, 0.7f, fsr); lpR.set(320.f + 880.f * sp, 0.7f, fsr);
        rumble.set(90.f, 1.f, fsr); thumpLP.set(400.f, 0.7f, fsr);
        const float level = 0.3f + 0.7f * sp;
        // Joints every ~30 m: a pair of thumps, front then rear wheels.
        if ((toJoint -= v * dt) <= 0) {
            toJoint = 30.f * (0.8f + 0.4f * rng.uniform());
            thumpT = 0; thumpGap = 2.7f / v; thumpAmp = 0.5f * (0.5f + 0.5f * sp);
        }
        for (int t = 0; t < n; ++t) {
            const float tyreL = lpL.low(pinkL.next(rng.bipolar())), tyreR = lpR.low(pinkR.next(rng.bipolar()));
            const float low = 0.5f * rumble.band(brown.next(rng.bipolar()) * 8.f);
            float th = 0;
            if (thumpT < 1.f) {
                for (float at : {0.f, thumpGap}) {
                    const float u = thumpT - at;
                    if (u >= 0 && u < 0.3f) th += thumpAmp * (std::exp(-u / 0.05f) * sin2pi(50.f * u) + 0.6f * std::exp(-u / 0.02f) * thumpLP.low(rng.bipolar()));
                }
                thumpT += invSr;
            }
            l[t] += level * (tyreL + low) + th;
            r[t] += level * (tyreR + low) + th;
        }
    }
};


// ---------------------------------------------------------------- Tone oscillators (engine purr, passing cars)
/// Advances a tone oscillator's phase (in cycles, kept in 0…1 so a float holds it exactly enough: harmonics
/// are whole multiples, so the wrap is seamless) by one sample's increment.
inline void advanceTone(float &ph, float inc) {
    ph += inc;
    if (ph >= 1.f) ph -= 1.f;
}

// ---------------------------------------------------------------- Engine (a soft purr that follows the speed)
class EngineHum final : public AmbienceSource {
    FastRandom rng;
    Wander load;
    SVF top;
    float ph = 0;

public:
    explicit EngineHum(uint64_t seed) : rng(seed) { direct = 1.f; send = 0.15f; }
    void render(float *l, float *r, int n, const AmbienceContext &c) override {
        const float fsr = c.sr, dt = (float)n / fsr, invSr = 1.f / fsr, sp = c.speed;
        const float w = load.next(rng, dt, 2.f);
        const float f = (35.f + 35.f * sp) * (1.f + 0.03f * (w - 0.5f));
        const float level = (0.4f + 0.6f * sp) * (0.9f + 0.2f * w);
        top.set(250.f, 0.7f, fsr);
        for (int t = 0; t < n; ++t) {
            advanceTone(ph, f * invSr);
            float x = 0;
            const float amps[6] = {1.f, 0.7f, 0.25f, 0.4f, 0.12f, 0.15f};   // a four-cylinder's even orders
            for (int k = 0; k < 6; ++k) x += amps[k] * sin2pi((float)(k + 1) * ph);
            const float y = level * top.low(0.3f * x + 0.05f * rng.bipolar());
            l[t] += y; r[t] += y;
        }
    }
};

// ---------------------------------------------------------------- Wind at the window
class WindowWind final : public AmbienceSource {
    FastRandom rng;
    Wander gust;
    SVF rushL, rushR, whistle;

public:
    explicit WindowWind(uint64_t seed) : rng(seed) { direct = 1.f; send = 0.2f; }
    void render(float *l, float *r, int n, const AmbienceContext &c) override {
        const float fsr = c.sr, dt = (float)n / fsr, sp = c.speed;
        const float g = gust.next(rng, dt, 1.7f);
        rushL.set(600.f + 1500.f * sp, 1.2f, fsr); rushR.set(650.f + 1450.f * sp, 1.2f, fsr);
        whistle.set(1800.f + 600.f * sp + 80.f * g, 12.f, fsr);
        const float amp = (0.15f + 0.85f * sp * sp) * (0.8f + 0.4f * g), wh = 0.15f * sp * sp;
        for (int t = 0; t < n; ++t) {
            const float a = rng.bipolar(), b = rng.bipolar();
            const float w = wh * whistle.band(a + b);
            l[t] += amp * rushL.band(a) + w;
            r[t] += amp * rushR.band(b) + 0.8f * w;
        }
    }
};

// ---------------------------------------------------------------- A car passing the other way
class PassingCar final : public AmbienceSource {
    FastRandom rng;
    SVF sweepL, sweepR;
    float nextCar = 6, t = -1, dur = 3, dir = 1, ph = 0;

public:
    explicit PassingCar(uint64_t seed) : rng(seed) { direct = 1.f; send = 0.3f; }
    void wake(const AmbienceContext &) override { nextCar = 4.f + 10.f * rng.uniform(); }
    void render(float *l, float *r, int n, const AmbienceContext &c) override {
        const float fsr = c.sr, dt = (float)n / fsr, invSr = 1.f / fsr;
        if (t < 0 && (nextCar -= dt) <= 0) {
            t = 0; dur = 2.6f + 1.2f * rng.uniform(); dir = rng.uniform() < 0.5f ? -1.f : 1.f;
            nextCar = (15.f + 30.f * rng.uniform()) / c.density;
        }
        if (t < 0) return;
        const float x0 = (t / dur) * 2.f - 1.f;
        const float centre = 1100.f * (1.f - 0.45f * std::tanh(3.f * x0));
        sweepL.set(centre, 1.5f, fsr); sweepR.set(centre * 1.03f, 1.5f, fsr);
        for (int i = 0; i < n; ++i) {
            const float x = (t / dur) * 2.f - 1.f;
            const float env = std::exp(-(x / 0.35f) * (x / 0.35f));
            const float pan = 0.9f * dir * x;
            float gl, gr; panGains(pan, gl, gr);
            advanceTone(ph, 95.f * (1.f - 0.15f * std::tanh(3.f * x)) * invSr);
            const float tone = 0.25f * sin2pi(ph) + 0.1f * sin2pi(2.f * ph);
            const float a = rng.bipolar(), b = rng.bipolar();
            l[i] += env * gl * (sweepL.band(a) + tone);
            r[i] += env * gr * (sweepR.band(b) + tone);
            t += invSr;
        }
        if (t > dur) t = -1;
    }
};

} // namespace amb

using namespace amb;

// ---------------------------------------------------------------- Thunder
class Thunder {
public:
    explicit Thunder(uint64_t seed) : rng(seed) {}
    void trigger(float distance) {
        for (auto &v : voices) {
            if (v.on) continue;
            v.on = true;
            v.d = clamp01(distance);
            v.delay = 0.5f + 5.5f * v.d;
            v.t = -v.delay;
            v.dur = 1.f + 3.f * (0.3f + 0.7f * v.d) * (0.8f + 0.2f * rng.uniform());
            v.level = 1.f - 0.75f * v.d;
            v.rolls = 2 + (int)(rng.uniform() * 2.99f);
            for (int i = 0; i < v.rolls; ++i) {
                v.at[i] = (i == 0 ? 0.f : (0.15f + 0.6f * rng.uniform()) * v.dur);
                v.rise[i] = 0.15f + 0.25f * rng.uniform();
                v.fall[i] = 0.6f + 1.2f * rng.uniform();
                v.amp[i] = i == 0 ? 1.f : 0.5f + 0.5f * rng.uniform();
            }
            v.crack = v.d < 0.3f ? 1.f - v.d / 0.3f : 0.f;
            return;
        }
    }
    bool active() const { for (auto &v : voices) if (v.on) return true; return false; }
    void render(float *l, float *r, int n, float sr) {
        const float invSr = 1.f / sr;
        for (auto &v : voices) {
            if (!v.on) continue;
            const float cut = 200.f - 80.f * v.d;
            v.lowA.set(cut, 0.7f, sr); v.lowB.set(cut, 0.7f, sr); v.crackF.set(900.f, 0.7f, sr);
            for (int t = 0; t < n; ++t) {
                v.t += invSr;
                if (v.t < 0) continue;
                float env = 0;
                for (int i = 0; i < v.rolls; ++i) {
                    const float u = v.t - v.at[i];
                    if (u < 0) continue;
                    if (u < v.rise[i]) { float s = std::sin(0.5f * kPi * u / v.rise[i]); env += v.amp[i] * s * s; }
                    else env += v.amp[i] * std::exp(-(u - v.rise[i]) / v.fall[i] * 2.3f);
                }
                const float rumble = v.lowB.low(v.lowA.low(v.brown.next(rng.bipolar()) * 6.f));
                const float crack = v.crack > 0 ? v.crack * std::exp(-v.t / 0.2f) * v.crackF.band(rng.bipolar()) : 0.f;
                const float x = v.level * (env * rumble + crack);
                l[t] += x; r[t] += x * 0.9f;
                if (v.t > v.dur + 6.f) { v.on = false; break; }
            }
        }
    }

private:
    FastRandom rng;
    struct Voice {
        bool on = false;
        float d = 0.5f, delay = 1, t = 0, dur = 2, level = 1, crack = 0;
        int rolls = 2;
        float at[4] = {}, rise[4] = {}, fall[4] = {}, amp[4] = {};
        Brown brown;
        SVF lowA, lowB, crackF;
    } voices[3];
};

Ambience::Ambience(double sampleRate, uint64_t seed) : sr(sampleRate), room(sampleRate, kBlock) {
    ctx.sr = (float)sampleRate;
    const float fsr = (float)sampleRate;
    auto s = [&](int i) { return seed * 0x9E3779B97F4A7C15ULL + 0x632BE59BD9B4E019ULL * (uint64_t)(i + 1); };
    sources[ISD_AMB_WATER] = std::make_unique<Water>(s(0));
    sources[ISD_AMB_CRICKETS] = std::make_unique<Crickets>(s(1));
    sources[ISD_AMB_BREEZE] = std::make_unique<Breeze>(s(2));
    sources[ISD_AMB_OWL] = std::make_unique<Owl>(s(3));
    sources[ISD_AMB_RAIN_WATER] = std::make_unique<Rain>(s(4), false, fsr);
    sources[ISD_AMB_RAIN_GLASS] = std::make_unique<Rain>(s(5), true, fsr);
    sources[ISD_AMB_DAWN_CHORUS] = std::make_unique<DawnChorus>(s(6));
    sources[ISD_AMB_SHIP_HUM] = std::make_unique<ShipHum>(s(7), fsr);
    sources[ISD_AMB_AIR_FLOW] = std::make_unique<AirFlow>(s(8), fsr);
    sources[ISD_AMB_CHIME] = std::make_unique<Chime>(s(9));
    sources[ISD_AMB_HULL_TICKS] = std::make_unique<HullTicks>(s(10));
    sources[ISD_AMB_WIND] = std::make_unique<Wind>(s(11));
    thunder = std::make_unique<Thunder>(s(12));
    auto surfSource = std::make_unique<Surf>(s(13));
    surf = surfSource.get();
    sources[ISD_AMB_SURF] = std::move(surfSource);
    sources[ISD_AMB_PALMS] = std::make_unique<Palms>(s(14));
    sources[ISD_AMB_GULLS] = std::make_unique<Gulls>(s(15));
    sources[ISD_AMB_ROAD] = std::make_unique<Road>(s(16));
    sources[ISD_AMB_ENGINE] = std::make_unique<EngineHum>(s(17));
    sources[ISD_AMB_WINDOW_WIND] = std::make_unique<WindowWind>(s(18));
    sources[ISD_AMB_PASSING_CAR] = std::make_unique<PassingCar>(s(19));
    closeness.init(sampleRate, 300.0);
    closeness.snap(0.5f);
}

Ambience::~Ambience() = default;

void Ambience::setLevel(int source, float level) {
    if (source < 0 || source >= ISD_AMB_COUNT) return;
    Ramp &r = ramps[source];
    const float v = clamp01(level);
    if (v > 0.f && r.silent()) sources[source]->wake(ctx);
    r.setTarget(v, (int)(kRampSeconds * (float)sr));
}

void Ambience::triggerThunder(float distance) { thunder->trigger(distance); }

void Ambience::triggerWave(float strength) {
    if (ramps[ISD_AMB_SURF].to <= 0.f) return;   // silent, or fading out as the world changes
    surf->trigger(strength, ctx.surfDistance);
}

void Ambience::render(float *left, float *right, int frames) {
    int pos = 0;
    while (pos < frames) {
        const int n = std::min(kBlock, frames - pos);
        processBlock(left + pos, right + pos, n);
        pos += n;
    }
}

void Ambience::processBlock(float *left, float *right, int n) {
    for (int t = 0; t < n; ++t) closeness.next();
    ctx.speed += (speedTarget - ctx.speed) * (1.f - std::exp(-(float)n / (0.5f * (float)sr)));
    const float c = closeness.value;
    if (std::fabs(c - closenessApplied) > 0.005f) {
        closenessApplied = c;
        const float cutoff = 5000.f * std::exp2(2.f * c);   // distant air takes the top off
        const float g = std::tan(kPi * std::min(cutoff, 0.45f * (float)sr) / (float)sr), k = 1.41421356f;
        airA1 = 1.f / (1.f + g * (g + k)); airA2 = g * airA1; airA3 = g * airA2;
        width = 0.75f + 0.5f * c;
        directGain = 0.6f + 0.4f * c;
        roomGain = 0.2f + 0.6f * (1.f - c);
        room.configure(0.25f, 0.5f, 8.f, 0.f);
    }

    float dl[kBlock] = {}, dr[kBlock] = {}, sl[kBlock] = {}, sr2[kBlock] = {};
    float tl[kBlock], tr[kBlock];
    bool any = false;
    for (int i = 0; i < ISD_AMB_COUNT; ++i) {
        Ramp &r = ramps[i];
        if (r.silent()) continue;
        const float g0 = r.value, g1 = r.advance(n);
        std::fill(tl, tl + n, 0.f); std::fill(tr, tr + n, 0.f);
        sources[i]->render(tl, tr, n, ctx);
        const float k = kGain[i], d = sources[i]->direct, s = sources[i]->send, step = (g1 - g0) / (float)n;
        float g = g0;
        for (int t = 0; t < n; ++t) {
            g += step;
            const float xl = tl[t] * g * k, xr = tr[t] * g * k;
            dl[t] += xl * d; dr[t] += xr * d;
            sl[t] += xl * s; sr2[t] += xr * s;
        }
        any = true;
    }
    if (thunder->active()) {
        // A near clap peaks about −7 dBFS (RMS ≈ −18) and a far one sits near the beds; never into the limiter.
        constexpr float kThunderGain = 0.11f;
        std::fill(tl, tl + n, 0.f); std::fill(tr, tr + n, 0.f);
        thunder->render(tl, tr, n, (float)sr);
        for (int t = 0; t < n; ++t) {
            const float xl = tl[t] * kThunderGain, xr = tr[t] * kThunderGain;
            dl[t] += xl; dr[t] += xr; sl[t] += 0.7f * xl; sr2[t] += 0.7f * xr;
        }
        any = true;
    }
    // Air absorption and width on the direct sound.
    if (any) {
        for (int t = 0; t < n; ++t) {
            float *in[2] = {dl, dr};
            for (int ch = 0; ch < 2; ++ch) {
                OneSVF &f = air[ch];
                const float x = in[ch][t], v3 = x - f.ic2, v1 = airA1 * f.ic1 + airA2 * v3, v2 = f.ic2 + airA2 * f.ic1 + airA3 * v3;
                f.ic1 = 2.f * v1 - f.ic1; f.ic2 = 2.f * v2 - f.ic2;
                in[ch][t] = v2;
            }
            const float m = 0.5f * (dl[t] + dr[t]), s = 0.5f * (dl[t] - dr[t]) * width;
            dl[t] = m + s; dr[t] = m - s;
        }
    }
    float rl[kBlock] = {}, rr[kBlock] = {};
    if (any || roomLive) {
        room.process(sl, sr2, rl, rr, n);
        roomLive = any;
        if (!any) {   // let the tail ring out, then rest
            float e = 0;
            for (int t = 0; t < n; ++t) e += rl[t] * rl[t] + rr[t] * rr[t];
            roomLive = e > 1e-12f;
        }
    }
    // Ducking: down within half a second, back over about two.
    const float target = -4.f * activity, tau = target < duckDb ? 0.12f : 0.7f;
    const float d0 = duckDb;
    duckDb += (target - duckDb) * (1.f - std::exp(-(float)n / (tau * (float)sr)));
    const float g0 = std::pow(10.f, d0 / 20.f), g1 = std::pow(10.f, duckDb / 20.f), dg = (g1 - g0) / (float)n;
    float g = g0;
    for (int t = 0; t < n; ++t) {
        g += dg;
        left[t] = softLimit(g * (directGain * dl[t] + roomGain * rl[t]));
        right[t] = softLimit(g * (directGain * dr[t] + roomGain * rr[t]));
    }
}

} // namespace isd

// ---------------------------------------------------------------- C API
struct ISDAmbience {
    isd::Ambience engine;
    std::atomic<float> levels[ISD_AMB_COUNT];
    float applied[ISD_AMB_COUNT];
    std::atomic<float> closeness{0.5f}, activity{0.f}, cool{0.f}, density{1.f}, thunderDistance{0.5f};
    std::atomic<int> thunderSeq{0};
    int thunderSeen = 0;
    std::atomic<float> speed{0.f}, surfDistance{0.f}, waveStrength{0.5f};
    std::atomic<int> waveSeq{0};
    int waveSeen = 0;
    ISDAmbience(double sr, uint64_t seed) : engine(sr, seed) {
        for (int i = 0; i < ISD_AMB_COUNT; ++i) { levels[i].store(0.f); applied[i] = 0.f; }
    }
};

extern "C" {

ISDAmbience *isd_ambience_create(double sampleRate, int maxFrames, uint64_t seed) {
    (void)maxFrames;
    if (sampleRate <= 0) return nullptr;
    return new ISDAmbience(sampleRate, seed);
}

void isd_ambience_destroy(ISDAmbience *a) { delete a; }

void isd_ambience_set_level(ISDAmbience *a, ISDAmbienceSource source, float level) {
    if (!a || (int)source < 0 || (int)source >= ISD_AMB_COUNT || !std::isfinite(level)) return;
    a->levels[source].store(isd::clamp01(level), std::memory_order_relaxed);
}

void isd_ambience_set_closeness(ISDAmbience *a, float c) { if (a && std::isfinite(c)) a->closeness.store(isd::clamp01(c), std::memory_order_relaxed); }
void isd_ambience_set_activity(ISDAmbience *a, float v) { if (a && std::isfinite(v)) a->activity.store(isd::clamp01(v), std::memory_order_relaxed); }
void isd_ambience_set_night_cool(ISDAmbience *a, float v) { if (a && std::isfinite(v)) a->cool.store(isd::clamp01(v), std::memory_order_relaxed); }
void isd_ambience_set_density(ISDAmbience *a, float v) { if (a && std::isfinite(v)) a->density.store(std::clamp(v, 0.5f, 1.5f), std::memory_order_relaxed); }

void isd_ambience_trigger_thunder(ISDAmbience *a, float distance) {
    if (!a || !std::isfinite(distance)) return;
    a->thunderDistance.store(isd::clamp01(distance), std::memory_order_relaxed);
    a->thunderSeq.fetch_add(1, std::memory_order_release);
}

void isd_ambience_trigger_wave(ISDAmbience *a, float strength) {
    if (!a || !std::isfinite(strength)) return;
    a->waveStrength.store(isd::clamp01(strength), std::memory_order_relaxed);
    a->waveSeq.fetch_add(1, std::memory_order_release);
}

void isd_ambience_set_speed(ISDAmbience *a, float v) { if (a && std::isfinite(v)) a->speed.store(isd::clamp01(v), std::memory_order_relaxed); }
void isd_ambience_set_surf_distance(ISDAmbience *a, float v) { if (a && std::isfinite(v)) a->surfDistance.store(isd::clamp01(v), std::memory_order_relaxed); }

void isd_ambience_render(ISDAmbience *a, float *left, float *right, int frames) {
    if (!a || frames <= 0) return;
    isd::DenormalGuard guard;
    for (int i = 0; i < ISD_AMB_COUNT; ++i) {
        const float v = a->levels[i].load(std::memory_order_relaxed);
        if (v != a->applied[i]) { a->applied[i] = v; a->engine.setLevel(i, v); }
    }
    a->engine.setCloseness(a->closeness.load(std::memory_order_relaxed));
    a->engine.setActivity(a->activity.load(std::memory_order_relaxed));
    a->engine.setNightCool(a->cool.load(std::memory_order_relaxed));
    a->engine.setDensity(a->density.load(std::memory_order_relaxed));
    const int seq = a->thunderSeq.load(std::memory_order_acquire);
    if (seq != a->thunderSeen) { a->thunderSeen = seq; a->engine.triggerThunder(a->thunderDistance.load(std::memory_order_relaxed)); }
    a->engine.setSpeed(a->speed.load(std::memory_order_relaxed));
    a->engine.setSurfDistance(a->surfDistance.load(std::memory_order_relaxed));
    const int waves = a->waveSeq.load(std::memory_order_acquire);
    if (waves != a->waveSeen) { a->waveSeen = waves; a->engine.triggerWave(a->waveStrength.load(std::memory_order_relaxed)); }
    a->engine.render(left, right, frames);
}

float isd_ambience_debug_tone_hz(float hz, float sampleRate, float seconds) {
    if (!(hz > 0.f) || !(sampleRate > 0.f) || !(seconds > 1.f)) return 0.f;
    using namespace isd::amb;
    float ph = 0.f;
    const float inc = hz / sampleRate;
    const long total = (long)((double)seconds * sampleRate), last = (long)sampleRate;
    double cycles = 0;
    for (long i = 0; i < total; ++i) {
        const float before = ph;
        advanceTone(ph, inc);
        if (i >= total - last) cycles += ph >= before ? (double)ph - before : (double)ph + (before - ph > 500.f ? 1000.0 : 1.0) - before;
    }
    return (float)cycles;
}

} // extern "C"
