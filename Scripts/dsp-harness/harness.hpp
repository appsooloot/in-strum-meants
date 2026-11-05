// Shared helpers for the DSP harness: render an engine through the C API with timed MIDI, and measure it.
#pragma once
#include "InStrumDSP.h"
#include <algorithm>
#include <cmath>
#include <complex>
#include <cstdio>
#include <cstdint>
#include <vector>

namespace harness {
inline int fails = 0;
#define CHECK(c, ...) do { if (!(c)) { ++harness::fails; printf("FAIL: " __VA_ARGS__); printf("\n"); } else { printf("ok:   " __VA_ARGS__); printf("\n"); } } while (0)

struct Midi { double t; std::vector<uint8_t> bytes; };
inline Midi on(double t, int n, int v) { return {t, {0x90, (uint8_t)n, (uint8_t)v}}; }
inline Midi off(double t, int n) { return {t, {0x80, (uint8_t)n, 0}}; }
inline Midi cc(double t, int c, int v) { return {t, {0xB0, (uint8_t)c, (uint8_t)v}}; }
inline Midi pressure(double t, int v) { return {t, {0xD0, (uint8_t)v}}; }
inline Midi bend(double t, int v14) { return {t, {0xE0, (uint8_t)(v14 & 0x7F), (uint8_t)(v14 >> 7)}}; }

struct Out { std::vector<float> l, r; double sr; };
inline Out render(ISDEngine e, double seconds, std::vector<std::pair<int, float>> params, std::vector<Midi> events, double sr = 48000, int block = 256, ISDSynth **keep = nullptr) {
    ISDSynth *s = isd_synth_create(e, sr, block);
    for (auto &p : params) isd_synth_set_param(s, p.first, p.second);
    std::sort(events.begin(), events.end(), [](const Midi &a, const Midi &b) { return a.t < b.t; });
    const int total = (int)(seconds * sr);
    Out o; o.sr = sr; o.l.assign(total, 0.f); o.r.assign(total, 0.f);
    size_t ei = 0;
    for (int i = 0; i < total; i += block) {
        const int n = std::min(block, total - i);
        while (ei < events.size() && (int)(events[ei].t * sr) < i + n) {
            const int off = std::max(0, (int)(events[ei].t * sr) - i);
            isd_synth_midi(s, events[ei].bytes.data(), (int)events[ei].bytes.size(), off);
            ++ei;
        }
        isd_synth_render(s, o.l.data() + i, o.r.data() + i, n);
    }
    if (keep) *keep = s; else isd_synth_destroy(s);
    return o;
}
inline std::vector<float> slice(const std::vector<float> &x, double a, double b, double sr) {
    int i0 = std::clamp((int)(a * sr), 0, (int)x.size()), i1 = std::clamp((int)(b * sr), 0, (int)x.size());
    return std::vector<float>(x.begin() + i0, x.begin() + i1);
}
inline void fft(std::vector<std::complex<double>> &a) {
    const size_t n = a.size();
    for (size_t i = 1, j = 0; i < n; ++i) { size_t bit = n >> 1; for (; j & bit; bit >>= 1) j ^= bit; j ^= bit; if (i < j) std::swap(a[i], a[j]); }
    for (size_t len = 2; len <= n; len <<= 1) {
        const double ang = -2 * M_PI / (double)len; const std::complex<double> wl(std::cos(ang), std::sin(ang));
        for (size_t i = 0; i < n; i += len) { std::complex<double> w(1); for (size_t j = 0; j < len / 2; ++j) { auto u = a[i + j], v = a[i + j + len / 2] * w; a[i + j] = u + v; a[i + j + len / 2] = u - v; w *= wl; } }
    }
}
/// The power spectrum (Hann) of x, zero-padded to a power of two ≥ minN.
inline std::vector<double> spectrum(const std::vector<float> &x, size_t minN = 0) {
    size_t n = 1; while (n < std::max(x.size(), minN)) n <<= 1;
    std::vector<std::complex<double>> a(n, 0.0);
    for (size_t i = 0; i < x.size(); ++i) a[i] = x[i] * (0.5 - 0.5 * std::cos(2 * M_PI * (double)i / (double)(x.size() - 1)));
    fft(a);
    std::vector<double> p(n / 2); for (size_t i = 0; i < n / 2; ++i) p[i] = std::norm(a[i]);
    return p;
}
inline double bandPower(const std::vector<double> &p, double sr, double lo, double hi) {
    const double binHz = sr / (2.0 * (double)p.size()); double s = 0;
    for (size_t i = 0; i < p.size(); ++i) { double f = (double)i * binHz; if (f >= lo && f < hi) s += p[i]; }
    return s;
}
inline double centroid(const std::vector<double> &p, double sr) {
    const double binHz = sr / (2.0 * (double)p.size()); double num = 0, den = 0;
    for (size_t i = 1; i < p.size(); ++i) { num += (double)i * binHz * p[i]; den += p[i]; }
    return den > 0 ? num / den : 0;
}
/// The strongest frequency within lo…hi (parabolic interpolation on the log spectrum).
inline double peakHz(const std::vector<float> &x, double sr, double lo, double hi) {
    auto p = spectrum(x, 1 << 18); const double binHz = sr / (2.0 * (double)p.size());
    size_t best = 0; double bp = -1;
    for (size_t i = 1; i + 1 < p.size(); ++i) { double f = (double)i * binHz; if (f < lo || f > hi) continue; if (p[i] > bp) { bp = p[i]; best = i; } }
    const double a = std::log(p[best - 1] + 1e-30), b = std::log(p[best] + 1e-30), c = std::log(p[best + 1] + 1e-30);
    return ((double)best + 0.5 * (a - c) / (a - 2 * b + c)) * binHz;
}
inline double rms(const std::vector<float> &x) { double s = 0; for (float v : x) s += (double)v * v; return x.empty() ? 0 : std::sqrt(s / (double)x.size()); }
inline double peak(const Out &o) { double m = 0; for (size_t i = 0; i < o.l.size(); ++i) m = std::max(m, (double)std::max(std::fabs(o.l[i]), std::fabs(o.r[i]))); return m; }
inline bool finite(const Out &o) { for (size_t i = 0; i < o.l.size(); ++i) if (!std::isfinite(o.l[i]) || !std::isfinite(o.r[i])) return false; return true; }
inline double db(double ratio) { return 10.0 * std::log10(ratio); }
inline double cents(double hz, double ref) { return 1200.0 * std::log2(hz / ref); }
inline double midiHz(double m) { return 440.0 * std::pow(2.0, (m - 69.0) / 12.0); }
} // namespace harness

