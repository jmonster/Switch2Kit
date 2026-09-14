#pragma once
// Private suspend-aware freshness clock. This is not a report/sensor timestamp
// and its epoch is never compared with Swift uptime or SDL's clock epoch.
#include <cstdint>
#include <limits>
#if defined(__APPLE__)
#include <mach/mach_time.h>
#elif defined(__linux__)
#include <time.h>
#endif

namespace Switch2Kit::Detail {
inline std::uint64_t scaledTicksNS(std::uint64_t ticks, std::uint32_t numer,
                                   std::uint32_t denom) noexcept {
    constexpr auto limit = static_cast<std::uint64_t>(std::numeric_limits<std::int64_t>::max());
    if (!numer || !denom) return 0;
    const auto whole = ticks / denom;
    if (whole > limit / numer) return 0;
    const auto base = whole * numer;
    // Both factors are at most UINT32_MAX, so this product fits UINT64.
    const auto tail = (ticks % denom) * numer / denom;
    return tail > limit - base ? 0 : base + tail;
}
inline std::uint64_t continuousTimeNS() noexcept {
#if defined(__APPLE__)
    // Unlike mach_absolute_time (used by the pinned SDL), this advances in sleep.
    static const auto scale = [] {
        mach_timebase_info_data_t value{};
        if (mach_timebase_info(&value) != 0) return mach_timebase_info_data_t{};
        return value;
    }();
    return scaledTicksNS(mach_continuous_time(), scale.numer, scale.denom);
#elif defined(__linux__) && defined(CLOCK_BOOTTIME)
    // Portable native-consumer fixtures also distinguish suspend from awake time.
    timespec value{};
    constexpr std::uint64_t second = 1000000000;
    constexpr auto limit = static_cast<std::uint64_t>(std::numeric_limits<std::int64_t>::max());
    if (clock_gettime(CLOCK_BOOTTIME, &value) != 0 || value.tv_sec < 0 ||
        value.tv_nsec < 0 || static_cast<std::uint64_t>(value.tv_nsec) >= second) return 0;
    const auto seconds = static_cast<std::uint64_t>(value.tv_sec);
    if (seconds > limit / second) return 0;
    const auto base = seconds * second;
    const auto tail = static_cast<std::uint64_t>(value.tv_nsec);
    return tail > limit - base ? 0 : base + tail;
#else
    return 0; // Unsupported freshness clock: fail closed for motion, not controls.
#endif
}
}
