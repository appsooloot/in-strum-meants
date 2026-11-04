// Morning Box: two hearts. On top, a struck box: a modelled celesta (steel bars over tuned wooden resonators,
// felt hammers) that morphs into a music box's plucked comb. Underneath, a warm synth wall that builds the
// longer you play (after the synths in "Dunno"): unison voices, an octave and a soft shimmer stack up, the
// filter opens and the wall widens, then it thins out gently in silence. Haze adds chorus and a soft tape blur.
// Everything is preallocated.
#pragma once
#include "DSPCommon.hpp"
#include "Engine.hpp"
#include "PianoStrings.hpp"
#include "SpaceReverb.hpp"
#include <vector>

namespace isd {

class MorningBox final : public Engine {
public:
    explicit MorningBox(double sampleRate);
    void setParam(int address, float value, bool snap) override;
    void noteOn(int note, int velocity) override;
    void noteOff(int note) override;
    void setSustain(bool down) override;
    void allNotesOff() override;
    void allSoundOff() override;
    void render(float *left, float *right, int frames) override;
    int debugCount(int which) const override;
    int activeVoices() const override;

    static constexpr int kBoxPolyphony = 24, kWallPolyphony = 24;
    static constexpr int kBoxPool = 30, kWallPool = 36;   // plus voices fading out after being stolen (a 12-note chord at once)
    static constexpr int kSub = 32;
    static constexpr int kUnison = 6;

private:
    struct Burst {
        int left = 0, age = 0, attack = 1;
        float amp = 0, decay = 0;
        Biquad bp;
        void start(float seconds, float hz, float q, float rms, double sr);
        inline float next(FastRandom &rng) {
            if (left <= 0) return 0.f;
            --left;
            float env = age < attack ? (float)age / (float)attack : 1.f;
            ++age;
            float x = rng.bipolar() * amp * env;
            amp *= decay;
            return bp.process(x);
        }
    };

    struct BoxVoice {
        bool active = false, keyDown = false, damped = false, fading = false;
        int note = 0, pitch = 0;
        float panL = 0.7071f, panR = 0.7071f;
        float fadeGain = 1, fadeStep = 0, level = 0, ref = 0;
        StringBank<8> modes;
        Burst tick;
    };

    struct WallVoice {
        bool active = false, keyDown = false, released = false, fading = false;
        int note = 0, pitch = 0;
        uint64_t born = 0;   // when it was struck (the wall's oldest held note is the one to let go)
        float velocity = 0, env = 0, attackK = 0, fadeGain = 1, fadeStep = 0;
        double phase[kUnison + 1] = {}, sub = 0, shimmer = 0;
        float s[2][4] = {};       // the two channels' 4-pole filter states
    };

    BoxVoice &allocateBox();
    WallVoice &allocateWall();
    void startBox(BoxVoice &v, int note, int pitch, int velocity);
    void startWall(WallVoice &v, int note, int pitch, int velocity);
    void dampBox(BoxVoice &v);
    void releaseWall(WallVoice &v);
    void retune();
    void stepBuild(int n);
    void processBlock(float *left, float *right, int n);
    void housekeeping();

    double sr;
    BoxVoice box[kBoxPool];
    WallVoice wall[kWallPool];
    uint64_t wallStamp = 0;
    bool sustain = false;
    FastRandom rng;

    // Dials (raw) and mood.
    float pTranspose = 0, pBars = 0.6f, pBox = 0.2f, pWidth = 0.55f;
    bool boxOnly = false, wallOnly = false;
    float mEnergy = 0.5f, mWarmth = 0.5f, mBright = 0.5f, mSpace = 0.5f, mMotion = 0.5f;
    Smoothed fine, bloom, build, haze, space, wet;
    float fineRatio = 1, appliedCents = 0, appliedSpace = -1, appliedHaze = -1, appliedBox = -1;

    // Build: how far the wall has grown (0…1), and what drives it.
    float buildLevel = 0, noteRate = 0;

    Biquad boxBody[2][2], hazeShelf[2];
    std::vector<float> hazeBuf[2];
    int hazePos = 0, hazeLen = 1;
    double lfo1 = 0, lfo2 = 0, wowPhase = 0;

    SpaceReverb reverb;
    PeakLimiter limiter;
    bool idle = true, reverbLive = false;
    int idleSamples = 0;
    unsigned blockCount = 0;   // wraps after 2^32 blocks, a multiple of 4: every-fourth-block work keeps its cadence
};

} // namespace isd