namespace harness {
/// Mirrors DSPTestKit.loudestHigh: the loudest 1 ms (hop 0.5 ms) above 10 kHz through an 8th-order Butterworth
/// high-pass settled over the 5 ms before, in dB.
inline double loudestHigh(const std::vector<float> &x, double t0, double t1, double sr) {
    struct HP { double b0, b1, b2, a1, a2, z1 = 0, z2 = 0; HP(double f, double q, double sr) { double w = 2 * M_PI * f / sr, c = std::cos(w), al = std::sin(w) / (2 * q), a0 = 1 + al; b0 = (1 + c) / 2 / a0; b1 = -(1 + c) / a0; b2 = b0; a1 = -2 * c / a0; a2 = (1 - al) / a0; }
        double run(double v) { double y = b0 * v + z1; z1 = b1 * v - a1 * y + z2; z2 = b2 * v - a2 * y; return y; } };
    std::vector<HP> f; for (double q : {0.5098, 0.6013, 0.9000, 2.5629}) f.emplace_back(10000, q, sr);
    int start = (int)(t0 * sr), end = std::min((int)x.size(), (int)(t1 * sr)), warm = std::max(0, start - (int)(0.005 * sr));
    if (end <= start) return -200;
    std::vector<double> y(end - warm);
    for (int i = warm; i < end; ++i) { double v = x[i]; for (auto &h : f) v = h.run(v); y[i - warm] = v; }
    int w = (int)(0.001 * sr), hop = w / 2; double loud = -200;
    for (int i = start - warm; i + w <= (int)y.size(); i += hop) { double s = 0; for (int k = i; k < i + w; ++k) s += y[k] * y[k]; loud = std::max(loud, 10 * std::log10(s / w + 1e-30)); }
    return loud;
}
inline std::vector<Midi> handChord(int c, double t, double gap, int vel) {
    std::vector<Midi> e; for (int k = 0; k < 8; ++k) { int n = 36 + 2 * (c % 5) + c / 5 + 5 * k; e.push_back(on(t, n, vel)); e.push_back(off(t + gap, n)); } return e;
}
/// Mirrors SynthRender.stealClicks.
inline std::vector<double> stealClicks(ISDEngine eng, std::vector<std::pair<int, float>> params, std::vector<int> vels, double gap, int first, double sr = 48000) {
    const double seconds = (double)(vels.size() - 1) * gap + 0.03;
    std::vector<Midi> all = {cc(0, 64, 127)};
    for (size_t c = 0; c < vels.size(); ++c) { auto h = handChord((int)c, c * gap, gap, vels[c]); all.insert(all.end(), h.begin(), h.end()); }
    auto out = render(eng, seconds, params, all, sr);
    std::vector<float> rl(out.l.size(), 0.f), rr(out.r.size(), 0.f);
    for (size_t c = 0; c < vels.size(); ++c) {
        double t = c * gap; std::vector<Midi> ev = {cc(0, 64, 127)}; auto h = handChord((int)c, 0, gap, vels[c]); ev.insert(ev.end(), h.begin(), h.end());
        auto solo = render(eng, seconds - t, params, ev, sr); int at = (int)(t * sr);
        for (size_t i = 0; i < solo.l.size() && at + i < rl.size(); ++i) { rl[at + i] += solo.l[i]; rr[at + i] += solo.r[i]; }
    }
    std::vector<double> clicks;
    for (size_t c = first; c < vels.size(); ++c) { double t = c * gap;
        double heard = std::max(loudestHigh(out.l, t - 0.002, t + 0.025, sr), loudestHigh(out.r, t - 0.002, t + 0.025, sr));
        double ref = std::max(loudestHigh(rl, t - 0.002, t + 0.025, sr), loudestHigh(rr, t - 0.002, t + 0.025, sr));
        clicks.push_back(heard - std::max(ref, -80.0)); }
    return clicks;
}
} // namespace harness
