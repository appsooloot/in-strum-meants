// Tea House Koto: a thirteen-string zither of paulownia on the plucked-string core (Set 9, Tea House Snow;
// docs/superpowers/briefs/tea-house-koto.md). Each note is one string plucked with a plectrum: treble near the
// bridge, gentler further off (Pick); a crisp tetron string … a soft silk one (Silk). The pitch wheel presses the
// strings (oshi: every sounding string glides up to a whole tone over about 25 ms, never re-plucked) and pressure
// gives yuri (a slow, irregular 4–6 Hz vibrato that waits until the pluck has spoken). The thirteen open strings,
// tuned to hirajōshi on the lowest note of each phrase, ring in sympathy (Bloom); a paulownia body (100, 194, 220,
// 285 Hz, a low thump on hard plucks), a plectrum scrape on the hardest notes and a small wooden room finish it.
// Everything is preallocated.
#pragma once
#include "DSPCommon.hpp"
#include "Engine.hpp"
#include "PluckedString.hpp"
#include "SpaceReverb.hpp"

namespace isd {

class TeaHouseKoto final : public Engine {
public:
    explicit TeaHouseKoto(double sampleRate);
    void setParam(int address, float value, bool snap) override;
    void noteOn(int note, int velocity) override;
    void noteOff(int note) override;
    void setSustain(bool down) override;
    void allNotesOff() override;
    void allSoundOff() override;
    void render(float *left, float *right, int frames) override;
    int activeVoices() const override;
    void pitchBend(float semitones) override;
    void aftertouch(int note, float pressure) override;

    static constexpr int kPolyphony = 24;   // sounding strings
    static constexpr int kPool = 30;        // plus strings fading out after being stolen
    static constexpr int kSub = 32;         // samples per inner block
    static constexpr int kOpenStrings = 13; // the sympathetic bank: the koto's open strings
    static constexpr int kOpenPartials = 3; // each rings at its first three partials
    static constexpr int kBodyModes = 4;

private:
    /// The plectrum's scrape on a hard note: a 2 ms band of noise (3–8 kHz).
    struct Scrape {
        int left = 0, length = 1;
        float amp = 0;
        Biquad hp, lp;
    };

    struct Voice {
        bool active = false, keyDown = false, damped = false, fading = false;
        int note = 0, pitch = 0;
        float hz0 = 440, amp = 0, t60 = 1, panPos = 0;
        float bend = 0;                 // semitones (follows the wheel while sounding; held while fading)
        float pressure = 0;             // smoothed pressure for yuri
        int age = 0;                    // samples since the pluck
        float vibPhase = 0, wander = 0, wanderTarget = 0;
        int wanderLeft = 0;
        float fadeGain = 1, fadeStep = 0;
        PluckedString str;
        Scrape scrape;
    };

    /// A gain that falls from 1 to 0 over 20 ms, after which its owner is cleared (panic, re-rooting).
    struct Fade {
        bool on = false;
        float gain = 1, step = 0;
        void start(double sr) { if (!on) { on = true; step = 1.f / (0.02f * (float)sr); } }
        void stop() { on = false; gain = 1; }
    };

    Voice &allocate();
    void startVoice(Voice &v, int note, int pitch, int velocity);
    void beginFade(Voice &v);
    void damp(Voice &v);
    void setRoot(int pitchClass);
    void tuneOpenStrings();
    /// The open string a note at `pitch` plucks (the highest of a unison: string 5 before its drone, string 1), or −1.
    int playedString(int pitch) const;
    float yuriCents(Voice &v, int n, float scale, float wanderK);
    void processBlock(float *left, float *right, int n);
    void housekeeping();

    double sr;
    Voice voices[kPool];
    bool keyDown[128] = {};
    float polyPressure[128] = {};
    int held = 0;
    bool sustain = false, noSympathy = false, noBody = false;
    FastRandom rng;

    // Dials: Pick and Silk shape each new pluck; the rest are smoothed and live.
    float pTranspose = 0, pPick = 0.55f, pSilk = 0.45f;
    float mEnergy = 0.5f, mWarmth = 0.5f, mBright = 0.5f, mSpace = 0.5f, mMotion = 0.5f;
    Smoothed fine, body, bloom, yuri, space, width, wet;
    float fineRatio = 1, appliedBright = -1, appliedSpace = -1, bankCents = 0, bankWidth = 0.5f;

    // The wheel (semitones) through two 4 ms smoothers, and channel pressure.
    float bendTarget = 0, bendMid = 0, bendNow = 0, channelPressure = 0;

    // Phrases: the open strings re-root on the lowest note of a phrase's first chord.
    int quietSamples = 0, rootWindow = 0, phraseLowest = 0, root = 4, pendingRoot = -1;

    SympatheticBank<kOpenStrings * kOpenPartials> bank;
    int openMidi[kOpenStrings] = {};
    int reverbMute = 0;   // samples: after all-sound-off the fading strings never reach the cleared room
    ModalBody<kBodyModes> board;
    Fade panicFade, bankFade;
    bool bankLive = false;

    Biquad radiation[2], highShelf[2];
    SpaceReverb reverb;
    PeakLimiter limiter;
    bool idle = true, reverbLive = false;
    int idleSamples = 0, blockCount = 0;
};

} // namespace isd
