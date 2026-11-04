// Zen Shakuhachi: an end-blown bamboo flute on the breath-wind core (BreathWind.hpp). Each note is a breath that
// rises from air into tone (the Air dial), with the breath's own noise beside it (the Breath dial). Pressure is
// meri (the pitch sinks up to 150 cents and the tone darkens, the way the player's head drops); the wheel up is kari
// (up to +100 cents, brighter), down a plain bend; a hard note bursts with muraiki; yuri is a slow, irregular
// vibrato that comes in after the note settles. Two bore formants and a key-click give the bamboo, a mountain
// echo and open air the garden. D4–D7: lower notes fold up an octave, higher down. Everything is preallocated.
#pragma once
#include "BreathWind.hpp"
#include "DSPCommon.hpp"
#include "Engine.hpp"
#include "SpaceReverb.hpp"
#include <vector>

namespace isd {

class ZenShakuhachi final : public Engine {
public:
    explicit ZenShakuhachi(double sampleRate);
    void setParam(int address, float value, bool snap) override;
    void noteOn(int note, int velocity) override;
    void noteOff(int note) override;
    void setSustain(bool down) override;
    /// Every note fades out over 20 ms, and the wheel and pressure go back to rest (a switch never leaves a flute
    /// flat); the echo and reverb tails continue.
    void allNotesOff() override;
    /// As allNotesOff, and the echo, the low wall's reflections and the reverb are cleared.
    void allSoundOff() override;
    void render(float *left, float *right, int frames) override;
    int activeVoices() const override;
    void pitchBend(float semitones) override;
    void aftertouch(int note, float pressure) override;

    static constexpr int kPolyphony = 8;    // sounding voices
    static constexpr int kPool = 10;        // plus voices fading out after being stolen
    static constexpr int kSub = 32;         // samples per inner block
    static constexpr int kLowest = 62;      // D4: lower notes fold up by octaves
    static constexpr int kHighest = 98;     // D7: higher notes fold down

private:
    struct Voice {
        bool active = false, keyDown = false, releasing = false, fading = false;
        int note = 0;                       // the key (note-off and poly pressure)
        unsigned age = 0;
        long life = 0;                      // samples since the note started
        float pitch = 0, vel = 0, peak = 0; // sounding MIDI pitch (transposed, folded), velocity 0…1, plateau breath
        float breath = 0, relCoef = 1, airRelCoef = 1;   // the breath; its fall above the threshold, then below
        int attackPos = 0, attackLen = 1;
        float wander = 0, wanderLP = 0;     // the breath's slow unsteadiness
        BreathWind wind;
        // Touch: this key's poly pressure; the wheel and the pressure as this voice hears them (smoothed).
        float poly = 0, wheelNow = 0, meriNow = 0;
        // Yuri: a phase, this cycle's rate, and a depth that wanders from one half-cycle to the next.
        float yuriPh = 0, yuriRate = 4, depthFrom = 12, depthTo = 12;
        // Muraiki (a breath burst) and the key-click.
        float murLevel = 0;
        int murPos = 0, murLen = 0;
        Biquad murBP;
        float clickC = 1, clickS = 0, clickCr = 1, clickCi = 0, clickAmp = 0;
        int clickPos = 0, clickLen = 0;
        float panL = 0.7071f, panR = 0.7071f;
        float fadeGain = 1, fadeStep = 0;
    };

    void startVoice(Voice &v, int note, int velocity);
    Voice &allocate();
    void beginFade(Voice &v);
    void release(Voice &v);
    void processBlock(float *left, float *right, int n);
    void renderVoice(Voice &v, float *outL, float *outR, int n);
    void echoAndWall(const float *dryL, const float *dryR, float *outL, float *outR, float *wetInL, float *wetInR, int n, int muted);
    void housekeeping();
    void clearTails();
    static float level(const Voice &v);

    double sr;
    BreathWind::Shape shape;
    Voice voices[kPool];
    bool sustain = false, toneOnly = false, noFold = false;
    unsigned noteCounter = 0;
    FastRandom rng;

    // Dials (smoothed) and mood.
    float pTranspose = 0;
    float mEnergy = 0.5f, mWarmth = 0.5f, mBright = 0.5f, mSpace = 0.5f, mMotion = 0.5f;
    Smoothed fine, breath, air, bend, bamboo, yuri, echo, space, width, wet, echoNear, echoFar, wall;
    float appliedBamboo = -1, appliedBright = -1, appliedSpace = -1;
    // The wheel (semitones) and channel pressure, as last played.
    float wheel = 0, chanPressure = 0;

    // Per-block values shared by every voice.
    float airLevel = 0, bendNow = 0.6f, yuriNow = 0.4f, widthNow = 0.5f, bambooNow = 0.5f, reflBase = 5000.f;
    float wheelA = 0, meriA = 0, wanderA = 0;

    // The mountain echo and the low wall's early reflections: mono delay lines, sized at construction.
    std::vector<float> echoBuf, wallBuf;
    int echoW = 0, wallW = 0, echoNearD = 1, echoFarD = 1, wallD[3] = {1, 1, 1};
    float echoLP[2] = {}, echoLPA = 0;
    int sendMute = 0;

    Biquad formant[2][2], highShelf[2];
    SpaceReverb reverb;
    PeakLimiter limiter;
    bool idle = true, reverbLive = false;
    int quietSamples = 0, blockCount = 0;
};

} // namespace isd
