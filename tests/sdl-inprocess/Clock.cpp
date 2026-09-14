#include "Clock.hpp"
#include "../../Integrations/SDL3/MotionClock.hpp"
#include <Switch2KitMotionProfile.h>
#include <cassert>
#include <limits>
#include <mutex>

namespace {
std::mutex mutex;
bool controlled = false;
Uint64 ticks = 0, elapsed = 0, continuous = 0, suspended = 0;
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
extern "C" Uint64 s2k_test_continuous_ns() noexcept {
    const std::lock_guard<std::mutex> lock(mutex);
    const auto now = controlled ? continuous + elapsed : Switch2Kit::Detail::continuousTimeNS();
    assert(suspended <= std::numeric_limits<Uint64>::max() - now);
    return now + suspended;
}
void TestClock::suspend(Uint64 nanoseconds) {
    const std::lock_guard<std::mutex> lock(mutex);
    assert(nanoseconds <= std::numeric_limits<Uint64>::max() - suspended);
    suspended += nanoseconds;
}
void TestClock::start() {
    const std::lock_guard<std::mutex> lock(mutex);
    assert(!controlled);
    ticks = SDL_GetTicksNS();
    receive = s2k_monotonic_time();
    continuous = Switch2Kit::Detail::continuousTimeNS();
    controlled = true;
}
void TestClock::advance(Uint64 nanoseconds) {
    const std::lock_guard<std::mutex> lock(mutex);
    if (!controlled) return;
    assert(nanoseconds <= std::numeric_limits<Uint64>::max() - ticks - elapsed);
    assert(nanoseconds <= std::numeric_limits<Uint64>::max() - continuous - elapsed - suspended);
    elapsed += nanoseconds;
}
