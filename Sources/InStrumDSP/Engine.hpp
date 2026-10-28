// The interface every built-in instrument engine implements. All calls happen on the render thread.
#pragma once

namespace isd {

class Engine {
public:
    virtual ~Engine() = default;
    /// `snap` jumps straight to the value (used before the first render).
    virtual void setParam(int address, float value, bool snap) = 0;
    virtual void noteOn(int note, int velocity) = 0;
    virtual void noteOff(int note) = 0;
    virtual void setSustain(bool down) = 0;
    /// Every note fades out over 20 ms; the reverb tail continues.
    virtual void allNotesOff() = 0;
    /// As allNotesOff, and the reverb is cleared.
    virtual void allSoundOff() = 0;
    /// Overwrites the buffers.
    virtual void render(float *left, float *right, int frames) = 0;
    virtual int activeVoices() const = 0;
    /// Internal counters for tests (see ISDDebugCount); engines without one return 0.
    virtual int debugCount(int which) const { (void)which; return 0; }
};

} // namespace isd
