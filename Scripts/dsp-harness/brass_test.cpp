// Replicant Brass with Chrome Bass, measured through the C API (Sets 13 & 14, Task 3). Mirrors ReplicantBrassTests.swift.
#include "harness.hpp"
#include <chrono>
using namespace harness;
const ISDEngine E = ISD_ENGINE_REPLICANT_BRASS;
const double sr = 48000;

/// Energy above `hz` in consecutive frames of `ms`.
std::vector<double> frames(const std::vector<float> &x, double ms, double lo, double hi) {
    std::vector<double> e; const int w = (int)(ms * 0.001 * sr); int n = 1; while (n < w) n <<= 1;
    for (size_t i = 0; i + w <= x.size(); i += w) { std::vector<float> f(x.begin() + i, x.begin() + i + w); e.push_back(bandPower(spectrum(f, n), sr, lo, hi)); }
    return e;
}
double timeTo90(const std::vector<double> &e, double ms) { double m = 0; for (double v : e) m = std::max(m, v); for (size_t i = 0; i < e.size(); ++i) if (e[i] >= 0.9 * m) return (double)i * ms; return 1e9; }
double corr(const std::vector<float> &a, const std::vector<float> &b) { double ab = 0, aa = 0, bb = 0; for (size_t i = 0; i < a.size(); ++i) { ab += a[i] * b[i]; aa += a[i] * a[i]; bb += b[i] * b[i]; } return ab / std::sqrt(aa * bb + 1e-30); }

