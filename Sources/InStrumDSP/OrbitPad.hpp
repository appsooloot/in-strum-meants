// Orbit Pad: a warm, slowly blooming analogue-style pad. Five detuned saws, three soft pulses an
// octave down and a sine sub (all band-limited with a 4-point B-spline BLEP), each oscillator on its
// own slow random pitch path; a zero-delay-feedback 4-pole ladder with gentle saturation whose cutoff
// blooms open as a chord is held; slow per-voice motion, a stereo chorus and the shared Space reverb.
// Everything is preallocated.
#pragma once
#include "DSPCommon.hpp"
#include "Engine.hpp"
#include "SpaceReverb.hpp"
#include <vector>

namespace isd {

class OrbitPad final : public Engine {
public:
    explicit OrbitPad(double sampleRate);
    void setParam(int address, float value, bool snap) override;
    void noteOn(int note, int velocity) override;
    void noteOff(int note) override;
    void setSustain(bool down) override;
    void allNotesOff() override;
    void allSoundOff() override;
    void render(float *left, float *right, int frames) override;
    int activeVoices() const override;

    static constexpr int kPolyphony = 16;   // sounding voices
    // As many again to fade out after being stolen: a two-hand chord on a full pool steals eight at once, and with
    // only four spares the rest were cut dead (a click up to 43 dB over the pad's quiet top end). A burst of up to
    // kPolyphony notes now always fades.
    static constexpr int kPool = 2 * kPolyphony;
    static constexpr int kSub = 32;         // samples per inner block
    static constexpr int kSaws = 5, kPulses = 3, kOsc = kSaws + kPulses;

private:
    struct Voice {
        bool active = false, keyDown = false, releasing = false, fading = false;
        int note = 0;
        unsigned age = 0;
        float pitch = 0, vel = 0, gain = 0, keyTrack = 1;
        float layerB = 1, subKey = 1, subMix = 0, subTarget = 0;   // octave-down layer and sub, scaled by key
        double phase[kOsc] = {};
        float walk[kOsc] = {}, walkLP[kOsc] = {};
        float pwPhase[kPulses] = {}, pwRate[kPulses] = {};
        float subC = 1, subS = 0;
        float lfoPhase[3] = {}, lfoRate[3] = {};
        // Envelopes
        int attackPos = 0, attackLen = 1;
        float env = 0, relCoef = 1;
        float bloomX = 0;
        // Filter
        float s[4] = {};
        float g = 0;
        // Stealing fade
        float fadeGain = 1, fadeStep = 0;
        float panL = 0.7071f, panR = 0.7071f;
    };

    void startVoice(Voice &v, int note, int velocity);
    Voice &allocate();
    void beginFade(Voice &v);
    void release(Voice &v);
    void processBlock(float *left, float *right, int n);
    void renderVoice(Voice &v, float *outL, float *outR, int n);
    void chorus(float *l, float *r, int n);
    void housekeeping();
    void chooseSubVoice();

    double sr;
    Voice voices[kPool];
    bool sustain = false, debugLayerA = false;
    unsigned noteCounter = 0;
    FastRandom rng;

    // Dials (smoothed where they act live) and mood.
    float pTranspose = 0;
    float mEnergy = 0.5f, mWarmth = 0.5f, mBright = 0.5f, mSpace = 0.5f, mMotion = 0.5f;
    Smoothed fine, bloom, drift, motion, shimmer, brightness, space, wet;
    float appliedWarmth = -1, appliedSpace = -1, appliedShimmer = -1;

    // Per-block values shared by every voice.
    float bloomRate = 0, releaseCoef = 1, closeCoef = 1, spreadCents = 0, driftCents = 0, motionAmt = 0;
    float brightNow = 0.5f, resonance = 0.8f;

    // Chorus (stereo, three modulated taps per side).
    std::vector<float> chorusBuf[2];
    int chorusW = 0, chorusLen = 0;
    float chorusPh[3] = {};

    Biquad lowShelf[2], highShelf[2];
    SpaceReverb reverb;
    PeakLimiter limiter;
    bool idle = true, reverbLive = false;
    int idleSamples = 0;
    unsigned blockCount = 0;   // wraps after 2^32 blocks, a multiple of 4: every-fourth-block work keeps its cadence
};

} // namespace isd
