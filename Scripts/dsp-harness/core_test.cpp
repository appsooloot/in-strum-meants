#include "AnalogVoice.hpp"
#include "Arp.hpp"
#include <cstdio>
#include <vector>
#include <complex>
using namespace isd;
static int fails = 0;
#define CHECK(c, ...) do { if (!(c)) { ++fails; printf("FAIL: " __VA_ARGS__); printf("\n"); } else { printf("ok: " __VA_ARGS__); printf("\n"); } } while (0)

struct Ev { int64_t t; int note; bool on; };
std::vector<Ev> runArp(Arp &a, int64_t total, std::vector<std::tuple<int64_t,int,bool>> keys) {
    std::vector<Ev> out; int64_t clock = 0; size_t ki = 0;
    while (clock < total) {
        while (ki < keys.size() && std::get<0>(keys[ki]) <= clock) {
            auto [t, n, d] = keys[ki++];
            if (d) a.keyDown(n, 100, clock); else a.keyUp(n, clock);
        }
        Arp::Event e; while (a.poll(clock, e)) out.push_back({clock, e.note, e.on});
        int64_t n = a.samplesToNext(clock);
        if (ki < keys.size()) n = std::min<int64_t>(n, std::get<0>(keys[ki]) - clock);
        n = std::max<int64_t>(1, std::min<int64_t>(n, 64));
        clock += n;
    }
    return out;
}
std::vector<Ev> ons(const std::vector<Ev> &v) { std::vector<Ev> o; for (auto &e : v) if (e.on) o.push_back(e); return o; }

