#include "TeaHouseKoto.hpp"
#include "include/InStrumDSP.h"
#include <algorithm>

namespace isd {

namespace {

// Level and tone calibration (see docs/superpowers/briefs/tea-house-koto.md).
constexpr float kGain = 0.12f;            // a string's fundamental at velocity 127
constexpr float kMaster = 1.14f;          // one loudness with the other built-ins (the presets within 2 dB of Felt Glass)
constexpr float kWetMax = 0.30f;          // the room's return at full Space (snow outside: a hushed room)
constexpr float kSympIn = 0.0316f;        // the voices reach the open strings at −30 dB
constexpr float kSympOut = 12.f;          // the open strings' ring at Bloom 1
constexpr float kOpenT60 = 7.f;           // the open strings' fundamentals ring this long (upper partials less)
constexpr float kBodyGain = 0.9f;         // the board at Body 1
constexpr float kThumpGain = 0.5f;        // the struts' thump on the hardest pluck, against the string
constexpr float kScrapeGain = 3.0f;       // the plectrum's scrape at velocity 127, against the string
constexpr float kNoise = 0.08f;           // each pluck's grain
constexpr float kDispersion = 0.5f;       // the dispersion allpass on a long string (shorter ones less)
constexpr float kReleaseT60 = 0.6f;       // a released string, settled by the hand
constexpr float kDecayScale = 1.6f;       // the fundamental's T60 against the brief's −40 dB time on A3
constexpr double kRadiationHz = 1000.0, kRadiationQ = 0.6, kRadiationDb = 6.0;   // the board radiates the middle partials best
constexpr float kYuriCents = 15.f, kYuriDelay = 0.15f, kYuriRamp = 0.12f;
constexpr float kBendTau = 0.004f;        // the press glides through two 4 ms smoothers: there within about 25 ms
constexpr float kPressureTau = 0.03f;
constexpr float kPhraseGap = 1.5f;        // seconds with no key held before a new phrase re-roots the open strings
constexpr float kRootWindow = 0.04f;      // a chord's notes within 40 ms of the phrase's first all count
/// Hirajōshi: strings 1–13 in semitones from string 5 (string 1 sounds with string 5, as a drone).
const int kHirajoshi[TeaHouseKoto::kOpenStrings] = {0, -7, -5, -4, 0, 1, 5, 7, 8, 12, 13, 17, 19};
const float kOpenWeights[TeaHouseKoto::kOpenPartials] = {1.f, 0.5f, 0.3f};
/// The paulownia board's low modes (Hz, Q, level), 100 Hz dominant (the JASA 2020 finite-element peaks).
const float kBoard[TeaHouseKoto::kBodyModes][3] = {{100.f, 12.f, 1.0f}, {194.f, 14.f, 0.55f}, {220.f, 14.f, 0.5f}, {285.f, 16.f, 0.45f}};

inline float midiHz(float m) { return 440.f * std::exp2((m - 69.f) / 12.f); }
inline float smooth01(float x) { x = clamp01(x); return x * x * (3.f - 2.f * x); }
/// The playable range: notes below C1 or above C8 fold in by octaves.
inline int fold(int p) { while (p < 24) p += 12; while (p > 108) p -= 12; return p; }

} // namespace

TeaHouseKoto::TeaHouseKoto(double sampleRate) : sr(sampleRate), rng(0x7EA4005E13ULL), reverb(sampleRate, kSub) {
    limiter.init(sr);
    fine.init(sr); body.init(sr); bloom.init(sr); yuri.init(sr); space.init(sr); width.init(sr); wet.init(sr);
    fine.snap(0); body.snap(0.50f); bloom.snap(0.40f); yuri.snap(0.30f); space.snap(0.35f); width.snap(0.50f); wet.snap(0);
    // Each loop holds the longest period asked for: C1 a whole tone down, fine tune −50 cents.
    const float lowest = midiHz(24.f) * std::exp2(-2.5f / 12.f);
    for (auto &v : voices) {
        v.str.allocate(sr, lowest);
        v.scrape.hp.setHighpass(3000.0, 0.7071, sr);
        v.scrape.lp.setLowpass(std::min(8000.0, 0.45 * sr), 0.7071, sr);
    }
    for (int k = 0; k < kBodyModes; ++k) board.setMode(k, kBoard[k][0], kBoard[k][1], kBoard[k][2], sr);
    board.setThump(30.f, 0.12f, sr);
    for (auto &f : radiation) f.setPeak(kRadiationHz, kRadiationQ, kRadiationDb, sr);
    quietSamples = (int)(kPhraseGap * sr);
    tuneOpenStrings();
}

void TeaHouseKoto::setParam(int address, float value, bool snap) {
    auto set = [&](Smoothed &s) { if (snap) s.snap(value); else s.setTarget(value); };
    switch (address) {
    case ISD_P_FINE_TUNE: set(fine); break;
    case ISD_P_TRANSPOSE: pTranspose = value; break;
    case ISD_P_PICK: pPick = value; break;
    case ISD_P_SILK: pSilk = value; break;
    case ISD_P_BODY: set(body); break;
    case ISD_P_BLOOM: set(bloom); break;
    case ISD_P_YURI: set(yuri); break;
    case ISD_P_SPACE: set(space); break;
    case ISD_P_WIDTH: set(width); break;
    case ISD_P_MOOD_ENERGY: mEnergy = value; break;
    case ISD_P_MOOD_WARMTH: mWarmth = value; break;
    case ISD_P_MOOD_BRIGHTNESS: mBright = value; break;
    case ISD_P_MOOD_SPACE: mSpace = value; break;
    case ISD_P_MOOD_MOTION: mMotion = value; break;
    case ISD_P_DEBUG_NO_SYMPATHY: noSympathy = value >= 0.5f; break;
    case ISD_P_DEBUG_NO_BODY: noBody = value >= 0.5f; break;
    default: break;
    }
}

int TeaHouseKoto::activeVoices() const {
    int n = 0;
    for (const auto &v : voices) if (v.active) ++n;
    return n;
}

TeaHouseKoto::Voice &TeaHouseKoto::allocate() {
    int sounding = 0;
    Voice *quietest = nullptr;
    for (auto &v : voices) {
        if (!v.active || v.fading) continue;
        ++sounding;
        if (!quietest || v.str.level < quietest->str.level) quietest = &v;
    }
    if (sounding >= kPolyphony && quietest) beginFade(*quietest);
    for (auto &v : voices) if (!v.active) return v;
    Voice *best = nullptr;
    for (auto &v : voices) if (v.fading && (!best || v.fadeGain < best->fadeGain)) best = &v;
    if (!best) best = &voices[0];
    best->active = false;
    return *best;
}

void TeaHouseKoto::beginFade(Voice &v) {
    if (v.fading) return;
    v.fading = true;
    v.fadeStep = 1.f / (0.02f * (float)sr);
}

void TeaHouseKoto::damp(Voice &v) {
    if (v.damped) return;
    v.damped = true;
    v.t60 = std::min(v.t60, kReleaseT60);
    v.str.setDecay(v.t60);
}

void TeaHouseKoto::startVoice(Voice &v, int note, int pitch, int velocity) {
    const float fsr = (float)sr;
    const float vel = (float)std::clamp(velocity, 1, 127) / 127.f;
    v.active = true; v.keyDown = true; v.damped = false; v.fading = false;
    v.note = note; v.pitch = pitch;
    v.fadeGain = 1; v.fadeStep = 0; v.age = 0;
    v.hz0 = midiHz((float)pitch);
    v.bend = bendNow;
    v.pressure = std::max(channelPressure, polyPressure[note]);
    v.vibPhase = rng.uniform(); v.wander = rng.bipolar(); v.wanderTarget = v.wander;
    v.wanderLeft = (int)((0.22f + 0.2f * rng.uniform()) * fsr);
    // The string. Silk is the material (the loss filter's cutoff on A3, key-tracked so every register keeps its
    // decay) and the decay: A3 falls 40 dB in 3.5 s (tetron) … 2 s (silk), 0.6× as long an octave up.
    const float silk = clamp01(pSilk + 0.4f * (mWarmth - 0.5f));
    const float fall40 = 3.5f - 1.5f * silk;
    v.t60 = std::clamp(kDecayScale * fall40 * std::pow(0.6f, (float)(pitch - 57) / 12.f), 0.25f, 14.f);
    const float ratio = v.hz0 / 220.f;
    const float cutoff = 9000.f * std::pow(2500.f / 9000.f, silk) * (ratio > 1.f ? ratio : std::sqrt(ratio));
    const float disp = kDispersion * clamp01((fsr / v.hz0 - 12.f) / 200.f);
    v.str.reset();
    v.str.tune(v.hz0 * fineRatio * std::exp2(v.bend / 12.f), v.t60, cutoff, disp);
    // The pluck. Pick is the position (energy and a hard note move it toward the bridge); a hard plectrum near the
    // bridge releases the string sharper.
    const float pick = clamp01(pPick - 0.4f * (mEnergy - 0.5f));
    const float pos = std::clamp(0.12f + 0.38f * pick - 0.05f * vel * vel, 0.06f, 0.5f);
    v.amp = kGain * (0.1f + 0.9f * std::pow(vel, 1.5f));
    const float hardness = (1500.f + 8000.f * vel * vel) * std::pow(0.3f / pos, 0.8f);
    // The thumb and the fingers pluck in opposite directions: neighbouring semitones start opposite ways (octaves
    // alike), so a chord's strings never all swing out together, whatever order its notes arrive in.
    const float direction = (pitch & 1) ? -1.f : 1.f;
    v.str.pluck(pos, direction * v.amp, hardness, kNoise, rng.next());
    // The hardest notes scrape the plectrum along the string; hard plucks knock the board.
    v.scrape.left = 0;
    if (velocity >= 118) {
        v.scrape.length = std::max(1, (int)(0.002f * fsr));
        v.scrape.left = v.scrape.length + 32;   // and the filters' tail
        v.scrape.amp = kScrapeGain * v.amp * (0.7f + 0.3f * (float)(velocity - 118) / 9.f);
        v.scrape.hp.clear(); v.scrape.lp.clear();
    }
    if (!noBody && velocity > 90) {
        const float h = (float)(velocity - 90) / 37.f;
        board.kick(kThumpGain * v.amp * h * std::sqrt(h));
    }
    // Low strings sit to the left, high ones to the right (Width scales it live).
    v.panPos = std::clamp((float)(pitch - 64) / 30.f, -1.f, 1.f);
    // A note on an open string's pitch plucks that string: its sympathetic ring gives way to the pluck.
    const int k = playedString(pitch);
    if (k >= 0) bank.quiet(k, kOpenPartials);
    idle = false; idleSamples = 0;
}

void TeaHouseKoto::noteOn(int note, int velocity) {
    if (velocity <= 0) { noteOff(note); return; }
    note &= 127;
    const int pitch = fold(note + (int)std::lround(pTranspose));
    const bool phrase = held == 0 && quietSamples >= (int)(kPhraseGap * sr);
    if (!keyDown[note]) { keyDown[note] = true; ++held; }
    quietSamples = 0;
    if (phrase) { rootWindow = (int)(kRootWindow * sr); phraseLowest = pitch; setRoot(pitch % 12); }
    else if (rootWindow > 0 && pitch < phraseLowest) { phraseLowest = pitch; setRoot(pitch % 12); }
    polyPressure[note] = 0.f;
    // The same string plucked again: its old voice gives way (20 ms) to the new pluck.
    for (auto &v : voices) if (v.active && !v.fading && v.note == note) beginFade(v);
    startVoice(allocate(), note, pitch, velocity);
}

void TeaHouseKoto::noteOff(int note) {
    note &= 127;
    if (keyDown[note]) { keyDown[note] = false; --held; }
    polyPressure[note] = 0.f;
    for (auto &v : voices)
        if (v.active && !v.fading && v.note == note && v.keyDown) { v.keyDown = false; if (!sustain) damp(v); }
}

void TeaHouseKoto::setSustain(bool down) {
    if (down == sustain) return;
    sustain = down;
    if (!down) for (auto &v : voices) if (v.active && !v.fading && !v.keyDown) damp(v);
}

void TeaHouseKoto::pitchBend(float semitones) { bendTarget = std::clamp(semitones, -2.f, 2.f); }

void TeaHouseKoto::aftertouch(int note, float pressure) {
    const float p = clamp01(pressure);
    if (note < 0) channelPressure = p; else polyPressure[note & 127] = p;
}

void TeaHouseKoto::allNotesOff() {
    for (auto &v : voices) if (v.active) beginFade(v);
    for (auto &k : keyDown) k = false;
    held = 0;
    rootWindow = 0;
    quietSamples = (int)(kPhraseGap * sr);   // the next note starts a new phrase
    // The wheel and pressure start neutral again (a switch with the wheel held must not leave a string pressed).
    bendTarget = bendMid = bendNow = 0.f;
    channelPressure = 0.f;
    for (auto &p : polyPressure) p = 0.f;
    // The open strings and the board fade with the strings.
    panicFade.start(sr);
}

void TeaHouseKoto::allSoundOff() {
    allNotesOff();
    reverb.clear();
    reverbMute = (int)(0.025 * sr);
}

void TeaHouseKoto::render(float *left, float *right, int frames) {
    int pos = 0;
    while (pos < frames) {
        const int n = std::min(kSub, frames - pos);
        processBlock(left + pos, right + pos, n);
        pos += n;
    }
}

void TeaHouseKoto::setRoot(int pitchClass) {
    const int pc = ((pitchClass % 12) + 12) % 12;
    if (pendingRoot >= 0) { pendingRoot = pc; return; }   // a re-rooting is under way: it lands on the newest
    if (pc == root) return;
    if (bankLive) { pendingRoot = pc; bankFade.start(sr); }   // the old phrase's ring fades before the retune
    else { root = pc; tuneOpenStrings(); }
}

void TeaHouseKoto::tuneOpenStrings() {
    const int base = 57 + (root + 3) % 12;   // string 5 between A3 and G♯4 (E4 on E, D4 on D)
    const float ratio = std::exp2(bankCents / 1200.f), spread = 0.7f * clamp01(width.value);
    for (int s = 0; s < kOpenStrings; ++s) {
        openMidi[s] = base + kHirajoshi[s];
        const float m = (float)openMidi[s] + (s == 0 ? 0.01f : 0.f);   // string 1 a hair off string 5
        const float pan = spread * std::clamp((m - 64.f) / 30.f, -1.f, 1.f);
        bank.setString(s, midiHz(m) * ratio, pan, kOpenPartials, kOpenWeights, kOpenT60, sr);
    }
    bankWidth = width.value;
}

int TeaHouseKoto::playedString(int pitch) const {
    for (int s = kOpenStrings - 1; s >= 0; --s) if (openMidi[s] == pitch) return s;
    return -1;
}

float TeaHouseKoto::yuriCents(Voice &v, int n, float scale, float wanderK) {
    const float fsr = (float)sr;
    v.age = std::min(v.age + n, 1 << 30);
    const float depth = kYuriCents * v.pressure * scale;
    if (depth < 1e-3f) return 0.f;
    // A slow, irregular vibrato: the rate wanders through 4–6 Hz (a hand, not an oscillator), a little shallower
    // when it hurries, and it waits until 150 ms after the pluck.
    v.wanderLeft -= n;
    if (v.wanderLeft <= 0) { v.wanderTarget = rng.bipolar(); v.wanderLeft = (int)((0.22f + 0.2f * rng.uniform()) * fsr); }
    v.wander += wanderK * (v.wanderTarget - v.wander);
    v.vibPhase += (5.f + v.wander) * (float)n / fsr;
    if (v.vibPhase >= 1.f) v.vibPhase -= 1.f;
    const float onset = smooth01(((float)v.age / fsr - kYuriDelay) / kYuriRamp);
    return depth * onset * (1.f - 0.12f * v.wander) * std::sin(kTwoPi * v.vibPhase);
}

void TeaHouseKoto::housekeeping() {
    bool any = false;
    for (auto &v : voices) {
        if (!v.active) continue;
        if (!v.fading && !v.str.plucking() && v.scrape.left <= 0 && v.str.level < 3e-5f * v.amp) { v.active = false; continue; }
        any = true;
    }
    if (bankLive && !any && bank.energy() < 1e-14f) { bank.clear(); bankLive = false; }
}

void TeaHouseKoto::processBlock(float *left, float *right, int n) {
    const float fsr = (float)sr;
    for (int t = 0; t < n; ++t) { fine.next(); body.next(); bloom.next(); yuri.next(); space.next(); width.next(); }
    fineRatio = std::exp2(fine.value / 1200.f);
    if (std::fabs(fine.value - bankCents) > 0.05f || std::fabs(width.value - bankWidth) > 0.01f) {
        bankCents = fine.value;
        if (pendingRoot < 0) tuneOpenStrings(); else bankWidth = width.value;
    }
    // The press: the wheel through two one-pole smoothers (S-shaped, settled within about 25 ms).
    const float kb = 1.f - std::exp(-(float)n / (kBendTau * fsr));
    bendMid += kb * (bendTarget - bendMid);
    bendNow += kb * (bendMid - bendNow);
    const float kp = 1.f - std::exp(-(float)n / (kPressureTau * fsr));
    const float wk = 1.f - std::exp(-(float)n / (0.15f * fsr));
    if (std::fabs(mBright - appliedBright) > 1e-3f) {
        appliedBright = mBright;
        for (auto &h : highShelf) h.setHighShelf(3500.0, 6.0 * (clamp01(mBright) - 0.5), sr);
    }
    // The tea house: a small, damped wooden room.
    const float sv = clamp01(space.value + 0.6f * (mSpace - 0.5f));
    if (std::fabs(sv - appliedSpace) > 2e-3f) {
        appliedSpace = sv;
        reverb.configure(0.08f + 0.22f * sv, 0.85f, 8.f, 0.f);
        wet.setTarget(sv > 0.f ? kWetMax * std::pow(sv, 0.8f) : 0.f);
    }
    if (held == 0) quietSamples = std::min(quietSamples + n, 1 << 30);
    if (rootWindow > 0) rootWindow = std::max(0, rootWindow - n);
    // The fades' gains across this block (the open strings and the board fade with a panic; the open strings alone
    // before a re-rooting).
    const float panicFrom = panicFade.gain, panicTo = panicFade.on ? std::max(0.f, panicFade.gain - panicFade.step * (float)n) : panicFade.gain;
    const float bankFrom = bankFade.gain, bankTo = bankFade.on ? std::max(0.f, bankFade.gain - bankFade.step * (float)n) : bankFade.gain;

    float dryL[kSub] = {}, dryR[kSub] = {}, mono[kSub] = {};
    if (!idle) {
        const float yuriScale = std::max(0.f, yuri.value * (1.f + 0.6f * (clamp01(mMotion) - 0.5f)));
        const float spread = 0.7f * clamp01(width.value);
        bool anyVoice = false;
        for (auto &v : voices) {
            if (!v.active) continue;
            anyVoice = true;
            if (!v.fading) {
                v.bend = bendNow;
                v.pressure += kp * (std::max(channelPressure, polyPressure[v.note]) - v.pressure);
            }
            const float cents = 100.f * v.bend + yuriCents(v, n, yuriScale, wk);
            v.str.glide(v.hz0 * fineRatio * std::exp2(cents / 1200.f), n);
            float vs[kSub] = {};
            v.str.render(vs, n);
            if (v.scrape.left > 0) {
                Scrape &s = v.scrape;
                for (int t = 0; t < n && s.left > 0; ++t, --s.left) {
                    const int k = s.length + 32 - s.left;
                    const float e = k < s.length ? std::sin(kPi * (float)k / (float)s.length) : 0.f;
                    vs[t] += s.lp.process(s.hp.process(rng.bipolar() * s.amp * e));
                }
            }
            if (v.fading) {
                for (int t = 0; t < n; ++t) { vs[t] *= v.fadeGain; v.fadeGain = std::max(0.f, v.fadeGain - v.fadeStep); }
                if (v.fadeGain <= 0.f) v.active = false;
            }
            const float p = std::clamp(spread * v.panPos, -1.f, 1.f);
            const float gl = std::sqrt(0.5f * (1.f - p)), gr = std::sqrt(0.5f * (1.f + p));
            for (int t = 0; t < n; ++t) { dryL[t] += vs[t] * gl; dryR[t] += vs[t] * gr; mono[t] += vs[t]; }
        }
        // What the board radiates of the strings: the middle partials (a broad +6 dB around 1 kHz) carry better than
        // the fundamental.
        for (int t = 0; t < n; ++t) { dryL[t] = radiation[0].process(dryL[t]); dryR[t] = radiation[1].process(dryR[t]); }
        // The open strings: rung by the voices at −30 dB, heard at Bloom.
        const bool sympOn = !noSympathy && (bloom.value > 1e-5f || bloom.target > 0.f);
        if (!sympOn) {
            if (bankLive) { bank.clear(); bankLive = false; }
        } else if (anyVoice || bankLive) {
            // A string being played is not also ringing in sympathy with itself.
            bool played[kOpenStrings] = {};
            for (const auto &v : voices) {
                if (!v.active || v.fading) continue;
                const int k = playedString(v.pitch);
                if (k >= 0) played[k] = true;
            }
            for (int k = 0; k < kOpenStrings; ++k) bank.setDrive(k, kOpenPartials, played[k] ? 0.f : 1.f);
            const float g = kSympOut * bloom.value;
            bank.render(mono, dryL, dryR, n, kSympIn, g * panicFrom * bankFrom, g * panicTo * bankTo);
            bankLive = true;
        }
        // The board: its low modes under the strings, and the struts' thump.
        const float bodyGain = noBody ? 0.f : kBodyGain * body.value;
        if (bodyGain > 1e-5f) {
            const float dg = (panicTo - panicFrom) / (float)n;
            float gp = panicFrom;
            for (int t = 0; t < n; ++t) {
                gp += dg;
                const float b = 0.7071f * bodyGain * gp * board.process(mono[t]);
                dryL[t] += b; dryR[t] += b;
            }
        } else {
            board.clear();
        }
        float peakAbs = 0;
        for (int t = 0; t < n; ++t) {
            dryL[t] = highShelf[0].process(dryL[t]);
            dryR[t] = highShelf[1].process(dryR[t]);
            peakAbs = std::max(peakAbs, std::max(std::fabs(dryL[t]), std::fabs(dryR[t])));
        }
        if (!anyVoice && !bankLive && !board.thumping() && peakAbs < 1e-6f) {
            idleSamples += n;
            if (idleSamples >= (int)(0.25f * fsr)) {
                idle = true;
                idleSamples = 0;
                board.clear();
                for (auto &h : highShelf) h.clear();
                for (auto &f : radiation) f.clear();
            }
        } else {
            idleSamples = 0;
        }
    }
    panicFade.gain = panicTo;
    if (panicFade.on && panicTo <= 0.f) {
        bank.clear(); board.clear(); bankLive = false;
        panicFade.stop();
    }
    bankFade.gain = bankTo;
    if (bankFade.on && bankTo <= 0.f) {
        bank.clear(); bankLive = false;
        if (pendingRoot >= 0) { root = pendingRoot; pendingRoot = -1; }
        tuneOpenStrings();
        bankFade.stop();
    }

    float revL[kSub] = {}, revR[kSub] = {};
    if (reverbMute > 0) {
        // All sound off: the strings fading out over these 20 ms stay out of the room.
        reverbMute -= n;
        reverb.clear();
    } else if (wet.target > 0.f || wet.value > 1e-5f) {
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
