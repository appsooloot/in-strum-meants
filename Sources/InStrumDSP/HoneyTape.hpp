// Honey Tape (after "Music to Watch Boys To"): a tape-replay keyboard made from scratch. Each note is a
// breathy flute (a near-pure tone with gentle overtones, band-passed breath, a chiff and delayed vibrato)
// and a soft string section (four detuned band-limited saws through a warm filter), blended by one dial.
// Both pass through one shared tape: wow and flutter, saturation, a rounded top, a warm bump and hiss.
// A reel can make held notes run out like tape strips. Everything is preallocated.
#pragma once
#include "DSPCommon.hpp"
#include "Engine.hpp"
#include "SpaceReverb.hpp"
#include "TapeKit.hpp"

namespace isd {

class HoneyTape final : public Engine {
public:
    explicit HoneyTape(double sampleRate);
    void setParam(int address, float value, bool snap) override;
    void noteOn(int note, int velocity) override;
    void noteOff(int note) override;
    void setSustain(bool down) override;
    void allNotesOff() override;
    void allSoundOff() override;
    void render(float *left, float *right, int frames) override;
    int activeVoices() const override;

    static constexpr int kPolyphony = 16;
    static constexpr int kPool = 20;
    static constexpr int kSub = 32;
    static constexpr int kSaws = 4;

private:
    struct Voice {
        bool active = false, keyDown = false, releasing = false, fading = false, reelFading = false;
        int note = 0;
        unsigned age = 0;
        long life = 0;                 // samples since the note started (the tape strip's position)
        float pitch = 0, vel = 0, gain = 0;
        // Flute
        float c = 1, s = 0;            // rotator: cos and sin of the fundamental's phase
        float a2 = 0, a3 = 0, a4 = 0;  // overtones
        Biquad breath1, breath2, chiffBP, hissBP;
        float hissLevel = 0;
        float chiff = 0, chiffDecay = 0;
        float vibPh = 0, vibRate = 5;
        float fEnv = 0;
        int fAttPos = 0, fAttLen = 1;
        // Strings
        double ph[kSaws] = {};
        float walk[kSaws] = {}, walkLP[kSaws] = {};
        SVF filt[2];
        float sEnv = 0;
        int sAttPos = 0, sAttLen = 1;
        // Endings
        float reelGain = 1, reelStep = 0;
        float fadeGain = 1, fadeStep = 0;
        float panL = 0.7071f, panR = 0.7071f;
    };

    void startVoice(Voice &v, int note, int velocity);
    Voice &allocate();
    void beginFade(Voice &v);
    void release(Voice &v);
    void processBlock(float *left, float *right, int n);
    void renderVoice(Voice &v, float *outL, float *outR, int n);
    void housekeeping();

    double sr;
    Voice voices[kPool];
    bool sustain = false, debugNoVibrato = false;
    unsigned noteCounter = 0;
    FastRandom rng;

    float pTranspose = 0;
    float mEnergy = 0.5f, mWarmth = 0.5f, mBright = 0.5f, mSpace = 0.5f, mMotion = 0.5f;
    Smoothed fine, breath, strings, wow, age, reel, space, width, wet;
    float appliedWarmth = -1, appliedSpace = -1;

    // Per-block values shared by every voice.
    float fluteMix = 1, stringsMix = 0, breathNow = 0.45f, motionNow = 0.5f, brightNow = 0.5f, wowNow = 0;
    float fRelCoef = 1, sRelCoef = 1, attackScale = 1, spreadCents = 8, reelSamples = -1, widthNow = 0.5f;

    TapeDelay tapeDelay;
    TapeSaturator tapeColour;
    Biquad warmShelf[2];
    SpaceReverb reverb;
    PeakLimiter limiter;
    bool idle = true, reverbLive = false;
    int idleSamples = 0;
    unsigned blockCount = 0;   // wraps after 2^32 blocks, a multiple of 4: every-fourth-block work keeps its cadence
};

} // namespace isd
