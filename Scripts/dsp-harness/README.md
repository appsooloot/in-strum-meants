# DSP harness

Plain C++ checks for the header-only DSP cores. Run them on any machine with a C++17 compiler, no Swift needed:

```
g++ -std=c++17 -O2 -ISources/InStrumDSP Scripts/dsp-harness/core_test.cpp -o /tmp/core_test && /tmp/core_test
```

- `core_test.cpp` covers the vintage-synth core's additions (`Shaper`, `Unison`, `Glide`) and the shared arpeggiator (`Arp.hpp`). Sets 13 & 14, Task 1.
- `magma_test.cpp` and `brass_test.cpp` render Magma Bass and Replicant Brass through the C API (`harness.hpp`) and mirror their XCTest suites. Build the library first:

```
mkdir -p /tmp/isd && for f in Sources/InStrumDSP/*.cpp; do g++ -std=c++17 -O2 -c -ISources/InStrumDSP -ISources/InStrumDSP/include $f -o /tmp/isd/$(basename $f .cpp).o; done
ar rcs /tmp/isd/libisd.a /tmp/isd/*.o
g++ -std=c++17 -O2 -ISources/InStrumDSP/include Scripts/dsp-harness/magma_test.cpp /tmp/isd/libisd.a -o /tmp/magma_test && /tmp/magma_test
```

Rebuild every object after a header changes a class's size; a stale object corrupts the heap.

The XCTest suites remain the real tests and run in CI. These checks exist so DSP work can be measured locally between CI runs.
