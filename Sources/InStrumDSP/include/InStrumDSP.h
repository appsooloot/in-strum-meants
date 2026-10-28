// In Strum Meants Sound Core: the only public interface to the real-time DSP.
// Plain C so Swift imports it directly. All render/process calls are real-time safe.
#ifndef IN_STRUM_DSP_H
#define IN_STRUM_DSP_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---------- Space reverb (100% wet) ----------
typedef struct ISDReverb ISDReverb;
ISDReverb *isd_reverb_create(double sampleRate, int maxFrames);
void isd_reverb_destroy(ISDReverb *reverb);
/// size, damping and shimmer 0…1; pre-delay 0…80 ms. Real-time safe.
void isd_reverb_configure(ISDReverb *reverb, float size, float damping, float predelayMs, float shimmer);
/// Real-time safe; in-place allowed.
void isd_reverb_process(ISDReverb *reverb, const float *inL, const float *inR, float *outL, float *outR, int frames);

// ---------- Built-in instruments ----------
typedef enum { ISD_ENGINE_FELT_GLASS = 0, ISD_ENGINE_ORBIT_PAD = 1, ISD_ENGINE_HONEY_TAPE = 2, ISD_ENGINE_HAZE_BELLS = 3, ISD_ENGINE_CABIN_FELT = 4, ISD_ENGINE_MORNING_BOX = 5 } ISDEngine;

/// Parameter addresses (stable: saved in presets and instrument state).
enum {
    ISD_P_FINE_TUNE = 0, ISD_P_TRANSPOSE = 1, ISD_P_SPACE = 2,
    ISD_P_FELT = 10, ISD_P_GLASS = 11, ISD_P_WARMTH = 12, ISD_P_RING = 13, ISD_P_WIDTH = 14,
    ISD_P_BLOOM = 20, ISD_P_DRIFT = 21, ISD_P_MOTION = 22, ISD_P_SHIMMER = 23, ISD_P_BRIGHTNESS = 24,
    ISD_P_BREATH = 30, ISD_P_STRINGS = 31, ISD_P_WOW = 32, ISD_P_AGE = 33, ISD_P_REEL = 34,
    ISD_P_BELLS = 40, ISD_P_ORGAN = 41, ISD_P_ECHO = 42, ISD_P_CRUSH = 43,
    ISD_P_HORN = 50, ISD_P_FIRE = 51, ISD_P_WOOD = 52,
    ISD_P_BARS = 60, ISD_P_BOX = 61, ISD_P_BUILD = 62, ISD_P_HAZE = 63,
    ISD_P_MOOD_ENERGY = 100, ISD_P_MOOD_WARMTH = 101, ISD_P_MOOD_BRIGHTNESS = 102, ISD_P_MOOD_SPACE = 103, ISD_P_MOOD_MOTION = 104,
    /// Test hook (unit 3, never shown): Orbit Pad plays one plain saw, no detune, drift, motion or chorus.
    ISD_P_DEBUG_LAYER_A_ONLY = 200,
    /// Test hook (unit 3, never shown): Honey Tape's flute plays without vibrato.
    ISD_P_DEBUG_NO_VIBRATO = 201,
    /// Test hooks (unit 3, never shown): Cabin Felt without its key and damper noises; Cabin Felt's horn alone.
    ISD_P_DEBUG_NO_MECHANICS = 202, ISD_P_DEBUG_HORN_ONLY = 203,
    /// Test hooks (unit 3, never shown): Morning Box's box alone; its wall alone.
    ISD_P_DEBUG_BOX_ONLY = 204, ISD_P_DEBUG_WALL_ONLY = 205
};

/// unit: 0 generic 0…1, 1 cents, 2 semitones, 3 internal (test hooks: hosts never show or save these).
typedef struct {
    int address;
    const char *identifier;
    const char *name;
    float minValue, maxValue, defaultValue;
    int unit;
} ISDParamInfo;

