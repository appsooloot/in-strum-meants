// Replicant Brass with Chrome Bass: see ReplicantBrass.hpp and docs/superpowers/briefs/replicant-brass.md.
#include "ReplicantBrass.hpp"
#include "include/InStrumDSP.h"
#include <algorithm>
#include <cmath>

namespace isd {

namespace {
constexpr float kBrassGain = 0.10f, kBassGain = 0.42f;   // a 6-note chord at velocity 100 peaks near 0.58: the limiter is for extremes only
constexpr float kPulseLevel = 0.30f, kPulseShape = 0.75f;
constexpr float kCutoffLow = 180.f, kCutoffHigh = 900.f;   // the brass filter's resting cutoff across Blaze
constexpr float kBrassKeyTrack = 0.5f, kBrassQ = 0.85f;
constexpr float kEnvOctaves = 2.f, kEnvOctavesBlaze = 1.5f;   // so the blare's overshoot stands out above it
constexpr float kBlareAttack = 0.07f, kOvershootTau = 0.1f;
constexpr float kPressureOctaves = 2.f, kVibratoHz = 5.f, kVibratoCents = 15.f;
constexpr float kFallTau = 0.03f;                          // a released note's bend falls away (~100 ms to 5%)
constexpr float kBassCutoff = 90.f, kBassKeyTrack = 0.5f, kBassRes = 0.25f;
constexpr float kBassGlide = 0.06f;
constexpr float kChorusMs = 7.f, kChorusDepthMs = 2.5f, kChorusHz = 0.33f;
constexpr float kHallSize = 0.85f;
constexpr float kPanicFade = 0.02f;

inline float midiHz(float m) { return 440.f * std::exp2((m - 69.f) / 12.f); }
inline float logLerp(float a, float b, float t) { return a * std::exp2(t * std::log2(b / a)); }
inline float velocityGain(int velocity) { return std::pow(0.35f + 0.65f * (float)std::clamp(velocity, 1, 127) / 127.f, 1.3f); }
inline float smoothstep(float a, float b, float x) { const float t = clamp01((x - a) / (b - a)); return t * t * (3.f - 2.f * t); }
/// Swell's filter attack: 40 ms at 0 to 600 ms at 1.
inline float swellSeconds(float s) { return 0.04f * std::exp2(clamp01(s) * std::log2(15.f)); }
inline Arp::Mode modeFromIndex(int i) {
    static const Arp::Mode m[6] = {Arp::Off, Arp::Up, Arp::Down, Arp::UpDown, Arp::Played, Arp::Random};
    return m[std::clamp(i, 0, 5)];
}
} // namespace

ReplicantBrass::ReplicantBrass(double sampleRate) : sr(sampleRate), reverb(sampleRate, kSub) {
    limiter.init(sr);
    const double blockRate = sr / (double)kSub;
    for (Smoothed *s : {&fine, &swell, &blaze, &width, &hall, &chrome, &punch}) s->init(blockRate);
    fine.snap(0); swell.snap(0.6f); blaze.snap(0.5f); width.snap(0.7f); hall.snap(0.55f); chrome.snap(0.6f); punch.snap(0.5f);
    arp.prepare(sr, 0xC4120EBA55ULL);
    arp.setMode(arpMode);
    arp.setRate(Arp::rateFromIndex(rateIndex));
    arp.setTempo(tempo);
    arp.setGate(0.55f);
    const int len = (int)std::ceil(0.03 * sr) + 4;
    chorusBuf[0].assign((size_t)len, 0.f);
    chorusBuf[1].assign((size_t)len, 0.f);
}

void ReplicantBrass::setParam(int address, float value, bool snap) {
    auto set = [&](Smoothed &s) { if (snap) s.snap(value); else s.setTarget(value); };
    switch (address) {
    case ISD_P_FINE_TUNE: set(fine); break;
    case ISD_P_TRANSPOSE: pTranspose = value; break;
    case ISD_P_SWELL_RB: set(swell); break;
    case ISD_P_BLAZE: set(blaze); break;
    case ISD_P_UNISON_WIDTH: set(width); break;
    case ISD_P_HALL: set(hall); break;
    case ISD_P_CHROME: set(chrome); break;
    case ISD_P_PUNCH: set(punch); break;
    case ISD_P_ARP_MODE: {
        const Arp::Mode m = modeFromIndex((int)std::lround(value));
        if (m != arpMode) {
            // A new mode starts clean: the bass lets go, the arp forgets, and keys held now stay quiet until struck.
            bassRelease();
            arp.reset();
            arpSounding = -1;
            bassKeys.clear();
            arpMode = m;
            arp.setMode(m == Arp::Off ? Arp::Played : m);
        }
        break;
    }
    case ISD_P_ARP_RATE: rateIndex = std::clamp((int)std::lround(value), 0, 5); arp.setRate(Arp::rateFromIndex(rateIndex)); break;
    case ISD_P_SPLIT: { const int n = (int)std::lround(value); splitNote = n < 28 ? 0 : std::min(n, 60); break; }
    case ISD_P_TEMPO_RB: tempo = std::clamp(value, 70.f, 170.f); arp.setTempo(tempo); break;
    case ISD_P_MOOD_ENERGY: mEnergy = value; break;
    case ISD_P_MOOD_WARMTH: mWarmth = value; break;
    case ISD_P_MOOD_BRIGHTNESS: mBright = value; break;
    case ISD_P_MOOD_SPACE: mSpace = value; break;
    case ISD_P_MOOD_MOTION: mMotion = value; break;
    case ISD_P_DEBUG_RB_NO_ARP: {
        const bool na = value >= 0.5f;
        if (na != noArp) { bassRelease(); arp.reset(); arpSounding = -1; bassKeys.clear(); noArp = na; }
        break;
    }
    case ISD_P_DEBUG_RB_DRY: dryHook = value >= 0.5f; break;
    default: break;
    }
}

int ReplicantBrass::activeVoices() const {
    int n = 0;
    for (const auto &v : brass) if (v.active) ++n;
    for (const auto &v : bass) if (v.active) ++n;
    return n;
}

// ---------- Notes ----------

void ReplicantBrass::noteOn(int note, int velocity) {
    note &= 127;
    const bool toBass = splitNote > 0 && note < splitNote;
    // A key struck again while it still sounds on its old layer lets that go first.
    if (layerOf[note] != None) noteOff(note);
    layerOf[note] = toBass ? Bass : Brass;
    if (toBass) { bassKeyDown(note, velocity); return; }
    if (BrassVoice *old = brassFor(note)) { old->fading = true; old->fadeStep = 1.f / (kPanicFade * (float)sr); }
    startBrass(allocateBrass(), note, velocity);
}

void ReplicantBrass::noteOff(int note) {
    note &= 127;
    const Layer layer = layerOf[note];
    layerOf[note] = None;
    if (layer == Bass) { bassKeyUp(note); return; }
    if (layer != Brass) return;
    for (auto &v : brass) {
        if (!v.active || v.fading || v.note != note || !v.keyDown) continue;
        v.keyDown = false;
        if (sustain) v.sustained = true; else releaseBrass(v);
    }
}

void ReplicantBrass::setSustain(bool down) {
    sustain = down;
    if (down) return;
    for (auto &v : brass) {
        if (!v.active || v.fading || !v.sustained) continue;
        v.sustained = false;
        if (!v.keyDown) releaseBrass(v);
    }
}

void ReplicantBrass::allNotesOff() {
    for (auto &v : brass) if (v.active && !v.fading) { v.fading = true; v.fadeStep = 1.f / (kPanicFade * (float)sr); }
    for (auto &v : bass) if (v.active && !v.fading) { v.fading = true; v.fadeStep = 1.f / (kPanicFade * (float)sr); }
    arp.reset();
    arpSounding = -1;
    bassKeys.clear();
    for (auto &l : layerOf) l = None;
    sustain = false;
    bendTarget = bendNow = 0.f;
    channelPressure = 0.f;
    for (auto &p : polyPressure) p = 0.f;
}

void ReplicantBrass::allSoundOff() {
    allNotesOff();
    // The hall empties over longer than the voices take to fade and the chorus to play their last out (20 + 9.5 ms),
    // takes nothing in meanwhile, and clears with the chorus, so nothing can set it ringing again.
    reverbEmptying = true;
    reverbFadeStep = 1.f / (1.6f * kPanicFade * (float)sr);
    for (auto &b : chorusBuf) std::fill(b.begin(), b.end(), 0.f);
}

void ReplicantBrass::pitchBend(float semitones) { bendTarget = std::clamp(semitones, -2.f, 2.f); }

void ReplicantBrass::aftertouch(int note, float pressure) {
    const float p = clamp01(pressure);
    if (note < 0) channelPressure = p; else polyPressure[note & 127] = p;
}

// ---------- Brass voices ----------

ReplicantBrass::BrassVoice *ReplicantBrass::brassFor(int note) {
    BrassVoice *found = nullptr;
    for (auto &v : brass) {
        if (!v.active || v.fading || v.note != note) continue;
        if (!found || v.age > found->age) found = &v;
    }
    return found;
}

ReplicantBrass::BrassVoice &ReplicantBrass::allocateBrass() {
    int sounding = 0;
    BrassVoice *victim = nullptr;
    for (auto &v : brass) {
        if (!v.active || v.fading) continue;
        ++sounding;
        if (!victim) { victim = &v; continue; }
        if (v.held() != victim->held()) { if (!v.held()) victim = &v; continue; }
        if (!v.held() ? v.amp.level < victim->amp.level : v.age < victim->age) victim = &v;
    }
    if (sounding >= kBrassPolyphony && victim) { victim->fading = true; victim->fadeStep = 1.f / (kPanicFade * (float)sr); }
    for (auto &v : brass) if (!v.active) return v;
    BrassVoice *best = nullptr;
    for (auto &v : brass) if (v.fading && (!best || v.fadeGain < best->fadeGain)) best = &v;
    if (!best) best = &brass[0];
    best->active = false;
    return *best;
}

void ReplicantBrass::startBrass(BrassVoice &v, int note, int velocity) {
    const float fsr = (float)sr;
    v = BrassVoice{};
    v.active = true;
    v.keyDown = true;
    v.note = note;
    v.age = ++noteCounter;
    v.gain = velocityGain(velocity);
    v.vel01 = (float)std::clamp(velocity, 0, 127) / 127.f;
    const uint64_t seed = voiceSeed + 0x9E3779B97F4A7C15ULL * v.age;
    FastRandom r(seed);
    for (int i = 0; i < kSaws; ++i) {
        v.sawPhase[i] = r.uniform();
        v.pan[i] = kSaws > 1 ? 2.f * (float)i / (float)(kSaws - 1) - 1.f : 0.f;
    }
    // Alternate the saws' sides so neighbouring detunes sit apart.
    std::swap(v.pan[1], v.pan[5]);
    v.pulse.reset(r.uniform());
    v.pulse.setShape(kPulseShape);
    v.slop.seed(seed ^ 0x7E1ACADEULL);
    // The swell: Swell's attack; at full velocity a quick blare that overshoots.
    const float blareMix = smoothstep(0.85f, 1.f, v.vel01);
    v.blare = blareMix * (0.5f + clamp01(blaze.target));
    const float attack = swellSeconds(swell.target) + (kBlareAttack - swellSeconds(swell.target)) * blareMix;
    v.filter.setAttack(attack, fsr); v.filter.setDecay(1.2f, fsr); v.filter.setSustain(0.88f);   // brass holds its brightness; only the blare overshoots v.filter.setRelease(0.45f, fsr);
    v.amp.setAttack(0.012f, fsr); v.amp.setDecay(2.f, fsr); v.amp.setSustain(0.85f); v.amp.setRelease(0.45f, fsr);
    v.filter.trigger(1.f);
    v.amp.trigger(1.f);
    v.bend = bendNow * kBladeRange;
}

void ReplicantBrass::releaseBrass(BrassVoice &v) {
    v.amp.release();
    v.filter.release();
}

void ReplicantBrass::renderBrass(BrassVoice &v, float *l, float *r, int n) {
    const float fsr = (float)sr, dt = (float)n / fsr;
    const bool dry = dryHook;
    v.pressure += (1.f - std::exp(-dt / 0.02f)) * (std::max(channelPressure, polyPressure[v.note]) - v.pressure);
    v.vibratoIn = clamp01(v.vibratoIn + (v.pressure > 0.05f ? dt / 0.4f : -dt / 0.2f));
    v.vibPhase += (double)(kVibratoHz * dt);
    v.vibPhase -= std::floor(v.vibPhase);
    v.slop.advance(dt);
    // The blade: held notes follow the wheel; a released note's bend falls away.
    if (v.held()) v.bend = bendNow * kBladeRange;
    else v.bend *= std::exp(-dt / kFallTau);
    const float vib = kVibratoCents * v.pressure * v.vibratoIn * (float)std::sin(v.vibPhase * 2.0 * 3.14159265358979);
    const float pitch = std::clamp((float)v.note + pTranspose, 0.f, 127.f) + v.bend + 0.01f * (fine.value + vib);
    const float f0 = midiHz(pitch), base = f0 / fsr;
    // Each saw drifts (60% of the core's slop: the stack's own detune already moves it); mood motion 0 halves it.
    const float slopDepth = dry ? 0.f : 0.6f * (0.5f + clamp01(mMotion));
    const float w = clamp01(width.value), spread = 2.f + 14.f * w;
    float incs[kSaws], gl[kSaws], gr[kSaws];
    for (int i = 0; i < kSaws; ++i) {
        const float pos = kSaws > 1 ? 2.f * (float)i / (float)(kSaws - 1) - 1.f : 0.f;
        incs[i] = std::min(analog::kMaxIncrement, base * std::exp2((pos * spread + v.slop.pitchCents(i, slopDepth)) / 1200.f));
        // A linear pan law (scaled to −3 dB in the centre): the stack really spreads at full Width.
        const float pan = v.pan[i] * w;
        gl[i] = 0.7071f * (1.f - pan) * (1.f / std::sqrt((float)kSaws));
        gr[i] = 0.7071f * (1.f + pan) * (1.f / std::sqrt((float)kSaws));
    }
    const float pulseInc = std::min(analog::kMaxIncrement, base);
    // The pulse leans to one side by the note's parity as Width opens, so the stack decorrelates fully.
    const float pulsePan = ((v.note & 1) ? 0.6f : -0.6f) * w;
    const float pl = kPulseLevel * 0.7071f * (1.f - pulsePan), pr = kPulseLevel * 0.7071f * (1.f + pulsePan);
    // The filter: Blaze's resting cutoff, key tracking, the swell's envelope, the blare's overshoot, pressure.
    const bool wasAttacking = v.filter.stage == analog::ADSR::Attack;
    float envLevel = 0.f;
    for (int i = 0; i < n; ++i) envLevel = v.filter.next();
    if (wasAttacking && v.filter.stage != analog::ADSR::Attack) v.overshoot = 2.f * v.blare;   // the attack just peaked
    else v.overshoot *= std::exp(-dt / kOvershootTau);
    const float bz = clamp01(blaze.value);
    const float octaves = (kEnvOctaves + kEnvOctavesBlaze * bz) * (0.6f + 0.4f * v.vel01) * envLevel + v.overshoot + kPressureOctaves * v.pressure;
    const float cutoff = logLerp(kCutoffLow, kCutoffHigh, bz) * analog::keyTrack(f0, kBrassKeyTrack) * v.slop.cutoffRatio(slopDepth) * std::exp2(octaves);
    v.lowL.set(std::min(cutoff, 0.45f * fsr), kBrassQ, fsr);
    v.lowR.a1 = v.lowL.a1; v.lowR.a2 = v.lowL.a2; v.lowR.a3 = v.lowL.a3; v.lowR.k = v.lowL.k;
    for (int i = 0; i < n; ++i) {
        float sl = 0.f, srr = 0.f;
        for (int k = 0; k < kSaws; ++k) {
            const float s = analog::saw((float)v.sawPhase[k], incs[k]);
            v.sawPhase[k] += incs[k];
            if (v.sawPhase[k] >= 1.0) v.sawPhase[k] -= 1.0;
            sl += gl[k] * s; srr += gr[k] * s;
        }
        const float p = v.pulse.next(pulseInc);
        sl += pl * p; srr += pr * p;
        float b1, lowLeft, lowRight;
        v.lowL.tick(sl, b1, lowLeft);
        v.lowR.tick(srr, b1, lowRight);
        float env = v.amp.next() * v.gain * kBrassGain;
        if (v.fading) {
            v.fadeGain -= v.fadeStep;
            if (v.fadeGain <= 0.f) { v.fadeGain = 0.f; v.active = false; }
            env *= v.fadeGain;
        }
        l[i] += env * lowLeft;
        r[i] += env * lowRight;
        if (!v.active) break;
    }
    if (v.active && v.amp.idle()) v.active = false;
}

// ---------- Chrome Bass ----------

ReplicantBrass::BassVoice *ReplicantBrass::bassSounding() {
    BassVoice *best = nullptr;
    for (auto &v : bass) if (v.active && !v.fading && (!best || v.age > best->age)) best = &v;
    return best;
}

ReplicantBrass::BassVoice &ReplicantBrass::allocateBass() {
    for (auto &v : bass) if (!v.active) return v;
    BassVoice *best = nullptr;
    for (auto &v : bass) if (v.fading && (!best || v.fadeGain < best->fadeGain)) best = &v;
    if (!best) best = &bass[0];
    best->active = false;
    return *best;
}

void ReplicantBrass::bassStrike(int note, int velocity, bool legato) {
    const float fsr = (float)sr;
    const float pitch = std::clamp((float)note + pTranspose, 0.f, 127.f);
    BassVoice *cur = bassSounding();
    if (legato && cur && cur->gated) {
        cur->note = note;
        cur->glide.setTime(kBassGlide, fsr);
        cur->glide.glideTo(pitch);
        return;
    }
    if (cur) { cur->fading = true; cur->fadeStep = 1.f / (kPanicFade * fsr); }
    BassVoice &v = allocateBass();
    v = BassVoice{};
    v.active = true;
    v.gated = true;
    v.note = note;
    v.age = ++noteCounter;
    v.gain = velocityGain(velocity);
    FastRandom r(voiceSeed ^ (0xBA55ULL * v.age));
    v.osc.reset(r.uniform());
    v.octave.reset(r.uniform());
    v.osc.setShape(0.05f);
    v.highPass.set(30.f, 0.707f, fsr);
    v.amp.setAttack(0.002f, fsr); v.amp.setDecay(0.35f, fsr); v.amp.setSustain(0.6f); v.amp.setRelease(0.08f, fsr);
    v.pluck.set(0.001f, 0.14f, 0.0f, 0.1f, fsr);
    v.pluck.setVelocityDepth(0.5f);
    v.ladder.setResonance(kBassRes);
    v.ladder.snapCutoff(kBassCutoff, fsr);
    v.glide.setTime(kBassGlide, fsr);
    v.glide.jump(pitch);
    v.amp.trigger(1.f);
    v.pluck.gate(true, (float)std::clamp(velocity, 0, 127) / 127.f);
}

void ReplicantBrass::bassRelease() {
    for (auto &v : bass) if (v.active && !v.fading && v.gated) { v.gated = false; v.amp.release(); v.pluck.gate(false, 0.f); }
}

void ReplicantBrass::bassKeyDown(int note, int velocity) {
    if (arpOn()) { arp.keyDown(note, velocity, clock); return; }
    const bool legato = !bassKeys.empty();
    bassKeys.press(note, velocity);
    bassStrike(note, velocity, legato);
}

void ReplicantBrass::bassKeyUp(int note) {
    if (arpOn()) { arp.keyUp(note, clock); bassKeys.release(note); return; }
    const int top = bassKeys.top();
    bassKeys.release(note);
    if (!bassKeys.empty()) {
        if (note == top) bassStrike(bassKeys.top(), bassKeys.topVelocity(), true);
        return;
    }
    if (top == note) bassRelease();
}

void ReplicantBrass::handleArp(const Arp::Event &e) {
    if (e.on) { bassStrike(e.note, e.velocity, false); arpSounding = e.note; }
    else if (e.note == arpSounding) { bassRelease(); arpSounding = -1; }
}

void ReplicantBrass::renderBass(BassVoice &v, float *l, float *r, int n) {
    const float fsr = (float)sr;
    const float pitch = v.glide.advance(n) + 0.01f * fine.value + bendNow;
    const float f0 = midiHz(pitch);
    const float inc = std::min(analog::kMaxIncrement, f0 / fsr), inc2 = std::min(analog::kMaxIncrement, 2.f * f0 / fsr);
    const float pu = clamp01(punch.value);
    v.pluck.setDepth(4.f * pu);
    const float oct = v.pluck.advance(n);
    v.ladder.setCutoff(kBassCutoff * analog::keyTrack(f0, kBassKeyTrack) * std::exp2(1.f + oct), fsr, n);
    v.ladder.setDrive(0.3f * pu);
    v.shaper.set(dryHook ? 0.f : 0.35f * (0.5f + pu), 0.f, 0.1f);
    const float level = v.gain * kBassGain * (0.25f + 1.25f * clamp01(chrome.value));
    for (int i = 0; i < n; ++i) {
        const float a = v.osc.nextWithSub(inc);
        const float x = 0.55f * a + 0.35f * v.octave.next(inc2) + 0.45f * v.osc.sub;
        float y = v.highPass.process(v.shaper.process(v.ladder.process(x)));
        float env = v.amp.next() * level;
        if (v.fading) {
            v.fadeGain -= v.fadeStep;
            if (v.fadeGain <= 0.f) { v.fadeGain = 0.f; v.active = false; }
            env *= v.fadeGain;
        }
        l[i] += env * y;
        r[i] += env * y;
        if (!v.active) break;
    }
    if (v.active && v.amp.idle()) v.active = false;
}

// ---------- Rendering ----------

void ReplicantBrass::chorus(float *l, float *r, int n) {
    const int len = (int)chorusBuf[0].size();
    const float mix = dryHook ? 0.f : 0.35f * clamp01(width.value);
    const double inc = (double)kChorusHz / sr;
    for (int i = 0; i < n; ++i) {
        chorusBuf[0][(size_t)chorusW] = l[i];
        chorusBuf[1][(size_t)chorusW] = r[i];
        for (int side = 0; side < 2; ++side) {
            const double ph = chorusPhase + (side ? 0.25 : 0.0);
            const float d = (kChorusMs + kChorusDepthMs * (float)std::sin(ph * 2.0 * 3.14159265358979)) * 0.001f * (float)sr;
            const float pos = (float)chorusW - d;
            const float fp = std::floor(pos), t = pos - fp;
            int i0 = (int)fp; while (i0 < 0) i0 += len; i0 %= len;
            const int i1 = (i0 + 1) % len;
            const float delayed = chorusBuf[side][(size_t)i0] * (1.f - t) + chorusBuf[side][(size_t)i1] * t;
            (side ? r : l)[i] += mix * delayed;
        }
        chorusPhase += inc;
        if (chorusPhase >= 1.0) chorusPhase -= 1.0;
        if (++chorusW == len) chorusW = 0;
    }
}

void ReplicantBrass::processBlock(float *left, float *right, int n) {
    const float dt = (float)n / (float)sr;
    for (Smoothed *s : {&fine, &swell, &blaze, &width, &hall, &chrome, &punch}) s->next();
    bendNow += (1.f - std::exp(-dt / 0.005f)) * (bendTarget - bendNow);
    const float hz = clamp01(hall.value);
    if (appliedHall < 0.f) { reverb.configure(kHallSize, 0.45f, 22.f, 0.f); appliedHall = hz; }

    float bl[kSub] = {}, br[kSub] = {}, ll[kSub] = {}, lr[kSub] = {}, wl[kSub], wr[kSub], sl[kSub], srr[kSub];
    for (auto &v : brass) if (v.active) renderBrass(v, bl, br, n);
    for (auto &v : bass) if (v.active) renderBass(v, ll, lr, n);
    chorus(bl, br, n);
    const bool quiet = dryHook || reverbEmptying;
    const float send = quiet ? 0.f : 0.8f * hz, bassSend = quiet ? 0.f : 0.15f * hz;
    for (int i = 0; i < n; ++i) { sl[i] = send * bl[i] + bassSend * ll[i]; srr[i] = send * br[i] + bassSend * lr[i]; }
    reverb.process(sl, srr, wl, wr, n);
    if (reverbEmptying) {
        for (int i = 0; i < n; ++i) { reverbFade = std::max(0.f, reverbFade - reverbFadeStep); wl[i] *= reverbFade; wr[i] *= reverbFade; }
        if (reverbFade <= 0.f) {
            reverb.clear();
            for (auto &b : chorusBuf) std::fill(b.begin(), b.end(), 0.f);
            reverbEmptying = false;
            reverbFade = 1.f;
        }
    }
    for (int i = 0; i < n; ++i) {
        float l = bl[i] + ll[i] + wl[i], r = br[i] + lr[i] + wr[i];
        limiter.process(l, r);
        left[i] = l; right[i] = r;
    }
}

void ReplicantBrass::render(float *left, float *right, int frames) {
    DenormalGuard guard;
    int pos = 0;
    while (pos < frames) {
        if (arpOn() || arp.running()) {
            Arp::Event e;
            while (arp.poll(clock, e)) if (arpOn()) handleArp(e);
        }
        int n = std::min(kSub, frames - pos);
        if (arpOn() || arp.running()) n = std::min(n, arp.samplesToNext(clock));
        processBlock(left + pos, right + pos, n);
        pos += n;
        clock += n;
    }
}

} // namespace isd
