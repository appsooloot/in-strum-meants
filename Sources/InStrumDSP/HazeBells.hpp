// Haze Bells (after "High by the Beach"): a dulcitone-style keyboard. Each key strikes a modelled tuning
// fork (a pure fundamental, a weak octave and a bright "clang" mode near 6.25 × f0 that dies in a moment,
// plus a felt thump), over an airy drawbar-style organ (8′, 4′ and 2⅔′ with slow vibrato). Everything passes
// through a lo-fi haze: gentle saturation, a parallel crush, a filtered ping-pong echo on the song's dotted
// eighth, a slow shared drift, then the shared Space reverb. Everything is preallocated.
#pragma once
#include "DSPCommon.hpp"
#include "Engine.hpp"
#include "SpaceReverb.hpp"
#include "TapeKit.hpp"
#include <vector>

namespace isd {

class HazeBells final : public Engine {
public:
    explicit HazeBells(double sampleRate);
    void setParam(int address, float value, bool snap) override;
    void noteOn(int note, int velocity) override;
    void noteOff(int note) override;
    void setSustain(bool down) override;
    void allNotesOff() override;
    void allSoundOff() override;
    void render(float *left, float *right, int frames) override;
    int activeVoices() const override;

    static constexpr int kPolyphony = 24;
    static constexpr int kPool = 28;
    static constexpr int kSub = 32;
    static constexpr int kModes = 4;   // fundamental, octave, clang, tink
    /// The brief's echo: a dotted eighth at 132 BPM (docs/superpowers/briefs/haze-bells.md).
    static constexpr float kEchoSeconds = 0.75f * 60.f / 132.f;

private:
    struct Voice {
        bool active = false, keyDown = false, releasing = false, fading = false;
        int note = 0;
        unsigned age = 0;
        float pitch = 0, vel = 0, gain = 0, hard = 0;
        // Fork: decaying complex oscillators (sin part is the output, so a strike starts from zero).
        float mc[kModes] = {}, ms[kModes] = {}, amp[kModes] = {}, t60[kModes] = {}, ratio[kModes] = {};
        bool modeOn[kModes] = {};
        float thump = 0, thumpLP = 0;
        float bellLevel = 1;           // damper: falls once the key (and pedal) let go
        // Organ
        float oc = 1, os = 0, oEnv = 0, click = 0;
        int oAttPos = 0, oAttLen = 1;
        float vibPh = 0, vibRate = 6;
        Biquad breathBP;
        float panL = 0.7071f, panR = 0.7071f;
        float fadeGain = 1, fadeStep = 0;
    };

    void startVoice(Voice &v, int note, int velocity);
    Voice &allocate();
    void beginFade(Voice &v);
    void release(Voice &v);
    void processBlock(float *left, float *right, int n);
    void renderVoice(Voice &v, float *outL, float *outR, float *orgL, float *orgR, int n);
    void organChorus(float *l, float *r, int n);
    void housekeeping();
    static float level(const Voice &v);

    double sr;
    Voice voices[kPool];
    bool sustain = false;
    unsigned noteCounter = 0;
    FastRandom rng;

    float pTranspose = 0;
    float mEnergy = 0.5f, mWarmth = 0.5f, mBright = 0.5f, mSpace = 0.5f, mMotion = 0.5f;
    Smoothed fine, bells, organ, echo, crush, drift, space, wet;
    float appliedSpace = -1;

    // Per-block values shared by every voice.
    float driftCents = 0, motionNow = 0.5f, bellsNow = 0.8f, organNow = 0.25f;
    float dampCoef = 1, organRelCoef = 1;
    float driftWalk = 0, driftLP = 0;

    // Organ chorus (one modulated tap per side).
    std::vector<float> chorusBuf[2];
    int chorusW = 0, chorusLen = 1;
    float chorusPh = 0;

    BitCrusher crusher;
    FilteredEcho echoes;
    SpaceReverb reverb;
    PeakLimiter limiter;
    bool idle = true, reverbLive = false;
    int idleSamples = 0;
    unsigned blockCount = 0;   // wraps after 2^32 blocks, a multiple of 4: every-fourth-block work keeps its cadence
};

} // namespace isd
