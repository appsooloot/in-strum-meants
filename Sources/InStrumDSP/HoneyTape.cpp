#include "HoneyTape.hpp"
#include "include/InStrumDSP.h"
#include <algorithm>

namespace isd {

namespace {

// Level and tone calibration (see docs/superpowers/briefs/honey-tape.md).
constexpr float kFlute = 0.30f;          // flute tone per voice (fundamental peak)
constexpr float kSaw = 0.16f;            // each of the four string saws
constexpr float kMaster = 0.31f;       // sits level with Felt Glass and Orbit Pad
constexpr float kWetMax = 0.50f;         // reverb return at full Space
constexpr float kFluteReleaseT60 = 0.35f;
constexpr float kStringsReleaseT60 = 0.8f;
constexpr float kVibratoCents = 16.f;    // at neutral motion
constexpr float kWowCents = 12.f, kFlutterCents = 3.f;   // at Wow 1
constexpr float kReelLongest = 20.f, kReelShortest = 8.f, kReelFade = 0.4f;
constexpr float kWalkTau = 2.f, kWalkLowpass = 0.25f, kWalkCents = 1.5f;

const float kSawPos[HoneyTape::kSaws] = {-1.f, -1.f / 3.f, 1.f / 3.f, 1.f};

inline float midiHz(float m) { return 440.f * std::exp2((m - 69.f) / 12.f); }
inline float smoothstep(float x) { x = clamp01(x); return x * x * (3.f - 2.f * x); }

} // namespace

HoneyTape::HoneyTape(double sampleRate) : sr(sampleRate), rng(0x40E7A9EULL), reverb(sampleRate, kSub) {
    limiter.init(sr);
    fine.init(sr); breath.init(sr); strings.init(sr); age.init(sr); reel.init(sr); space.init(sr); width.init(sr); wet.init(sr);
    wow.init(sr, 300.0);   // the tape's sway changes depth slowly, never in a lurch
    fine.snap(0); breath.snap(0.45f); strings.snap(0.30f); wow.snap(0.35f); age.snap(0.40f); reel.snap(0);
    space.snap(0.50f); width.snap(0.50f); wet.snap(0);
    tapeDelay.prepare(sr);
    tapeColour.prepare(sr);
}

void HoneyTape::setParam(int address, float value, bool snap) {
    auto set = [&](Smoothed &s) { if (snap) s.snap(value); else s.setTarget(value); };
    switch (address) {
    case ISD_P_FINE_TUNE: set(fine); break;
    case ISD_P_TRANSPOSE: pTranspose = value; break;
    case ISD_P_SPACE: set(space); break;
    case ISD_P_WIDTH: set(width); break;
    case ISD_P_BREATH: set(breath); break;
    case ISD_P_STRINGS: set(strings); break;
    case ISD_P_WOW: set(wow); break;
    case ISD_P_AGE: set(age); break;
    case ISD_P_REEL: set(reel); break;
    case ISD_P_MOOD_ENERGY: mEnergy = value; break;
    case ISD_P_MOOD_WARMTH: mWarmth = value; break;
    case ISD_P_MOOD_BRIGHTNESS: mBright = value; break;
    case ISD_P_MOOD_SPACE: mSpace = value; break;
    case ISD_P_MOOD_MOTION: mMotion = value; break;
    case ISD_P_DEBUG_NO_VIBRATO: debugNoVibrato = value >= 0.5f; break;
    default: break;
    }
}

int HoneyTape::activeVoices() const {
    int n = 0;
    for (const auto &v : voices) if (v.active) ++n;
    return n;
}

HoneyTape::Voice &HoneyTape::allocate() {
    int sounding = 0;
    Voice *victim = nullptr;
    for (auto &v : voices) {
        if (!v.active || v.fading) continue;
        ++sounding;
        // Released voices go first (quietest first); otherwise the oldest held note.
        if (!victim) { victim = &v; continue; }
        if (v.releasing != victim->releasing) { if (v.releasing) victim = &v; continue; }
        const float a = std::max(v.fEnv, v.sEnv), b = std::max(victim->fEnv, victim->sEnv);
        if (v.releasing ? a < b : v.age < victim->age) victim = &v;
    }
    if (sounding >= kPolyphony && victim) beginFade(*victim);
    for (auto &v : voices) if (!v.active) return v;
    Voice *best = nullptr;
    for (auto &v : voices) if (v.fading && (!best || v.fadeGain < best->fadeGain)) best = &v;
    if (!best) best = &voices[0];
    best->active = false;
    return *best;
}

void HoneyTape::beginFade(Voice &v) {
    if (v.fading) return;
    v.fading = true;
    v.fadeStep = 1.f / (0.02f * (float)sr);
}

void HoneyTape::release(Voice &v) {
    v.releasing = true;
    v.fAttPos = v.fAttLen;
    v.sAttPos = v.sAttLen;
}

void HoneyTape::startVoice(Voice &v, int note, int velocity) {
    const float fsr = (float)sr;
    v = Voice{};
    v.active = true;
    v.keyDown = true;
    v.note = note;
    v.age = ++noteCounter;
    v.pitch = std::clamp((float)note + pTranspose, 0.f, 127.f);
    v.vel = (float)velocity / 127.f;
    v.gain = std::pow(0.3f + 0.7f * v.vel, 1.4f);
    const float f0 = midiHz(v.pitch);
    // A harder breath brings out the overtones; Breath adds a little more of the second.
    v.a2 = 0.02f + 0.55f * v.vel + 0.05f * breathNow;
    v.a3 = 0.005f + 0.32f * v.vel;
    v.a4 = 0.14f * v.vel;
    v.breath1.setBandpass(std::min(f0, 0.4f * fsr), 3.0, sr);
    v.breath2.setBandpass(std::min(2.f * f0, 0.4f * fsr), 3.0, sr);
    v.chiffBP.setBandpass(std::min(2.7f * f0, 7000.f), 1.4, sr);
    v.hissBP.setBandpass(std::min(3.f * f0 + 2500.f, 0.4f * fsr), 0.8, sr);
    v.hissLevel = 0.12f * (0.3f + 0.7f * v.vel);   // harder blowing, more turbulence
    v.chiff = 0.10f + 0.30f * v.vel;
    v.chiffDecay = std::exp(-1.f / (0.018f * fsr));
    v.vibPh = rng.uniform();
    v.vibRate = 4.8f + 0.6f * rng.uniform();
    v.fAttLen = std::max(1, (int)((0.12f - 0.06f * v.vel) * attackScale * fsr));
    v.sAttLen = std::max(1, (int)((0.8f - 0.5f * v.vel) * attackScale * fsr));
    for (int k = 0; k < kSaws; ++k) {
        v.ph[k] = rng.uniform();
        v.walk[k] = 0.3f * rng.bipolar();
        v.walkLP[k] = v.walk[k];
    }
    const float pan = widthNow * 0.6f * std::clamp((v.pitch - 64.f) / 30.f, -1.f, 1.f);
    const float th = (pan + 1.f) * kPi / 4.f;
    v.panL = std::cos(th); v.panR = std::sin(th);
    idle = false;
}

void HoneyTape::noteOn(int note, int velocity) {
    if (velocity <= 0) { noteOff(note); return; }
    startVoice(allocate(), note, velocity);
}

void HoneyTape::noteOff(int note) {
    for (auto &v : voices)
        if (v.active && !v.fading && v.note == note && v.keyDown) { v.keyDown = false; if (!sustain) release(v); }
}

void HoneyTape::setSustain(bool down) {
    if (down == sustain) return;
    sustain = down;
    if (!down)
        for (auto &v : voices) if (v.active && !v.fading && !v.keyDown && !v.releasing) release(v);
}

void HoneyTape::allNotesOff() {
    for (auto &v : voices) if (v.active) beginFade(v);
}

void HoneyTape::allSoundOff() {
    allNotesOff();
    reverb.clear();
    tapeDelay.clear();
    tapeColour.clear();
}

void HoneyTape::render(float *left, float *right, int frames) {
    int pos = 0;
    while (pos < frames) {
        int n = std::min(kSub, frames - pos);
        processBlock(left + pos, right + pos, n);
        pos += n;
    }
}

void HoneyTape::renderVoice(Voice &v, float *outL, float *outR, int n) {
    const float fsr = (float)sr, dtb = (float)n / fsr, t0 = (float)v.life / fsr;
    // Pitch for this block: fine tune, the tape strip engaging (a tiny wobble in the first 80 ms) and vibrato.
    float cents = fine.value;
    const float x = t0 / 0.08f;
    if (x < 1.f) cents += (3.f + 3.f * wowNow) * (1.f - x) * (1.f - x) * std::sin(kTwoPi * 1.5f * x);
    const float stringsCents = cents;
    float ampVib = 1.f;
    if (!debugNoVibrato) {
        const float grow = smoothstep((t0 - 0.25f) / (0.6f + 0.4f * (1.f - motionNow)));
        v.vibPh += v.vibRate * dtb;
        if (v.vibPh >= 1.f) v.vibPh -= 1.f;
        const float vib = std::sin(kTwoPi * v.vibPh);
        cents += grow * kVibratoCents * (0.7f + 0.6f * motionNow) * vib;
        ampVib = 1.f + 0.04f * grow * vib;
    }
    const float base = midiHz(v.pitch);
    const float f = std::min(base * std::exp2(cents / 1200.f), 0.45f * fsr);
    const float w = kTwoPi * f / fsr, cw = std::cos(w), sw = std::sin(w);
    {   // keep the rotator on the unit circle
        const float m = 1.5f - 0.5f * (v.c * v.c + v.s * v.s);
        v.c *= m; v.s *= m;
    }
    // Envelopes: raised-cosine attacks, exponential releases.
    auto attack = [n](int &pos, int len, float env, bool releasing) {
        if (pos < len) {
            const int end = std::min(len, pos + n);
            const float target = 0.5f - 0.5f * std::cos(kPi * (float)end / (float)len);
            pos = end;
            return (target - env) / (float)n;
        }
        return releasing ? 0.f : (1.f - env) / (float)n;
    };
    const float dF = attack(v.fAttPos, v.fAttLen, v.fEnv, v.releasing);
    const float dS = attack(v.sAttPos, v.sAttLen, v.sEnv, v.releasing);
    const float relF = v.releasing ? fRelCoef : 1.f, relS = v.releasing ? sRelCoef : 1.f;

    // Strings: four saws spread across the unison, each on its own slow random walk.
    const bool doFlute = fluteMix > 1e-4f, doStrings = stringsMix > 1e-4f;
    float inc[kSaws] = {};
    if (doStrings) {
        const float a = dtb / kWalkTau, kick = std::sqrt(2.f * a) * 0.5f;
        const float lp = 1.f - std::exp(-kTwoPi * kWalkLowpass * dtb);
        float mean = 0;
        for (int k = 0; k < kSaws; ++k) {
            const float gauss = rng.bipolar() + rng.bipolar() + rng.bipolar();
            v.walk[k] += -v.walk[k] * a + kick * gauss;
            v.walkLP[k] += (v.walk[k] - v.walkLP[k]) * lp;
            mean += softSat(v.walkLP[k]) / (float)kSaws;
        }
        for (int k = 0; k < kSaws; ++k) {
            // Each player wanders, but the section's centre stays in tune.
            const float c = stringsCents + kSawPos[k] * spreadCents + kWalkCents * (0.5f + motionNow) * (softSat(v.walkLP[k]) - mean);
            inc[k] = std::min(0.24f, base * std::exp2(c / 1200.f) / fsr);
        }
        float fc = (450.f + 1200.f * brightNow) * (1.f + 3.5f * v.vel * brightNow) * std::sqrt(base / 261.63f);
        fc = std::clamp(fc, 60.f, std::min(12000.f, 0.45f * fsr));
        v.filt[0].set(fc, 0.6f, fsr);
        v.filt[1].set(fc, 0.6f, fsr);
    }
    // The reel: a held note runs out at the end of its strip.
    if (reelSamples > 0.f && !v.reelFading && (float)v.life >= reelSamples) {
        v.reelFading = true;
        v.reelStep = 1.f / (kReelFade * fsr);
    }

    const float breathGain = 0.02f + 2.5f * breathNow;
    const float fg = fluteMix * kFlute * v.gain, sg = stringsMix * kSaw * v.gain;
    const float side = 0.5f * widthNow;
    float c = v.c, s = v.s, fEnv = v.fEnv, sEnv = v.sEnv, fade = v.fadeGain, reelG = v.reelGain;
    for (int t = 0; t < n; ++t) {
        const float nc = c * cw - s * sw, ns = c * sw + s * cw;
        c = nc; s = ns;
        fEnv = fEnv * relF + dF;
        sEnv = sEnv * relS + dS;
        float l = 0, r = 0;
        const float noise = rng.bipolar();
        if (doFlute) {
            const float c2 = c * c;
            const float tone = c + v.a2 * (2.f * c2 - 1.f) + v.a3 * c * (4.f * c2 - 3.f) + v.a4 * (8.f * c2 * c2 - 8.f * c2 + 1.f);
            const float air = 0.6f * v.breath1.process(noise) + 0.4f * v.breath2.process(noise) + v.hissLevel * v.hissBP.process(noise);
            float flute = (tone * ampVib + breathGain * air) * fEnv;
            if (v.chiff > 1e-4f) { flute += v.chiff * v.chiffBP.process(noise); v.chiff *= v.chiffDecay; }
            l += fg * flute * v.panL;
            r += fg * flute * v.panR;
        }
        if (doStrings) {
            float sl = 0, sr2 = 0;
            for (int k = 0; k < kSaws; ++k) {
                const float y = blepSaw((float)v.ph[k], inc[k]);
                v.ph[k] += inc[k]; if (v.ph[k] >= 1.0) v.ph[k] -= 1.0;
                // Each side gets a pair placed symmetrically about the note (outer pair left, inner pair right),
                // so either channel alone is centred in tune.
                if (k == 0 || k == 3) sl += y; else sr2 += y;
            }
            const float mid = 0.5f * (sl + sr2), sd = side * (sl - sr2);
            l += sg * sEnv * v.filt[0].lowpass(mid + sd);
            r += sg * sEnv * v.filt[1].lowpass(mid - sd);
        }
        float g = 1.f;
        if (v.reelFading) { g *= reelG; reelG = std::max(0.f, reelG - v.reelStep); }
        if (v.fading) { g *= fade; fade = std::max(0.f, fade - v.fadeStep); }
        outL[t] += l * g;
        outR[t] += r * g;
    }
    v.c = c; v.s = s; v.fEnv = fEnv; v.sEnv = sEnv; v.fadeGain = fade; v.reelGain = reelG;
    v.life += n;
    if ((v.fading && fade <= 0.f) || (v.reelFading && reelG <= 0.f)) v.active = false;
}

void HoneyTape::housekeeping() {
    for (auto &v : voices)
        if (v.active && v.releasing && !v.fading && v.fEnv < 1e-5f && v.sEnv < 1e-5f) v.active = false;
}

void HoneyTape::processBlock(float *left, float *right, int n) {
    const float fsr = (float)sr;
    for (int t = 0; t < n; ++t) {
        fine.next(); breath.next(); strings.next(); wow.next(); age.next(); reel.next(); space.next(); width.next();
    }
    // Dials with the mood underneath them.
    breathNow = clamp01(breath.value);
    const float b = clamp01(strings.value);
    fluteMix = std::cos(0.5f * kPi * b);
    stringsMix = std::sin(0.5f * kPi * b);
    motionNow = clamp01(0.5f + 0.6f * (mMotion - 0.5f));
    brightNow = clamp01(0.5f + 0.6f * (mBright - 0.5f));
    wowNow = clamp01(wow.value);
    widthNow = clamp01(width.value);
    attackScale = 1.f - 0.6f * (mEnergy - 0.5f);
    fRelCoef = std::pow(10.f, -3.f / (kFluteReleaseT60 * fsr));
    sRelCoef = std::pow(10.f, -3.f / (kStringsReleaseT60 * fsr));
    spreadCents = 6.f + 4.f * motionNow;
    const float r = clamp01(reel.value);
    reelSamples = r > 0.001f ? (kReelLongest - (kReelLongest - kReelShortest) * r) * fsr : -1.f;
    tapeDelay.setDepth(kWowCents * wowNow, kFlutterCents * wowNow);
    tapeColour.setAge(clamp01(age.value));
    if (std::fabs(mWarmth - appliedWarmth) > 1e-3f) {
        appliedWarmth = mWarmth;
        for (auto &shelf : warmShelf) shelf.setHighShelf(3000.0, -6.0 * (mWarmth - 0.5), sr);
    }
    const float sv = clamp01(space.value + 0.6f * (mSpace - 0.5f));
    if (std::fabs(sv - appliedSpace) > 2e-3f) {
        appliedSpace = sv;
        reverb.configure(0.45f + 0.45f * sv, 0.6f, 12.f, 0.f);
        wet.setTarget(sv > 0.f ? kWetMax * std::pow(sv, 0.77f) : 0.f);
    }

    float dryL[kSub] = {}, dryR[kSub] = {};
    if (!idle) {
        bool anyVoice = false;
        for (auto &v : voices) {
            if (!v.active) continue;
            anyVoice = true;
            renderVoice(v, dryL, dryR, n);
        }
        float peakAbs = 0;
        for (int t = 0; t < n; ++t) {
            float l = dryL[t], rr = dryR[t];
            tapeDelay.process(l, rr);
            tapeColour.process(l, rr);
            dryL[t] = warmShelf[0].process(l);
            dryR[t] = warmShelf[1].process(rr);
            peakAbs = std::max(peakAbs, std::max(std::fabs(dryL[t]), std::fabs(dryR[t])));
        }
        if (!anyVoice && peakAbs < 1e-6f) {
            idleSamples += n;
            if (idleSamples >= (int)(0.25f * fsr)) {
                idle = true;
                idleSamples = 0;
                tapeDelay.clear();
                tapeColour.clear();
                for (auto &shelf : warmShelf) shelf.clear();
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
        float l = kMaster * (dryL[t] + w * revL[t]), rr = kMaster * (dryR[t] + w * revR[t]);
        limiter.process(l, rr);
        left[t] = softLimit(l);
        right[t] = softLimit(rr);
    }
    if (++blockCount % 4 == 0) housekeeping();
}

} // namespace isd
