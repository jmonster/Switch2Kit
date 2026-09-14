#include "Clock.hpp"
#include <Switch2KitMotionProfile.h>
#include <cassert>
#include <limits>
#include <mutex>

namespace {
std::mutex mutex;
bool controlled = false;
Uint64 ticks = 0, elapsed = 0;
double receive = 0;
}
extern "C" Uint64 SDLCALL s2k_test_ticks_ns() {
    const std::lock_guard<std::mutex> lock(mutex);
    return controlled ? ticks + elapsed : SDL_GetTicksNS();
}
extern "C" double s2k_test_monotonic_time() {
    const std::lock_guard<std::mutex> lock(mutex);
    return controlled ? receive + static_cast<double>(elapsed) / 1e9 : s2k_monotonic_time();
}
void TestClock::start() {
    const std::lock_guard<std::mutex> lock(mutex);
    assert(!controlled);
    ticks = SDL_GetTicksNS();
    receive = s2k_monotonic_time();
    controlled = true;
}
void TestClock::advance(Uint64 nanoseconds) {
    const std::lock_guard<std::mutex> lock(mutex);
    if (!controlled) return;
    assert(nanoseconds <= std::numeric_limits<Uint64>::max() - ticks - elapsed);
    elapsed += nanoseconds;
}
