#include "ZenShakuhachi.hpp"
#include "include/InStrumDSP.h"
#include <algorithm>

namespace isd {

namespace {

// Level and tone calibration (see docs/superpowers/briefs/zen-shakuhachi.md).
constexpr float kTone = 0.5f;            // the core's tone into the mix
constexpr float kAirRef = 1.88f;         // the core's air at full breath × this matches its tone at full breath
constexpr float kMuraiki = 2.53f;        // the burst over the breath: +9 dB, less the 2–6 kHz band's extra noise
constexpr float kClick = 0.32f;          // the key-click at full Bamboo, × the tone
constexpr float kMaster = 0.22f;         // sits level with Felt Glass
constexpr float kWetMax = 0.42f;         // reverb return at full Space
constexpr float kMeriCents = 150.f;      // full pressure at Bend 1
constexpr float kKariCents = 100.f;      // the wheel's first semitone up
constexpr float kMeriDarkest = 1800.f / 5000.f;   // the open end's low-pass at full meri, × its rest
constexpr float kYuriStart = 0.4f, kYuriFade = 0.2f;
constexpr float kEchoNear = 0.42f, kEchoFar = 0.78f;   // the mountain echo's two slopes (s)
constexpr float kWallMs[3] = {7.3f, 11.9f, 17.6f};     // the low wall's reflections
constexpr float kWallGain[3] = {0.32f, 0.24f, 0.17f};
constexpr float kWallPan[3] = {0.7f, -0.6f, 0.3f};
constexpr float kMuraikiRise = 0.015f, kMuraikiLength = 0.12f, kClickSeconds = 0.003f;

inline float midiHz(float m) { return 440.f * std::exp2((m - 69.f) / 12.f); }
inline float smoothstep(float x) { x = clamp01(x); return x * x * (3.f - 2.f * x); }
inline void panGains(float pan, float &l, float &r) { const float th = (std::clamp(pan, -1.f, 1.f) + 1.f) * kPi / 4.f; l = std::cos(th); r = std::sin(th); }

} // namespace

ZenShakuhachi::ZenShakuhachi(double sampleRate) : sr(sampleRate), rng(0x5A4C0BA3B00ULL), reverb(sampleRate, kSub) {
    // The bamboo's jet: an offset jet (a strong second harmonic), a swing that clips a little at full breath, a
    // breath that must pass a quarter of its range before the bore speaks (pullCents measured on this shape).
    shape.jetQLocked = 10.f; shape.jetQLoose = 3.f; shape.jetOffset = 0.6f; shape.swing = 0.95f;
    shape.threshold = 0.25f; shape.toneCurve = 1.5f; shape.airHz = 2000.f; shape.airQ = 0.667f;
    shape.turbulence = 0.12f; shape.minGain = 0.5f; shape.maxGain = 2.5f; shape.pullCents = 1.2f;
    limiter.init(sr);
    fine.init(sr); breath.init(sr); air.init(sr); bend.init(sr); bamboo.init(sr); yuri.init(sr); echo.init(sr);
    space.init(sr); width.init(sr); wet.init(sr); echoNear.init(sr); echoFar.init(sr); wall.init(sr);
    fine.snap(0); breath.snap(0.45f); air.snap(0.55f); bend.snap(0.60f); bamboo.snap(0.50f); yuri.snap(0.40f); echo.snap(0.30f);
    space.snap(0.40f); width.snap(0.45f); wet.snap(0); echoNear.snap(0); echoFar.snap(0); wall.snap(0);
    // The lowest pitch a bore is asked for: MIDI 36 (the no-fold test hook) under the wheel, full meri, yuri and fine tune.
    const float lowest = midiHz(36.f) * std::exp2(-(200.f + kMeriCents + 30.f + 50.f) / 1200.f);
    for (auto &v : voices) v.wind.prepare(sr, lowest, shape);
    echoBuf.assign((size_t)(1.0 * sr) + 8, 0.f);
    wallBuf.assign((size_t)(0.032 * sr) + 8, 0.f);
    echoNearD = (int)(kEchoNear * sr);
    echoFarD = (int)(kEchoFar * sr);
    for (int k = 0; k < 3; ++k) wallD[k] = std::max(1, (int)(kWallMs[k] * 0.001 * sr));
    echoLPA = (float)std::exp(-2.0 * M_PI * 2800.0 / sr);
}

void ZenShakuhachi::setParam(int address, float value, bool snap) {
    auto set = [&](Smoothed &s) { if (snap) s.snap(value); else s.setTarget(value); };
    switch (address) {
    case ISD_P_FINE_TUNE: set(fine); break;
    case ISD_P_TRANSPOSE: pTranspose = value; break;
    case ISD_P_BREATH: set(breath); break;
    case ISD_P_AIR: set(air); break;
    case ISD_P_BEND: set(bend); break;
    case ISD_P_BAMBOO: set(bamboo); break;
    case ISD_P_YURI: set(yuri); break;
    case ISD_P_ECHO: set(echo); break;
    case ISD_P_SPACE: set(space); break;
    case ISD_P_WIDTH: set(width); break;
    case ISD_P_MOOD_ENERGY: mEnergy = value; break;
    case ISD_P_MOOD_WARMTH: mWarmth = value; break;
    case ISD_P_MOOD_BRIGHTNESS: mBright = value; break;
    case ISD_P_MOOD_SPACE: mSpace = value; break;
    case ISD_P_MOOD_MOTION: mMotion = value; break;
    case ISD_P_DEBUG_TONE_ONLY: toneOnly = value >= 0.5f; break;
    case ISD_P_DEBUG_NO_FOLD: noFold = value >= 0.5f; break;
    default: break;
    }
}

int ZenShakuhachi::activeVoices() const {
    int n = 0;
    for (const auto &v : voices) if (v.active) ++n;
    return n;
}

float ZenShakuhachi::level(const Voice &v) { return std::max(v.breath, v.wind.swing()); }

ZenShakuhachi::Voice &ZenShakuhachi::allocate() {
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

void ZenShakuhachi::beginFade(Voice &v) {
    if (v.fading) return;
    v.fading = true;
    v.fadeStep = 1.f / (0.02f * (float)sr);
}

void ZenShakuhachi::release(Voice &v) {
    if (v.releasing) return;
    v.releasing = true;
    // The tone is gone 150–400 ms after the key (the Air dial; energy quickens it): the breath falls to the
    // threshold by then. The air lingers on below it for 0.35–0.85 s.
    const float pace = 1.f - 0.5f * (clamp01(mEnergy) - 0.5f), a = clamp01(air.value);
    const float toneGone = (0.15f + 0.25f * a) * pace;
    const float from = std::max(v.breath, shape.threshold * 1.05f);
    const float t60 = std::max(0.05f, 3.f * toneGone / std::log10(from / shape.threshold));
    v.relCoef = std::pow(10.f, -3.f / (t60 * (float)sr));
    v.airRelCoef = std::pow(10.f, -3.f / ((0.35f + 0.5f * a) * pace * (float)sr));
}

void ZenShakuhachi::startVoice(Voice &v, int note, int velocity) {
    const float fsr = (float)sr;
    v.active = true; v.keyDown = true; v.releasing = false; v.fading = false;
    v.note = note;
    v.age = ++noteCounter;
    v.life = 0;
    float p = (float)note + pTranspose;
    if (!noFold) {
        while (p < (float)kLowest) p += 12.f;
        while (p > (float)kHighest) p -= 12.f;
    }
    v.pitch = std::clamp(p, 0.f, 127.f);
    v.vel = (float)velocity / 127.f;
    v.peak = 0.15f + 0.85f * std::pow(v.vel, 0.9f);
    v.breath = 0; v.relCoef = v.airRelCoef = 1;
    const float pace = 1.f - 0.5f * (clamp01(mEnergy) - 0.5f);
    v.attackLen = std::max(1, (int)((0.06f + 0.29f * clamp01(air.value)) * pace * fsr));
    v.attackPos = 0;
    v.wander = 0; v.wanderLP = 0;
    v.wind.start(rng.next());
    // A new note hears the wheel and channel pressure as they are now (both at rest after a switch).
    v.poly = 0; v.wheelNow = wheel; v.meriNow = chanPressure;
    v.yuriPh = 0; v.yuriRate = 3.2f + 1.6f * rng.uniform();
    v.depthFrom = 8.f + 12.f * rng.uniform(); v.depthTo = 8.f + 12.f * rng.uniform();
    // Muraiki: a hard note bursts with breath. (From the dials themselves: a note can arrive before the first block.)
    const int murThreshold = 112 - (int)std::lround(24.f * (clamp01(mEnergy) - 0.5f));
    v.murPos = 0; v.murLen = 0; v.murLevel = 0;
    if (!toneOnly && velocity >= murThreshold) {
        v.murLen = (int)(kMuraikiLength * fsr);
        v.murLevel = 0.7f + 0.3f * (float)(velocity - murThreshold) / (float)std::max(1, 127 - murThreshold);
        v.murBP.setBandpass(3460.0, 0.87, sr);
        v.murBP.clear();
    }
    // The key-click: a finger on the bamboo.
    v.clickPos = 0;
    v.clickLen = toneOnly ? 0 : std::max(1, (int)(kClickSeconds * fsr));
    const float clickW = kTwoPi * std::min(2200.f * (0.9f + 0.2f * rng.uniform()), 0.4f * fsr) / fsr;
    v.clickCr = std::cos(clickW); v.clickCi = std::sin(clickW);
    v.clickC = 1; v.clickS = 0;
    v.clickAmp = kClick * kTone * clamp01(bamboo.value) * (0.4f + 0.6f * v.vel);
    const float spread = 0.3f + 0.4f * clamp01(width.value);
    panGains(spread * 0.8f * std::clamp((v.pitch - 74.f) / 12.f, -1.f, 1.f), v.panL, v.panR);
    v.fadeGain = 1; v.fadeStep = 0;
    idle = false;
}

void ZenShakuhachi::noteOn(int note, int velocity) {
    if (velocity <= 0) { noteOff(note); return; }
    startVoice(allocate(), note, velocity);
}

void ZenShakuhachi::noteOff(int note) {
    for (auto &v : voices)
        if (v.active && !v.fading && v.note == note && v.keyDown) { v.keyDown = false; if (!sustain) release(v); }
}

void ZenShakuhachi::setSustain(bool down) {
    if (down == sustain) return;
    sustain = down;
    if (!down)
        for (auto &v : voices) if (v.active && !v.fading && !v.keyDown && !v.releasing) release(v);
}

void ZenShakuhachi::pitchBend(float semitones) { wheel = std::clamp(semitones, -2.f, 2.f); }

void ZenShakuhachi::aftertouch(int note, float pressure) {
    const float p = clamp01(pressure);
    if (note < 0) { chanPressure = p; return; }
    for (auto &v : voices) if (v.active && !v.fading && v.note == note) v.poly = p;
}

void ZenShakuhachi::allNotesOff() {
    for (auto &v : voices) if (v.active) { beginFade(v); v.poly = 0; }
    wheel = 0;
    chanPressure = 0;
}

void ZenShakuhachi::clearTails() {
    std::fill(echoBuf.begin(), echoBuf.end(), 0.f);
    std::fill(wallBuf.begin(), wallBuf.end(), 0.f);
    echoLP[0] = echoLP[1] = 0;
}

void ZenShakuhachi::allSoundOff() {
    allNotesOff();
    clearTails();
    reverb.clear();
    sendMute = (int)(0.03 * sr);   // the 20 ms fades never reach the echo or the reverb
}

void ZenShakuhachi::render(float *left, float *right, int frames) {
    int pos = 0;
    while (pos < frames) {
        int n = std::min(kSub, frames - pos);
        processBlock(left + pos, right + pos, n);
        pos += n;
    }
}

void ZenShakuhachi::renderVoice(Voice &v, float *outL, float *outR, int n) {
    const float fsr = (float)sr, dtb = (float)n / fsr, t0 = (float)v.life / fsr;
    // The breath: a raised-cosine rise to its plateau, a slow unsteadiness while held, an exponential fall.
    if (v.releasing) {
        v.breath *= std::pow(v.breath > shape.threshold ? v.relCoef : v.airRelCoef, (float)n);
    } else if (v.attackPos < v.attackLen) {
        v.attackPos = std::min(v.attackLen, v.attackPos + n);
        v.breath = v.peak * (0.5f - 0.5f * std::cos(kPi * (float)v.attackPos / (float)v.attackLen));
    } else {
        if (!toneOnly) {
            v.wander += -v.wander * wanderA + std::sqrt(2.f * wanderA) * 0.5f * (rng.bipolar() + rng.bipolar() + rng.bipolar());
            v.wanderLP += (v.wander - v.wanderLP) * wanderA * 4.f;
        }
        v.breath = v.peak * (1.f + 0.015f * std::clamp(v.wanderLP, -1.5f, 1.5f));
    }
    // Touch: the wheel and the pressure glide (the pressure slowly, like a head dropping).
    v.wheelNow += (wheel - v.wheelNow) * wheelA;
    v.meriNow += (std::max(chanPressure, v.poly) - v.meriNow) * meriA;
    const float m = clamp01(v.meriNow) * bendNow;                // meri depth
    const float up = std::clamp(v.wheelNow, 0.f, 1.f);           // kari: the wheel's first semitone up, in pitch
    const float bright = std::clamp(0.5f * v.wheelNow, 0.f, 1.f); // and its whole up half, in brightness
    float cents = fine.value - kMeriCents * m + (v.wheelNow >= 0.f ? kKariCents * up : 100.f * v.wheelNow);
    // Yuri: one cycle at a time, each at its own rate (3.2–4.8 Hz), its depth wandering 8–20 cents.
    float shade = 0;
    if (!toneOnly && yuriNow > 1e-4f) {
        const float grow = smoothstep((t0 - kYuriStart) / kYuriFade);
        if (grow > 0.f) {
            v.yuriPh += v.yuriRate * dtb;
            if (v.yuriPh >= 1.f) {
                v.yuriPh -= 1.f;
                v.yuriRate = 3.2f + 1.6f * rng.uniform();
                v.depthFrom = v.depthTo;
                v.depthTo = 8.f + 12.f * rng.uniform();
            }
            const float depth = v.depthFrom + (v.depthTo - v.depthFrom) * smoothstep(v.yuriPh);
            const float y = yuriNow * grow * depth * std::sin(kTwoPi * v.yuriPh);
            cents += y;
            shade = y / 20.f;   // the head's movement colours the tone a little too
        }
    }
    BreathWind::Control c;
    c.hz = midiHz(v.pitch + cents / 100.f);
    c.breath = v.breath;
    c.reflectionHz = reflBase * std::pow(kMeriDarkest, m) * std::exp2(0.7f * bright + 0.2f * shade);
    c.drive = (1.f - 0.45f * m) * (1.f + 0.3f * bright) * (1.f + 0.05f * shade);
    c.offset = 1.f - 0.5f * m;
    c.radiation = 1.f - 0.7f * m;
    const float mur = v.murPos < v.murLen ? 1.f : 0.f;
    c.turbulence = toneOnly ? 0.f : (0.6f + 0.8f * clamp01(breath.value)) * (1.f + 2.f * mur);
    c.airShift = 1.f - 0.4f * m;
    float tone[kSub] = {}, airBuf[kSub] = {};
    v.wind.render(c, n, tone, airBuf);

    const float tg = kTone * (1.f + 0.25f * m), ag = toneOnly ? 0.f : airLevel * (1.f - 0.35f * m);
    const float murG = airLevel * kMuraiki * v.peak * v.murLevel;
    const int rise = (int)(kMuraikiRise * fsr);
    float fade = v.fadeGain;
    for (int t = 0; t < n; ++t) {
        float x = tg * tone[t] + ag * airBuf[t];
        if (v.murPos < v.murLen) {
            const int k = v.murPos++;
            const float e = k < rise ? 0.5f - 0.5f * std::cos(kPi * (float)k / (float)rise)
                                     : 0.5f + 0.5f * std::cos(kPi * (float)(k - rise) / (float)(v.murLen - rise));
            x += murG * e * v.murBP.process(rng.bipolar());
        }
        if (v.clickPos < v.clickLen) {
            const float hann = 0.5f - 0.5f * std::cos(kTwoPi * (float)v.clickPos / (float)v.clickLen);
            const float cc = v.clickC * v.clickCr - v.clickS * v.clickCi, ss = v.clickC * v.clickCi + v.clickS * v.clickCr;
            v.clickC = cc; v.clickS = ss;
            x += v.clickAmp * hann * ss;
            ++v.clickPos;
        }
        if (v.fading) { x *= fade; fade = std::max(0.f, fade - v.fadeStep); }
        outL[t] += x * v.panL;
        outR[t] += x * v.panR;
    }
    v.fadeGain = fade;
    v.life += n;
    if (v.fading && fade <= 0.f) v.active = false;
}

void ZenShakuhachi::echoAndWall(const float *dryL, const float *dryR, float *outL, float *outR, float *wetInL, float *wetInR, int n,
                                int muted) {
    const int en = (int)echoBuf.size(), wn = (int)wallBuf.size();
    float nl, nr, fl, fr;
    panGains(-0.55f * widthNow / 0.7f, nl, nr);   // the near slope to one side, the far to the other
    panGains(0.6f * widthNow / 0.7f, fl, fr);
    float wl[3], wr[3];
    for (int k = 0; k < 3; ++k) panGains(kWallPan[k] * widthNow / 0.7f, wl[k], wr[k]);
    for (int t = 0; t < n; ++t) {
        const float x = t < muted ? 0.f : 0.7071f * (dryL[t] + dryR[t]);   // a centred note keeps its level
        echoBuf[(size_t)echoW] = x;
        wallBuf[(size_t)wallW] = x;
        int i0 = echoW - echoNearD; if (i0 < 0) i0 += en;
        int i1 = echoW - echoFarD; if (i1 < 0) i1 += en;
        echoLP[0] = echoBuf[(size_t)i0] + (echoLP[0] - echoBuf[(size_t)i0]) * echoLPA;
        echoLP[1] = echoBuf[(size_t)i1] + (echoLP[1] - echoBuf[(size_t)i1]) * echoLPA;
        const float a = echoNear.next() * echoLP[0], b = echoFar.next() * echoLP[1];
        outL[t] = dryL[t] + a * nl + b * fl;
        outR[t] = dryR[t] + a * nr + b * fr;
        const float g = wall.next();
        float sl = 0, sr2 = 0;
        for (int k = 0; k < 3; ++k) {
            int j = wallW - wallD[k]; if (j < 0) j += wn;
            const float y = kWallGain[k] * wallBuf[(size_t)j];
            sl += y * wl[k]; sr2 += y * wr[k];
        }
        wetInL[t] = g * sl;
        wetInR[t] = g * sr2;
        if (++echoW == en) echoW = 0;
        if (++wallW == wn) wallW = 0;
    }
}

void ZenShakuhachi::housekeeping() {
    for (auto &v : voices)
        if (v.active && v.releasing && !v.fading && v.breath < 2e-4f && v.wind.swing() < 1e-5f && v.murPos >= v.murLen) v.active = false;
}

void ZenShakuhachi::processBlock(float *left, float *right, int n) {
    const float fsr = (float)sr;
    for (int t = 0; t < n; ++t) {
        fine.next(); breath.next(); air.next(); bend.next(); bamboo.next(); yuri.next(); echo.next(); space.next(); width.next();
    }
    // Dials with the mood underneath them: energy adds breath and eases muraiki; warmth darkens the bore;
    // brightness tilts; space adds echo and space; motion widens yuri.
    const float breathEff = clamp01(breath.value + 0.3f * (mEnergy - 0.5f));
    airLevel = kTone * kAirRef * std::pow(10.f, (-24.f + 18.f * breathEff) / 20.f);
    bendNow = clamp01(bend.value);
    yuriNow = clamp01(yuri.value) * (0.6f + 0.8f * clamp01(mMotion));
    widthNow = 0.3f + 0.4f * clamp01(width.value);
    bambooNow = clamp01(bamboo.value);
    reflBase = 5000.f * std::exp2(-1.2f * (clamp01(mWarmth) - 0.5f));
    wheelA = 1.f - std::exp(-(float)n / (0.012f * fsr));
    meriA = 1.f - std::exp(-(float)n / (0.05f * fsr));
    wanderA = std::min(1.f, (float)n / (0.6f * fsr));
    const float echoEff = toneOnly ? 0.f : clamp01(echo.value + 0.5f * (mSpace - 0.5f));
    echoNear.setTarget(0.2f * echoEff);
    echoFar.setTarget(0.14f * smoothstep((echoEff - 0.25f) / 0.75f));
    if (std::fabs(bambooNow - appliedBamboo) > 1e-3f || std::fabs(mBright - appliedBright) > 1e-3f) {
        appliedBamboo = bambooNow; appliedBright = mBright;
        for (int ch = 0; ch < 2; ++ch) {
            formant[ch][0].setPeak(600.0, 3.0, 6.0 * bambooNow, sr);
            formant[ch][1].setPeak(1900.0, 3.0, 6.0 * bambooNow, sr);
            highShelf[ch].setHighShelf(3000.0, 6.0 * (clamp01(mBright) - 0.5), sr);
        }
    }
    const float sv = clamp01(space.value + 0.6f * (mSpace - 0.5f));
    if (std::fabs(sv - appliedSpace) > 2e-3f) {
        appliedSpace = sv;
        reverb.configure(0.15f + 0.35f * sv, 0.7f, 14.f, 0.f);
        wet.setTarget(sv > 0.f ? kWetMax * std::pow(sv, 0.77f) : 0.f);
        wall.setTarget(0.9f * sv);
    }

    // After all-sound-off the voices' 20 ms fades are kept out of the echo, the wall and the reverb.
    const int muted = std::min(sendMute, n);
    sendMute -= muted;
    float dryL[kSub] = {}, dryR[kSub] = {}, wallL[kSub] = {}, wallR[kSub] = {};
    if (!idle) {
        float vl[kSub] = {}, vr[kSub] = {};
        bool anyVoice = false;
        for (auto &v : voices) {
            if (!v.active) continue;
            anyVoice = true;
            renderVoice(v, vl, vr, n);
        }
        float peakAbs = 0;
        for (int t = 0; t < n; ++t) {
            vl[t] = highShelf[0].process(formant[0][1].process(formant[0][0].process(vl[t])));
            vr[t] = highShelf[1].process(formant[1][1].process(formant[1][0].process(vr[t])));
            peakAbs = std::max(peakAbs, std::max(std::fabs(vl[t]), std::fabs(vr[t])));
        }
        echoAndWall(vl, vr, dryL, dryR, wallL, wallR, n, muted);
        // Idle once the voices are gone and the echo has had time to say everything it heard.
        if (!anyVoice && peakAbs < 1e-6f) {
            quietSamples += n;
            if (quietSamples >= (int)((kEchoFar + 0.25f) * fsr)) {
                idle = true;
                quietSamples = 0;
                clearTails();
                for (int ch = 0; ch < 2; ++ch) { formant[ch][0].clear(); formant[ch][1].clear(); highShelf[ch].clear(); }
            }
        } else {
            quietSamples = 0;
        }
    }

    float revL[kSub] = {}, revR[kSub] = {};
    if (wet.target > 0.f || wet.value > 1e-5f) {
        float inL[kSub], inR[kSub];
        for (int t = 0; t < n; ++t) {
            inL[t] = t < muted ? 0.f : dryL[t];
            inR[t] = t < muted ? 0.f : dryR[t];
        }
        reverb.process(inL, inR, revL, revR, n);
        reverbLive = true;
    } else if (reverbLive) {
        reverb.clear();
        reverbLive = false;
    }
    for (int t = 0; t < n; ++t) {
        const float w = wet.next();
        float l = kMaster * (dryL[t] + w * revL[t] + wallL[t]), r = kMaster * (dryR[t] + w * revR[t] + wallR[t]);
        limiter.process(l, r);
        left[t] = softLimit(l);
        right[t] = softLimit(r);
    }
    if (++blockCount % 4 == 0) housekeeping();
}

} // namespace isd