int main() {
    const std::vector<std::pair<int, float>> dry = {{ISD_P_DEBUG_RB_DRY, 1}, {ISD_P_SPLIT, 0}};
    { // the swell follows its dial
        auto t = [&](float s) { auto p = dry; p.push_back({ISD_P_SWELL_RB, s}); auto o = render(E, 1.2, p, {on(0, 60, 90)}); return timeTo90(frames(o.l, 5, 1000, 4000), 5); };
        double t0 = t(0), t1 = t(1);
        CHECK(std::fabs(t0 - 40) <= 15 && t1 >= 450, "Swell: 1–4 kHz reaches 90%% at %.0f ms (Swell 0), %.0f ms (Swell 1)", t0, t1);
    }
    { // the blare: at full velocity the brass peaks early (≤ 100 ms) and far brighter than a mid-velocity note,
      // which swells to its peak after 150 ms. (A bright-share ratio against the settled tone can't show the
      // overshoot: a saw puts at most ~11% of its power above 1.5 kHz, and the peak already reaches that.)
        auto curve = [&](int vel, double &peakMs) { auto o = render(E, 0.6, {{ISD_P_DEBUG_RB_DRY, 1}, {ISD_P_SPLIT, 0}, {ISD_P_UNISON_WIDTH, 0}}, {on(0, 60, vel)});
            auto e = frames(o.l, 10, 20, 20000), h = frames(o.l, 10, 1500, 20000); double pk = 0; peakMs = 0;
            for (size_t i = 2; i < 40 && i < e.size(); ++i) if (h[i] / e[i] > pk) { pk = h[i] / e[i]; peakMs = 10.0 * (double)i; } return pk; };
        double tHard, tMid; double hard = curve(127, tHard), mid = curve(76, tMid);
        CHECK(hard >= 1.5 * mid && tHard <= 100 && tMid >= 150, "the blare: fff peaks %.2f× brighter than velocity 0.6, at %.0f ms (0.6 peaks at %.0f ms)", hard / mid, tHard, tMid);
    }
    { // width spreads the stack
        auto c = [&](float w) { auto p = dry; p.push_back({ISD_P_UNISON_WIDTH, w}); auto o = render(E, 1.0, p, {on(0, 60, 90), on(0, 64, 90), on(0, 67, 90)}); return corr(slice(o.l, 0.3, 0.9, sr), slice(o.r, 0.3, 0.9, sr)); };
        double c0 = c(0), c1 = c(1);
        CHECK(c0 >= 0.9 && c1 <= 0.5, "Width: stereo correlation %.2f at 0, %.2f at 1", c0, c1);
    }
    { // the split routes, and a moved split never strands a voice
        auto p = std::vector<std::pair<int, float>>{{ISD_P_DEBUG_RB_DRY, 1}, {ISD_P_ARP_MODE, 0}};
        ISDSynth *s = nullptr; auto bassOnly = render(E, 0.5, p, {on(0, 36, 100)}, sr, 256, &s); isd_synth_destroy(s);
        auto brassOnly = render(E, 0.5, p, {on(0, 72, 100)});
        double lowShare = bandPower(spectrum(slice(bassOnly.l, 0.05, 0.45, sr)), sr, 20, 200) / bandPower(spectrum(slice(bassOnly.l, 0.05, 0.45, sr)), sr, 20, 20000);
        double brassLow = bandPower(spectrum(slice(brassOnly.l, 0.05, 0.45, sr)), sr, 20, 200) / bandPower(spectrum(slice(brassOnly.l, 0.05, 0.45, sr)), sr, 20, 20000);
        CHECK(lowShare > 0.5 && brassLow < 0.05, "C2 plays the bass (%.0f%% below 200 Hz), C5 the brass (%.1f%%)", 100 * lowShare, 100 * brassLow);
        // C4 held as brass; the split moves to C5 (so C4 would now be bass); C4 lets go: its brass voice must release.
        ISDSynth *s2 = isd_synth_create(E, sr, 256); for (auto &q : p) isd_synth_set_param(s2, q.first, q.second);
        std::vector<float> l(256), r(256); uint8_t onb[3] = {0x90, 60, 100}, offb[3] = {0x80, 60, 0};
        isd_synth_midi(s2, onb, 3, 0); for (int i = 0; i < 40; ++i) isd_synth_render(s2, l.data(), r.data(), 256);
        isd_synth_set_param(s2, ISD_P_SPLIT, 72); for (int i = 0; i < 10; ++i) isd_synth_render(s2, l.data(), r.data(), 256);
        isd_synth_midi(s2, offb, 3, 0); double tail = 0; for (int i = 0; i < 400; ++i) { isd_synth_render(s2, l.data(), r.data(), 256); if (i > 300) for (float v : l) tail = std::max(tail, (double)std::fabs(v)); }
        int voices = isd_synth_active_voices(s2); isd_synth_destroy(s2);
        CHECK(tail < 1e-4 && voices == 0, "moving the split while C4 is held: it still releases (tail %.1e, %d voices)", tail, voices);
    }
    { // the Chrome arp is sample-accurate
        auto o = render(E, 1.6, {{ISD_P_DEBUG_RB_DRY, 1}, {ISD_P_ARP_MODE, 4}, {ISD_P_ARP_RATE, 3}, {ISD_P_TEMPO_RB, 120}}, {on(0.1, 36, 100), on(0.1, 43, 100)});
        auto e = frames(o.l, 1, 1500, 8000); std::vector<double> onsets;
        for (size_t i = 3; i + 1 < e.size(); ++i) { double before = std::max({e[i - 1], e[i - 2], e[i - 3]}); if (e[i] > 8 * before && e[i] > 1e-6 && (onsets.empty() || (double)i - onsets.back() > 50)) onsets.push_back((double)i); }
        bool spaced = onsets.size() >= 8; for (size_t i = 1; i < onsets.size(); ++i) if (std::fabs(onsets[i] - onsets[i - 1] - 125) > 1.5) spaced = false;
        CHECK(spaced && std::fabs(onsets[0] - 100) <= 1.5, "the arp steps every 125 ms from the first key (%zu onsets, first at %.0f ms)", onsets.size(), onsets.empty() ? -1.0 : onsets[0]);
    }
    { // the blade: ±7 semitones, and a released note's bend falls away
        auto o = render(E, 1.0, dry, {on(0, 60, 90), bend(0.0, 16383)});
        double h = peakHz(slice(o.l, 0.2, 1.0, sr), sr, midiHz(67) * 0.97, midiHz(67) * 1.03);
        CHECK(std::fabs(cents(h, midiHz(67))) < 10, "a full bend: +7 semitones (%.1f cents off)", cents(h, midiHz(67)));
        auto f = render(E, 1.0, dry, {on(0, 60, 90), bend(0.0, 16383), off(0.5, 60)});
        double g = peakHz(slice(f.l, 0.62, 0.8, sr), sr, midiHz(60) * 0.95, midiHz(67) * 1.03);
        CHECK(std::fabs(cents(g, midiHz(60))) < 25, "released with the bend held, it falls back within 120 ms (%.1f cents from C4)", cents(g, midiHz(60)));
    }
    { // panic mid-arp; a fresh grid after
        auto o = render(E, 1.2, {{ISD_P_ARP_MODE, 4}}, {on(0, 36, 100), on(0, 43, 100), on(0, 72, 100), cc(0.5, 120, 0), on(0.8, 38, 100)});
        double tail = rms(slice(o.l, 0.55, 0.79, sr));
        CHECK(tail < 1e-3, "all sound off mid-arp: silent within 50 ms (%.1e)", tail);
        auto e = frames(o.l, 1, 1500, 8000); size_t first = 0; for (size_t i = 790; i < e.size(); ++i) if (e[i] > 1e-4) { first = i; break; }
        CHECK(first >= 800 && first <= 802, "the next key starts a fresh grid on its own sample (%zu ms)", first);
    }
    { // ceiling
        std::vector<Midi> ch; for (int n : {36, 43, 48, 55, 60, 64, 67, 71, 74, 79}) ch.push_back(on(0, n, 127));
        auto o = render(E, 3.0, {{ISD_P_HALL, 1}, {ISD_P_BLAZE, 1}}, ch);
        CHECK(finite(o) && peak(o) <= 0.966, "a 10-note fff chord, Hall 1: peak %.3f, finite", peak(o));
    }
    { // stealing
        auto c = stealClicks(E, {{ISD_P_SPLIT, 0}}, {100, 100, 100, 100, 100, 100}, 0.25, 1);
        double worst = -1e9; for (double v : c) worst = std::max(worst, v);
        CHECK(worst < 3, "stealing is click-free: worst %.1f dB", worst);
    }
    { // CPU
        ISDSynth *s = isd_synth_create(E, sr, 256);
        for (int n : {36, 43, 60, 64, 67, 71, 74, 79}) { uint8_t b[3] = {0x90, (uint8_t)n, 100}; isd_synth_midi(s, b, 3, 0); }
        std::vector<float> l(256), r(256); const int blocks = (int)(sr * 4 / 256);
        auto t0 = std::chrono::steady_clock::now(); for (int i = 0; i < blocks; ++i) isd_synth_render(s, l.data(), r.data(), 256);
        double secs = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count(); isd_synth_destroy(s);
        printf("   CPU: 6 brass notes and a 2-note arp use %.1f%% of a core here\n", 100 * secs / 4);
    }
    printf("%s (%d failures)\n", fails ? "FAILED" : "ALL OK", fails);
    return fails ? 1 : 0;
}
