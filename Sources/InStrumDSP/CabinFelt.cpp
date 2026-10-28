#include "CabinFelt.hpp"
#include "include/InStrumDSP.h"
#include <algorithm>
#include <cstring>

namespace isd {

namespace {

// Level calibration (see docs/superpowers/briefs/cabin-felt.md).
constexpr float kStringGain = 0.30f;
constexpr float kSympIn = 0.02f;
constexpr float kSympOut = 8.0f;
constexpr float kHornLevel = 0.16f;
constexpr float kMaster = 1.0f;
/// An upright's shorter strings: more inharmonic than Felt Glass's grand, a little wider in unison.
constexpr float kUprightB = 1.6f, kUprightDetune = 1.3f;

const float kTapMs[2][4] = {{3.1f, 5.7f, 9.2f, 13.4f}, {4.3f, 7.6f, 11.1f, 14.8f}};
const float kTapGain[4] = {0.35f, 0.28f, 0.22f, 0.16f};

inline float smoothstep01(float x) { x = clamp01(x); return x * x * (3.f - 2.f * x); }

} // namespace

void CabinFelt::Burst::start(float seconds, float hz, float q, float rms, double sampleRate) {
    const float fsr = (float)sampleRate;
    left = std::max(1, (int)(seconds * fsr)); age = 0; attack = std::max(1, (int)(0.001f * fsr));
    // Uniform noise (RMS 0.577) through the band-pass and its low-pass keeps ≈ sqrt(π·f/(Q·sr))·0.8 of its RMS.
    const float keep = 0.577f * std::sqrt(kPi * std::min(hz, 0.4f * fsr) / (q * fsr)) * 0.8f;
    amp = rms / std::max(keep, 1e-4f);
    decay = std::exp(-1.f / (seconds / 3.f * fsr));
    bp.setBandpass(std::min(hz, 0.45f * fsr), q, sampleRate);
    lp.setCutoff(std::min(2.f * hz, 0.45f * fsr), sampleRate);
}

CabinFelt::CabinFelt(double sampleRate) : sr(sampleRate), rng(0xCAB1F317ULL), reverb(sampleRate, kSub) {
    limiter.init(sr);
    fine.init(sr); hornGain.init(sr); fire.init(sr); wood.init(sr); space.init(sr); wet.init(sr); sympGain.init(sr, 50.0);
    fine.snap(0); hornGain.snap(0.30f); fire.snap(0.5f); wood.snap(0.5f); space.snap(0.35f); wet.snap(0); sympGain.snap(0);
    // An upright's cabinet: a warm low body, a softer middle, a slight dip in the honk.
    const double peaks[4][3] = {{95, 1.0, 3.0}, {190, 1.2, 2.0}, {360, 1.2, 1.5}, {720, 1.0, -1.0}};
    for (int b = 0; b < 4; ++b)
        for (int c = 0; c < 2; ++c) body[b][c].setPeak(peaks[b][0], peaks[b][1], peaks[b][2], sr);
    // Early reflections off the log walls (sized for this rate, made here, never on the audio thread).
    erLen = (int)(0.02 * sr) + 8;
    for (int c = 0; c < 2; ++c) {
        erBuf[c].assign((size_t)erLen, 0.f);
        erTone[c].setCutoff(3000.f, sr);
        for (int k = 0; k < 4; ++k) erTap[c][k] = std::min(erLen - 1, (int)(kTapMs[c][k] * 0.001 * sr));
    }
    horn.f1.setBandpass(700.0, 2.0, sr);
    horn.f2.setBandpass(1300.0, 2.0, sr);
    horn.breath.setBandpass(1500.0, 1.0, sr);
    horn.dark.setCutoff(4500.f, sr);
    symp.init(sr);
    setSympDecay(0.08f);
}

void CabinFelt::setParam(int address, float value, bool snap) {
    auto set = [&](Smoothed &s) { if (snap) s.snap(value); else s.setTarget(value); };
    switch (address) {
    case ISD_P_FINE_TUNE: set(fine); break;
    case ISD_P_TRANSPOSE: pTranspose = value; break;
    case ISD_P_FELT: pFelt = value; break;
    case ISD_P_HORN: set(hornGain); break;
    case ISD_P_FIRE: set(fire); break;
    case ISD_P_WOOD: set(wood); break;
    case ISD_P_SPACE: set(space); break;
    case ISD_P_WIDTH: pWidth = value; break;
    case ISD_P_MOOD_ENERGY: mEnergy = value; break;
    case ISD_P_MOOD_WARMTH: mWarmth = value; break;
    case ISD_P_MOOD_BRIGHTNESS: mBright = value; break;
    case ISD_P_MOOD_SPACE: mSpace = value; break;
    case ISD_P_MOOD_MOTION: mMotion = value; break;
    case ISD_P_DEBUG_NO_MECHANICS: noMechanics = value > 0.5f; break;
    case ISD_P_DEBUG_HORN_ONLY: hornOnly = value > 0.5f; break;
    default: break;
    }
}

int CabinFelt::activeVoices() const {
    int n = horn.sounding ? 1 : 0;
    for (const auto &v : voices) n += v.active ? 1 : 0;
    return n;
}

int CabinFelt::debugCount(int which) const {
    if (which == ISD_DEBUG_HORN_NOTE) return horn.sounding && !horn.released ? horn.pitch : -1;
    return 0;
}

CabinFelt::Voice &CabinFelt::allocate() {
    int sounding = 0;
    Voice *quietest = nullptr;
    for (auto &v : voices) {
        if (!v.active || v.fading) continue;
        ++sounding;
        if (!quietest || v.level < quietest->level) quietest = &v;
    }
    if (sounding >= kPolyphony && quietest) beginFade(*quietest);
    for (auto &v : voices) if (!v.active) return v;
    Voice *best = nullptr;
    for (auto &v : voices) if (v.fading && (!best || v.fadeGain < best->fadeGain)) best = &v;
    if (!best) best = &voices[0];
    best->active = false;
    return *best;
}

void CabinFelt::beginFade(Voice &v) {
    if (v.fading) return;
    v.fading = true;
    v.fadeStep = 1.f / (0.02f * (float)sr);
}

void CabinFelt::noteOn(int note, int velocity) {
    if (velocity <= 0) { noteOff(note); return; }
    note &= 127;
    idle = false; idleSamples = 0;
    // The horn takes a note that is the highest key held at the moment it's pressed.
    bool highest = true;
    for (int k = note + 1; k < 128; ++k) if (keyDown[k]) { highest = false; break; }
    keyDown[note] = true;
    if (highest) startHorn(note, velocity);
    if (hornOnly) return;
    int pitch = std::clamp(note + (int)std::lround(pTranspose), 0, 127);
    for (auto &v : voices)
        if (v.active && !v.fading && v.note == note && v.keyDown) { v.keyDown = false; if (!sustain) damp(v); }
    startVoice(allocate(), note, pitch, velocity);
}

void CabinFelt::startVoice(Voice &v, int note, int pitch, int velocity) {
    const float fsr = (float)sr, nyq = 0.45f * fsr;
    const float vp = (float)std::clamp(velocity, 1, 127) / 127.f;
    const float vb = clamp01(vp + 0.3f * (mBright - 0.5f) + 0.2f * (mEnergy - 0.5f));
    const float felt = clamp01(pFelt);
    const float f0 = midiHz((float)pitch);
    // The felt strip takes up to 6 dB off the strike.
    const float A = std::pow(vp, 1.7f) * std::pow(10.f, -6.f * felt / 20.f);

    v.active = true; v.keyDown = true; v.damped = false; v.fading = false;
    v.note = note; v.pitch = pitch;
    v.fadeGain = 1; v.fadeStep = 0;
    v.str.clear();

    const float B = kUprightB * inharmonicity(pitch), s1 = std::sqrt(1.f + B);
    const int N = partialCount(pitch);
    // The hammer's cutoff follows the string (treble hammers are smaller and harder), opens with velocity and
    // closes under the felt.
    const float hammer = 360.f * std::pow(f0 / 261.63f, 0.6f);
    const float fc = hammer * (1.f - 0.7f * felt) * std::exp2(4.5f * vb), fcRef = hammer * std::exp2(4.5f);
    // An upright rings shorter than a grand, and the felt shortens it further.
    const float t0 = 30.f * std::pow(10.f, -(float)(pitch - 21) / 87.f) * (1.f - 0.35f * felt);
    float refE = 0;
    int k = 0;
    float phase = 0;
    auto add = [&](float hz, float a, float t60) {
        v.str.hz[k] = hz; v.str.re[k] = a * std::cos(phase); v.str.im[k] = a * std::sin(phase); v.str.dr[k] = decayR(t60, sr); ++k;
    };
    for (int n = 1; n <= N && k < kStrings; ++n) {
        float nf = (float)n, fn = nf * f0 * std::sqrt(1.f + B * nf * nf) / s1;
        if (fn > nyq) break;
        float pos = std::sin(nf * kPi / 8.f);
        if (std::fabs(pos) < 1e-3f) continue;
        float edge = nf > 0.75f * (float)N ? 0.5f + 0.5f * std::cos(kPi * (nf - 0.75f * (float)N) / (0.25f * (float)N + 1.f)) : 1.f;
        float aRef = edge * pos / (1.f + std::pow(fn / fcRef, 3.f));
        float a = edge * pos / (1.f + std::pow(fn / fc, 3.f));
        float t60 = t0 / (1.f + fn / 2500.f);
        phase = kTwoPi * (0.381966f * nf + 0.137f * (float)pitch - std::floor(0.381966f * nf + 0.137f * (float)pitch));
        if (n <= 12 && k + 2 <= kStrings) {
            float d = (0.15f + 0.35f * nf / 12.f) * kUprightDetune;
            add(fn * std::exp2(-d / 1200.f), a, t60);
            add(fn * std::exp2(d / 1200.f), 0.25f * a, 2.6f * t60);
            refE += aRef * aRef * 1.0625f;
        } else {
            add(fn, a, t60);
            refE += aRef * aRef;
        }
    }
    const float norm = refE > 0 ? A * kStringGain / std::sqrt(refE) : 0.f;
    v.stringRef = 0;
    for (int i = 0; i < k; ++i) {
        v.str.re[i] *= norm; v.str.im[i] *= norm;
        v.stringRef += v.str.re[i] * v.str.re[i] + v.str.im[i] * v.str.im[i];
    }
    v.str.setUsed(k);
    v.str.retune(fineRatio, sr, kStrings);

    // Felt contact: longer and softer under the felt.
    v.attackPos = 0;
    v.attackLen = std::max(1, (int)((4.f - 3.f * vp) * (1.f + 1.5f * felt) * 0.001f * fsr));
    v.noteRms = std::sqrt(0.5f * v.stringRef);
    const float hz = 180.f + 220.f * (float)(pitch - 21) / 87.f;
    v.hammer.bp.clear(); v.hammer.lp.clear();
    v.hammer.start((25.f - 17.f * vp) * 0.001f, hz, 1.2f, v.noteRms * std::pow(10.f, (-18.f + 10.f * felt) / 20.f), sr);
    v.thump.left = v.lift.left = v.chuff.left = 0;
    if (!noMechanics) {
        // The key bottoming out: a low thud. The dampers lifting: a faint breath of felt.
        v.thump.bp.clear(); v.thump.lp.clear();
        v.thump.start(0.015f, 90.f, 0.9f, v.noteRms * 0.1f * (0.4f + 0.6f * vp), sr);
        v.lift.bp.clear(); v.lift.lp.clear();
        v.lift.start(0.008f, 2500.f, 0.7f, v.noteRms * 0.01f, sr);
    }
    const float pan = std::clamp(clamp01(pWidth) * (float)(pitch - 64) / 44.f, -1.f, 1.f), th = (pan + 1.f) * kPi / 4.f;
    v.panL = std::cos(th); v.panR = std::sin(th);
    v.level = v.stringRef;
}

void CabinFelt::damp(Voice &v) {
    if (v.damped) return;
    v.damped = true;
    v.str.damp(decayR(0.15f, sr));
    if (!noMechanics) {
        // The damper's felt landing on the strings: a short, soft chuff around the low mids.
        const float now = std::sqrt(0.5f * std::max(v.level, 0.f));
        v.chuff.bp.clear(); v.chuff.lp.clear();
        v.chuff.start(0.020f, 560.f, 1.4f, now * 3.5f, sr);
    }
}

void CabinFelt::noteOff(int note) {
    note &= 127;
    keyDown[note] = false;
    if (horn.sounding && !horn.released && horn.key == note) releaseHorn(false);
    for (auto &v : voices)
        if (v.active && !v.fading && v.note == note && v.keyDown) { v.keyDown = false; if (!sustain) damp(v); }
}

void CabinFelt::setSustain(bool down) {
    if (down == sustain) return;
    sustain = down;
    if (down) {
        setSympDecay(3.f);
        sympGain.setTarget(1.f);
        sympActive = true;
        if (!noMechanics && !hornOnly) {
            // The pedal rod lifting every damper: a soft thud in the nearest free voice's burst.
            for (auto &v : voices) if (v.active) { v.thump.bp.clear(); v.thump.lp.clear(); v.thump.start(0.03f, 60.f, 0.8f, 0.004f, sr); break; }
        }
    } else {
        setSympDecay(0.08f);
        sympGain.setTarget(0.f);
        for (auto &v : voices) if (v.active && !v.fading && !v.keyDown) damp(v);
    }
}

void CabinFelt::allNotesOff() {
    for (auto &v : voices) if (v.active) beginFade(v);
    for (auto &k : keyDown) k = false;
    releaseHorn(true);
    sympGain.setTarget(0.f);
    setSympDecay(0.08f);
}

void CabinFelt::allSoundOff() {
    allNotesOff();
    reverb.clear();
    for (auto &b : erBuf) std::fill(b.begin(), b.end(), 0.f);
}

void CabinFelt::retune() {
    for (auto &v : voices) if (v.active) v.str.retune(fineRatio, sr);
    setSympDecay(sustain ? 3.f : 0.08f);
}

// MARK: - Horn

void CabinFelt::startHorn(int note, int velocity) {
    int p = note + (int)std::lround(pTranspose);
    while (p > kHornHigh) p -= 12;
    while (p < kHornLow) p += 12;
    const float vp = (float)std::clamp(velocity, 1, 127) / 127.f;
    const bool legato = horn.sounding && !horn.released && !horn.fast;
    horn.key = note; horn.pitch = p; horn.released = false; horn.fast = false;
    horn.velocity = vp;
    horn.bright = clamp01(0.25f + 0.75f * clamp01(vp + 0.3f * (mBright - 0.5f)));
    horn.age = 0;   // the vibrato waits again on every new note
    if (legato) {
        // A slur: glide from wherever the pitch is now, with a small dip in breath.
        horn.from = horn.midi; horn.to = (float)p; horn.glidePos = 0; horn.glideLen = std::max(1, (int)(0.075 * sr));
    } else {
        // A fresh phrase: scoop up into the note with a puff of breath.
        horn.sounding = true;
        horn.midi = horn.from = horn.to = (float)p; horn.glidePos = horn.glideLen = 1;
        horn.scoop = -40.f;
        horn.env = 0;
        horn.phase = 0;
        horn.f1.clear(); horn.f2.clear(); horn.breath.clear(); horn.dark.clear();
    }
    idle = false; idleSamples = 0;
}

void CabinFelt::releaseHorn(bool fast) {
    if (!horn.sounding) return;
    horn.released = true;
    horn.fast = fast;
}

/// One sample of the horn (mono), before its level dial. `freqRatio` carries Fine tune.
float CabinFelt::renderHorn(float freqRatio) {
    const float fsr = (float)sr;
    // Envelope: a quick breathy attack, a 130 ms release (20 ms on panic).
    const float tauUp = 0.025f, tauDown = horn.fast ? 0.004f : 0.019f;
    if (horn.released) horn.env *= std::exp(-1.f / (tauDown * fsr));
    else horn.env += (1.f - horn.env) * (1.f - std::exp(-1.f / (tauUp * fsr)));
    if (horn.released && horn.env < 1e-5f) { horn.sounding = false; horn.env = 0; return 0.f; }

    // Pitch: glide, scoop and a delayed vibrato.
    float dip = 1.f;
    if (horn.glidePos < horn.glideLen) {
        const float x = (float)horn.glidePos / (float)horn.glideLen;
        horn.midi = horn.from + (horn.to - horn.from) * smoothstep01(x);
        dip = 1.f - 0.25f * std::sin(kPi * x);
        ++horn.glidePos;
    } else {
        horn.midi = horn.to;
    }
    const float scoopTau = 0.035f * (1.2f - 0.4f * clamp01(mEnergy));
    horn.scoop *= std::exp(-1.f / (scoopTau * fsr));
    const float t = (float)horn.age / fsr;
    ++horn.age;
    const float vibIn = smoothstep01((t - 0.5f) / 0.3f);
    horn.vibPhase += 5.0 / sr;
    if (horn.vibPhase >= 1.0) horn.vibPhase -= 1.0;
    const float vib = 12.f * (0.5f + clamp01(mMotion)) * vibIn * std::sin(kTwoPi * (float)horn.vibPhase);
    const float hz = midiHz(horn.midi + (horn.scoop + vib) / 100.f) * freqRatio;

    // Tone: harmonics whose tilt opens with velocity and over the first 80 ms (brass brightens as it speaks).
    horn.phase += (double)hz / sr;
    if (horn.phase >= 1.0) horn.phase -= 1.0;
    const float open = 0.75f + 0.25f * smoothstep01(t / 0.08f);
    const float g = 0.46f + 0.5f * horn.bright * open;
    const int K = std::clamp((int)(0.45f * fsr / std::max(hz, 1.f)), 1, 16);
    const float th = kTwoPi * (float)horn.phase, c2 = 2.f * std::cos(th);
    float s1 = std::sin(th), s0 = 0.f, a = 1.f, sum = 0.f, norm = 0.f;
    for (int k = 1; k <= K; ++k) {
        sum += a * s1;
        norm += a * a;
        const float s2 = c2 * s1 - s0;
        s0 = s1; s1 = s2;
        a *= g;
    }
    const float raw = sum / std::sqrt(norm);
    float y = 0.5f * raw + horn.f1.process(raw) + 1.2f * horn.f2.process(raw);
    y = horn.dark.process(y);
    const float breath = horn.breath.process(rng.bipolar()) * 0.04f * (0.5f + 0.5f * horn.bright);
    const float level = kHornLevel * (0.3f + 0.7f * std::pow(horn.velocity, 1.2f));
    return (y + breath) * horn.env * dip * level;
}

// MARK: - Render

void CabinFelt::render(float *left, float *right, int frames) {
    int pos = 0;
    while (pos < frames) {
        int n = std::min(kSub, frames - pos);
        processBlock(left + pos, right + pos, n);
        pos += n;
    }
}

void CabinFelt::renderVoice(Voice &v, float *sL, float *sR, float *mono, int n) {
    v8 lane[kSub];
    float vs[kSub];
    for (int t = 0; t < n; ++t) lane[t] = v8{};
    v.str.render(lane, n);
    for (int t = 0; t < n; ++t) vs[t] = hsum(lane[t]);
    if (v.attackPos < v.attackLen) {
        for (int t = 0; t < n && v.attackPos < v.attackLen; ++t, ++v.attackPos)
            vs[t] *= 0.5f - 0.5f * std::cos(kPi * (float)v.attackPos / (float)v.attackLen);
    }
    if (v.hammer.left > 0 || v.thump.left > 0 || v.lift.left > 0 || v.chuff.left > 0) {
        for (int t = 0; t < n; ++t)
            vs[t] += v.hammer.next(rng) + v.thump.next(rng) + v.lift.next(rng) + v.chuff.next(rng);
    }
    if (v.fading) {
        for (int t = 0; t < n; ++t) {
            vs[t] *= v.fadeGain;
            v.fadeGain = std::max(0.f, v.fadeGain - v.fadeStep);
        }
        if (v.fadeGain <= 0.f) v.active = false;
    }
    for (int t = 0; t < n; ++t) {
        sL[t] += vs[t] * v.panL; sR[t] += vs[t] * v.panR;
        mono[t] += vs[t];
    }
}

void CabinFelt::housekeeping() {
    for (auto &v : voices) {
        if (!v.active) continue;
        const float floorS = std::max(1e-8f * v.stringRef, 1e-14f);
        const float e = v.str.energyAndPrune(floorS);
        v.level = e;
        const bool bursting = v.hammer.left > 0 || v.thump.left > 0 || v.lift.left > 0 || v.chuff.left > 0;
        if (e <= 0 && !bursting) v.active = false;
    }
    if (sympActive && sympGain.target == 0.f && sympGain.value < 1e-4f && symp.pruneIfSilent()) sympActive = false;
}

void CabinFelt::processBlock(float *left, float *right, int n) {
    const float fsr = (float)sr;
    for (int t = 0; t < n; ++t) { fine.next(); fire.next(); wood.next(); space.next(); }
    if (blockCount % 4 == 0) {
        const bool landed = std::fabs(fine.value - fine.target) < 0.01f && std::fabs(fine.target - appliedCents) > 1e-4f;
        if (landed || std::fabs(fine.value - appliedCents) > 0.1f) {
            appliedCents = landed ? fine.target : fine.value;
            fineRatio = std::exp2(appliedCents / 1200.f);
            retune();
        }
    }
    const float fv = clamp01(fire.value + 0.5f * (mWarmth - 0.5f));
    if (std::fabs(fv - appliedFire) > 1e-3f) {
        appliedFire = fv;
        for (int c = 0; c < 2; ++c) {
            lowShelf[c].setLowShelf(250.0, 3.0 * fv, sr);
            highShelf[c].setHighShelf(4000.0, -4.0 * fv, sr);
        }
    }
    const float wv = clamp01(wood.value);
    const float sv = clamp01(space.value + 0.6f * (mSpace - 0.5f));
    if (std::fabs(sv - appliedSpace) > 2e-3f || std::fabs(wv - appliedWood) > 2e-3f) {
        appliedSpace = sv; appliedWood = wv;
        reverb.configure(0.08f + 0.17f * wv, 0.6f, 6.f, 0.f);
        wet.setTarget(0.6f * sv);
    }
    erGain = wv;
    // Fire: a warm tanh, unity gain for small signals, gently rounding the loud ones.
    const float drive = 0.5f + 1.0f * fv, invDrive = 1.f / drive;

    float sL[kSub] = {}, sR[kSub] = {}, mono[kSub] = {}, hornOut[kSub] = {};
    float dryL[kSub] = {}, dryR[kSub] = {};
    if (!idle) {
        bool anyVoice = false;
        for (auto &v : voices) {
            if (!v.active) continue;
            anyVoice = true;
            renderVoice(v, sL, sR, mono, n);
        }
        if (sympActive) symp.render(mono, sL, sR, n, sympGain, kSympIn, kSympOut);
        const bool hornLive = horn.sounding;
        for (int t = 0; t < n; ++t) {
            const float hg = hornGain.next();
            if (hornLive && horn.sounding) hornOut[t] = hg * renderHorn(fineRatio);
        }
        float peakAbs = 0;
        for (int t = 0; t < n; ++t) {
            float l = sL[t], r = sR[t];
            for (int b = 0; b < 4; ++b) { l = body[b][0].process(l); r = body[b][1].process(r); }
            l += hornOut[t]; r += hornOut[t];
            l = std::tanh(drive * l) * invDrive;
            r = std::tanh(drive * r) * invDrive;
            l = highShelf[0].process(lowShelf[0].process(l));
            r = highShelf[1].process(lowShelf[1].process(r));
            // Early reflections off the log walls.
            erBuf[0][(size_t)erPos] = l; erBuf[1][(size_t)erPos] = r;
            float el = 0, er = 0;
            for (int k = 0; k < 4; ++k) {
                el += kTapGain[k] * erBuf[0][(size_t)((erPos - erTap[0][k] + erLen) % erLen)];
                er += kTapGain[k] * erBuf[1][(size_t)((erPos - erTap[1][k] + erLen) % erLen)];
            }
            if (++erPos == erLen) erPos = 0;
            l += erGain * erTone[0].process(er * 0.6f + el * 0.4f);
            r += erGain * erTone[1].process(el * 0.6f + er * 0.4f);
            dryL[t] = l; dryR[t] = r;
            peakAbs = std::max(peakAbs, std::max(std::fabs(l), std::fabs(r)));
        }
        if (!anyVoice && !sympActive && !horn.sounding && peakAbs < 1e-6f) {
            idleSamples += n;
            if (idleSamples >= (int)(0.25f * fsr)) {
                idle = true;
                idleSamples = 0;
                for (auto &bq : body) { bq[0].clear(); bq[1].clear(); }
                for (int c = 0; c < 2; ++c) { highShelf[c].clear(); lowShelf[c].clear(); erTone[c].clear(); }
                for (auto &b : erBuf) std::fill(b.begin(), b.end(), 0.f);
            }
        } else {
            idleSamples = 0;
        }
    } else {
        for (int t = 0; t < n; ++t) hornGain.next();
    }

    float revL[kSub] = {}, revR[kSub] = {};
    if (wet.target > 0.f || wet.value > 1e-5f) {
        reverb.process(dryL, dryR, revL, revR, n);
        reverbLive = true;
    } else if (reverbLive) {
        reverb.clear();
        reverbLive = false;
    }
    for (int t = 0; t < n; ++t) {
        float w = wet.next();
        float l = kMaster * (dryL[t] + w * revL[t]), r = kMaster * (dryR[t] + w * revR[t]);
        limiter.process(l, r);
        left[t] = softLimit(l);
        right[t] = softLimit(r);
    }
    if (++blockCount % 4 == 0) housekeeping();
}

} // namespace isd