int main() {
    const double sr = 48000;
    { // timing + played order with grouping
        Arp a; a.prepare(sr); a.setMode(Arp::Played); a.setRate(0.25f); a.setTempo(120); a.setGate(0.5f);
        auto ev = ons(runArp(a, 48000, {{0,67,true},{100,60,true},{200,64,true}}));
        bool timing = true, order = true; int exp[3] = {60,64,67};
        // first step at sample 0 plays G (only G held then)
        for (size_t i = 1; i < ev.size(); ++i) { if (ev[i].t != (int64_t)(i * 6000)) timing = false; }
        // after grouping (all within 30ms) the order is 60,64,67 low to high
        for (size_t i = 1; i < 7 && i < ev.size(); ++i) if (ev[i].note != exp[i % 3]) order = false;
        CHECK(ev.size() >= 8 && ev[0].t == 0, "arp first step on the first key's sample (%zu steps)", ev.size());
        CHECK(timing, "arp steps exactly every 6000 samples at 120 BPM in sixteenths");
        printf("   order:"); for (size_t i = 0; i < 7 && i < ev.size(); ++i) printf(" %d", ev[i].note); printf("\n");
        CHECK(order, "keys within 30 ms are ordered low to high, and the order runs on");
    }
    { // modes
        auto seq = [&](Arp::Mode m, int oct) { Arp a; a.prepare(sr); a.setMode(m); a.setRate(0.25f); a.setTempo(120); a.setOctaves(oct);
            auto ev = ons(runArp(a, 6000 * 12, {{0,64,true},{0,60,true},{0,67,true}})); std::vector<int> n; for (auto &e : ev) n.push_back(e.note); return n; };
        auto up = seq(Arp::Up, 1), dn = seq(Arp::Down, 1), ud = seq(Arp::UpDown, 1), up2 = seq(Arp::Up, 2), rnd = seq(Arp::Random, 1);
        CHECK(up[0]==60&&up[1]==64&&up[2]==67&&up[3]==60, "Up: %d %d %d %d", up[0],up[1],up[2],up[3]);
        CHECK(dn[0]==67&&dn[1]==64&&dn[2]==60&&dn[3]==67, "Down: %d %d %d %d", dn[0],dn[1],dn[2],dn[3]);
        CHECK(ud[0]==60&&ud[1]==64&&ud[2]==67&&ud[3]==64&&ud[4]==60&&ud[5]==64, "UpDown no repeated ends: %d %d %d %d %d %d", ud[0],ud[1],ud[2],ud[3],ud[4],ud[5]);
        CHECK(up2[3]==72&&up2[5]==79&&up2[6]==60, "two octaves: %d %d %d", up2[3],up2[5],up2[6]);
        bool norep = true; for (size_t i = 1; i < rnd.size(); ++i) if (rnd[i]==rnd[i-1]) norep = false;
        CHECK(norep && rnd.size() >= 11, "Random never repeats a note (%zu steps)", rnd.size());
    }
    { // swing
        Arp a; a.prepare(sr); a.setMode(Arp::Up); a.setRate(0.25f); a.setTempo(120); a.setSwing(0.5f); a.setGate(0.3f);
        auto ev = ons(runArp(a, 6000 * 6, {{0,60,true},{0,64,true}}));
        CHECK(ev.size()>=5 && ev[0].t==0 && ev[1].t==8000 && ev[2].t==12000 && ev[3].t==20000 && ev[4].t==24000,
              "swing 0.5 delays every second step by a third of a step: %lld %lld %lld %lld %lld", (long long)ev[0].t,(long long)ev[1].t,(long long)ev[2].t,(long long)ev[3].t,(long long)ev[4].t);
    }
    { // gate and note-offs pair
        Arp a; a.prepare(sr); a.setMode(Arp::Up); a.setRate(0.25f); a.setTempo(120); a.setGate(0.5f);
        auto ev = runArp(a, 6000 * 4, {{0,60,true}});
        bool paired = ev.size() >= 2 && !ev[1].on && ev[1].t == 3000;
        CHECK(paired, "gate 0.5: the note lets go half a step later (%lld)", ev.size() > 1 ? (long long)ev[1].t : -1LL);
        Arp b; b.prepare(sr); b.setMode(Arp::Up); b.setRate(0.25f); b.setTempo(120); b.setGate(1.f);
        auto e2 = runArp(b, 6000 * 4, {{0,60,true}});
        int on = 0, maxOn = 0; for (auto &e : e2) { on += e.on ? 1 : -1; maxOn = std::max(maxOn, on); }
        CHECK(maxOn == 1, "gate 1: never two of its notes on at once");
    }
    { // hold
        Arp a; a.prepare(sr); a.setMode(Arp::Up); a.setRate(0.25f); a.setTempo(120); a.setHold(true);
        auto ev = ons(runArp(a, 6000 * 10, {{0,60,true},{0,64,true},{1000,60,false},{1000,64,false},{30000,70,true},{31000,70,false}}));
        bool latched = false, replaced = true; for (auto &e : ev) { if (e.t > 6000 && e.t < 30000 && (e.note==60||e.note==64)) latched = true; if (e.t > 30000 && e.note != 70) replaced = false; }
        CHECK(latched, "Hold keeps the pattern after the keys let go");
        CHECK(replaced, "a new key after all keys are up replaces the latched pattern");
    }
    { // reset then fresh grid
        Arp a; a.prepare(sr); a.setMode(Arp::Up); a.setRate(0.25f); a.setTempo(120);
        int64_t clock = 0; Arp::Event e; a.keyDown(60, 100, 0);
        for (; clock < 10000; ++clock) while (a.poll(clock, e)) {}
        a.reset();
        bool silent = true; for (; clock < 20000; ++clock) while (a.poll(clock, e)) silent = false;
        a.keyDown(62, 100, 20003); bool fresh = false; while (a.poll(20003, e)) if (e.on && e.note == 62) fresh = true;
        CHECK(silent && fresh, "reset: silent, then the next key starts a fresh grid on its own sample");
    }
    { // phrase gap keeps the grid for 2 s
        Arp a; a.prepare(sr); a.setMode(Arp::Up); a.setRate(0.25f); a.setTempo(120); a.setGate(0.3f);
        auto ev = ons(runArp(a, 48000 * 5, {{0,60,true},{20000,60,false},{50000,62,true},{60000,62,false},{200000,64,true}}));
        bool kept = false, fresh = false; for (auto &e : ev) { if (e.note==62 && e.t==54000) kept = true; if (e.note==64 && e.t==200000) fresh = true; }
        CHECK(kept, "a key within 2 s of the last stays on the grid (next step 54000)");
        CHECK(fresh, "after 2 s of nothing, a key starts a fresh grid");
    }
    { // unison equal power
        bool ok = true; float r1 = 0;
        for (int n = 1; n <= 7; ++n) { analog::Unison<7> u; u.setCount(n); u.setSpread(9.f); u.reset(42);
            double s = 0; const int N = 96000; for (int i = 0; i < N; ++i) { float x = u.next(110.f / 48000.f); s += x * x; }
            float r = std::sqrt(s / N); if (n == 1) r1 = r; float db = 20 * std::log10(r / r1); printf("   unison %d: %+.2f dB\n", n, db); if (std::fabs(db) > 1.0f) ok = false; }
        CHECK(ok, "unison keeps equal power within ±1 dB for 1…7 saws");
    }
    { // glide
        analog::Glide g; g.setTime(0.2f, 48000); g.jump(45); g.glideTo(57);
        float at = g.advance(9600); float after = g.advance(480);
        CHECK(std::fabs(at - 57) < 0.05f && after == 57.f, "glide arrives in exactly its time (%.4f)", at);
    }
    { // shaper: ADAA vs naive aliasing on a driven band-limited saw
        const int N = 8192; const double fs = 44100; const int k = 372; const double f0 = fs * k / N;
        auto spectrum = [&](bool adaa, float drive, float fold, double &harm, double &alias) {
            analog::Shaper sh; sh.set(drive, fold, 0.f); analog::SawOsc o; o.reset(0.f);
            std::vector<float> x(N); const float inc = (float)(f0 / fs);
            for (int i = 0; i < 4096; ++i) { float v = 0.7f * o.next(inc); adaa ? sh.process(v) : 0; }
            for (int i = 0; i < N; ++i) { float v = 0.7f * o.next(inc);
                if (adaa) x[i] = sh.process(v);
                else { float g = 1 + 11 * drive; float y = v; if (fold > 0) { float m = std::min(1.f, 5 * fold); y = m * std::sin(1.5707963f * (1 + 3 * fold) * y) + (1 - m) * y; } x[i] = analog::tanhApprox(g * y) / analog::tanhApprox(g); } }
            harm = alias = 0;
            for (int b = 1; b < N / 2; ++b) { std::complex<double> s = 0; for (int i = 0; i < N; ++i) s += (double)x[i] * std::polar(1.0, -2 * M_PI * b * i / N);
                double p = std::norm(s); if (b % k == 0) harm += p; else alias += p; }
        };
        for (float d : {0.5f, 1.f}) for (float f : {0.f, 0.6f}) {
            double h1, a1, h2, a2; spectrum(false, d, f, h1, a1); spectrum(true, d, f, h2, a2);
            double naive = 10 * std::log10(a1 / h1), adaa = 10 * std::log10(a2 / h2);
            printf("   drive %.1f fold %.1f: aliasing naive %.1f dB, ADAA %.1f dB\n", d, f, naive, adaa);
            CHECK(adaa < naive - 6, "ADAA cuts aliasing by more than 6 dB (drive %.1f fold %.1f)", d, f);
        }
    }
    { // shaper bypass + finite
        analog::Shaper sh; sh.set(0.f, 0.f, 0.f); double err = 0; float prev = 0;
        for (int i = 0; i < 1000; ++i) { float x = 0.3f * std::sin(i * 0.01f); float y = sh.process(x); if (i > 0) err = std::max(err, (double)std::fabs(y - analog::tanhApprox(0.5f*(x+prev)) / analog::tanhApprox(1.f))); prev = x; }
        CHECK(err < 1e-3, "drive 0, fold 0: a gentle unity clipper (err %.2e)", err);
        analog::Shaper s2; s2.set(1, 1, 1); bool fin = true; for (int i = 0; i < 100000; ++i) { float y = s2.process(4.f * std::sin(i * 0.37f)); if (!std::isfinite(y) || std::fabs(y) > 1.2f) fin = false; }
        CHECK(fin, "full growl on a hot input stays finite and bounded");
    }
    printf("%s (%d failures)\n", fails ? "FAILED" : "ALL OK", fails);
    return fails ? 1 : 0;
}
