#include "SpaceReverb.hpp"
#include "include/InStrumDSP.h"
#include <algorithm>

namespace isd {

static const float kBaseMs[8] = {29.7f, 37.1f, 41.1f, 43.7f, 53.3f, 61.3f, 71.9f, 83.9f};
static const float kInSign[8] = {1, -1, 1, 1, -1, 1, -1, -1};
static const float kOutL[8] = {1, -1, 1, -1, 1, -1, 1, -1};
static const float kOutR[8] = {1, 1, -1, -1, 1, 1, -1, -1};

SpaceReverb::SpaceReverb(double sampleRate, int /*maxFrames*/) : sr(sampleRate) {
    modDepth = (float)(0.0005 * sr);
    predelay.init((int)(0.081 * sr) + 4);
    const float apMs[4] = {4.7f, 3.6f, 12.7f, 9.3f};
    for (int i = 0; i < 4; ++i) {
        diffusers[i].length = std::max(1, (int)(apMs[i] * 0.001 * sr));
        diffusers[i].d.init(diffusers[i].length + 2);
    }
    int maxLen = (int)(0.170 * sr) + (int)modDepth + 8;
    for (int i = 0; i < kLines; ++i) {
        lines[i].init(maxLen);
        length[i].init(sr, 60.0);
        lfoRate[i] = 0.1f + 0.6f * (float)i / 7.f;
        lfoPhase[i] = (float)i / 8.f;
    }
    shimmerWindow = (float)(0.08 * sr);
    shimmerBuf.init((int)shimmerWindow + 8);
    shimmerAmount.init(sr, 50.0);
    predelaySamples.init(sr, 50.0);
    configure(0.5f, 0.5f, 10.f, 0.f);
    for (int i = 0; i < kLines; ++i) length[i].snap(length[i].target);
    predelaySamples.snap(predelaySamples.target);
    shimmerAmount.snap(shimmerAmount.target);
}

void SpaceReverb::configure(float size, float damping, float predelayMs, float shimmer) {
    size = std::clamp(size, 0.f, 1.f); damping = std::clamp(damping, 0.f, 1.f); shimmer = std::clamp(shimmer, 0.f, 1.f);
    // Shimmer feeds energy back in, so the tank's own decay is shortened a little to keep the total tail similar.
    float rt60 = (1.2f + 6.8f * size) * (1.f - 0.3f * shimmer);
    float scale = 0.5f + 1.5f * size;
    float cutoff = 1500.f + (1.f - damping) * 14000.f;
    for (int i = 0; i < kLines; ++i) {
        float samples = kBaseMs[i] * 0.001f * (float)sr * scale;
        length[i].setTarget(samples);
        gain[i] = std::pow(10.f, -3.f * samples / (rt60 * (float)sr));
        damp[i].setCutoff(cutoff, sr);
    }
    predelaySamples.setTarget(std::clamp(predelayMs, 0.f, 80.f) * 0.001f * (float)sr);
    shimmerAmount.setTarget(shimmer);
}

void SpaceReverb::clear() {
    predelay.clear();
    for (auto &a : diffusers) a.d.clear();
    for (int i = 0; i < kLines; ++i) { lines[i].clear(); damp[i].clear(); }
    shimmerBuf.clear();
}

void SpaceReverb::process(const float *inL, const float *inR, float *outL, float *outR, int frames) {
    DenormalGuard guard;
    float inPeak = 0;
    for (int n = 0; n < frames; ++n) inPeak = std::max(inPeak, std::max(std::fabs(inL[n]), std::fabs(inR[n])));
    if (inPeak >= 1e-6f) gated = false;
    if (gated) {
        std::fill(outL, outL + frames, 0.f);
        std::fill(outR, outR + frames, 0.f);
        return;
    }
    float outPeak = 0;
    const float twoPiOverSr = kTwoPi / (float)sr;
    for (int n = 0; n < frames; ++n) {
        float x = 0.5f * (inL[n] + inR[n]);
        predelay.write(x);
        float d = predelay.read(std::max(1.f, predelaySamples.next()));
        for (auto &a : diffusers) d = a.process(d);

        float y[kLines];
        float mono = 0;
        for (int i = 0; i < kLines; ++i) {
            lfoPhase[i] += lfoRate[i] / (float)sr;
            if (lfoPhase[i] >= 1.f) lfoPhase[i] -= 1.f;
            float delay = length[i].next() + modDepth * std::sin(kTwoPi * lfoPhase[i]);
            y[i] = lines[i].read(delay);
            mono += y[i];
        }
        (void)twoPiOverSr;
        // Shimmer: octave-up grains of the tank sum, fed back in.
        float shimmerOut = 0;
        float amount = shimmerAmount.next();
        shimmerBuf.write(mono * 0.125f);
        if (amount > 1e-4f) {
            shimmerPhase += 1.f / shimmerWindow;
            if (shimmerPhase >= 1.f) shimmerPhase -= 1.f;
            for (int k = 0; k < 2; ++k) {
                float p = shimmerPhase + 0.5f * (float)k;
                if (p >= 1.f) p -= 1.f;
                float delay = 1.f + shimmerWindow * (1.f - p);
                float s = std::sin(kPi * p);
                shimmerOut += shimmerBuf.read(delay) * s * s;
            }
        }
        // Damping and feedback gain, then Hadamard mixing.
        float f[kLines];
        for (int i = 0; i < kLines; ++i) f[i] = damp[i].process(y[i]) * gain[i];
        for (int h = 1; h < kLines; h <<= 1)
            for (int i = 0; i < kLines; i += h << 1)
                for (int j = i; j < i + h; ++j) { float a = f[j], b = f[j + h]; f[j] = a + b; f[j + h] = a - b; }
        const float norm = 0.35355339f;
        float inject = 0.35f * d + 0.35f * amount * shimmerOut;
        float l = 0, r = 0;
        for (int i = 0; i < kLines; ++i) {
            lines[i].write(f[i] * norm + kInSign[i] * inject);
            l += kOutL[i] * y[i];
            r += kOutR[i] * y[i];
        }
        outL[n] = 0.35f * l;
        outR[n] = 0.35f * r;
        outPeak = std::max(outPeak, std::max(std::fabs(outL[n]), std::fabs(outR[n])));
    }
    if (inPeak < 1e-6f && outPeak < 1e-6f) {
        silentFrames += frames;
        if (silentFrames >= (int)(0.25 * sr)) { clear(); gated = true; silentFrames = 0; }
    } else {
        silentFrames = 0;
    }
}

} // namespace isd

using isd::SpaceReverb;
struct ISDReverb { SpaceReverb impl; ISDReverb(double sr, int mf) : impl(sr, mf) {} };

extern "C" {
ISDReverb *isd_reverb_create(double sampleRate, int maxFrames) { return new ISDReverb(sampleRate, maxFrames); }
void isd_reverb_destroy(ISDReverb *r) { delete r; }
void isd_reverb_configure(ISDReverb *r, float size, float damping, float predelayMs, float shimmer) { r->impl.configure(size, damping, predelayMs, shimmer); }
void isd_reverb_process(ISDReverb *r, const float *inL, const float *inR, float *outL, float *outR, int frames) { r->impl.process(inL, inR, outL, outR, frames); }
}
