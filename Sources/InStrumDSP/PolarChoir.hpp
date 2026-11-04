// Polar Choir: a vowel pad that breathes. Each voice is two detuned band-limited saws (the Orbit Pad BLEP)
// through three parallel formant band-passes that morph u → o → a → e → i, with breath noise through the same
// formants, a bowed-glass partial layer on top and a swell that keeps leaning in while a note is held.
// A two-tap chorus and the shared Space reverb (with shimmer) widen it. Everything is preallocated.
#pragma once
#include "DSPCommon.hpp"
#include "Engine.hpp"
#include "SpaceReverb.hpp"
#include <vector>

namespace isd {

class PolarChoir final : public Engine {
public:
    explicit PolarChoir(double sampleRate);
    void setParam(int address, float value, bool snap) override;
    void noteOn(int note, int velocity) override;
    void noteOff(int note) override;
    void setSustain(bool down) override;
    void allNotesOff() override;
    void allSoundOff() override;
    void render(float *left, float *right, int frames) override;
    int activeVoices() const override;

    static constexpr int kPolyphony = 16;   // sounding voices
    static constexpr int kPool = 20;        // plus voices fading out after being stolen
    static constexpr int kSub = 32;         // samples per inner block
    static constexpr int kGlass = 4;        // glass partials (each a beating pair of sines)

private:
    struct Voice {
        bool active = false, keyDown = false, releasing = false, fading = false;
        int note = 0;
        unsigned age = 0;
        float pitch = 0, gain = 0, pan = 0;
        double phase[2] = {};
        Biquad formant[3];
        float driftPhase = 0, driftRate = 0, breathPhase = 0, breathRate = 0;
        // Envelopes: raised-cosine attack, exponential release; the swell's press (0…1) and the glass onset.
        int attackPos = 0, attackLen = 1;
        float env = 0, pressX = 0, glassX = 0, glassRate = 0;
        float glassC[kGlass][2] = {}, glassS[kGlass][2] = {};
        float airZ = 0;
        float fadeGain = 1, fadeStep = 0;
    };

    void startVoice(Voice &v, int note, int velocity);
    Voice &allocate();
    void beginFade(Voice &v);
    void release(Voice &v);
    void processBlock(float *left, float *right, int n);
    void renderVoice(Voice &v, float *outL, float *outR, int n);
    void chorus(float *l, float *r, int n);
    void housekeeping();

    double sr;
    Voice voices[kPool];
    bool sustain = false, voicesOnly = false;
    unsigned noteCounter = 0;
    FastRandom rng;

    // Dials (smoothed) and mood.
    float pTranspose = 0;
    float mEnergy = 0.5f, mWarmth = 0.5f, mBright = 0.5f, mSpace = 0.5f, mMotion = 0.5f;
    Smoothed fine, vowel, breath, glass, swell, shimmer, space, width, wet;
    float appliedWarmth = -1, appliedBright = -1, appliedSpace = -1, appliedShimmer = -1;

    // Per-block values shared by every voice.
    float swellNow = 0.5f, releaseCoef = 1, pressUp = 0, pressDown = 0, driftDepth = 0;

    // Chorus (stereo, two modulated taps per side).
    std::vector<float> chorusBuf[2];
    int chorusW = 0, chorusLen = 0;
    float chorusPh[2] = {};

    Biquad lowShelf[2], highShelf[2];
    SpaceReverb reverb;
    PeakLimiter limiter;
    bool idle = true, reverbLive = false;
    int idleSamples = 0, blockCount = 0;
};

} // namespace isd
