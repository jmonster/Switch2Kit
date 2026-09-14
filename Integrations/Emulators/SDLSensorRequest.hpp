#pragma once
#include <SDL3/SDL.h>

namespace Switch2Kit {
/** An emulator consumer owns one request on its existing SDL gamepad. Multiple
 * settings/enumeration objects can refer to the SAME SDL object: one object's
 * destruction or disabled setting must not switch off another's active request.
 * Only the first/last request changes SDL sensor enablement. No new SDL instance. */
class SDLSensorRequest final {
public:
    ~SDLSensorRequest() { update(nullptr, false); }
    SDLSensorRequest() = default;
    SDLSensorRequest(const SDLSensorRequest&) = delete;
    SDLSensorRequest& operator=(const SDLSensorRequest&) = delete;
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
    static constexpr const char* key = "Switch2Kit.emulator.motion.requests";
    SDL_Gamepad* gamepad_{};
};
}