typedef struct ISDSynth ISDSynth;
/// Returns NULL for an engine that isn't available.
ISDSynth *isd_synth_create(ISDEngine engine, double sampleRate, int maxFrames);
void isd_synth_destroy(ISDSynth *synth);
int isd_synth_param_count(ISDEngine engine);
const ISDParamInfo *isd_synth_param_info(ISDEngine engine, int index);
/// Any thread. Values are clamped to the parameter's range and smoothed while playing.
void isd_synth_set_param(ISDSynth *synth, int address, float value);
float isd_synth_get_param(const ISDSynth *synth, int address);
/// Render thread, before the render call it belongs to. `sampleOffset` is within that render.
void isd_synth_midi(ISDSynth *synth, const uint8_t *bytes, int length, int sampleOffset);
/// Render thread. Overwrites `left`/`right`.
void isd_synth_render(ISDSynth *synth, float *left, float *right, int frames);
/// Any thread: every note fades out over 20 ms at the next render.
void isd_synth_all_notes_off(ISDSynth *synth);
int isd_synth_active_voices(const ISDSynth *synth);
/// Internal counters for tests. Not real-time safe to rely on; read between renders.
/// RETUNES: Felt Glass retunes. HORN_NOTE: Cabin Felt's horn note (folded into its range), or -1.
/// BUILD_PERMILLE and WALL_UNISON: Morning Box's build level × 1000 and its wall's unison count.
typedef enum { ISD_DEBUG_RETUNES = 0, ISD_DEBUG_HORN_NOTE = 1, ISD_DEBUG_BUILD_PERMILLE = 2, ISD_DEBUG_WALL_UNISON = 3 } ISDDebugCount;
int isd_synth_debug_count(const ISDSynth *synth, ISDDebugCount which);

// ---------- Ambience (generated live, never loops) ----------
typedef enum {
    ISD_AMB_WATER, ISD_AMB_CRICKETS, ISD_AMB_BREEZE, ISD_AMB_OWL, ISD_AMB_RAIN_WATER, ISD_AMB_RAIN_GLASS,
    ISD_AMB_DAWN_CHORUS, ISD_AMB_SHIP_HUM, ISD_AMB_AIR_FLOW, ISD_AMB_CHIME, ISD_AMB_HULL_TICKS, ISD_AMB_WIND,
    ISD_AMB_SURF, ISD_AMB_PALMS, ISD_AMB_GULLS, ISD_AMB_ROAD, ISD_AMB_ENGINE, ISD_AMB_WINDOW_WIND, ISD_AMB_PASSING_CAR,
    ISD_AMB_COUNT
} ISDAmbienceSource;

typedef struct ISDAmbience ISDAmbience;
/// Internal (tests): the frequency the ambience's tone oscillators really run at, measured over the last second
/// of a run of `seconds` from phase 0.
float isd_ambience_debug_tone_hz(float hz, float sampleRate, float seconds);
/// The same seed gives the same ambience.
ISDAmbience *isd_ambience_create(double sampleRate, int maxFrames, uint64_t seed);
void isd_ambience_destroy(ISDAmbience *ambience);
/// Any thread. 0…1; the source glides to it over 2.5 s. Continuous sources sit near −24 dBFS RMS at 1.
void isd_ambience_set_level(ISDAmbience *ambience, ISDAmbienceSource source, float level);
/// Any thread. 0 distant (roomy, softer top) … 1 all around you (close, dry, wide).
void isd_ambience_set_closeness(ISDAmbience *ambience, float closeness);
/// Any thread. 0…1 while playing: ducks up to 4 dB within half a second, swells back over about 2 s.
void isd_ambience_set_activity(ISDAmbience *ambience, float activity);
/// Any thread. 0 warm early night … 1 cool late night (crickets chirp up to 40% slower).
void isd_ambience_set_night_cool(ISDAmbience *ambience, float cool);
/// Any thread. 0.5…1.5: multiplies how often things happen (calls, chirps, drops, chimes).
void isd_ambience_set_density(ISDAmbience *ambience, float density);
/// Any thread. Thunder rolls in 0.5 s (near) to 6 s (far) later.
void isd_ambience_trigger_thunder(ISDAmbience *ambience, float distance);
/// Any thread. A wave breaks on the shore (strength 0…1): a crash, a wash up the sand and a backwash. Silent
/// unless the surf is up.
void isd_ambience_trigger_wave(ISDAmbience *ambience, float strength);
/// Any thread. A car's speed 0…1 for the road, engine and window wind (glides over half a second).
void isd_ambience_set_speed(ISDAmbience *ambience, float speed);
/// Any thread. 0 close, detailed surf … 1 a far, low roar.
void isd_ambience_set_surf_distance(ISDAmbience *ambience, float distance);
/// Render thread. Overwrites `left`/`right`.
void isd_ambience_render(ISDAmbience *ambience, float *left, float *right, int frames);

#ifdef __cplusplus
}
#endif

#endif
