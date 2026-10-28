#include "HazeBells.hpp"
#include "include/InStrumDSP.h"
#include <algorithm>

namespace isd {

namespace {

// Level and tone calibration (see docs/superpowers/briefs/haze-bells.md).
constexpr float kBell = 0.55f;           // fork fundamental per voice at full velocity
constexpr float kOrgan = 0.11f;          // organ 8′ per voice
constexpr float kMaster = 0.34f;       // sits level with Felt Glass and Orbit Pad
constexpr float kWetMax = 0.5f;
constexpr float kClangRatio = 6.25f;     // the tuning fork's first "clang" mode
constexpr float kClangT60 = 0.15f;
constexpr float kTinkRatio = 17.55f;     // its second, fainter and shorter
constexpr float kTinkT60 = 0.06f;
constexpr float kDamperT60 = 0.35f;      // a key let go (pedal up) damps its fork
constexpr float kOrganReleaseT60 = 0.2f;
constexpr float kDriftCents = 8.f;
constexpr float kDriftTau = 3.f, kDriftLowpass = 0.2f;

inline float midiHz(float m) { return 440.f * std::exp2((m - 69.f) / 12.f); }

} // namespace

HazeBells::HazeBells(double sampleRate) : sr(sampleRate), rng(0x4A2EBE11ULL), reverb(sampleRate, kSub) {
    limiter.init(sr);
    fine.init(sr); bells.init(sr); organ.init(sr); echo.init(sr); crush.init(sr); drift.init(sr); space.init(sr); wet.init(sr);
    fine.snap(0); bells.snap(0.80f); organ.snap(0.25f); echo.snap(0.35f); crush.snap(0.15f); drift.snap(0.30f);
    space.snap(0.50f); wet.snap(0);
    chorusLen = (int)(0.02 * sr) + 8;
    for (auto &b : chorusBuf) b.assign((size_t)chorusLen, 0.f);
    crusher.prepare(sr);
    echoes.prepare(sr, kEchoSeconds);
}

void HazeBells::setParam(int address, float value, bool snap) {
    auto set = [&](Smoothed &s) { if (snap) s.snap(value); else s.setTarget(value); };
    switch (address) {
    case ISD_P_FINE_TUNE: set(fine); break;
    case ISD_P_TRANSPOSE: pTranspose = value; break;
    case ISD_P_SPACE: set(space); break;
    case ISD_P_BELLS: set(bells); break;
    case ISD_P_ORGAN: set(organ); break;
    case ISD_P_ECHO: set(echo); break;
    case ISD_P_CRUSH: set(crush); break;
    case ISD_P_DRIFT: set(drift); break;
    case ISD_P_MOOD_ENERGY: mEnergy = value; break;
    case ISD_P_MOOD_WARMTH: mWarmth = value; break;
    case ISD_P_MOOD_BRIGHTNESS: mBright = value; break;
    case ISD_P_MOOD_SPACE: mSpace = value; break;
    case ISD_P_MOOD_MOTION: mMotion = value; break;
    default: break;
    }
}

int HazeBells::activeVoices() const {
    int n = 0;
    for (const auto &v : voices) if (v.active) ++n;
    return n;
}

float HazeBells::level(const Voice &v) {
    float bell = 0;
    for (int k = 0; k < kModes; ++k) if (v.modeOn[k]) bell += v.amp[k] * std::sqrt(v.mc[k] * v.mc[k] + v.ms[k] * v.ms[k]);
    return std::max(bell * v.bellLevel, v.oEnv);
}

HazeBells::Voice &HazeBells::allocate() {
    int sounding = 0;
    Voice *victim = nullptr;
    for (auto &v : voices) {
        if (!v.active || v.fading) continue;
        ++sounding;
        // Released voices go first (quietest first); otherwise the oldest held note.
        if (!victim) { victim = &v; continue; }
        if (v.releasing != victim->releasing) { if (v.releasing) victim = &v; continue; }
        if (v.releasing ? level(v) < level(*victim) : v.age < victim->age) victim = &v;
    }
    if (sounding >= kPolyphony && victim) beginFade(*victim);
    for (auto &v : voices) if (!v.active) return v;
    Voice *best = nullptr;
    for (auto &v : voices) if (v.fading && (!best || v.fadeGain < best->fadeGain)) best = &v;
    if (!best) best = &voices[0];
    best->active = false;
    return *best;
}

void HazeBells::beginFade(Voice &v) {
    if (v.fading) return;
    v.fading = true;
    v.fadeStep = 1.f / (0.02f * (float)sr);
}

void HazeBells::release(Voice &v) {
    v.releasing = true;
    v.oAttPos = v.oAttLen;
}

void HazeBells::startVoice(Voice &v, int note, int velocity) {
    const float fsr = (float)sr;
    v = Voice{};
    v.active = true;
    v.keyDown = true;
    v.note = note;
    v.age = ++noteCounter;
    v.pitch = std::clamp((float)note + pTranspose, 0.f, 127.f);
    v.vel = (float)velocity / 127.f;
    v.gain = std::pow(0.25f + 0.75f * v.vel, 1.5f);
    // Harder hands (and more energy) strike harder: a brighter clang and thump.
    v.hard = clamp01(v.vel * (0.75f + 0.5f * mEnergy));
    const float f0 = midiHz(v.pitch);
    const float ring = std::clamp(7.f * std::pow(261.63f / f0, 0.6f), 1.5f, 10.f);
    v.ratio[0] = 1.f; v.amp[0] = 1.f; v.t60[0] = ring;
    v.ratio[1] = 2.f; v.amp[1] = 0.18f * (0.5f + 0.5f * v.hard); v.t60[1] = 0.6f * ring;
    const float soften = 1.3f - 0.6f * mWarmth;
    v.ratio[2] = kClangRatio; v.amp[2] = (0.2f + 1.2f * v.hard * v.hard) * soften; v.t60[2] = kClangT60;
    v.ratio[3] = kTinkRatio; v.amp[3] = 0.25f * v.hard * v.hard * soften; v.t60[3] = kTinkT60;
    for (int k = 0; k < kModes; ++k) { v.mc[k] = 1.f; v.ms[k] = 0.f; v.modeOn[k] = f0 * v.ratio[k] < 0.45f * fsr; }
    v.thump = 0.3f * v.hard;
    // Organ
    v.oAttLen = std::max(1, (int)(0.03f * fsr));
    v.click = organNow > 0.5f ? 0.25f * (organNow - 0.5f) * 2.f : 0.f;
    v.vibPh = rng.uniform();
    v.vibRate = 5.6f + 0.8f * rng.uniform();
    v.breathBP.setBandpass(std::min(3.f * f0, 0.4f * fsr), 2.0, sr);
    const float pan = 0.5f * std::clamp((v.pitch - 66.f) / 30.f, -1.f, 1.f);
    const float th = (pan + 1.f) * kPi / 4.f;
    v.panL = std::cos(th); v.panR = std::sin(th);
    idle = false;
}

void HazeBells::noteOn(int note, int velocity) {
    if (velocity <= 0) { noteOff(note); return; }
    startVoice(allocate(), note, velocity);
}

void HazeBells::noteOff(int note) {
    for (auto &v : voices)
        if (v.active && !v.fading && v.note == note && v.keyDown) { v.keyDown = false; if (!sustain) release(v); }
}

void HazeBells::setSustain(bool down) {
    if (down == sustain) return;
    sustain = down;
    if (!down)
        for (auto &v : voices) if (v.active && !v.fading && !v.keyDown && !v.releasing) release(v);
}

void HazeBells::allNotesOff() {
    for (auto &v : voices) if (v.active) beginFade(v);
}

void HazeBells::allSoundOff() {
    allNotesOff();
    reverb.clear();
    echoes.clear();
    crusher.clear();
    for (auto &b : chorusBuf) std::fill(b.begin(), b.end(), 0.f);
}

void HazeBells::render(float *left, float *right, int frames) {
    int pos = 0;
    while (pos < frames) {
        int n = std::min(kSub, frames - pos);
        processBlock(left + pos, right + pos, n);
        pos += n;
    }
}

void HazeBells::renderVoice(Voice &v, float *outL, float *outR, float *orgL, float *orgR, int n) {
    const float fsr = (float)sr, dtb = (float)n / fsr;
    const float cents = fine.value + driftCents;
    const float f0 = midiHz(v.pitch) * std::exp2(cents / 1200.f);
    // Fork modes for this block: rotation × decay.
    float cr[kModes], ci[kModes];
    for (int k = 0; k < kModes; ++k) {
        const float w = kTwoPi * std::min(f0 * v.ratio[k], 0.45f * fsr) / fsr;
        const float r = std::pow(10.f, -3.f / (v.t60[k] * fsr));
        cr[k] = r * std::cos(w); ci[k] = r * std::sin(w);
    }
    const float thumpDecay = std::exp(-1.f / (0.004f * fsr)), thumpA = std::exp(-kTwoPi * 2500.f / fsr);
    const float damp = v.releasing ? dampCoef : 1.f;
    const float bellG = kBell * v.gain * bellsNow;
    // Organ: vibrato once per block, the rotator per sample.
    const bool doOrgan = organNow > 1e-4f || v.oEnv > 1e-6f;
    float ocr = 1, oci = 0, dO = 0;
    const float organG = kOrgan * v.gain * organNow;
    if (doOrgan) {
        v.vibPh += v.vibRate * dtb;
        if (v.vibPh >= 1.f) v.vibPh -= 1.f;
        const float vib = (4.f + 8.f * motionNow) * std::sin(kTwoPi * v.vibPh);
        const float w = kTwoPi * std::min(midiHz(v.pitch) * std::exp2((cents + vib) / 1200.f), 0.45f * fsr) / fsr;
        ocr = std::cos(w); oci = std::sin(w);
        const float m = 1.5f - 0.5f * (v.oc * v.oc + v.os * v.os);
        v.oc *= m; v.os *= m;
        if (v.oAttPos < v.oAttLen) {
            const int end = std::min(v.oAttLen, v.oAttPos + n);
            const float target = 0.5f - 0.5f * std::cos(kPi * (float)end / (float)v.oAttLen);
            dO = (target - v.oEnv) / (float)n;
            v.oAttPos = end;
        } else if (!v.releasing) {
            dO = (1.f - v.oEnv) / (float)n;
        }
    }
    const float oRel = v.releasing ? organRelCoef : 1.f;
    const float clickDecay = std::exp(-1.f / (0.0015f * fsr));

    float mc[kModes], ms[kModes];
    for (int k = 0; k < kModes; ++k) { mc[k] = v.mc[k]; ms[k] = v.ms[k]; }
    float bellLevel = v.bellLevel, thump = v.thump, thumpLP = v.thumpLP, fade = v.fadeGain;
    float oc = v.oc, os = v.os, oEnv = v.oEnv, click = v.click;
    for (int t = 0; t < n; ++t) {
        float b = 0;
        for (int k = 0; k < kModes; ++k) {
            if (!v.modeOn[k]) continue;
            const float c = mc[k] * cr[k] - ms[k] * ci[k], s = mc[k] * ci[k] + ms[k] * cr[k];
            mc[k] = c; ms[k] = s;
            b += v.amp[k] * s;
        }
        const float noise = rng.bipolar();
        if (thump > 1e-5f) {
            thumpLP = noise + (thumpLP - noise) * thumpA;
            b += thump * thumpLP;
            thump *= thumpDecay;
        }
        bellLevel *= damp;
        float g = 1.f;
        if (v.fading) { g = fade; fade = std::max(0.f, fade - v.fadeStep); }
        const float bell = b * bellLevel * bellG * g;
        outL[t] += bell * v.panL;
        outR[t] += bell * v.panR;
        if (doOrgan) {
            const float c = oc * ocr - os * oci, s = oc * oci + os * ocr;
            oc = c; os = s;
            oEnv = oEnv * oRel + dO;
            const float c2 = oc * oc;
            float o = oc + 0.5f * (2.f * c2 - 1.f) + 0.25f * oc * (4.f * c2 - 3.f) + 0.04f * v.breathBP.process(noise);
            o *= oEnv;
            if (click > 1e-5f) { o += click * noise; click *= clickDecay; }
            const float out = o * organG * g;
            orgL[t] += out * v.panR;   // the organ sits mirrored against the bells
            orgR[t] += out * v.panL;
        }
    }
    for (int k = 0; k < kModes; ++k) { v.mc[k] = mc[k]; v.ms[k] = ms[k]; }
    v.bellLevel = bellLevel; v.thump = thump; v.thumpLP = thumpLP; v.fadeGain = fade;
    v.oc = oc; v.os = os; v.oEnv = oEnv; v.click = click;
    if (v.fading && fade <= 0.f) v.active = false;
}

void HazeBells::organChorus(float *l, float *r, int n) {
    const float fsr = (float)sr;
    float *io[2] = {l, r};
    for (int t = 0; t < n; ++t) {
        chorusPh += 6.f / fsr;
        if (chorusPh >= 1.f) chorusPh -= 1.f;
        for (int c = 0; c < 2; ++c) {
            float *buf = chorusBuf[c].data();
            buf[chorusW] = io[c][t];
            const float d = (0.007f + 0.0003f * std::sin(kTwoPi * (chorusPh + 0.25f * (float)c))) * fsr;
            const float whole = std::floor(d), frac = d - whole;
            int i0 = chorusW - (int)whole; if (i0 < 0) i0 += chorusLen;
            int i1 = i0 - 1; if (i1 < 0) i1 += chorusLen;
            io[c][t] = 0.85f * io[c][t] + 0.35f * (buf[i0] + frac * (buf[i1] - buf[i0]));
        }
        if (++chorusW == chorusLen) chorusW = 0;
    }
}

void HazeBells::housekeeping() {
    for (auto &v : voices) {
        if (!v.active || v.fading) continue;
        const bool organHeld = !v.releasing && organNow > 1e-4f;
        if (!organHeld && level(v) < 1e-5f) v.active = false;
    }
}

void HazeBells::processBlock(float *left, float *right, int n) {
    const float fsr = (float)sr, dtb = (float)n / fsr;
    for (int t = 0; t < n; ++t) { fine.next(); bells.next(); organ.next(); echo.next(); crush.next(); drift.next(); space.next(); }
    bellsNow = clamp01(bells.value);
    organNow = clamp01(organ.value);
    motionNow = clamp01(0.5f + 0.6f * (mMotion - 0.5f));
    dampCoef = std::pow(10.f, -3.f / (kDamperT60 * fsr));
    organRelCoef = std::pow(10.f, -3.f / (kOrganReleaseT60 * fsr));
    // A slow shared wander, like a warped record.
    {
        const float a = dtb / kDriftTau, kick = std::sqrt(2.f * a) * 0.5f;
        const float lp = 1.f - std::exp(-kTwoPi * kDriftLowpass * dtb);
        driftWalk += -driftWalk * a + kick * (rng.bipolar() + rng.bipolar() + rng.bipolar());
        driftLP += (driftWalk - driftLP) * lp;
        const float d = clamp01(drift.value + 0.4f * (mMotion - 0.5f));
        driftCents = kDriftCents * d * softSat(driftLP);
    }
    crusher.set(crush.value);
    echoes.set(echo.value, clamp01(0.5f + 0.8f * (mBright - 0.5f)));
    const float sv = clamp01(space.value + 0.6f * (mSpace - 0.5f));
    if (std::fabs(sv - appliedSpace) > 2e-3f) {
        appliedSpace = sv;
        reverb.configure(0.5f + 0.45f * sv, 0.55f, 18.f, 0.f);
        wet.setTarget(sv > 0.f ? kWetMax * std::pow(sv, 0.77f) : 0.f);
    }

    float dryL[kSub] = {}, dryR[kSub] = {};
    if (!idle) {
        float orgL[kSub] = {}, orgR[kSub] = {};
        bool anyVoice = false;
        for (auto &v : voices) {
            if (!v.active) continue;
            anyVoice = true;
            renderVoice(v, dryL, dryR, orgL, orgR, n);
        }
        organChorus(orgL, orgR, n);
        float peakAbs = 0;
        for (int t = 0; t < n; ++t) {
            float l = softSat(1.4f * (dryL[t] + orgL[t])) / 1.4f, r = softSat(1.4f * (dryR[t] + orgR[t])) / 1.4f;
            crusher.process(l, r);
            echoes.process(l, r);
            dryL[t] = l; dryR[t] = r;
            peakAbs = std::max(peakAbs, std::max(std::fabs(l), std::fabs(r)));
        }
        if (!anyVoice && peakAbs < 1e-6f) {
            idleSamples += n;
            if (idleSamples >= (int)(0.25f * fsr)) {
                idle = true;
                idleSamples = 0;
                echoes.clear();
                crusher.clear();
                for (auto &b : chorusBuf) std::fill(b.begin(), b.end(), 0.f);
            }
        } else {
            idleSamples = 0;
        }
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
        const float w = wet.next();
        float l = kMaster * (dryL[t] + w * revL[t]), r = kMaster * (dryR[t] + w * revR[t]);
        limiter.process(l, r);
        left[t] = softLimit(l);
        right[t] = softLimit(r);
    }
    if (++blockCount % 4 == 0) housekeeping();
}

} // namespace isd
