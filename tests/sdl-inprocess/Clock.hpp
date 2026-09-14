#pragma once
#include <SDL3/SDL.h>

// Only the test copy of the production adapter redirects its two clock reads.
// SDL itself and the Swift engine/C ABI remain real. Initially these forward to
// the real clocks, so the first sensor payload checks also test clock correlation.
extern "C" Uint64 SDLCALL s2k_test_ticks_ns();
extern "C" double s2k_test_monotonic_time();
namespace TestClock {
void start();
void advance(Uint64 nanoseconds);
}
