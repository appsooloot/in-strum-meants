// Ambience: twelve sources generated live (never loops), each gliding to its level over 2.5 s, through a
// small room whose amount follows "closeness", ducking under the instrument while you play.
// Everything is preallocated; the setters are lock-free atomics read at the start of each render.
#pragma once
#include "DSPCommon.hpp"
#include "SpaceReverb.hpp"
#include "include/InStrumDSP.h"
#include <atomic>
#include <memory>

namespace isd {

struct AmbienceContext {
    float sr = 48000.f;
    float density = 1.f;     // multiplies event rates
    float cool = 0.f;        // night cool 0…1
};

/// One generator. `render` adds its sound (calibrated for level 1) into `l`/`r`.
class AmbienceSource {
public:
    virtual ~AmbienceSource() = default;
    /// Called when the source comes up from silence: schedule events afresh.
    virtual void wake(const AmbienceContext &) {}
    virtual void render(float *l, float *r, int n, const AmbienceContext &c) = 0;
    float direct = 1.f, send = 0.5f;   // how much goes straight out and how much into the room
};

class Thunder;

class Ambience {
public:
    Ambience(double sampleRate, uint64_t seed);
    ~Ambience();
    void setLevel(int source, float level);
    void setCloseness(float c) { closeness.setTarget(clamp01(c)); }
    void setActivity(float a) { activity = clamp01(a); }
    void setNightCool(float c) { ctx.cool = clamp01(c); }
    void setDensity(float d) { ctx.density = d < 0.5f ? 0.5f : (d > 1.5f ? 1.5f : d); }
    void triggerThunder(float distance);
    void render(float *left, float *right, int frames);

    static constexpr int kBlock = 64;

private:
    struct Ramp {
        float value = 0, from = 0, to = 0;
        int pos = 0, len = 1;
        void setTarget(float t, int samples) { if (t == to) return; from = value; to = t; pos = 0; len = samples; }
        float advance(int n) {
            if (pos >= len) { value = to; return value; }
            pos = pos + n > len ? len : pos + n;
            float x = (float)pos / (float)len;
            value = from + (to - from) * x * x * (3.f - 2.f * x);
            return value;
        }
        bool silent() const { return value == 0.f && to == 0.f; }
    };

    void processBlock(float *left, float *right, int n);

    double sr;
    AmbienceContext ctx;
    std::unique_ptr<AmbienceSource> sources[ISD_AMB_COUNT];
    std::unique_ptr<Thunder> thunder;
    Ramp ramps[ISD_AMB_COUNT];
    float closenessApplied = -1, duckDb = 0, activity = 0;
    Smoothed closeness;
    struct OneSVF { float ic1 = 0, ic2 = 0; } air[2];
    float airA1 = 1, airA2 = 0, airA3 = 0, width = 1, directGain = 0.8f, roomGain = 0.5f;
    SpaceReverb room;
    bool roomLive = false;
};

} // namespace isd
