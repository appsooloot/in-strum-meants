// Replicant Brass with Chrome Bass (Neon Night Drive): a huge, swelling film-score synth brass in the right hand
// and a punchy, bright bass with the shared arpeggiator in the left. The second instrument on the vintage-synth
// core (AnalogVoice.hpp, Arp.hpp).
//   Brass (from the Split up): seven saws spread across ±2…±16 cents and across the stereo field (Width), with a
//   pulse beneath, through a 2-pole low-pass whose envelope swells (Swell: 40–600 ms). At full velocity the
//   attack shortens to 70 ms and overshoots by up to 2 octaves, settling over 300 ms: the blare (Blaze). Pressure
//   brightens and fades in a 5 Hz vibrato. The wheel is a blade: ±7 semitones, and a released note's bend falls
//   away over 100 ms. A shared chorus and a big hall (Hall).
//   Chrome Bass (below the Split): two saws an octave apart and a sub, through a ladder with a fast pluck (Punch)
//   and a little drive, mono-legato, played by the arp (Arp, Rate, Tempo) or straight from the keys.
// Each note remembers the layer it started on, so moving the Split or the Arp mode while keys are held never
// strands a voice. Everything is preallocated (docs/superpowers/briefs/replicant-brass.md; spec §4.3).
#pragma once
#include "AnalogVoice.hpp"
#include "Arp.hpp"
#include "DSPCommon.hpp"
#include "Engine.hpp"
#include "SpaceReverb.hpp"
#include <cstdint>
#include <vector>

namespace isd {

class ReplicantBrass final : public Engine {
public:
    explicit ReplicantBrass(double sampleRate);
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

    static constexpr int kBrassPolyphony = 6, kBrassPool = 18;   // room for a 10-note chord to steal every voice and still fade each one
    static constexpr int kBassPool = 4;
    static constexpr int kSub = 32;
    static constexpr int kSaws = 7;
    static constexpr float kBladeRange = 3.5f;   // the wheel's ±2 semitones become ±7

private:
    enum Layer : uint8_t { None = 0, Brass = 1, Bass = 2 };

    struct BrassVoice {
        bool active = false, fading = false, keyDown = false, sustained = false;
        int note = 0;
        unsigned age = 0;
        float gain = 0, vel01 = 0, pressure = 0, bend = 0, vibratoIn = 0, blare = 0, overshoot = 0;
        double sawPhase[kSaws] = {};
        float pan[kSaws] = {};
        analog::ShapeOsc pulse;
        analog::SVFCore lowL, lowR;
        analog::ADSR amp, filter;
        analog::Slop slop;
        double vibPhase = 0;
        float fadeGain = 1, fadeStep = 0;
        bool held() const { return keyDown || sustained; }
    };
    struct BassVoice {
        bool active = false, fading = false, gated = false;
        int note = 0;
        unsigned age = 0;
        float gain = 0;
        analog::ShapeOsc osc;
        analog::SawOsc octave;
        analog::DrivenLadder ladder;
        analog::Shaper shaper;
        analog::HighPass highPass;
        analog::ADSR amp;
        analog::FilterEnv pluck;
        analog::Glide glide;
        float fadeGain = 1, fadeStep = 0;
    };

    // Brass.
    BrassVoice *brassFor(int note);
    BrassVoice &allocateBrass();
    void startBrass(BrassVoice &v, int note, int velocity);
    void releaseBrass(BrassVoice &v);
    void renderBrass(BrassVoice &v, float *l, float *r, int n);
    // Bass.
    void bassKeyDown(int note, int velocity);
    void bassKeyUp(int note);
    void bassStrike(int note, int velocity, bool legato);
    void bassRelease();
    void renderBass(BassVoice &v, float *l, float *r, int n);
    BassVoice *bassSounding();
    BassVoice &allocateBass();
    void handleArp(const Arp::Event &e);
    bool arpOn() const { return arpMode != Arp::Off && !noArp; }

    void processBlock(float *left, float *right, int n);
    void chorus(float *l, float *r, int n);

    double sr;
    BrassVoice brass[kBrassPool];
    BassVoice bass[kBassPool];
    Layer layerOf[128] = {};
    bool sustain = false, noArp = false, dryHook = false;
    unsigned noteCounter = 0;
    uint64_t voiceSeed = 0x8E91CA27B4A55ULL;

    // Dials.
    float pTranspose = 0;
    float mEnergy = 0.5f, mWarmth = 0.5f, mBright = 0.5f, mSpace = 0.5f, mMotion = 0.5f;
    Smoothed fine, swell, blaze, width, hall, chrome, punch;
    int splitNote = 48;          // below it, Chrome Bass (0: no split, everything is brass)
    Arp::Mode arpMode = Arp::Played;
    int rateIndex = 3;
    float tempo = 120.f;
    float appliedHall = -1;

    // The left hand: the keys held for the bass (last pressed last), for straight playing.
    analog::MonoKeys bassKeys;
    Arp arp;
    int arpSounding = -1;

    // Performance.
    float bendNow = 0, bendTarget = 0, channelPressure = 0, polyPressure[128] = {};
    int64_t clock = 0;

    // The shared chorus: two modulated delays, one per side.
    std::vector<float> chorusBuf[2];
    int chorusW = 0;
    double chorusPhase = 0;

    SpaceReverb reverb;
    PeakLimiter limiter;
    float reverbFade = 1, reverbFadeStep = 0;
    bool reverbEmptying = false;
};

} // namespace isd
