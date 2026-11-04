// Cabin Felt: a modelled upright piano with the felt moderator down (shared modal strings, a felt hammer whose
// hardness follows velocity, the quiet mechanics of the key and dampers, an upright's cabinet and a small log
// room), warmed by Fire, with a soft flugelhorn that follows the top note you play (after Keyon Harrold's
// trumpet on "Stay"). Everything is preallocated.
#pragma once
#include "DSPCommon.hpp"
#include "Engine.hpp"
#include "PianoStrings.hpp"
#include "SpaceReverb.hpp"
#include <vector>

namespace isd {

class CabinFelt final : public Engine {
public:
    explicit CabinFelt(double sampleRate);
    void setParam(int address, float value, bool snap) override;
    void noteOn(int note, int velocity) override;
    void noteOff(int note) override;
    void setSustain(bool down) override;
    void allNotesOff() override;
    void allSoundOff() override;
    void render(float *left, float *right, int frames) override;
    int debugCount(int which) const override;
    int activeVoices() const override;

    static constexpr int kPolyphony = 32;   // sounding piano voices
    static constexpr int kPool = 40;        // plus voices fading out after being stolen
    static constexpr int kSub = 32;         // samples per inner block
    static constexpr int kStrings = 64;     // string components per voice
    /// The horn's range (a flugelhorn's sweet range, E3–C6); other notes move by octaves into it.
    static constexpr int kHornLow = 52, kHornHigh = 84;

private:
    /// A short band-passed noise burst (hammer felt, key thump, damper lift and chuff).
    struct Burst {
        int left = 0, age = 0, attack = 1;
        float amp = 0, decay = 0;
        Biquad bp;
        OnePole lp;
        void start(float seconds, float hz, float q, float rms, double sr);
        inline float next(FastRandom &rng) {
            if (left <= 0) return 0.f;
            --left;
            float env = age < attack ? (float)age / (float)attack : 1.f;
            ++age;
            float x = rng.bipolar() * amp * env;
            amp *= decay;
            return lp.process(bp.process(x));
        }
    };

    struct Voice {
        bool active = false, keyDown = false, damped = false, fading = false;
        int note = 0, pitch = 0;
        float panL = 0.7071f, panR = 0.7071f;
        int attackPos = 0, attackLen = 1;
        float fadeGain = 1, fadeStep = 0;
        float level = 0, stringRef = 0, noteRms = 0;
        StringBank<kStrings> str;
        Burst hammer, thump, lift, chuff;
    };

    /// One soft flugelhorn voice on the top line.
    struct Horn {
        bool sounding = false, released = true, fast = false;
        int key = -1, pitch = 0;
        float midi = 0, from = 0, to = 0, scoop = 0, env = 0, velocity = 0, bright = 0;
        float velTarget = 0, brightTarget = 0;   // velocity and brightness glide to these over about 15 ms
        int glidePos = 0, glideLen = 1, age = 0;
        int sinceOnset = 1 << 30;                // samples since the phrase or slur began (a chord's later notes land within 35 ms)
        double phase = 0, vibPhase = 0;
        Biquad f1, f2, breath;
        OnePole dark;
    };

    void startVoice(Voice &v, int note, int pitch, int velocity);
    Voice &allocate();
    void damp(Voice &v, float chuffScale = 1.f);
    void beginFade(Voice &v);
    void retune();
    void startHorn(int note, int velocity);
    void releaseHorn(bool fast);
    float renderHorn(float freqRatio);
    void setSympDecay(float t60) { symp.setDecay(t60, fineRatio); }
    void processBlock(float *left, float *right, int n);
    void renderVoice(Voice &v, float *sL, float *sR, float *mono, int n);
    void housekeeping();

    double sr;
    Voice voices[kPool];
    Horn horn;
    bool keyDown[128] = {};
    bool sustain = false;
    FastRandom rng;

    // Dials (raw) and mood.
    float pTranspose = 0, pFelt = 0.6f, pWidth = 0.5f;
    bool noMechanics = false, hornOnly = false;
    float mEnergy = 0.5f, mWarmth = 0.5f, mBright = 0.5f, mSpace = 0.5f, mMotion = 0.5f;
    Smoothed fine, hornGain, fire, wood, space, wet, sympGain;
    float fineRatio = 1, appliedCents = 0, appliedFire = -1, appliedSpace = -1, appliedWood = -1;

    Biquad body[4][2], lowShelf[2], highShelf[2];
    OnePole erTone[2];
    std::vector<float> erBuf[2];
    int erPos = 0, erLen = 1;
    int erTap[2][4] = {};
    float erGain = 0;
    SympBank symp;
    bool sympActive = false;

    SpaceReverb reverb;
    PeakLimiter limiter;
    bool idle = true, reverbLive = false;
    int idleSamples = 0;
    unsigned blockCount = 0;   // wraps after 2^32 blocks, a multiple of 4: every-fourth-block work keeps its cadence
};

} // namespace isd
