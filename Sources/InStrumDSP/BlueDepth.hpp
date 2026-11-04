// Blue Depth (after "Underwater"): hold a chord and it blinks. The first instrument on the analogue voice core
// (AnalogVoice.hpp). Held notes from C3 up are arpeggiated in the order they were pressed, one sixteenth per step
// at the Tempo, on the sample clock; each step re-plucks its note's voice (a saw-leaning pulse and a saw a few
// cents apart, a sub and a breath of noise through a ZDF ladder with a fast filter envelope). A dotted-eighth
// ping-pong echo darkens with every repeat; Murk lowers the filter's ceiling and the reverb's highs while a slow
// current sways them; ghostly "oo"/"oh" voices swell in an octave above the held notes and sit deep in a dark
// reverb; notes below C3 are big held bass voices. The wheel bends everything ±2 semitones and pressure opens the
// filter and brings the ghosts forward. Width spreads the voices (each note its own place), the echo's ping-pong and
// the ghosts. Everything is preallocated, the echo's line for the slowest Tempo at the engine's sample rate
// (docs/superpowers/briefs/blue-depth.md).
#pragma once
#include "AnalogVoice.hpp"
#include "DSPCommon.hpp"
#include "Engine.hpp"
#include "SpaceReverb.hpp"
#include <cstdint>
#include <vector>

namespace isd {

class BlueDepth final : public Engine {
public:
    explicit BlueDepth(double sampleRate);
    void setParam(int address, float value, bool snap) override;
    void noteOn(int note, int velocity) override;
    void noteOff(int note) override;
    void setSustain(bool down) override;
    /// Every voice fades out over 20 ms, the arp stops (the next note starts a fresh grid), the echo fades and
    /// empties, and the wheel and pressure return to rest; the reverb tail continues.
    void allNotesOff() override;
    /// As allNotesOff, and the reverb fades and empties too.
    void allSoundOff() override;
    void render(float *left, float *right, int frames) override;
    int activeVoices() const override;
    void pitchBend(float semitones) override;
    void aftertouch(int note, float pressure) override;

    static constexpr int kPolyphony = 12;   // sounding voices
    static constexpr int kPool = 16;        // plus voices fading out after being stolen
    static constexpr int kSub = 32;         // samples per inner block (shorter where an arp step falls)
    static constexpr int kSplit = 48;       // C3: notes from here up blink and have ghosts; below it, the bass
    static constexpr float kSlowestTempo = 70.f;
    /// The echo: a dotted eighth (3/16 of a bar) at the Tempo.
    static float echoSeconds(float bpm) { return 0.75f * 60.f / bpm; }
    /// One arp step: a sixteenth at the Tempo.
    static float stepSeconds(float bpm) { return 15.f / bpm; }

private:
    struct Voice {
        bool active = false, fading = false;
        bool keyDown = false, sustained = false;   // held by its key, or by the pedal after the key let go
        bool bass = false;                          // a held bass voice (below C3 with Bass up): never arpeggiated
        bool ghost = false;                         // C3 and up: a ghost sings an octave above it
        int note = 0;
        unsigned age = 0;
        float pitch = 0, gain = 0, pan = 0, ghostPan = 0;   // gain: the velocity's (the arp's accents ride on it)
        float detuneA = 0, detuneB = 0, keyTrack = 1, hpHz = 30;
        analog::ShapeOsc oscA;
        analog::SawOsc oscB;
        analog::Slop slop;
        analog::Ladder ladder;
        analog::HighPass highPass;
        analog::ADSR amp, filter;
        float pressure = 0;
        // The ghost: a soft pulse an octave up with breath, through two drifting formants, swelling in slowly.
        analog::ShapeOsc ghostOsc;
        analog::TwoFormant formant;
        float ghostEnv = 0, ghostX = 0, ghostSwell = 1.5f, ghostVel = 0, vowelPhase = 0, vowelRate = 0.08f, softZ = 0;
        float fadeGain = 1, fadeStep = 0;
        bool held() const { return keyDown || sustained; }
    };

