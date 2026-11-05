// The shared arpeggiator (Sets 13 & 14, spec §4.4 of docs/superpowers/specs/2026-11-05-fire-and-neon-design.md).
// Any engine can run one: it turns held keys into a stream of timed note-ons and note-offs on the sample clock.
// Header-only, no allocation (fixed arrays), deterministic per seed.
//
// API
//   prepare(sampleRate, seed)
//   setMode(Arp::Mode)            Off, Up, Down, UpDown (no repeated ends), Played (as pressed; keys pressed
//                                 within 30 ms of each other go low to high), Random (seeded, never the same note
//                                 twice in a row when there is a choice).
//   setRate(beatsPerStep)         a step's length in quarter notes: 1 (1/4), 0.5 (1/8), 1/3 (1/8T), 0.25 (1/16),
//                                 1/6 (1/16T), 0.125 (1/32). rateFromIndex(i) maps the engines' 0…5 menu to these.
//   setOctaves(1…3)               the pattern repeats an octave up (and two).
//   setGate(0.1…1)                how much of a step each note sounds.
//   setSwing(0…0.5)               delays every second step by swing × 2/3 of a step (0.5: a third of a step).
//   setHold(bool)                 latch: letting go keeps the pattern; the next key pressed after all keys are up
//                                 starts a new one.
//   setTempo(bpm)                 read at each step, so a tempo change lands on the next step.
//   keyDown(note, velocity, clock) / keyUp(note, clock)
//   reset()                       panic: no notes, no clock; the next key starts a fresh grid on its own sample.
//   poll(clock, event)            call at the start of each sub-block: returns true (and fills `event`) for each
//                                 event due at or before `clock`; call again until it returns false.
//   samplesToNext(clock)          how far the engine may render before the next event (≥ 1).
//   running()                     a pattern is playing or a step's note is still sounding.
// A phrase begins on the sample of its first key: the first step plays there. After the pattern empties, the grid
// keeps its place for 2 s (so a quick change of chord stays in time), then the next key starts a fresh grid.
#pragma once
#include "DSPCommon.hpp"
#include <algorithm>
#include <cmath>
#include <cstdint>

namespace isd {

struct Arp {
    enum Mode { Off = 0, Up, Down, UpDown, Played, Random };
    struct Event { int note = 0, velocity = 0; bool on = false; };

    static constexpr int kMaxKeys = 32, kMaxOrder = kMaxKeys * 3 * 2;
    static constexpr double kGroupWindow = 0.03, kPhraseGap = 2.0;

    static float rateFromIndex(int i) {
        static const float rates[6] = {1.f, 0.5f, 1.f / 3.f, 0.25f, 1.f / 6.f, 0.125f};
        return rates[std::clamp(i, 0, 5)];
    }

    void prepare(double sampleRate, uint64_t seed = 0xA4B5C6D7E8F9ULL) { sr = sampleRate; rng = FastRandom(seed); reset(); }
    void setMode(Mode m) { mode = m; }
    void setRate(float beatsPerStep) { rate = std::max(beatsPerStep, 1.f / 32.f); }
    void setOctaves(int n) { octaves = std::clamp(n, 1, 3); }
    void setGate(float g) { gate = std::clamp(g, 0.1f, 1.f); }
    void setSwing(float s) { swing = std::clamp(s, 0.f, 0.5f); }
    void setHold(bool h) {
        if (hold && !h) {   // unlatching: only the keys still down stay
            int k = 0;
            for (int i = 0; i < count; ++i) if (down[keys[i]]) { keys[k] = keys[i]; vel[k] = vel[i]; ++k; }
            count = k;
        }
        hold = h;
    }
    void setTempo(float bpm) { tempo = std::clamp(bpm, 20.f, 300.f); }
    bool enabled() const { return mode != Off; }

    void keyDown(int note, int velocity, int64_t clock) {
        note &= 127;
        if (hold && downCount == 0) count = 0;   // a new chord after the last was latched replaces it
        if (!down[note]) { down[note] = true; ++downCount; }
        for (int i = 0; i < count; ++i) if (keys[i] == note) { vel[i] = velocity; return; }
        if (count >= kMaxKeys) return;
        const int64_t window = (int64_t)std::llround(kGroupWindow * sr);
        int at = count;
        if (groupStart < count && clock - groupLatest <= window) {
            at = groupStart;
            while (at < count && keys[at] < note) ++at;
        } else {
            groupStart = count;
        }
        for (int i = count; i > at; --i) { keys[i] = keys[i - 1]; vel[i] = vel[i - 1]; }
        keys[at] = note; vel[at] = velocity; ++count;
        groupLatest = clock;
    }
    void keyUp(int note, int64_t) {
        note &= 127;
        if (down[note]) { down[note] = false; --downCount; }
        if (hold) return;
        for (int i = 0; i < count; ++i) if (keys[i] == note) {
            for (int j = i + 1; j < count; ++j) { keys[j - 1] = keys[j]; vel[j - 1] = vel[j]; }
            --count;
            if (i < groupStart) --groupStart;
            return;
        }
    }
    void reset() {
        count = groupStart = downCount = 0;
        for (auto &d : down) d = false;
        clockRunning = false;
        sounding = -1;
        position = -1;
        stepIndex = 0;
        lastRandom = -1;
    }

