// Shared real-time helpers for the Sound Core. Header-only; nothing here allocates.
#pragma once
#include <cmath>
#include <cstdint>
#if defined(__x86_64__) || defined(__i386__)
#include <xmmintrin.h>
#endif

namespace isd {

constexpr float kPi = 3.14159265358979f;
constexpr float kTwoPi = 6.28318530717959f;

/// Flushes denormals to zero for the lifetime of the guard (x86 FTZ/DAZ, arm64 FPCR.FZ).
struct DenormalGuard {
#if defined(__x86_64__) || defined(__i386__)
    unsigned int saved;
    DenormalGuard() : saved(_mm_getcsr()) { _mm_setcsr(saved | 0x8040); }
    ~DenormalGuard() { _mm_setcsr(saved); }
#elif defined(__aarch64__)
    uint64_t saved;
    DenormalGuard() {
        __asm__ __volatile__("mrs %0, fpcr" : "=r"(saved));
        uint64_t fz = saved | (1ULL << 24);
        __asm__ __volatile__("msr fpcr, %0" : : "r"(fz));
    }
    ~DenormalGuard() { __asm__ __volatile__("msr fpcr, %0" : : "r"(saved)); }
#else
    DenormalGuard() {}
#endif
    DenormalGuard(const DenormalGuard &) = delete;
    DenormalGuard &operator=(const DenormalGuard &) = delete;
};

/// One-pole glide toward a target (default 20 ms), so dial changes never click.
struct Smoothed {
    float value = 0, target = 0, coeff = 0;
    void init(double sampleRate, double ms = 20.0) { coeff = (float)std::exp(-1.0 / (ms * 0.001 * sampleRate)); }
    void setTarget(float t) { target = t; }
    void snap(float v) { value = target = v; }
    float next() { value = target + (value - target) * coeff; return value; }
};

/// One-pole low-pass: y += (1 - a)(x - y).
struct OnePole {
    float a = 0, y = 0;
    void setCutoff(float hz, double sampleRate) { a = (float)std::exp(-2.0 * M_PI * hz / sampleRate); }
    float process(float x) { y = x + (y - x) * a; return y; }
    void clear() { y = 0; }
};

/// xorshift64* noise source: deterministic per seed.
struct FastRandom {
    uint64_t state;
    explicit FastRandom(uint64_t seed = 0x9E3779B97F4A7C15ULL) : state(seed ? seed : 1) {}
    uint64_t next() { state ^= state >> 12; state ^= state << 25; state ^= state >> 27; return state * 0x2545F4914F6CDD1DULL; }
    float uniform() { return (float)(next() >> 40) * (1.0f / 16777216.0f); }
    float bipolar() { return uniform() * 2.f - 1.f; }
};

/// RBJ biquad, transposed direct form II.
struct Biquad {
    float b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0, z1 = 0, z2 = 0;
    float process(float x) { float y = b0 * x + z1; z1 = b1 * x - a1 * y + z2; z2 = b2 * x - a2 * y; return y; }
    void clear() { z1 = z2 = 0; }
    void set(double nb0, double nb1, double nb2, double na0, double na1, double na2) {
        b0 = (float)(nb0 / na0); b1 = (float)(nb1 / na0); b2 = (float)(nb2 / na0); a1 = (float)(na1 / na0); a2 = (float)(na2 / na0);
    }
    void setPeak(double hz, double q, double dB, double sr) {
        double A = std::pow(10.0, dB / 40.0), w = 2 * M_PI * hz / sr, al = std::sin(w) / (2 * q), c = std::cos(w);
        set(1 + al * A, -2 * c, 1 - al * A, 1 + al / A, -2 * c, 1 - al / A);
    }
    /// Constant 0 dB peak gain.
    void setBandpass(double hz, double q, double sr) {
        double w = 2 * M_PI * hz / sr, al = std::sin(w) / (2 * q), c = std::cos(w);
        set(al, 0, -al, 1 + al, -2 * c, 1 - al);
    }
    void setLowShelf(double hz, double dB, double sr) {
        double A = std::pow(10.0, dB / 40.0), w = 2 * M_PI * hz / sr, c = std::cos(w), al = std::sin(w) / 2 * std::sqrt(2.0), sq = 2 * std::sqrt(A) * al;
        set(A * ((A + 1) - (A - 1) * c + sq), 2 * A * ((A - 1) - (A + 1) * c), A * ((A + 1) - (A - 1) * c - sq),
            (A + 1) + (A - 1) * c + sq, -2 * ((A - 1) + (A + 1) * c), (A + 1) + (A - 1) * c - sq);
    }
    void setHighShelf(double hz, double dB, double sr) {
        double A = std::pow(10.0, dB / 40.0), w = 2 * M_PI * hz / sr, c = std::cos(w), al = std::sin(w) / 2 * std::sqrt(2.0), sq = 2 * std::sqrt(A) * al;
        set(A * ((A + 1) + (A - 1) * c + sq), -2 * A * ((A - 1) + (A + 1) * c), A * ((A + 1) + (A - 1) * c - sq),
            (A + 1) - (A - 1) * c + sq, 2 * ((A - 1) - (A + 1) * c), (A + 1) - (A - 1) * c - sq);
    }
};

/// Identity below 0.9, then a smooth knee that never exceeds ±1.
inline float softLimit(float x) {
    float a = std::fabs(x);
    if (a <= 0.9f) return x;
    float y = 0.9f + 0.1f * std::tanh((a - 0.9f) * 10.f);
    return x < 0 ? -y : y;
}

/// Zero-latency stereo peak limiter: gain drops at once to keep peaks at `ceiling`, then recovers smoothly.
/// Keeps dense chords clean so softLimit (the last-resort knee) never has to shape the waveform.
struct PeakLimiter {
    float gain = 1, release = 0, ceiling = 0.9f;
    void init(double sampleRate, double releaseMs = 150.0) { release = (float)std::exp(-1.0 / (releaseMs * 0.001 * sampleRate)); }
    void process(float &l, float &r) {
        float p = std::fmax(std::fabs(l), std::fabs(r));
        float target = p > ceiling ? ceiling / p : 1.f;
        gain = target < gain ? target : target + (gain - target) * release;
        l *= gain; r *= gain;
    }
    void clear() { gain = 1; }
};

inline float clamp01(float x) { return x < 0 ? 0 : (x > 1 ? 1 : x); }

} // namespace isd