    /// The stereo dotted-eighth echo: ping-pong by Width, each repeat darker through a one-pole in the loop, a
    /// slow wow. Its buffer is sized at construction for the slowest Tempo.
    struct Echo {
        std::vector<float> buf[2];
        int len = 1, w = 0;
        double sr = 48000;
        float delay = 1, from = 1;                  // samples: the glide's goal and where this block starts
        double wowPhase = 0;
        float feedback = 0, mix = 0, width = 0, lpA = 0, hpA = 0;
        float lp[2] = {}, hpX[2] = {}, hpY[2] = {};
        bool awake = false;
        int quiet = 0;
        float fade = 1, fadeStep = 0;
        bool emptying = false;
        void prepare(double sampleRate, float maxSeconds);
        void clear();
        void beginEmpty();
        void process(const float *inL, const float *inR, float *outL, float *outR, int n);
    };

    Voice *voiceFor(int note);
    Voice &allocate();
    void startVoice(Voice &v, int note, int velocity, bool bass);
    void strike(Voice &v, float peak);
    void releaseGate(Voice &v);
    void beginFade(Voice &v);
    void letGo(Voice &v);
    float level(const Voice &v) const;
    void renderVoice(Voice &v, float *pluckL, float *pluckR, float *bassL, float *bassR, float *ghostL, float *ghostR, int n);
    void processBlock(float *left, float *right, int n);
    void housekeeping();
    // The arp.
    void arpInsert(int note);
    void arpRemove(int note);
    void arpTick();
    int samplesToNextArpEvent() const;
    void arpStep(double stepLength);
    void stopArp();
    void resetTouch();
    bool arpEnabled() const;
    int indexOf(const Voice &v) const { return (int)(&v - voices); }

    double sr;
    Voice voices[kPool];
    bool sustain = false, noArp = false, dryHook = false;
    unsigned noteCounter = 0;
    FastRandom rng;
    analog::Noise noise;
    uint64_t voiceSeed = 0x0B1DE9E7ULL;

    // Dials (smoothed where they act live) and mood.
    float pTranspose = 0, tempo = 118.f;
    float mEnergy = 0.5f, mWarmth = 0.5f, mBright = 0.5f, mSpace = 0.5f, mMotion = 0.5f;
    Smoothed fine, blink, murk, ghosts, echoAmt, bass, space, width, wet;
    float appliedSpace = -1, appliedDamp = -1;

    // Per-block values shared by every voice.
    float ceiling = 2000.f, bassNow = 0.55f, ghostGain = 0, ghostDrift = 1, slopDepth = 1;
    float subBoost = 1;
    double currentPhase = 0, currentWander = 0;
    float bendTarget = 0, bendMid = 0, bendNow = 0;
    float channelPressure = 0, polyPressure[128] = {};
    float sendLP[2] = {}, sendLPA = 0;

    // The arp: the held notes from C3 up (all of them at Bass 0) in the order they were pressed, except that notes
    // pressed within 30 ms of each other (the trailing group from groupStart, last pressed at groupLatest) go low to
    // high.
    int arpNotes[128] = {};
    int arpCount = 0, groupStart = 0, lastIndex = -1, stepCount = 0;
    int64_t groupLatest = 0;
    bool clockRunning = false;
    double nextStep = 0;                 // the next step, in samples on `clock`
    int64_t lastPlayed = 0;              // when a step last played
    int gateVoice = -1;                  // the voice the current step holds open (if it is still that note's)…
    unsigned gateAge = 0;
    int64_t gateOffAt = 0;               // …and when it lets go
    int64_t clock = 0;                   // samples rendered so far
    int noteVelocity[128] = {};
    bool noteDown[128] = {};

    Echo echo;
    SpaceReverb reverb;
    PeakLimiter limiter;
    float reverbFade = 1, reverbFadeStep = 0;
    bool reverbEmptying = false;
    bool idle = true, reverbLive = false;
    int idleSamples = 0, blockCount = 0;
};

} // namespace isd
