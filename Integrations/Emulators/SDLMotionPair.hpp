#pragma once
#include <Switch2KitSDL3.hpp>
#include <algorithm>
#include <array>
#include <cmath>
#include <optional>
#include <utility>

namespace Switch2Kit {
/** Pairs actual SDL sensor events, without converting raw counts or fusing
 * orientation. One pair is retained; every accepted pair is consumed once.
 * The host resets its OWN integrator when synchronize() or takeReset() returns
 * true. Poll synchronize(motionState(id)) even when no events arrive. */
class SDLMotionPair final {
public:
    struct Sample {
        Uint64 timestampNS{}, sequence{};
        double deltaSeconds{};
        std::array<float, 3> acceleration{}, angularVelocity{};
    };
    bool synchronize(const SDL3MotionState& state) {
        const bool usable = state.owned && state.status == SDL3MotionStatus::Active &&
                            state.epoch && state.validSinceNS && state.validSinceSequence &&
                            state.timestampNS > state.validSinceNS;
        const bool changed = usable != usable_ || state.epoch != epoch_ ||
                             state.validSinceNS != floor_;
        if (changed) {
            usable_ = usable; epoch_ = state.epoch; floor_ = state.validSinceNS;
            last_ = floor_; lastSequence_ = state.validSinceSequence;
            pending_ = 0; mask_ = 0; reset_ = false;
        }
        time_ = state.timestampNS; sequence_ = state.sequence;
        return changed;
    }
    /** First synchronize with motionStateAt(id, event.sensor_timestamp).
     * event.timestamp is delivery time: intentionally NOT used for integration.
     * sensor_timestamp is mapped RECEIVE time, not a hardware sampling clock.
     * Never pass an SDL snapshot/poll of cached sensor data to this method. */
    std::optional<Sample> consume(const SDL_GamepadSensorEvent& event) {
        const unsigned bit = event.sensor == SDL_SENSOR_ACCEL ? 1 : event.sensor == SDL_SENSOR_GYRO ? 2 : 0;
        const auto time = event.sensor_timestamp;
        if (!usable_ || !bit || time != time_ || time <= last_ || sequence_ <= lastSequence_) return {};
        // Detect a missing complete report, a missing half, or excessive receive
        // separation. The current report rearms; it never integrates across loss.
        if (sequence_ - lastSequence_ != 1 || (pending_ && time != pending_) || time - last_ > 100000000) {
            breakAt(time); return {};
        }
        for (const float value : event.data) if (!std::isfinite(value)) { breakAt(time); return {}; }
        if (time != pending_) { pending_ = time; mask_ = 0; }
        if (mask_ & bit) return {};
        auto& values = bit == 1 ? acceleration_ : angularVelocity_;
        std::copy_n(event.data, 3, values.begin());
        mask_ |= bit;
        if (mask_ != 3) return {};
        mask_ = 0; pending_ = 0;
        const auto delta = time - last_;
        last_ = time; lastSequence_ = sequence_;
        return Sample{time, sequence_, delta / 1e9, acceleration_, angularVelocity_};
    }
    bool takeReset() { return std::exchange(reset_, false); }
private:
    void breakAt(Uint64 time) {
        reset_ = true; last_ = time; lastSequence_ = sequence_; pending_ = 0; mask_ = 0;
    }
    bool usable_{}, reset_{};
    Uint64 epoch_{}, floor_{}, time_{}, sequence_{}, last_{}, lastSequence_{}, pending_{};
    unsigned mask_{};
    std::array<float, 3> acceleration_{}, angularVelocity_{};
};
}
