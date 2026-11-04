// Plankton Keys: a modelled electric piano whose notes scatter glowing sparks (after "Happiness Is a Butterfly").
// Each voice is a tine (a sine fundamental, a slow second and a quickly decaying third partial, slightly stretched)
// read by an asymmetric pickup that barks when you dig in, over a tone-bar partial that rings longer. A hammer
// thump on the strike, a damper click on release. Every note throws a few short glassy sparks a moment later,
// scattered across the stereo field. A pan tremolo, a four-stage phaser and the shared Space reverb finish it.
// Everything is preallocated.
#pragma once
#include "DSPCommon.hpp"
#include "Engine.hpp"
#include "SpaceReverb.hpp"

namespace isd {

class PlanktonKeys final : public Engine {
public:
    explicit PlanktonKeys(double sampleRate);
    void setParam(int address, float value, bool snap) override;
    void noteOn(int note, int velocity) override;
    void noteOff(int note) override;
    void setSustain(bool down) override;
    void allNotesOff() override;
    void allSoundOff() override;
    void render(float *left, float *right, int frames) override;
    int activeVoices() const override;

    static constexpr int kPolyphony = 24;   // sounding voices
    // As many again to fade out after being stolen (or struck again): chords under the pedal on a full pool steal
    // eight at once, and with only six spares the rest were cut dead (a click). A burst of up to kPolyphony notes
    // now always fades.
    static constexpr int kPool = 2 * kPolyphony;
    static constexpr int kSparks = 64;      // spark pool (pending and sounding)
    static constexpr int kSub = 32;         // samples per inner block
    static constexpr int kPartials = 4;     // tine fundamental, second, third; tone bar

private:
    /// A short band-passed noise burst (the damper's release click).
    struct Burst {
        int left = 0, age = 0, attack = 1;
        float amp = 0, decay = 0;
        Biquad bp;
        void start(float seconds, float hz, float q, float rms, double sr);
        inline float next(FastRandom &rng) {
            if (left <= 0) return 0.f;
            --left;
            const float env = age < attack ? (float)age / (float)attack : 1.f;
            ++age;
            const float x = rng.bipolar() * amp * env;
            amp *= decay;
            return bp.process(x);
        }
    };

    struct Voice {
        bool active = false, keyDown = false, damped = false, fading = false;
        int note = 0, pitch = 0;
        unsigned age = 0;
        float amp = 0, drive = 1, velDrive = 0, pan = 0;
        // Decaying phasors (output is the imaginary part): 0 fundamental, 1 second, 2 third (the tine), 3 tone bar.
        float re[kPartials] = {}, im[kPartials] = {}, cr[kPartials] = {}, ci[kPartials] = {};
        float hz[kPartials] = {}, dr[kPartials] = {};
        float dcZ = 0;
        int thumpPos = 0, thumpLen = 1;
        float thumpW = 0, thumpAmp = 0;
        Burst click;
        float level = 0, ref = 0, fadeGain = 1, fadeStep = 0;
    };

    struct Spark {
        bool active = false, fading = false;
        int wait = 0, age = 0, attack = 1;
        float re = 0, im = 0, cr = 0, ci = 0, gl = 0, gr = 0, floor = 0;
        float fadeGain = 1, fadeStep = 0;
    };

    Voice &allocate();
    void startVoice(Voice &v, int note, int velocity);
    void spawnSparks(const Voice &v);
    void damp(Voice &v);
    void beginFade(Voice &v);
    void retune(Voice &v);
    void processBlock(float *left, float *right, int n);
    void renderVoice(Voice &v, float *outL, float *outR, int n, float tineW, float barW, float panScale);
    void renderSparks(float *outL, float *outR, int n);
    void phaser(float *l, float *r, int n);
    void housekeeping();

    double sr;
    Voice voices[kPool];
    Spark sparks[kSparks];
    bool sustain = false, noSparkle = false, noTremolo = false;
    unsigned noteCounter = 0;
    FastRandom rng, noise;

    // Dials (smoothed) and mood.
    float pTranspose = 0;
    float mEnergy = 0.5f, mWarmth = 0.5f, mBright = 0.5f, mSpace = 0.5f, mMotion = 0.5f;
    Smoothed fine, tine, bark, sparkle, tremolo, phase, space, width, wet;
    float fineRatio = 1, appliedCents = 0, appliedBright = -1, appliedSpace = -1;

    // Tremolo and phaser state.
    double tremPhase = 0, phasePhase = 0;
    float tremGL = 1, tremGR = 1;
    float apX[2][4] = {}, apY[2][4] = {};
    float apA[2] = {};

    Biquad highShelf[2];
    SpaceReverb reverb;
    PeakLimiter limiter;
    bool idle = true, reverbLive = false;
    int idleSamples = 0;
    unsigned blockCount = 0;   // wraps after 2^32 blocks, a multiple of 4: every-fourth-block work keeps its cadence
};

} // namespace isd
