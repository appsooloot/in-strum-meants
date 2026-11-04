// Reef Marimba: rosewood bars over tuned tubes, played with yarn-to-rubber mallets, on the modal mallet core
// (ModalBar.hpp). Each bar rings at 1 : 3.99 : 9.2–10 with a torsional and a lateral knock; the mallet's contact
// time shapes every strike, the strike point follows the bar's own mode shapes, and the tube blooms the
// fundamental. Hold a note and it rolls: two mallets alternate at 9–13 Hz, and pressure swells the roll. A
// tuned-steel layer (1, 2 and 3 × f0 and a beating pair) shimmers over the wood. Open air over a lagoon: a short
// reverb and a 6 ms slap off the water. Bars don't bend, so the pitch wheel is ignored. Everything is preallocated.
#pragma once
#include "DSPCommon.hpp"
#include "Engine.hpp"
#include "ModalBar.hpp"
#include "SpaceReverb.hpp"
#include <vector>

namespace isd {

class ReefMarimba final : public Engine {
public:
    explicit ReefMarimba(double sampleRate);
    void setParam(int address, float value, bool snap) override;
    void noteOn(int note, int velocity) override;
    void noteOff(int note) override;
    void setSustain(bool down) override;
    void allNotesOff() override;
    void allSoundOff() override;
    void render(float *left, float *right, int frames) override;
    /// Bars sounding. A bar fading out after being stolen (20 ms) no longer counts, so this never exceeds kPolyphony.
    int activeVoices() const override;
    void aftertouch(int note, float pressure) override;

    static constexpr int kPolyphony = 32;   // bars sounding (mallet players run fast and roll)
    static constexpr int kPool = 40;        // plus bars fading out after being stolen
    static constexpr int kRolls = 4;        // notes rolling at once
    static constexpr int kSub = 32;         // samples per inner block, at most
    static constexpr int kLowest = 36, kHighest = 96;   // C2–C7: notes outside fold in by octaves

private:
    struct Voice {
        bool active = false, fading = false, steelOn = false;
        int pitch = 0;
        ModalBar<8> wood;     // 1, 3.99 and 9.2–10 × f0, the torsional and lateral modes, the tube and the click
        ModalBar<4> steel;    // a beating pair on f0, then 2 and 3 × f0
        float steelNow = 0;   // the steel layer's gain, ramped per block
        float level = 0, ref = 0;
        float fadeGain = 1, fadeStep = 0;
        float gl = 0.7071f, gr = 0.7071f;
    };

    struct Roll {
        bool active = false;
        int note = 0, wait = 0;   // samples to the next stroke
        unsigned strokes = 0;
        float pressure = 0;       // smoothed
        FastRandom rng;
    };

    Voice *voiceFor(int pitch);
    Voice &allocate();
    void startVoice(Voice &v, int pitch);
    void strikeBar(int pitch, float velocity, bool otherMallet);
    void beginFade(Voice &v);
    void stopRoll(int note);
    bool rollsOn() const;
    void stepRolls();
    void advanceRolls(int n);
    int samplesToNextRollEvent() const;
    void rollStroke(Roll &r);
    void placeVoice(Voice &v) const;
    void processBlock(float *left, float *right, int n);
    void housekeeping();
    float pressureOf(int note) const { return std::max(channelPressure, polyPressure[note & 127]); }

    double sr;
    Voice voices[kPool];
    Roll rolls[kRolls];
    // Keys (MIDI notes): held, how hard, on which bar, held for how long, pressed when.
    bool keyDown[128] = {}, keyRolling[128] = {};
    float keyVel[128] = {}, polyPressure[128] = {};
    int keyPitch[128] = {}, keyHeld[128] = {};
    unsigned keyOrder[128] = {};
    int pitchHeld[128] = {};   // keys down on each bar
    int keysDown = 0, holdSamples = 1;
    unsigned pressCounter = 0;
    float channelPressure = 0;
    bool sustain = false, noRoll = false, barOnly = false;

    // Dials (smoothed) and mood.
    float pTranspose = 0;
    float mEnergy = 0.5f, mWarmth = 0.5f, mBright = 0.5f, mSpace = 0.5f, mMotion = 0.5f;
    Smoothed fine, mallet, strike, tube, roll, steel, space, width, wet, slapGain;
    float fineRatio = 1, appliedCents = 0, appliedSpace = -1, appliedWidth = -1;

    // The slap off the water: 6 ms, a little darker.
    std::vector<float> slapBuf[2];
    int slapPos = 0, slapLen = 1;
    OnePole slapLP[2];

    SpaceReverb reverb;
    PeakLimiter limiter;
    bool idle = true, reverbLive = false;
    int idleSamples = 0, blockCount = 0, reverbMute = 0;
};

} // namespace isd
