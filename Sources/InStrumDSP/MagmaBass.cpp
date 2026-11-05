// Magma Bass: see MagmaBass.hpp and docs/superpowers/briefs/magma-bass.md.
#include "MagmaBass.hpp"
#include "include/InStrumDSP.h"
#include <algorithm>
#include <cmath>

namespace isd {

namespace {
constexpr float kVoiceGain = 0.30f;      // headroom, so the swell isn't eaten by the limiter
constexpr float kSubLevel = 0.55f;          // the sub-octave square under the oscillator
constexpr float kRumbleMax = 0.75f;         // the sine two octaves down, at Rumble 1
constexpr float kSwellGain = 0.4125f;       // +3 dB on sub and rumble at the swell's peak
constexpr float kSwellAttack = 0.15f, kSwellHold = 0.6f, kSwellEnd = 1.2f;
constexpr float kSparkLevel = 0.5f;         // the Spark at 1
constexpr float kSparkBody = 0.4f;          // from C4 up the main voice thins to 40%…
constexpr float kSparkGrowl = 0.5f;         // …with half its growl, so the Spark carries the top
constexpr float kKeyTrack = 0.35f;
constexpr float kCutoffLow = 60.f, kCutoffHigh = 2400.f;
constexpr float kEnvOctavesMax = 6.f;       // the filter envelope's reach at Erupt 1
constexpr float kPressureOctaves = 1.5f, kPressureGrowl = 0.2f;
constexpr float kWobbleOctaves = 1.f;       // the mod wheel's filter wobble at full
constexpr float kHighPassHz = 25.f;
constexpr float kPanicFade = 0.02f;
constexpr float kSendGain = 0.25f;          // a bass stays mostly dry

inline float midiHz(float m) { return 440.f * std::exp2((m - 69.f) / 12.f); }
inline float logLerp(float a, float b, float t) { return a * std::exp2(t * std::log2(b / a)); }
inline float velocityGain(int velocity) { return std::pow(0.35f + 0.65f * (float)std::clamp(velocity, 1, 127) / 127.f, 1.3f); }
inline float smoothstep(float a, float b, float x) { const float t = clamp01((x - a) / (b - a)); return t * t * (3.f - 2.f * t); }
/// Flow's glide time: 5 ms at 0 to 600 ms at 1.
inline float glideSeconds(float flow) { return 0.005f * std::exp2(clamp01(flow) * std::log2(120.f)); }
} // namespace

MagmaBass::MagmaBass(double sampleRate) : sr(sampleRate), reverb(sampleRate, kSub) {
    limiter.init(sr);
    const double blockRate = sr / (double)kSub;   // the dials glide once per inner block
    for (Smoothed *s : {&fine, &growl, &heat, &erupt, &rumble, &grit, &flow, &shape, &spark, &res, &space, &width}) s->init(blockRate);
    fine.snap(0); growl.snap(0.55f); heat.snap(0.5f); erupt.snap(0.7f); rumble.snap(0.35f); grit.snap(0.25f);
    flow.snap(0.2f); shape.snap(0.15f); spark.snap(0.4f); res.snap(0.35f); space.snap(0.3f); width.snap(0.4f);
}

void MagmaBass::setParam(int address, float value, bool snap) {
    auto set = [&](Smoothed &s) { if (snap) s.snap(value); else s.setTarget(value); };
    switch (address) {
    case ISD_P_FINE_TUNE: set(fine); break;
    case ISD_P_TRANSPOSE: pTranspose = value; break;
    case ISD_P_GROWL: set(growl); break;
    case ISD_P_HEAT: set(heat); break;
    case ISD_P_ERUPT: set(erupt); break;
    case ISD_P_RUMBLE: set(rumble); break;
    case ISD_P_GRIT: set(grit); break;
    case ISD_P_FLOW: set(flow); break;
    case ISD_P_SHAPE: set(shape); break;
    case ISD_P_MONO: {
        const bool m = value >= 0.5f;
        if (m != mono) { allNotesOff(); mono = m; }
        break;
    }
    case ISD_P_SPARK: set(spark); break;
    case ISD_P_RES: set(res); break;
    case ISD_P_SPACE: set(space); break;
    case ISD_P_WIDTH: set(width); break;
    case ISD_P_MOOD_ENERGY: mEnergy = value; break;
    case ISD_P_MOOD_WARMTH: mWarmth = value; break;
    case ISD_P_MOOD_BRIGHTNESS: mBright = value; break;
    case ISD_P_MOOD_SPACE: mSpace = value; break;
    case ISD_P_MOOD_MOTION: mMotion = value; break;
    case ISD_P_DEBUG_MB_DRY: dryHook = value >= 0.5f; break;
    default: break;
    }
}

int MagmaBass::activeVoices() const {
    int n = 0;
    for (const auto &v : voices) if (v.active) ++n;
    return n;
}

int MagmaBass::debugCount(int which) const { return which == ISD_DEBUG_ERUPTIONS ? eruptions : 0; }

float MagmaBass::level(const Voice &v) const { return v.amp.level * v.gain * v.fadeGain; }

MagmaBass::Voice *MagmaBass::voiceFor(int note) {
    Voice *found = nullptr;
    for (auto &v : voices) {
        if (!v.active || v.fading || v.note != note) continue;
        if (!found || (v.held() && !found->held()) || (v.held() == found->held() && v.age > found->age)) found = &v;
    }
    return found;
}

MagmaBass::Voice &MagmaBass::allocate() {
    int sounding = 0;
    Voice *victim = nullptr;
    for (auto &v : voices) {
        if (!v.active || v.fading) continue;
        ++sounding;
        // Released voices go first (quietest first); otherwise the oldest held note.
        if (!victim) { victim = &v; continue; }
        if (v.held() != victim->held()) { if (!v.held()) victim = &v; continue; }
        if (!v.held() ? level(v) < level(*victim) : v.age < victim->age) victim = &v;
    }
    if (sounding >= kPolyphony && victim) beginFade(*victim);
    for (auto &v : voices) if (!v.active) return v;
    Voice *best = nullptr;
    for (auto &v : voices) if (v.fading && (!best || v.fadeGain < best->fadeGain)) best = &v;
    if (!best) best = &voices[0];
    best->active = false;
    return *best;
}

void MagmaBass::beginFade(Voice &v) {
    if (v.fading) return;
    v.fading = true;
    v.fadeStep = 1.f / (kPanicFade * (float)sr);
}

void MagmaBass::startVoice(Voice &v, int note, int velocity, float fromPitch, bool glide) {
    const float fsr = (float)sr;
    v = Voice{};
    v.active = true;
    v.keyDown = true;
    v.note = note;
    v.velocity = velocity;
    v.age = ++noteCounter;
    v.gain = velocityGain(velocity);
    v.vel01 = (float)std::clamp(velocity, 0, 127) / 127.f;
    v.spark = note >= kSparkFrom;
    v.pan = (float)((note * 5) % 12) / 5.5f - 1.f;
    const uint64_t seed = voiceSeed + 0x9E3779B97F4A7C15ULL * v.age;
    FastRandom r(seed);
    v.osc.reset(r.uniform());
    v.sparkOsc.reset(r.uniform());
    v.rumblePhase = r.uniform();
    v.slop.seed(seed ^ 0x51095109ULL);
    v.highPass.set(kHighPassHz, 0.707f, fsr);
    v.amp.setAttack(0.002f, fsr); v.amp.setDecay(0.9f, fsr); v.amp.setSustain(0.7f); v.amp.setRelease(0.25f, fsr);
    v.fenv.set(0.004f, 1.2f, 0.3f, 0.3f, fsr);   // decay as a −60 dB time: the rip holds through the note's first half-second
    const float target = std::clamp((float)note + pTranspose, 0.f, 127.f);
    v.glide.setTime(glideSeconds(flow.target), fsr);
    if (glide && fromPitch >= 0.f) { v.glide.jump(fromPitch); v.glide.glideTo(target); }
    else v.glide.jump(target);
    v.ladder.snapCutoff(kCutoffLow, fsr);
    v.amp.trigger(1.f);
    v.fenv.setVelocityDepth(erupt.target);   // before the gate, which fixes this note's velocity scale
    v.fenv.gate(true, v.vel01 * std::sqrt(v.vel01));   // velocity^1.5: soft notes stay darker
    lastPitch = target;
}

void MagmaBass::noteEruption(int note, int velocity) {
    const double now = (double)clock / sr;
    recentNote[recentHead] = note;
    recentVel[recentHead] = (float)std::clamp(velocity, 0, 127) / 127.f;
    recentTime[recentHead] = now;
    recentHead = (recentHead + 1) % kRecent;
    recentCount = std::min(recentCount + 1, kRecent);
    if (swellAge > 0.3 && magma::isEruptChord(recentNote, recentVel, recentTime, recentCount, now)) {
        swellAge = 0;
        ++eruptions;
    }
}

void MagmaBass::noteOn(int note, int velocity) {
    note &= 127;
    noteEruption(note, velocity);
    if (mono) { monoNoteOn(note, velocity); return; }
    // A key struck again while its note still sounds takes a fresh voice; the old one fades.
    if (Voice *old = voiceFor(note)) beginFade(*old);
    Voice &v = allocate();
    startVoice(v, note, velocity, lastPitch, flow.target > 0.6f);
}

void MagmaBass::noteOff(int note) {
    note &= 127;
    if (mono) { monoNoteOff(note); return; }
    for (auto &v : voices) {
        if (!v.active || v.fading || v.note != note || !v.keyDown) continue;
        v.keyDown = false;
        if (sustain) v.sustained = true;
        else { v.amp.release(); v.fenv.gate(false, 0.f); }
    }
}

void MagmaBass::monoNoteOn(int note, int velocity) {
    const bool overlapping = !monoKeys.empty();
    monoKeys.press(note, velocity);
    Voice *cur = nullptr;
    for (auto &v : voices) if (v.active && !v.fading) { cur = &v; break; }
    const float target = std::clamp((float)note + pTranspose, 0.f, 127.f);
    if (cur && overlapping && cur->keyDown) {
        // Legato: no retrigger; the pitch glides to the new key.
        cur->note = note;
        cur->spark = note >= kSparkFrom;
        cur->glide.setTime(glideSeconds(flow.target), (float)sr);
        cur->glide.glideTo(target);
        lastPitch = target;
        return;
    }
    const float from = cur ? cur->glide.current : lastPitch;
    if (cur) beginFade(*cur);
    Voice &v = allocate();
    startVoice(v, note, velocity, from, cur != nullptr && flow.target > 0.6f);
}

void MagmaBass::monoNoteOff(int note) {
    const int top = monoKeys.top();
    monoKeys.release(note);
    Voice *cur = nullptr;
    for (auto &v : voices) if (v.active && !v.fading) { cur = &v; break; }
    if (!cur) return;
    if (!monoKeys.empty()) {
        if (note == top) {   // back to the key still held, legato
            const float target = std::clamp((float)monoKeys.top() + pTranspose, 0.f, 127.f);
            cur->note = monoKeys.top();
            cur->spark = cur->note >= kSparkFrom;
            cur->glide.setTime(glideSeconds(flow.target), (float)sr);
            cur->glide.glideTo(target);
            lastPitch = target;
        }
        return;
    }
    cur->keyDown = false;
    if (sustain) cur->sustained = true;
    else { cur->amp.release(); cur->fenv.gate(false, 0.f); }
}

void MagmaBass::setSustain(bool down) {
    sustain = down;
    if (down) return;
    for (auto &v : voices) {
        if (!v.active || v.fading || !v.sustained) continue;
        v.sustained = false;
        if (!v.keyDown) { v.amp.release(); v.fenv.gate(false, 0.f); }
    }
}

void MagmaBass::allNotesOff() {
    for (auto &v : voices) if (v.active) beginFade(v);
    monoKeys.clear();
    sustain = false;
    bendTarget = bendNow = 0.f;
    channelPressure = 0.f;
    for (auto &p : polyPressure) p = 0.f;
    modWheel = modNow = 0.f;
}

void MagmaBass::allSoundOff() {
    allNotesOff();
    // The reverb empties over a little longer than the voices fade, and takes nothing in meanwhile.
    reverbEmptying = true;
    reverbFadeStep = 1.f / (1.25f * kPanicFade * (float)sr);
}

void MagmaBass::pitchBend(float semitones) { bendTarget = std::clamp(semitones, -2.f, 2.f); }

void MagmaBass::aftertouch(int note, float pressure) {
    const float p = clamp01(pressure);
    if (note < 0) channelPressure = p; else polyPressure[note & 127] = p;
}

void MagmaBass::controller(int cc, float value) { if (cc == 1) modWheel = clamp01(value); }

void MagmaBass::renderVoice(Voice &v, float *l, float *r, float *sendL, float *sendR, int n) {
    const float fsr = (float)sr, dt = (float)n / fsr;
    v.pressure += (1.f - std::exp(-dt / 0.015f)) * (std::max(channelPressure, polyPressure[v.note]) - v.pressure);
    v.slop.advance(dt);
    const bool dry = dryHook;
    const float pitch = v.glide.advance(n) + bendNow + 0.01f * fine.value;
    const float f0 = midiHz(pitch);
    const float slopDepth = dry ? 0.f : 0.5f + clamp01(mMotion);   // mood motion 0 halves the drift, as on Blue Depth
    const float inc = std::min(analog::kMaxIncrement, f0 * std::exp2(v.slop.pitchCents(0, slopDepth) / 1200.f) / fsr);
    const float sparkInc = std::min(analog::kMaxIncrement, 2.f * inc);
    const double rumbleInc = (double)f0 * 0.25 / sr;
    // The filter: Heat's base, key tracking, the envelope (Erupt × velocity), pressure and the wobble.
    const float g = clamp01(growl.value + kPressureGrowl * v.pressure) * (v.spark ? kSparkGrowl : 1.f);
    const float body = v.spark ? kSparkBody : 1.f;
    const float envDepth = kEnvOctavesMax * std::pow(clamp01(erupt.value), 1.4f);
    v.fenv.setDepth(envDepth);
    v.fenv.setVelocityDepth(erupt.value);
    const float envOct = v.fenv.advance(n);
    const float wobble = kWobbleOctaves * modNow * std::sin((float)(lfoPhase * 2.0 * 3.14159265358979));
    float cutoff = logLerp(kCutoffLow, kCutoffHigh, clamp01(heat.value)) * analog::keyTrack(f0, kKeyTrack)
                   * v.slop.cutoffRatio(slopDepth) * std::exp2(envOct + kPressureOctaves * v.pressure + wobble);
    v.ladder.setCutoff(cutoff, fsr, n);
    v.ladder.setResonance(res.value);
    v.ladder.setDrive(dry ? 0.f : g);
    v.osc.setShape(shape.value);
    v.shaper.set(dry ? 0.f : g, dry ? 0.f : 0.4f * g * g, dry ? 0.f : grit.value);
    // Low notes carry the sub and the rumble; the swell lifts them by up to +3 dB.
    const float swellGain = 1.f + kSwellGain * swell;
    const float subLevel = v.spark ? 0.f : kSubLevel * swellGain;
    const float rumbleLevel = v.spark ? 0.f : kRumbleMax * clamp01(rumble.value) * swellGain * smoothstep(18.f, 30.f, f0 * 0.25f);
    const float sparkLevel = (v.spark && !dry) ? kSparkLevel * clamp01(spark.value) : 0.f;
    // Into the growl at 0.35…1 with velocity; out at a gentler curve, since the growl itself compresses.
    const float drivePre = 0.35f + 0.65f * v.vel01;
    const float level = v.gain / std::sqrt(drivePre);
    if (sparkLevel > 0.f) { v.sparkShaper.set(0.35f, 0.6f, 0.f); v.sparkBand.set(std::min(4.f * f0, 0.4f * fsr), 1.5f, fsr); }
    const float gritNoise = dry ? 0.f : 0.06f * grit.value;
    const float w = clamp01(width.value);
    const float panL = 0.5f - 0.5f * 0.3f * w * v.pan, panR = 1.f - panL;
    const float sparkL = 0.5f - 0.5f * w * v.pan, sparkR = 1.f - sparkL;
    const float send = reverbEmptying ? 0.f : kSendGain * clamp01(space.value);
    for (int i = 0; i < n; ++i) {
        const float a = v.osc.nextWithSub(inc);
        // The filter first, then the growl: saturating the filtered tone adds new harmonics above the cutoff
        // (driving the raw saw would only square it off). The velocity drives the growl, so a hard note both
        // opens the filter and saturates harder, and a soft one stays round.
        const float x = 0.8f * a + subLevel * v.osc.sub + gritNoise * noise.next();
        float y = v.shaper.process(drivePre * v.ladder.process(x));
        y += rumbleLevel * (float)std::sin(v.rumblePhase * 2.0 * 3.14159265358979);
        v.rumblePhase += rumbleInc;
        if (v.rumblePhase >= 1.0) v.rumblePhase -= 1.0;
        y = v.highPass.process(y);
        float sp = 0.f;
        if (sparkLevel > 0.f) sp = sparkLevel * v.sparkBand.process(v.sparkShaper.process(0.7f * v.sparkOsc.next(sparkInc)));
        else v.sparkOsc.skip(1, sparkInc);
        y *= body;
        float env = v.amp.next() * level * kVoiceGain;
        if (v.fading) {
            v.fadeGain -= v.fadeStep;
            if (v.fadeGain <= 0.f) { v.fadeGain = 0.f; v.active = false; }
            env *= v.fadeGain;
        }
        const float ol = env * (y * panL * 2.f + sp * sparkL * 2.f);
        const float orr = env * (y * panR * 2.f + sp * sparkR * 2.f);
        l[i] += ol; r[i] += orr;
        sendL[i] += send * ol; sendR[i] += send * orr;
        if (!v.active) break;
    }
    if (v.active && v.amp.idle()) v.active = false;
}

void MagmaBass::processBlock(float *left, float *right, int n) {
    const float fsr = (float)sr, dt = (float)n / fsr;
    for (Smoothed *s : {&fine, &growl, &heat, &erupt, &rumble, &grit, &flow, &shape, &spark, &res, &space, &width}) s->next();
    bendNow += (1.f - std::exp(-dt / 0.005f)) * (bendTarget - bendNow);
    modNow += (1.f - std::exp(-dt / 0.03f)) * (modWheel - modNow);
    lfoPhase += (double)(5.f + 2.f * modNow) * (double)dt;
    lfoPhase -= std::floor(lfoPhase);
    // The swell: up over 0.15 s, held, then down by 1.2 s after the chord.
    swellAge += (double)dt;
    swell = swellAge < kSwellEnd ? smoothstep(0.f, kSwellAttack, (float)swellAge) * (1.f - smoothstep(kSwellHold, kSwellEnd, (float)swellAge)) : 0.f;
    const float sz = clamp01(space.value);
    if (std::fabs(sz - appliedSpace) > 0.01f) { reverb.configure(0.35f + 0.4f * sz, 0.65f, 12.f, 0.f); appliedSpace = sz; }

    float dl[kSub] = {}, dr[kSub] = {}, sl[kSub] = {}, srr[kSub] = {}, wl[kSub], wr[kSub];
    for (auto &v : voices) if (v.active) renderVoice(v, dl, dr, sl, srr, n);
    reverb.process(sl, srr, wl, wr, n);
    if (reverbEmptying) {
        for (int i = 0; i < n; ++i) { reverbFade = std::max(0.f, reverbFade - reverbFadeStep); wl[i] *= reverbFade; wr[i] *= reverbFade; }
        if (reverbFade <= 0.f) { reverb.clear(); reverbEmptying = false; reverbFade = 1.f; }
    }
    const float wet = dryHook ? 0.f : 1.f;
    for (int i = 0; i < n; ++i) {
        float l = dl[i] + wet * wl[i], r = dr[i] + wet * wr[i];
        limiter.process(l, r);
        left[i] = l; right[i] = r;
    }
}

void MagmaBass::render(float *left, float *right, int frames) {
    DenormalGuard guard;
    int pos = 0;
    while (pos < frames) {
        const int n = std::min(kSub, frames - pos);
        processBlock(left + pos, right + pos, n);
        pos += n;
        clock += n;
    }
}

} // namespace isd
