#pragma once
#include <Switch2KitSDL3.hpp>
#include <array>
#include <algorithm>
#include <mutex>
#include "HostFile.hpp"
#include <map>
#include <string>

namespace Switch2Kit {
/** Application-owned session for an SDL emulator. There is no process singleton.
 * On macOS, the first call allocating a context (initialize, policy selection,
 * start or discover) must run on the main thread. pump belongs to the emulator's
 * input loop. Other calls are serialized; stop before SDL quits.
 * The library remains loaded until process exit. This owner never starts a worker.
 */
class SDLHost final {
public:
    /** Takes ownership of an optional existing context, useful for replay tests. */
    explicit SDLHost(S2KContext* context = nullptr) : context_(context) {}
    ~SDLHost() { shutdown(); }
    SDLHost(const SDLHost&) = delete;
    SDLHost& operator=(const SDLHost&) = delete;

    /** Allocate the context without opening Bluetooth. Main-thread first call. */
    S2KResult initialize() {
        Guard lock(mutex_);
        if (context_) return S2K_OK;
        context_ = s2k_create(nullptr, &error_);
        return error_;
    }
    /** Select continuous or on-demand discovery without starting support.
     * Hosts own consent and persistence. Disabling preserves ready controllers;
     * a stopped host remains stopped. BUSY is returned while stop is finishing. */
    S2KResult setAutomaticDiscovery(bool enabled) {
        if (const auto result = initialize(); result != S2K_OK) return result;
        Guard lock(mutex_);
        return error_ = s2k_set_automatic_discovery(context_, enabled ? 1u : 0u);
    }
    /** Start with the selected policy, without opening a finite discovery window.
     * Call once after saved consent, or as an explicit user action, not per pump. */
    S2KResult start() {
        if (const auto result = initialize(); result != S2K_OK) return result;
        Guard lock(mutex_);
        return error_ = s2k_start(context_);
    }
    /** Explicit settings action: start support and open one bounded scan window. */
    S2KResult discover(double seconds = 60.0) {
        if (const auto result = initialize(); result != S2K_OK) return result;
        Guard lock(mutex_);
        if ((error_ = s2k_start(context_)) != S2K_OK) return error_;
        return error_ = s2k_discover(context_, seconds);
    }
    /** Call from the existing live input loop. Does not poll SDL's event queue. */
    S2KResult pump(bool active = true) {
        Guard lock(mutex_);
        if (!context_) return S2K_OK;
        if (!(SDL_WasInit(SDL_INIT_GAMEPAD) & SDL_INIT_GAMEPAD)) return S2K_OK;
        if (!adapter_) {
            adapter_ = std::make_unique<SDL3Adapter>(context_);
            for (const auto& [id, profile] : profiles_) {
                (void)id;
                if ((error_ = adapter_->installMotionProfile(profile)) != S2K_OK) return error_;
            }
        }
        return error_ = adapter_->pump(active);
    }
    /** Retire native sessions and detach only this host's virtual SDL devices.
     * Call before SDL_Quit; context allocation remains available for restart. */
    S2KResult stop() {
        Guard lock(mutex_);
        adapter_.reset();
        return error_ = context_ ? s2k_stop(context_) : S2K_OK;
    }
    /** Idempotent final ownership boundary. No callback can enter host code. */
    void shutdown() {
        Guard lock(mutex_);
        adapter_.reset();
        if (context_) { s2k_destroy(context_); context_ = nullptr; }
    }
    /** Immediate status for controller settings; this does not consume input. */
    S2KSnapshot snapshot() {
        Guard lock(mutex_);
        S2KSnapshot value{};
        if (context_) {
            uint32_t count{}, flags{};
            error_ = s2k_read(context_, nullptr, 0, sizeof(S2KEvent), &count,
                              &value, sizeof(value), &flags);
        }
        return value;
    }
    /** Persistent physical key for host profiles. Empty for unrelated SDL devices.
     * A key is not a controller name and must not be sent to diagnostic logging. */
    std::string identity(SDL_JoystickID instance) {
        Guard lock(mutex_);
        S2KID id{};
        if (!adapter_ || !adapter_->identity(instance, &id, nullptr)) return {};
        return physicalKey(id);
    }
    /** Resolve a saved physical key; never fall back to a different controller. */
    SDL_JoystickID instance(const std::string& identity) {
        S2KID id{};
        if (!parseKey(identity, id)) return 0;
        Guard lock(mutex_);
        return adapter_ ? adapter_->instance(id) : 0;
    }

