#pragma once
#include "SDLMotionPair.hpp"
#include "SDLSensorRequest.hpp"
#include "input/motion/MotionHandler.h"

namespace Switch2Kit {
// Preserve the Cemu-facing name while sharing enablement ownership with Dolphin.
class CemuSensorPolicy final {
public:
    bool update(SDL_Gamepad* gamepad, bool enabled) { return request_.update(gamepad, enabled); }
private:
    SDLSensorRequest request_;
};
/** Cemu-specific boundary into its existing Mahony/Wii U processing. The caller
 * owns synchronization; no worker, protocol, sensor calibration or new fusion
 * algorithm is introduced. Both sensors must describe the same fresh report. */
class CemuMotion final {
public:
    void synchronize(const SDL3MotionState& state) {
        if (pair_.synchronize(state)) resetProcessor();
    }
    void consume(const SDL3MotionState& state, const SDL_GamepadSensorEvent& event) {
        synchronize(state);
        const auto sample = pair_.consume(event);
        if (pair_.takeReset()) resetProcessor();
        if (!sample) return;
        const auto& a = sample->acceleration;
        const auto& g = sample->angularVelocity;
        // Preserve Cemu's SDL-to-Wii-U frame conversion exactly once. Its
        // handler expects acceleration in standard g and gyro in rad/s.
        // This replaces the legacy 9.81 approximation only for calibrated input.
        constexpr float gravity = 9.80665f;
        handler_.processMotionSample(static_cast<float>(sample->deltaSeconds),
            g[0], -g[1], -g[2], -a[0] / gravity, a[1] / gravity, a[2] / gravity);
        data_ = handler_.getMotionSample(); active_ = true;
    }
    MotionSample snapshot() const { return data_; }
    bool active() const { return active_; }
    std::optional<MotionSample> availableSample() const { return active_ ? std::optional{data_} : std::nullopt; }
private:
    void resetProcessor() { handler_ = WiiUMotionHandler{}; data_ = MotionSample{}; active_ = false; }
    SDLMotionPair pair_;
    WiiUMotionHandler handler_;
    MotionSample data_;
    bool active_ = false;
};
}
