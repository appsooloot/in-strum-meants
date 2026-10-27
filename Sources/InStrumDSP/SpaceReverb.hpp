// Space: an 8-line feedback delay network with input diffusion, modulated delays,
// per-line damping, pre-delay, optional octave-up shimmer and a silence gate.
#pragma once
#include "DSPCommon.hpp"
#include <vector>

namespace isd {

class SpaceReverb {
public:
    SpaceReverb(double sampleRate, int maxFrames);
    /// size, damping, shimmer 0…1; pre-delay 0…80 ms. Real-time safe.
    void configure(float size, float damping, float predelayMs, float shimmer);
    /// 100% wet. In-place is allowed.
    void process(const float *inL, const float *inR, float *outL, float *outR, int frames);
    void clear();

private:
    static constexpr int kLines = 8;
    struct Delay {
        std::vector<float> buf;
        int w = 0;
        void init(int length) { buf.assign((size_t)length, 0.f); w = 0; }
        void write(float x) { buf[(size_t)w] = x; if (++w == (int)buf.size()) w = 0; }
        /// Linear-interpolated read of the sample written `d` samples before the most recent one (d ≥ 0).
        /// Integer and fractional parts are split first so large buffers keep full precision.
        float read(float d) const {
            int n = (int)buf.size();
            float whole = std::floor(d);
            int id = (int)whole; float f = d - whole;
            int i0 = w - 1 - id; while (i0 < 0) i0 += n;
            int i1 = i0 - 1; if (i1 < 0) i1 += n;
            return buf[(size_t)i0] + f * (buf[(size_t)i1] - buf[(size_t)i0]);
        }
        float tap(int d) const { int i = w - d; while (i < 0) i += (int)buf.size(); return buf[(size_t)i]; }
        void clear() { std::fill(buf.begin(), buf.end(), 0.f); w = 0; }
    };
    struct Allpass { Delay d; int length = 1; float g = 0.65f;
        float process(float x) { float v = d.tap(length); float y = -g * x + v; d.write(x + g * v); return y; } };

    double sr;
    Delay predelay;
    Allpass diffusers[4];
    Delay lines[kLines];
    OnePole damp[kLines];
    Smoothed length[kLines];
    float gain[kLines] = {};
    float lfoPhase[kLines] = {}, lfoRate[kLines] = {};
    float modDepth;
    Smoothed predelaySamples;
    // Shimmer (octave up, two crossfaded grains)
    Delay shimmerBuf;
    float shimmerPhase = 0, shimmerWindow;
    Smoothed shimmerAmount;
    // Silence gate
    int silentFrames = 0;
    bool gated = true;
};

} // namespace isd
