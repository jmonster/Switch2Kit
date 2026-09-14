#pragma once
#include "SDLMotionPair.hpp"
#include "input/motion/MotionHandler.h"

namespace Switch2Kit {
/** A Cemu controller owns one request on its existing SDL gamepad. Multiple
 * settings/enumeration objects can refer to the SAME SDL object: one object's
 * destruction or disabled setting must not switch off another's active request.
 * Only the first/last request changes SDL sensor enablement. No new SDL instance. */
class CemuSensorPolicy final {
public:
    ~CemuSensorPolicy() { update(nullptr, false); }
    CemuSensorPolicy() = default;
    CemuSensorPolicy(const CemuSensorPolicy&) = delete;
    CemuSensorPolicy& operator=(const CemuSensorPolicy&) = delete;
    bool update(SDL_Gamepad* gamepad, bool enabled) {
        struct Lock { Lock() { SDL_LockJoysticks(); } ~Lock() { SDL_UnlockJoysticks(); } } lock;
        if (gamepad == gamepad_ && enabled && gamepad_ && SDL_GamepadConnected(gamepad_)) return true;
        release();
        if (!enabled) return true;
        if (!gamepad || !SDL_GamepadConnected(gamepad) ||
            !SDL_GamepadHasSensor(gamepad, SDL_SENSOR_ACCEL) || !SDL_GamepadHasSensor(gamepad, SDL_SENSOR_GYRO)) return false;
        const auto properties = SDL_GetJoystickProperties(SDL_GetGamepadJoystick(gamepad));
        const auto count = SDL_GetNumberProperty(properties, key, 0);
        if (count < 0 || count >= 64) return false;
        gamepad_ = SDL_OpenGamepad(SDL_GetGamepadID(gamepad)); // Retain the SAME object until release.
        if (!gamepad_) return false;
        if (!SDL_SetNumberProperty(properties, key, count + 1)) {
            SDL_CloseGamepad(gamepad_); gamepad_ = nullptr; return false;
        }
        if (count) return true;
        // Aggregate off/on is deliberate: even a rapid last-disable/first-enable
        // must break the adapter epoch before any downstream integration resumes.
        SDL_SetGamepadSensorEnabled(gamepad_, SDL_SENSOR_ACCEL, false);
        SDL_SetGamepadSensorEnabled(gamepad_, SDL_SENSOR_GYRO, false);
        if (SDL_SetGamepadSensorEnabled(gamepad_, SDL_SENSOR_ACCEL, true) &&
            SDL_SetGamepadSensorEnabled(gamepad_, SDL_SENSOR_GYRO, true)) return true;
        release(); return false;
    }
private:
    void release() {
        if (!gamepad_) return;
        const auto properties = SDL_GetJoystickProperties(SDL_GetGamepadJoystick(gamepad_));
        const auto count = SDL_GetNumberProperty(properties, key, 0);
        if (count <= 1) {
            SDL_SetGamepadSensorEnabled(gamepad_, SDL_SENSOR_ACCEL, false);
            SDL_SetGamepadSensorEnabled(gamepad_, SDL_SENSOR_GYRO, false);
            SDL_ClearProperty(properties, key);
        } else SDL_SetNumberProperty(properties, key, count - 1);
        SDL_CloseGamepad(gamepad_); gamepad_ = nullptr;
    }
    static constexpr const char* key = "Switch2Kit.Cemu.motion.requests";
    SDL_Gamepad* gamepad_{};
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
