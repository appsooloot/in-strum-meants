# DSP harness

Plain C++ checks for the header-only DSP cores. Run them on any machine with a C++17 compiler, no Swift needed:

```
g++ -std=c++17 -O2 -ISources/InStrumDSP Scripts/dsp-harness/core_test.cpp -o /tmp/core_test && /tmp/core_test
```

- `core_test.cpp` covers the vintage-synth core's additions (`Shaper`, `Unison`, `Glide`) and the shared arpeggiator (`Arp.hpp`). Sets 13 & 14, Task 1.

The XCTest suites remain the real tests and run in CI. These checks exist so DSP work can be measured locally between CI runs.
