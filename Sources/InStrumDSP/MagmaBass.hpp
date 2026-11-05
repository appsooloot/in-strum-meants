// Magma Bass (Volcano Rim): a growling analogue bass for a crater's edge. The first bass on the vintage-synth core
// (AnalogVoice.hpp). Each voice: a shaped oscillator (saw → square → pulse) with its sub-octave square and a
// breath of noise for grit, through a driven ZDF ladder whose envelope opens with velocity (Erupt) and pressure,
// then the ADAA wavefolder and drive (Growl) on the filtered tone, a clean sine Rumble two octaves down, a 25 Hz
// high-pass and the amp envelope. Notes
// from C4 up drop their sub and rumble and add the Spark: a folded, band-passed partial an octave up, so the right
// hand adds fire instead of mud. A hard low chord (isEruptChord) swells the sub and rumble for 1.2 s, on the same
// rule the world's eruption uses. Poly by default (6 voices, pool 8); Mono is mono-legato with Flow's glide. The
// wheel bends ±2 semitones, the mod wheel (CC 1) brings in a 5–7 Hz filter wobble. Everything is preallocated
// (docs/superpowers/briefs/magma-bass.md; spec 2026-11-05-fire-and-neon-design.md §4.2).
#pragma once
#include "AnalogVoice.hpp"
#include "DSPCommon.hpp"
#include "Engine.hpp"
#include "SpaceReverb.hpp"
#include <cstdint>

namespace isd {

namespace magma {
/// The eruption chord: three or more note-ons within 40 ms whose mean velocity (0…1) is at least 0.8 and whose
/// mean pitch is below C3 (48). Core's BigMoments mirrors this rule so the sound and the world agree.
inline bool isEruptChord(const int *notes, const float *velocities, const double *seconds, int count, double now) {
    int n = 0;
    float v = 0.f, p = 0.f;
    for (int i = 0; i < count; ++i) {
        if (now - seconds[i] > 0.040 + 1e-9 || seconds[i] > now) continue;
        ++n; v += velocities[i]; p += (float)notes[i];
    }
    return n >= 3 && v / (float)n >= 0.8f && p / (float)n < 48.f;
}
} // namespace magma

class MagmaBass final : public Engine {
public:
    explicit MagmaBass(double sampleRate);
    void setParam(int address, float value, bool snap) override;
    void noteOn(int note, int velocity) override;
    void noteOff(int note) override;
    void setSustain(bool down) override;
    void allNotesOff() override;
    void allSoundOff() override;
    void render(float *left, float *right, int frames) override;
    int activeVoices() const override;
    int debugCount(int which) const override;
    void pitchBend(float semitones) override;
    void aftertouch(int note, float pressure) override;
    void controller(int cc, float value) override;

    static constexpr int kPolyphony = 6;
    static constexpr int kPool = 12;        // a spare for every sounding voice, so a chord that steals them all still fades each one
    static constexpr int kSub = 32;
    static constexpr int kSparkFrom = 60;   // C4

private:
    struct Voice {
        bool active = false, fading = false, keyDown = false, sustained = false;
        int note = 0, velocity = 0;
        unsigned age = 0;
        float gain = 0, vel01 = 0, pressure = 0, pan = 0;
        bool spark = false;
        analog::ShapeOsc osc, sparkOsc;
        double rumblePhase = 0;
        analog::Shaper shaper, sparkShaper;
        analog::DrivenLadder ladder;
        analog::HighPass highPass;
        analog::BandPass sparkBand;
        analog::ADSR amp;
        analog::FilterEnv fenv;
        analog::Glide glide;
        analog::Slop slop;
        float fadeGain = 1, fadeStep = 0;
        bool held() const { return keyDown || sustained; }
    };

    Voice *voiceFor(int note);
    Voice &allocate();
    void startVoice(Voice &v, int note, int velocity, float fromPitch, bool glide);
    void beginFade(Voice &v);
    float level(const Voice &v) const;
    void renderVoice(Voice &v, float *l, float *r, float *sendL, float *sendR, int n);
    void processBlock(float *left, float *right, int n);
    void noteEruption(int note, int velocity);
    void monoNoteOn(int note, int velocity);
    void monoNoteOff(int note);

    double sr;
    Voice voices[kPool];
    bool sustain = false, mono = false, dryHook = false;
    unsigned noteCounter = 0;
    uint64_t voiceSeed = 0x3A63A1BA55ULL;
    analog::Noise noise{0x9417A3A1ULL};
    analog::MonoKeys monoKeys;
    float lastPitch = -1.f;

    // Dials and mood.
    float pTranspose = 0;
    float mEnergy = 0.5f, mWarmth = 0.5f, mBright = 0.5f, mSpace = 0.5f, mMotion = 0.5f;
    Smoothed fine, growl, heat, erupt, rumble, grit, flow, shape, spark, res, space, width;
    float appliedSpace = -1;

    // Performance.
    float bendNow = 0, bendTarget = 0, channelPressure = 0, polyPressure[128] = {};
    float modWheel = 0, modNow = 0;
    double lfoPhase = 0;
    // The eruption: recent note-ons and the swell they set off.
    static constexpr int kRecent = 16;
    int recentNote[kRecent] = {};
    float recentVel[kRecent] = {};
    double recentTime[kRecent] = {};
    int recentCount = 0, recentHead = 0;
    float swell = 0;        // 0…1, the swell's envelope
    double swellAge = 1e9;  // seconds since the last eruption
    int eruptions = 0;
    int64_t clock = 0;

    SpaceReverb reverb;
    PeakLimiter limiter;
    float reverbFade = 1, reverbFadeStep = 0;
    bool reverbEmptying = false;
};

} // namespace isd