    /** Explicit user-selected file import. Read at most 4097 bytes outside the SDL
     * and host locks; no default directory, background watcher or library preference
     * store exists. The file chooses a physical device, never a player/SDL ordinal.
     * Hosts may persist the chosen path in their OWN settings and explicitly reload.
     * A malformed/oversized/unreadable file leaves the previous profile untouched. */
    S2KResult loadMotionProfile(const std::string& path, const std::string& expectedPhysicalKey = {},
                                S2KID* loadedPhysical = nullptr) {
        std::string bytes;
        if (readHostFile(path, S2K_MOTION_PROFILE_MAX_BYTES, bytes) != HostFileResult::OK)
            return S2K_INVALID_ARGUMENT;
        S2KMotionProfile profile{};
        const auto result = s2k_decode_motion_profile(reinterpret_cast<const uint8_t*>(bytes.data()), static_cast<uint32_t>(bytes.size()), &profile, sizeof(profile));
        if (result != S2K_OK) return result;
        if (!expectedPhysicalKey.empty() && physicalKey(profile.device) != expectedPhysicalKey)
            return S2K_INVALID_ARGUMENT;
        const auto installed = installMotionProfile(profile);
        if (installed == S2K_OK && loadedPhysical) *loadedPhysical = profile.device;
        return installed;
    }
    /** Host-owned bounded in-memory selection, also usable without a filesystem. */
    S2KResult installMotionProfile(const S2KMotionProfile& profile) {
        S2KMotionCalibration checked{};
        if (const auto result = s2k_motion_profile_calibration(&profile, nullptr, &checked, sizeof(checked)); result != S2K_OK)
            return result;
        Guard lock(mutex_);
        std::array<uint8_t, 16> id{}; std::copy_n(profile.device.bytes, 16, id.begin());
        if (!profiles_.count(id) && profiles_.size() >= S2K_MAX_CONTROLLERS) return S2K_QUEUE_FULL;
        if (adapter_) if (const auto result = adapter_->installMotionProfile(profile); result != S2K_OK) return result;
        profiles_[id] = profile;
        return S2K_OK;
    }
    /** Explicit removal. Controller input/assignment remains available; sensor
     * topology changes on the next pump. No caller-owned file is deleted. */
    void removeMotionProfile(const S2KID& physical) {
        Guard lock(mutex_);
        std::array<uint8_t, 16> id{}; std::copy_n(physical.bytes, 16, id.begin());
        profiles_.erase(id);
        if (adapter_) adapter_->removeMotionProfile(physical);
    }
    void removeMotionProfile(const std::string& physicalKey) {
        S2KID id{};
        if (parseKey(physicalKey, id)) removeMotionProfile(id);
    }
    void clearMotionProfiles() {
        Guard lock(mutex_);
        if (adapter_) for (const auto& [id, profile] : profiles_) { (void)id; adapter_->removeMotionProfile(profile.device); }
        profiles_.clear();
    }
    /** Status from the actual SDL device, not a presentation snapshot. */
    SDL3MotionState motionState(const S2KID& physical) {
        Guard lock(mutex_);
        return adapter_ ? SDL3Adapter::motionState(adapter_->instance(physical)) : SDL3MotionState{};
    }
    /** Explicit feedback action, separate from SDL's cancellable game effects. */
    S2KResult feedback(SDL_JoystickID instance, double intensity = 0.5) {
        Guard lock(mutex_);
        S2KID id{}, connection{};
        if (!adapter_ || !adapter_->identity(instance, &id, &connection)) return S2K_NOT_READY;
        return error_ = s2k_play_feedback(context_, &id, &connection, intensity);
    }
    /** Physical key encoding shared by host-owned persistence. Not for logging. */
    static std::string physicalKey(const S2KID& id) {
        static constexpr char hex[] = "0123456789abcdef";
        std::string result = "s2k:";
        for (const auto b : id.bytes) { result += hex[b >> 4]; result += hex[b & 15]; }
        return result;
    }
private:
    static bool parseKey(const std::string& identity, S2KID& id) {
        if (identity.size() != 36 || identity.compare(0, 4, "s2k:") != 0) return false;
        const auto digit = [](char c) -> int {
            if (c >= '0' && c <= '9') return c - '0';
            if (c >= 'a' && c <= 'f') return c - 'a' + 10;
            return -1;
        };
        for (size_t i = 0; i != 16; ++i) {
            const auto a = digit(identity[4 + 2 * i]), b = digit(identity[5 + 2 * i]);
            if (a < 0 || b < 0) return false;
            id.bytes[i] = static_cast<uint8_t>(a * 16 + b);
        }
        return true;
    }
    // SDL callbacks take SDL's joystick lock first. Keep the same order for all
    // accesses so an emulator's enumeration thread cannot deadlock its input loop.
    struct Guard {
        explicit Guard(std::mutex& hostMutex) : mutex(hostMutex) { SDL_LockJoysticks(); mutex.lock(); }
        ~Guard() { mutex.unlock(); SDL_UnlockJoysticks(); }
        std::mutex& mutex;
    };
    std::mutex mutex_;
    S2KContext* context_{};
    std::unique_ptr<SDL3Adapter> adapter_;
    S2KResult error_ = S2K_OK;
    std::map<std::array<uint8_t, 16>, S2KMotionProfile> profiles_;
};
}
