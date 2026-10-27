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

} // namespace isd
