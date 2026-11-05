// Magma Bass, measured through the C API (Sets 13 & 14, Task 2). Mirrors MagmaBassTests.swift.
#include "harness.hpp"
#include <chrono>
using namespace harness;
const ISDEngine E = ISD_ENGINE_MAGMA_BASS;

int main() {
    const double sr = 48000;
    { // tuning, dry
        double worst = 0;
        for (int n : {28, 45, 57, 60}) {
            auto o = render(E, 3.0, {{ISD_P_DEBUG_MB_DRY, 1}, {ISD_P_RUMBLE, 0}, {ISD_P_HEAT, 1}}, {on(0, n, 100)});
            double f = midiHz(n), h = peakHz(slice(o.l, 0.3, 2.9, sr), sr, f * 0.97, f * 1.03);
            worst = std::max(worst, std::fabs(cents(h, f)));
        }
        CHECK(worst < 3.0, "tuning (dry) within 3 cents, E1…C4: worst %.2f", worst);
    }
    { // velocity rips the filter open: the share of 0.5–4 kHz in the first 0.4 s
        auto share = [&](float growl, int vel) { auto o = render(E, 0.5, {{ISD_P_GROWL, growl}}, {on(0, 33, vel)}); auto p = spectrum(slice(o.l, 0.05, 0.4, sr));
            return db(bandPower(p, sr, 500, 4000) / bandPower(p, sr, 20, 20000)); };
        double d0 = share(0.55f, 127) - share(0.55f, 25), d1 = share(0.f, 127) - share(0.f, 25);
        CHECK(d0 >= 4 && d1 >= 9, "velocity rips the filter open: fff is %.1f dB brighter at the defaults, %.1f dB at Growl 0", d0, d1);
    }
    { // rumble adds f/4
        auto r1 = render(E, 1.5, {{ISD_P_RUMBLE, 1}}, {on(0, 57, 100)}), r0 = render(E, 1.5, {{ISD_P_RUMBLE, 0}}, {on(0, 57, 100)});
        double f4 = midiHz(57) / 4;
        double a = bandPower(spectrum(slice(r1.l, 0.2, 1.4, sr)), sr, f4 * 0.9, f4 * 1.1), b = bandPower(spectrum(slice(r0.l, 0.2, 1.4, sr)), sr, f4 * 0.9, f4 * 1.1);
        CHECK(db(a / b) >= 10, "Rumble 1 lifts f/4 by %.1f dB", db(a / b));
    }
    { // growl brightens monotonically
        double prev = -1e9; bool mono = true; printf("   growl:");
        for (float g : {0.f, 0.33f, 0.66f, 1.f}) {
            auto o = render(E, 1.0, {{ISD_P_GROWL, g}, {ISD_P_HEAT, 0.8f}, {ISD_P_ERUPT, 0}, {ISD_P_RES, 0}}, {on(0, 45, 100)});
            auto p = spectrum(slice(o.l, 0.2, 0.9, sr));
            double ratio = db(bandPower(p, sr, 800, 5000) / bandPower(p, sr, 20, 400));
            printf(" %.1f", ratio); if (ratio < prev) mono = false; prev = ratio;
        }
        printf(" dB\n");
        CHECK(mono, "growl raises the upper harmonics monotonically");
    }
    { // mono legato glide
        ISDSynth *s = nullptr;
        auto o = render(E, 1.0, {{ISD_P_MONO, 1}, {ISD_P_FLOW, 0.5f}, {ISD_P_DEBUG_MB_DRY, 1}, {ISD_P_RUMBLE, 0}, {ISD_P_HEAT, 1}},
                        {on(0, 45, 100), on(0.3, 52, 100)}, sr, 256, &s);
        int voices = isd_synth_active_voices(s); isd_synth_destroy(s);
        double h = peakHz(slice(o.l, 0.45, 1.0, sr), sr, midiHz(52) * 0.97, midiHz(52) * 1.03);
        // no re-attack: the 5 ms RMS never jumps by more than 3 dB across the change
        double worstJump = 0; for (double t = 0.22; t < 0.42; t += 0.005) { double a = rms(slice(o.l, t, t + 0.025, sr)), b = rms(slice(o.l, t + 0.025, t + 0.05, sr)); worstJump = std::max(worstJump, 20 * std::log10((b + 1e-9) / (a + 1e-9))); }
        CHECK(voices == 1 && std::fabs(cents(h, midiHz(52))) < 5 && worstJump < 3, "Mono legato glides on one voice (%d), arrives within 5 cents (%.1f), no re-attack (+%.1f dB)", voices, cents(h, midiHz(52)), worstJump);
    }
    { // spark only above C4
        auto s1 = render(E, 1.0, {{ISD_P_SPARK, 1}}, {on(0, 72, 100)}), s0 = render(E, 1.0, {{ISD_P_SPARK, 0}}, {on(0, 72, 100)});
        double a = bandPower(spectrum(slice(s1.l, 0.1, 0.9, sr)), sr, 2000, 6000), b = bandPower(spectrum(slice(s0.l, 0.1, 0.9, sr)), sr, 2000, 6000);
        auto c1 = render(E, 1.0, {{ISD_P_SPARK, 1}}, {on(0, 48, 100)}), c0 = render(E, 1.0, {{ISD_P_SPARK, 0}}, {on(0, 48, 100)});
        double d3 = 20 * std::log10(rms(c1.l) / rms(c0.l));
        CHECK(db(a / b) >= 6 && std::fabs(d3) < 0.5, "Spark lifts C5's 2–6 kHz by %.1f dB; C3 changes %.2f dB", db(a / b), d3);
    }
    { // the eruption swell
        ISDSynth *s = nullptr;
        auto chord = render(E, 1.5, {}, {on(0, 28, 120), on(0.01, 33, 120), on(0.02, 40, 120), on(0.03, 45, 120)}, sr, 256, &s);
        int er = isd_synth_debug_count(s, ISD_DEBUG_ERUPTIONS); isd_synth_destroy(s);
        ISDSynth *s2 = nullptr;
        auto spread = render(E, 1.5, {}, {on(0, 28, 120), on(0.05, 33, 120), on(0.10, 40, 120), on(0.15, 45, 120)}, sr, 256, &s2);
        int er2 = isd_synth_debug_count(s2, ISD_DEBUG_ERUPTIONS); isd_synth_destroy(s2);
        double a = bandPower(spectrum(slice(chord.l, 0.25, 0.7, sr)), sr, 20, 60), b = bandPower(spectrum(slice(spread.l, 0.25, 0.7, sr)), sr, 20, 60);
        CHECK(er == 1 && er2 == 0 && db(a / b) >= 2.5, "a hard low chord erupts once (%d; spread %d) and swells 20–60 Hz by %.1f dB (peak %.2f)", er, er2, db(a / b), peak(chord));
        ISDSynth *s3 = nullptr; render(E, 0.5, {}, {on(0, 60, 127), on(0.01, 64, 127), on(0.02, 67, 127)}, sr, 256, &s3);
        int high = isd_synth_debug_count(s3, ISD_DEBUG_ERUPTIONS); isd_synth_destroy(s3);
        ISDSynth *s4 = nullptr; render(E, 0.5, {}, {on(0, 28, 80), on(0.01, 33, 80), on(0.02, 40, 80)}, sr, 256, &s4);
        int softc = isd_synth_debug_count(s4, ISD_DEBUG_ERUPTIONS); isd_synth_destroy(s4);
        CHECK(high == 0 && softc == 0, "no eruption for a high chord (%d) or a soft low one (%d)", high, softc);
    }
    { // ceiling
        auto o = render(E, 3.0, {{ISD_P_GROWL, 1}, {ISD_P_RES, 0.9f}, {ISD_P_RUMBLE, 1}, {ISD_P_SPACE, 1}},
                        {on(0, 28, 127), on(0, 35, 127), on(0, 40, 127), on(0, 47, 127), on(0, 52, 127), on(0, 59, 127)});
        double pk = peak(o);
        CHECK(finite(o) && pk <= 0.966, "fff six-note chord at full growl: peak %.3f (%.2f dBFS), finite", pk, 20 * std::log10(pk));
    }
    { // pressure, bend, wheel, panic
        auto p1 = render(E, 1.0, {{ISD_P_HEAT, 0.3f}}, {on(0, 45, 90), pressure(0.1, 127)}), p0 = render(E, 1.0, {{ISD_P_HEAT, 0.3f}}, {on(0, 45, 90)});
        double a = bandPower(spectrum(slice(p1.l, 0.3, 0.9, sr)), sr, 500, 3000), b = bandPower(spectrum(slice(p0.l, 0.3, 0.9, sr)), sr, 500, 3000);
        CHECK(db(a / b) >= 4, "pressure opens the filter: +%.1f dB at 0.5–3 kHz", db(a / b));
        auto bt = render(E, 1.0, {{ISD_P_DEBUG_MB_DRY, 1}, {ISD_P_RUMBLE, 0}, {ISD_P_HEAT, 1}}, {on(0, 45, 100), bend(0.0, 16383)});
        double h = peakHz(slice(bt.l, 0.2, 1.0, sr), sr, midiHz(47) * 0.97, midiHz(47) * 1.03);
        CHECK(std::fabs(cents(h, midiHz(47))) < 5, "the wheel bends +2 semitones (%.1f cents off)", cents(h, midiHz(47)));
        auto wob = render(E, 2.0, {{ISD_P_HEAT, 0.4f}}, {on(0, 45, 90), cc(0.05, 1, 127)});
        // the wobble: 500–3000 Hz energy in 20 ms frames swings by > 6 dB
        double lo = 1e9, hi = 0; for (double t = 0.5; t < 1.8; t += 0.02) { double e = bandPower(spectrum(slice(wob.l, t, t + 0.02, sr)), sr, 500, 3000); lo = std::min(lo, e); hi = std::max(hi, e); }
        CHECK(db(hi / lo) > 6, "the mod wheel wobbles the filter (%.1f dB swing)", db(hi / lo));
        auto pan = render(E, 1.0, {}, {on(0, 45, 127), on(0, 52, 127), cc(0.5, 120, 0)});
        double tail = rms(slice(pan.l, 0.55, 1.0, sr));
        CHECK(tail < 1e-3, "all sound off: silent within 50 ms (%.2e)", tail);
    }
    { // voices never exceed the pool, stealing stays finite
        ISDSynth *s = nullptr; std::vector<Midi> ev; for (int i = 0; i < 40; ++i) ev.push_back(on(0.02 * i, 28 + (i * 5) % 30, 110));
        auto o = render(E, 2.0, {}, ev, sr, 256, &s); int v = isd_synth_active_voices(s); isd_synth_destroy(s);
        CHECK(finite(o) && v <= 12, "40 fast notes: %d voices at most the pool, finite", v);
    }
    { // stealing fades instead of clicking
        auto c = stealClicks(E, {}, {105, 105, 105, 105, 105, 105}, 0.25, 1);
        double worst = -1e9; for (double v : c) worst = std::max(worst, v);
        CHECK(worst < 3, "stealing is click-free: worst %.1f dB over the chords without stealing", worst);
    }
    { // CPU
        ISDSynth *s = isd_synth_create(E, sr, 256); for (int n : {28, 35, 40, 47, 52, 59}) { uint8_t b[3] = {0x90, (uint8_t)n, 110}; isd_synth_midi(s, b, 3, 0); }
        isd_synth_set_param(s, ISD_P_GROWL, 0.8f);
        std::vector<float> l(256), r(256); const int blocks = (int)(sr * 4 / 256);
        auto t0 = std::chrono::steady_clock::now(); for (int i = 0; i < blocks; ++i) isd_synth_render(s, l.data(), r.data(), 256);
        double secs = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count(); isd_synth_destroy(s);
        printf("   CPU: 6 voices at Growl .8 use %.1f%% of a core here (4 s in %.3f s)\n", 100 * secs / 4, secs);
    }
    printf("%s (%d failures)\n", fails ? "FAILED" : "ALL OK", fails);
    return fails ? 1 : 0;
}