    bool running() const { return clockRunning || sounding >= 0; }

    bool poll(int64_t clock, Event &e) {
        // A step's note lets go at the end of its gate (before anything else due on the same sample).
        if (sounding >= 0 && clock >= offAt) {
            e = {sounding, 0, false};
            sounding = -1;
            return true;
        }
        const bool playable = enabled() && count > 0;
        if (!clockRunning) {
            if (!playable) return false;
            clockRunning = true;
            gridStart = (double)clock;
            stepIndex = 0;
            position = -1;
            nextStep = straightNext = gridStart;
            lastPlayed = clock;
        }
        if ((double)clock < nextStep - 0.5) return false;
        const double length = stepSamples();
        if (!playable) {
            if ((double)(clock - lastPlayed) >= kPhraseGap * sr) { clockRunning = false; return false; }
            advanceGrid(clock, length);
            return false;
        }
        if (sounding >= 0) {   // the last step's note is still on (gate 1): let it go first, on this sample
            e = {sounding, 0, false};
            sounding = -1;
            return true;
        }
        const int n = buildOrder();
        int idx;
        if (mode == Random) {
            idx = (int)(rng.uniform() * (float)n);
            if (idx >= n) idx = n - 1;
            if (n > 1 && idx == lastRandom) idx = (idx + 1 + (int)(rng.uniform() * (float)(n - 1))) % n;
            lastRandom = idx;
        } else {
            idx = (position + 1) % n;
        }
        position = idx;
        const int note = std::clamp(order[idx], 0, 127);
        e = {note, orderVel[idx], true};
        sounding = note;
        offAt = clock + std::max<int64_t>(1, (int64_t)std::llround(gate * length) - (gate >= 1.f ? 1 : 0));
        lastPlayed = clock;
        advanceGrid(clock, length);
        return true;
    }

    int samplesToNext(int64_t clock) const {
        int64_t n = 1 << 20;
        if (clockRunning) n = std::min<int64_t>(n, (int64_t)std::floor(nextStep + 0.5) - clock);
        if (sounding >= 0) n = std::min<int64_t>(n, offAt - clock);
        return (int)std::max<int64_t>(1, n);
    }

    double stepSamples() const { return 60.0 / (double)tempo * (double)rate * sr; }

private:
    /// Moves to the next step. The grid itself stays straight (`straightNext`); swing only delays every second
    /// step from its straight place.
    void advanceGrid(int64_t clock, double length) {
        ++stepIndex;
        straightNext += length;
        while (straightNext < (double)clock + 0.5) { straightNext += length; ++stepIndex; }
        nextStep = straightNext + ((stepIndex & 1) ? swingOffset(length) : 0.0);
    }
    double swingOffset(double length) const { return (double)swing * (2.0 / 3.0) * length; }

    /// The pattern for the held keys in the current mode, octaves included; returns its length (≥ 1).
    int buildOrder() {
        int base[kMaxKeys], bv[kMaxKeys];
        for (int i = 0; i < count; ++i) { base[i] = keys[i]; bv[i] = vel[i]; }
        if (mode == Up || mode == Down || mode == UpDown || mode == Random) {
            for (int i = 1; i < count; ++i) {   // insertion sort, low to high
                int k = base[i], v = bv[i], j = i - 1;
                while (j >= 0 && base[j] > k) { base[j + 1] = base[j]; bv[j + 1] = bv[j]; --j; }
                base[j + 1] = k; bv[j + 1] = v;
            }
        }
        int n = 0;
        for (int o = 0; o < octaves; ++o)
            for (int i = 0; i < count; ++i) { order[n] = base[i] + 12 * o; orderVel[n] = bv[i]; ++n; }
        if (mode == Down) {
            std::reverse(order, order + n);
            std::reverse(orderVel, orderVel + n);
        } else if (mode == UpDown && n > 2) {
            for (int i = n - 2; i >= 1; --i) { order[n + (n - 2 - i)] = order[i]; orderVel[n + (n - 2 - i)] = orderVel[i]; }
            n = 2 * n - 2;
        }
        return std::max(n, 1);
    }

    double sr = 48000.0;
    FastRandom rng;
    Mode mode = Played;
    float rate = 0.25f, gate = 0.6f, swing = 0.f, tempo = 120.f;
    int octaves = 1;
    bool hold = false;

    int keys[kMaxKeys] = {}, vel[kMaxKeys] = {};
    int count = 0, groupStart = 0, downCount = 0;
    int64_t groupLatest = 0;
    bool down[128] = {};

    int order[kMaxOrder] = {}, orderVel[kMaxOrder] = {};
    bool clockRunning = false;
    double gridStart = 0.0, nextStep = 0.0, straightNext = 0.0;
    int stepIndex = 0, position = -1, lastRandom = -1;
    int sounding = -1;
    int64_t offAt = 0, lastPlayed = 0;
};

} // namespace isd
