#include "FeltGlass.hpp"
#include "include/InStrumDSP.h"
#include <algorithm>
#include <cstring>

// The 8-lane helpers below are always inlined, so no vector values cross a call boundary.
#if defined(__clang__)
#pragma clang diagnostic ignored "-Wpsabi"
#elif defined(__GNUC__)
#pragma GCC diagnostic ignored "-Wpsabi"
#endif

namespace isd {

namespace {

// Level calibration (see docs/superpowers/briefs/felt-glass.md).
constexpr float kStringGain = 0.30f;
constexpr float kGlassGain = 0.146f;
constexpr float kDamperNoiseGain = 1.0f;
constexpr float kSympIn = 0.02f;
constexpr float kSympOut = 8.0f;
constexpr float kMaster = 1.0f;

const float kGlassRatio[6] = {1.0f, 2.32f, 4.25f, 6.63f, 9.38f, 12.5f};
const float kGlassBase[6] = {1.0f, 0.55f, 0.35f, 0.22f, 0.14f, 0.09f};

typedef float v8 __attribute__((vector_size(32)));
__attribute__((always_inline)) inline v8 ld8(const float *p) { v8 v; std::memcpy(&v, p, sizeof v); return v; }
__attribute__((always_inline)) inline void st8(float *p, v8 v) { std::memcpy(p, &v, sizeof v); }
__attribute__((always_inline)) inline float hsum(v8 v) { return ((v[0] + v[4]) + (v[1] + v[5])) + ((v[2] + v[6]) + (v[3] + v[7])); }

/// Advances one 8-lane chunk of decaying phasors `n` samples, adding their imaginary parts into `lane`.
__attribute__((always_inline)) inline void run1(float *re, float *im, const float *cr, const float *ci, v8 *lane, int n) {
    v8 r = ld8(re), i = ld8(im), c = ld8(cr), s = ld8(ci);
    for (int t = 0; t < n; ++t) {
        v8 nr = r * c - i * s, ni = r * s + i * c;
        r = nr; i = ni;
        lane[t] += ni;
    }
    st8(re, r); st8(im, i);
}

/// Two chunks at once: independent chains keep the multiplier pipelines busy.
__attribute__((always_inline)) inline void run2(float *re, float *im, const float *cr, const float *ci, v8 *lane, int n) {
    v8 r0 = ld8(re), i0 = ld8(im), c0 = ld8(cr), s0 = ld8(ci);
    v8 r1 = ld8(re + 8), i1 = ld8(im + 8), c1 = ld8(cr + 8), s1 = ld8(ci + 8);
    for (int t = 0; t < n; ++t) {
        v8 nr0 = r0 * c0 - i0 * s0, ni0 = r0 * s0 + i0 * c0;
        v8 nr1 = r1 * c1 - i1 * s1, ni1 = r1 * s1 + i1 * c1;
        r0 = nr0; i0 = ni0; r1 = nr1; i1 = ni1;
        lane[t] += ni0 + ni1;
    }
    st8(re, r0); st8(im, i0); st8(re + 8, r1); st8(im + 8, i1);
}

inline float midiHz(float m) { return 440.f * std::exp2((m - 69.f) / 12.f); }
inline float decayR(float t60, double sr) { return (float)std::pow(10.0, -3.0 / (t60 * sr)); }

/// String inharmonicity: lowest around the tenor (MIDI 45), rising gently into the bass and steeply into the treble.
inline float inharmonicity(int m) {
    float lg = m >= 45 ? -3.9f + (float)(m - 45) * (2.3f / 63.f) : -3.9f + (float)(45 - m) * (0.6f / 24.f);
    return std::pow(10.f, lg);
}

inline int partialCount(int m) {
    if (m <= 40) return 40;
    if (m <= 64) return (int)std::lround(40.f - (float)(m - 40) * (20.f / 24.f));
    if (m >= 96) return 8;
    return (int)std::lround(20.f - (float)(m - 64) * (12.f / 32.f));
}


inline float chunkEnergy(const float *re, const float *im) {
    float e = 0;
    for (int k = 0; k < 8; ++k) e += re[k] * re[k] + im[k] * im[k];
    return e;
}

} // namespace

FeltGlass::FeltGlass(double sampleRate) : sr(sampleRate), rng(0x5EED1234ABCDULL), reverb(sampleRate, kSub) {
    limiter.init(sr);
    fine.init(sr); glassGain.init(sr); warmth.init(sr); space.init(sr); wet.init(sr); sympGain.init(sr, 50.0);
    fine.snap(0); glassGain.snap(0.35f); warmth.snap(0.60f); space.snap(0.45f); wet.snap(0); sympGain.snap(0);
    const double peaks[4][3] = {{110, 1.0, 3.0}, {250, 1.2, 2.0}, {1200, 0.9, -2.0}, {3500, 1.0, 1.5}};
    for (int b = 0; b < 4; ++b)
        for (int c = 0; c < 2; ++c) body[b][c].setPeak(peaks[b][0], peaks[b][1], peaks[b][2], sr);
    std::fill(yre, yre + kSymp, 0.f); std::fill(yim, yim + kSymp, 0.f);
    std::fill(yhz, yhz + kSymp, 0.f); std::fill(yL, yL + kSymp, 0.f); std::fill(yR, yR + kSymp, 0.f);
    for (int k = 0; k < 36; ++k) {
        yhz[k] = midiHz((float)(48 + k));
        float pan = 0.5f * (float)(48 + k - 64) / 44.f, th = (pan + 1.f) * kPi / 4.f;
        yL[k] = std::cos(th); yR[k] = std::sin(th);
    }
    setSympDecay(0.08f);
}

void FeltGlass::setParam(int address, float value, bool snap) {
    auto set = [&](Smoothed &s) { if (snap) s.snap(value); else s.setTarget(value); };
    switch (address) {
    case ISD_P_FINE_TUNE: pFine = value; set(fine); break;
    case ISD_P_TRANSPOSE: pTranspose = value; break;
    case ISD_P_SPACE: set(space); break;
    case ISD_P_FELT: pFelt = value; break;
    case ISD_P_GLASS: set(glassGain); break;
    case ISD_P_WARMTH: set(warmth); break;
    case ISD_P_RING: pRing = value; break;
    case ISD_P_WIDTH: pWidth = value; break;
    case ISD_P_MOOD_ENERGY: mEnergy = value; break;
    case ISD_P_MOOD_WARMTH: mWarmth = value; break;
    case ISD_P_MOOD_BRIGHTNESS: mBright = value; break;
    case ISD_P_MOOD_SPACE: mSpace = value; break;
    case ISD_P_MOOD_MOTION: mMotion = value; break;
    default: break;
    }
}

int FeltGlass::activeVoices() const {
    int n = 0;
    for (const auto &v : voices) n += v.active ? 1 : 0;
    return n;
}

void FeltGlass::setSympDecay(float t60) {
    sympR = decayR(t60, sr);
    for (int k = 0; k < kSymp; ++k) {
        float w = kTwoPi * yhz[k] * fineRatio / (float)sr;
        ycr[k] = yhz[k] > 0 ? sympR * std::cos(w) : 0.f;
        yci[k] = yhz[k] > 0 ? sympR * std::sin(w) : 0.f;
    }
}

FeltGlass::Voice &FeltGlass::allocate() {
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

void FeltGlass::beginFade(Voice &v) {
    if (v.fading) return;
    v.fading = true;
    v.fadeStep = 1.f / (0.02f * (float)sr);
}

void FeltGlass::noteOn(int note, int velocity) {
    if (velocity <= 0) { noteOff(note); return; }
    idle = false; idleSamples = 0;
    int pitch = std::clamp(note + (int)std::lround(pTranspose), 0, 127);
    // Struck again without a release: the earlier strike counts as released. The new strike gets its own
    // components, which sum with the still-ringing ones exactly as re-exciting the same string would.
    for (auto &v : voices)
        if (v.active && !v.fading && v.note == note && v.keyDown) { v.keyDown = false; if (!sustain) damp(v); }
    startVoice(allocate(), note, pitch, velocity);
}

void FeltGlass::startVoice(Voice &v, int note, int pitch, int velocity) {
    const float fsr = (float)sr, nyq = 0.45f * fsr;
    const float vp = (float)std::clamp(velocity, 1, 127) / 127.f;
    const float vb = clamp01(vp + 0.3f * (mBright - 0.5f));
    const float felt = clamp01(pFelt), ring = clamp01(pRing);
    const float f0 = midiHz((float)pitch);
    const float A = std::pow(vp, 1.7f);

    v.active = true; v.keyDown = true; v.damped = false; v.fading = false;
    v.note = note; v.pitch = pitch; v.amp = A;
    v.fadeGain = 1; v.fadeStep = 0;
    std::fill(v.sre, v.sre + kStrings, 0.f); std::fill(v.sim, v.sim + kStrings, 0.f);
    std::fill(v.scr, v.scr + kStrings, 0.f); std::fill(v.sci, v.sci + kStrings, 0.f);
    std::fill(v.shz, v.shz + kStrings, 0.f); std::fill(v.sdr, v.sdr + kStrings, 0.f);
    std::fill(v.gre, v.gre + kGlass, 0.f); std::fill(v.gim, v.gim + kGlass, 0.f);
    std::fill(v.gcr, v.gcr + kGlass, 0.f); std::fill(v.gci, v.gci + kGlass, 0.f);
    std::fill(v.ghz, v.ghz + kGlass, 0.f); std::fill(v.gdr, v.gdr + kGlass, 0.f);

    // Strings: inharmonic partials shaped by the felt hammer; the lower twelve as beating unison pairs.
    const float B = inharmonicity(pitch), s1 = std::sqrt(1.f + B);
    const int N = partialCount(pitch);
    // The felt hammer's cutoff follows the string's pitch (treble hammers are smaller and harder) and opens with velocity.
    const float hammer = 360.f * std::pow(f0 / 261.63f, 0.6f);
    const float fc = hammer * (1.f - 0.6f * felt) * std::exp2(4.5f * vb), fcRef = hammer * std::exp2(4.5f);
    const float t0 = 18.f * std::pow(10.f, -(float)(pitch - 21) / 87.f) * (0.45f + 1.4f * ring) * (1.f - 0.35f * felt);
    float refE = 0, actE = 0;
    int k = 0;
    // Each partial starts at a fixed quasi-random phase (the contact ramp hides the start), which keeps
    // the crest factor of chords and bass notes musical instead of one coherent spike.
    float phase = 0;
    auto add = [&](float hz, float a, float t60) {
        v.shz[k] = hz; v.sre[k] = a * std::cos(phase); v.sim[k] = a * std::sin(phase); v.sdr[k] = decayR(t60, sr); ++k;
    };
    for (int n = 1; n <= N && k < kStrings; ++n) {
        float nf = (float)n, fn = nf * f0 * std::sqrt(1.f + B * nf * nf) / s1;
        if (fn > nyq) break;
        float pos = std::sin(nf * kPi / 8.f);
        if (std::fabs(pos) < 1e-3f) continue;
        // The top quarter of the partials tapers off, so the partial cap never leaves a spectral edge.
        float edge = nf > 0.75f * (float)N ? 0.5f + 0.5f * std::cos(kPi * (nf - 0.75f * (float)N) / (0.25f * (float)N + 1.f)) : 1.f;
        float aRef = edge * pos / (1.f + std::pow(fn / fcRef, 3.f));
        float a = edge * pos / (1.f + std::pow(fn / fc, 3.f));
        float t60 = t0 / (1.f + fn / 2500.f);
        phase = kTwoPi * (0.381966f * nf + 0.137f * (float)pitch - std::floor(0.381966f * nf + 0.137f * (float)pitch));
        if (n <= 12 && k + 2 <= kStrings) {
            float d = 0.15f + 0.35f * nf / 12.f;
            add(fn * std::exp2(-d / 1200.f), a, t60);
            add(fn * std::exp2(d / 1200.f), 0.25f * a, 2.6f * t60);
            refE += aRef * aRef * 1.0625f; actE += a * a * 1.0625f;
        } else {
            add(fn, a, t60);
            refE += aRef * aRef; actE += a * a;
        }
    }
    const float norm = refE > 0 ? A * kStringGain / std::sqrt(refE) : 0.f;
    v.stringRef = 0;
    for (int i = 0; i < k; ++i) {
        v.sre[i] *= norm; v.sim[i] *= norm;
        v.stringRef += v.sre[i] * v.sre[i] + v.sim[i] * v.sim[i];
    }
    v.nStr = (k + 7) & ~7;
    for (int c = 0; c < kStrings / 8; ++c) v.strOn[c] = c * 8 < k;

    // Glass: inharmonic bell partials an octave up, each a swell (difference of two decays).
    const float tau = 0.3f + 1.2f * (1.f - clamp01(mEnergy));
    const float t60g = std::clamp(8.f * std::pow(0.5f, (float)(pitch - 36) / 60.f), 3.f, 9.f);
    const float detune = 0.5f + 3.f * clamp01(mMotion);
    float w[6], wE = 0;
    for (int i = 0; i < 6; ++i) { w[i] = kGlassBase[i] * std::exp(-(1.f - vb) * (float)i * 0.5f); wE += w[i] * w[i]; }
    // The glass halo softens with the touch too: half as many dB as the hammer took from the strings.
    const float hammerLoss = refE > 0 ? actE / refE : 1.f;
    const float gAmp = A * kGlassGain * std::pow(hammerLoss, 0.25f) / std::sqrt(wE);
    int g = 0;
    v.glassRef = 0;
    for (int i = 0; i < 6 && g + 2 <= kGlass; ++i) {
        float hz = 2.f * f0 * kGlassRatio[i] * std::exp2(((i & 1) ? -detune : detune) / 1200.f);
        if (hz > nyq) continue;
        // Like a real bell, higher partials fade sooner. Each partial swells in (difference of two decays),
        // normalised so its peak is its weight.
        const float t60 = t60g / (1.f + hz / 6000.f), alpha = 6.9078f / t60;
        const float tstar = tau * std::log(1.f + 1.f / (alpha * tau));
        const float peak = std::exp(-alpha * tstar) * (1.f - std::exp(-tstar / tau));
        const float rg = decayR(t60, sr), rs = rg * std::exp(-1.f / (tau * fsr));
        float a = w[i] * gAmp / peak;
        float ph = kTwoPi * (0.618034f * (float)(i + 1) + 0.29f * (float)pitch - std::floor(0.618034f * (float)(i + 1) + 0.29f * (float)pitch));
        v.ghz[g] = hz; v.gre[g] = a * std::cos(ph); v.gim[g] = a * std::sin(ph); v.gdr[g] = rg; ++g;
        v.ghz[g] = hz; v.gre[g] = -a * std::cos(ph); v.gim[g] = -a * std::sin(ph); v.gdr[g] = rs; ++g;
        v.glassRef += 2.f * a * a;
    }
    v.nGlass = (g + 7) & ~7;
    for (int c = 0; c < kGlass / 8; ++c) v.glassOn[c] = c * 8 < g;

    for (int i = 0; i < kStrings; ++i) {
        float w0 = kTwoPi * v.shz[i] * fineRatio / fsr;
        v.scr[i] = v.sdr[i] * std::cos(w0); v.sci[i] = v.sdr[i] * std::sin(w0);
    }
    for (int i = 0; i < kGlass; ++i) {
        float w0 = kTwoPi * v.ghz[i] * fineRatio / fsr;
        v.gcr[i] = v.gdr[i] * std::cos(w0); v.gci[i] = v.gdr[i] * std::sin(w0);
    }

    // Felt contact ramp, thump and stereo place. The thump sits (−18 + 10·felt) dB under the note's initial level.
    v.attackPos = 0;
    v.attackLen = std::max(1, (int)((4.f - 3.f * vp) * 0.001f * fsr));
    v.noteRms = std::sqrt(0.5f * v.stringRef);
    v.noiseFilter.clear(); v.noiseLowpass.clear();
    v.noiseHz = 180.f + 220.f * (float)(pitch - 21) / 87.f;
    const float td = (25.f - 17.f * vp) * 0.001f;
    startNoise(v, td, v.noiseHz, v.noteRms * std::pow(10.f, (-18.f + 10.f * felt) / 20.f));
    const float pan = std::clamp(clamp01(pWidth) * (float)(pitch - 64) / 44.f, -1.f, 1.f), th = (pan + 1.f) * kPi / 4.f;
    v.panL = std::cos(th); v.panR = std::sin(th);
    v.level = v.stringRef + v.glassRef;
}

void FeltGlass::damp(Voice &v) {
    if (v.damped) return;
    v.damped = true;
    const float rd = decayR(0.15f, sr), rgd = decayR(0.6f, sr);
    for (int i = 0; i < v.nStr; ++i)
        if (v.sdr[i] > rd) { float s = rd / v.sdr[i]; v.scr[i] *= s; v.sci[i] *= s; v.sdr[i] = rd; }
    for (int i = 0; i < v.nGlass; ++i)
        if (v.gdr[i] > rgd) { float s = rgd / v.gdr[i]; v.gcr[i] *= s; v.gci[i] *= s; v.gdr[i] = rgd; }
    startNoise(v, 0.01f, 2.f * v.noiseHz, v.noteRms * 0.0316f * kDamperNoiseGain);
}

/// A short band-limited noise burst whose RMS starts at `rms`.
void FeltGlass::startNoise(Voice &v, float seconds, float hz, float rms) {
    const float fsr = (float)sr;
    v.noiseLeft = (int)(seconds * fsr); v.noiseAge = 0; v.noiseAttack = std::max(1, (int)(0.001f * fsr));
    // Uniform noise (RMS 0.577) through the band-pass and its low-pass keeps ≈ sqrt(π·f/(Q·sr))·0.8 of its RMS.
    const float keep = 0.577f * std::sqrt(kPi * hz / (1.2f * fsr)) * 0.8f;
    v.noiseAmp = rms / keep;
    v.noiseDecay = std::exp(-1.f / (seconds / 3.f * fsr));
    v.noiseFilter.setBandpass(hz, 1.2, sr);
    v.noiseLowpass.setCutoff(2.f * hz, sr);
}

void FeltGlass::noteOff(int note) {
    for (auto &v : voices)
        if (v.active && !v.fading && v.note == note && v.keyDown) { v.keyDown = false; if (!sustain) damp(v); }
}

void FeltGlass::setSustain(bool down) {
    if (down == sustain) return;
    sustain = down;
    if (down) {
        setSympDecay(3.f);
        sympGain.setTarget(1.f);
        sympActive = true;
    } else {
        setSympDecay(0.08f);
        sympGain.setTarget(0.f);
        for (auto &v : voices) if (v.active && !v.fading && !v.keyDown) damp(v);
    }
}

void FeltGlass::allNotesOff() {
    for (auto &v : voices) if (v.active) beginFade(v);
    sympGain.setTarget(0.f);
    setSympDecay(0.08f);
}

void FeltGlass::allSoundOff() {
    allNotesOff();
    reverb.clear();
}

void FeltGlass::retune() {
    ++retunes;
    const float fsr = (float)sr;
    for (auto &v : voices) {
        if (!v.active) continue;
        for (int i = 0; i < v.nStr; ++i) {
            float w0 = kTwoPi * v.shz[i] * fineRatio / fsr;
            v.scr[i] = v.sdr[i] * std::cos(w0); v.sci[i] = v.sdr[i] * std::sin(w0);
        }
        for (int i = 0; i < v.nGlass; ++i) {
            float w0 = kTwoPi * v.ghz[i] * fineRatio / fsr;
            v.gcr[i] = v.gdr[i] * std::cos(w0); v.gci[i] = v.gdr[i] * std::sin(w0);
        }
    }
    setSympDecay(sustain ? 3.f : 0.08f);
}

void FeltGlass::render(float *left, float *right, int frames) {
    int pos = 0;
    while (pos < frames) {
        int n = std::min(kSub, frames - pos);
        processBlock(left + pos, right + pos, n);
        pos += n;
    }
}

void FeltGlass::renderVoice(Voice &v, float *sL, float *sR, float *gL, float *gR, float *mono, int n) {
    v8 lane[kSub];
    float vs[kSub], vg[kSub];
    for (int t = 0; t < n; ++t) lane[t] = v8{};
    const int sc = v.nStr / 8;
    for (int c = 0; c < sc;) {
        if (v.strOn[c] && c + 1 < sc && v.strOn[c + 1]) {
            run2(v.sre + 8 * c, v.sim + 8 * c, v.scr + 8 * c, v.sci + 8 * c, lane, n); c += 2;
        } else {
            if (v.strOn[c]) run1(v.sre + 8 * c, v.sim + 8 * c, v.scr + 8 * c, v.sci + 8 * c, lane, n);
            ++c;
        }
    }
    for (int t = 0; t < n; ++t) vs[t] = hsum(lane[t]);
    if (v.attackPos < v.attackLen) {
        for (int t = 0; t < n && v.attackPos < v.attackLen; ++t, ++v.attackPos)
            vs[t] *= 0.5f - 0.5f * std::cos(kPi * (float)v.attackPos / (float)v.attackLen);
    }
    if (v.noiseLeft > 0) {
        for (int t = 0; t < n && v.noiseLeft > 0; ++t, --v.noiseLeft, ++v.noiseAge) {
            float env = v.noiseAge < v.noiseAttack ? (float)v.noiseAge / (float)v.noiseAttack : 1.f;
            float x = rng.bipolar() * v.noiseAmp * env;
            v.noiseAmp *= v.noiseDecay;
            vs[t] += v.noiseLowpass.process(v.noiseFilter.process(x));
        }
    }
    for (int t = 0; t < n; ++t) lane[t] = v8{};
    const int gc = v.nGlass / 8;
    if (gc == 2 && v.glassOn[0] && v.glassOn[1]) run2(v.gre, v.gim, v.gcr, v.gci, lane, n);
    else for (int c = 0; c < gc; ++c) if (v.glassOn[c]) run1(v.gre + 8 * c, v.gim + 8 * c, v.gcr + 8 * c, v.gci + 8 * c, lane, n);
    for (int t = 0; t < n; ++t) vg[t] = hsum(lane[t]);
    if (v.fading) {
        for (int t = 0; t < n; ++t) {
            vs[t] *= v.fadeGain; vg[t] *= v.fadeGain;
            v.fadeGain = std::max(0.f, v.fadeGain - v.fadeStep);
        }
        if (v.fadeGain <= 0.f) v.active = false;
    }
    for (int t = 0; t < n; ++t) {
        sL[t] += vs[t] * v.panL; sR[t] += vs[t] * v.panR;
        gL[t] += vg[t] * v.panL; gR[t] += vg[t] * v.panR;
        mono[t] += vs[t];
    }
}

void FeltGlass::renderSymp(const float *mono, float *sL, float *sR, int n) {
    v8 laneL[kSub], laneR[kSub];
    float x[kSub];
    const float scale = kSympIn * (1.f - sympR);
    for (int t = 0; t < n; ++t) { x[t] = mono[t] * scale * sympGain.next(); laneL[t] = v8{}; laneR[t] = v8{}; }
    for (int c = 0; c < kSymp / 8; ++c) {
        v8 r = ld8(yre + 8 * c), i = ld8(yim + 8 * c), cr = ld8(ycr + 8 * c), ci = ld8(yci + 8 * c);
        const v8 wl = ld8(yL + 8 * c), wr = ld8(yR + 8 * c);
        for (int t = 0; t < n; ++t) {
            v8 nr = r * cr - i * ci + x[t], ni = r * ci + i * cr;
            r = nr; i = ni;
            laneL[t] += ni * wl; laneR[t] += ni * wr;
        }
        st8(yre + 8 * c, r); st8(yim + 8 * c, i);
    }
    for (int t = 0; t < n; ++t) { sL[t] += kSympOut * hsum(laneL[t]); sR[t] += kSympOut * hsum(laneR[t]); }
}

void FeltGlass::housekeeping() {
    for (auto &v : voices) {
        if (!v.active) continue;
        const float floorS = std::max(1e-8f * v.stringRef, 1e-14f), floorG = std::max(1e-8f * v.glassRef, 1e-14f);
        float e = 0, eg = 0;
        bool any = false;
        for (int c = 0; c < v.nStr / 8; ++c) {
            if (!v.strOn[c]) continue;
            float ce = chunkEnergy(v.sre + 8 * c, v.sim + 8 * c);
            if (ce < floorS) {
                v.strOn[c] = false;
                std::fill(v.sre + 8 * c, v.sre + 8 * c + 8, 0.f); std::fill(v.sim + 8 * c, v.sim + 8 * c + 8, 0.f);
            } else { e += ce; any = true; }
        }
        for (int c = 0; c < v.nGlass / 8; ++c) {
            if (!v.glassOn[c]) continue;
            float ce = chunkEnergy(v.gre + 8 * c, v.gim + 8 * c);
            if (ce < floorG) {
                v.glassOn[c] = false;
                std::fill(v.gre + 8 * c, v.gre + 8 * c + 8, 0.f); std::fill(v.gim + 8 * c, v.gim + 8 * c + 8, 0.f);
            } else { eg += ce; any = true; }
        }
        float g = glassGain.value;
        v.level = e + eg * g * g;
        if (!any && v.noiseLeft <= 0) v.active = false;
    }
    if (sympActive && sympGain.target == 0.f && sympGain.value < 1e-4f) {
        float e = 0;
        for (int k = 0; k < kSymp; ++k) e += yre[k] * yre[k] + yim[k] * yim[k];
        if (e < 1e-14f) {
            sympActive = false;
            std::fill(yre, yre + kSymp, 0.f); std::fill(yim, yim + kSymp, 0.f);
        }
    }
}

void FeltGlass::processBlock(float *left, float *right, int n) {
    const float fsr = (float)sr;
    // Control-rate updates.
    for (int t = 0; t < n; ++t) { fine.next(); warmth.next(); space.next(); }
    if (std::fabs(fine.value - appliedCents) > 0.005f) {
        appliedCents = fine.value;
        fineRatio = std::exp2(appliedCents / 1200.f);
        retune();
    }
    const float wv = clamp01(warmth.value + 0.5f * (mWarmth - 0.5f));
    if (std::fabs(wv - appliedWarmth) > 1e-3f) {
        appliedWarmth = wv;
        for (int c = 0; c < 2; ++c) {
            highShelf[c].setHighShelf(3000.0, 3.0 - 9.0 * wv, sr);
            lowShelf[c].setLowShelf(200.0, 1.5 * wv, sr);
        }
    }
    const float sv = clamp01(space.value + 0.6f * (mSpace - 0.5f));
    if (std::fabs(sv - appliedSpace) > 2e-3f) {
        appliedSpace = sv;
        reverb.configure(0.05f + 0.5f * std::pow(sv, 1.5f), 0.55f, 12.f, 0.f);
        wet.setTarget(0.6f * sv);
    }

    float sL[kSub] = {}, sR[kSub] = {}, gL[kSub] = {}, gR[kSub] = {}, mono[kSub] = {};
    float dryL[kSub] = {}, dryR[kSub] = {};
    bool anyVoice = false;
    if (!idle) {
        for (auto &v : voices) {
            if (!v.active) continue;
            anyVoice = true;
            renderVoice(v, sL, sR, gL, gR, mono, n);
        }
        if (sympActive) renderSymp(mono, sL, sR, n);
        float peakAbs = 0;
        for (int t = 0; t < n; ++t) {
            float l = sL[t], r = sR[t];
            for (int b = 0; b < 4; ++b) { l = body[b][0].process(l); r = body[b][1].process(r); }
            float g = glassGain.next();
            l += g * gL[t]; r += g * gR[t];
            l = highShelf[0].process(lowShelf[0].process(l));
            r = highShelf[1].process(lowShelf[1].process(r));
            dryL[t] = l; dryR[t] = r;
            peakAbs = std::max(peakAbs, std::max(std::fabs(l), std::fabs(r)));
        }
        if (!anyVoice && !sympActive && peakAbs < 1e-6f) {
            idleSamples += n;
            if (idleSamples >= (int)(0.25f * fsr)) {
                idle = true;
                idleSamples = 0;
                for (auto &bq : body) { bq[0].clear(); bq[1].clear(); }
                for (int c = 0; c < 2; ++c) { highShelf[c].clear(); lowShelf[c].clear(); }
            }
        } else {
            idleSamples = 0;
        }
    } else {
        for (int t = 0; t < n; ++t) glassGain.next();
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
