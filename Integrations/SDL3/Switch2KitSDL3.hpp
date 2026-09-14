#pragma once
#include <Switch2KitC.h>
#include <Switch2KitMotionProfile.h>
#include <SDL3/SDL.h>
#include <memory>

namespace Switch2Kit {
/** In-process SDL3 input adapter. The host owns context and SDL initialization.
 * Construct after SDL_INIT_GAMEPAD; destroy BEFORE s2k_destroy/SDL_Quit.
 * Call pump on one host input thread, before processing its SDL events. Other
 * threads may invoke ordinary SDL rumble APIs. Do not call pump reentrantly from
 * an SDL event watch/filter or joystick callback. No controller protocol lives here.
 */
enum class SDL3MotionStatus { UnavailableProfile, Disabled, Waiting, Active, InvalidCalibration };
/** Metadata, not another measurement channel. A host must reset its motion processor
 * when epoch changes or status is not Active. Discard queued sensor events older
 * than validSinceNS; a snapshot and a previous epoch are never fresh measurements.
 * Sensor timestamps are correlated HOST RECEIVE times in SDL_GetTicksNS's clock,
 * not hardware sampling timestamps. The adapter never estimates a hardware rate. */
struct SDL3MotionState {
    bool owned = false;
    SDL3MotionStatus status = SDL3MotionStatus::UnavailableProfile;
    Uint64 epoch{}, validSinceNS{}, timestampNS{}, sequence{}, validSinceSequence{};
};

class SDL3Adapter final {
public:
    /** Borrows a live context. Does not start Bluetooth or discovery. */
    explicit SDL3Adapter(S2KContext* context);
    ~SDL3Adapter();
    SDL3Adapter(const SDL3Adapter&) = delete;
    SDL3Adapter& operator=(const SDL3Adapter&) = delete;
    /** Apply at most 256 input events. Each transition crosses an SDL update
     * boundary, preserving short press/release edges for SDL event consumers.
     * active=false releases controls and stops rumble; reactivation requires
     * a neutral report per controller. A >500 ms pump gap also stops effects.
     * No self-renewing timer can sustain rumble while the host is stalled.
     */
    S2KResult pump(bool active = true);
    /** Detach owned SDL devices, neutralize input, and stop effects. Does not stop
     * the borrowed manager or detach unrelated SDL devices. */
    void clear();
    /** Current immediate state and last operation error, for host-owned settings UI.
     * Access these only on the pump thread. No unbounded diagnostic queue is retained. */
    const S2KSnapshot& snapshot() const;
    S2KResult lastError() const;
    /** Install/replace a validated physical-device profile (at most 64 retained).
     * No file I/O. Call on the pump thread. A connected device is deliberately
     * detached/re-attached at the next pump because SDL sensor topology is fixed
     * at attachment. Physical assignment survives; transient SDL instance changes.
     * Failure leaves the preceding profile/device intact. An identical install is
     * a no-op. Removal uses the same deliberate lifecycle. Never use an ordinal. */
    S2KResult installMotionProfile(const S2KMotionProfile& profile);
    void removeMotionProfile(const S2KID& physical);
    /** Bounded, thread-safe metadata query through the host's existing SDL instance.
     * Safe inside an SDL event handler; it does not enter the adapter or host mutex.
     * No identity, sensor contents or diagnostic history is returned. */
    static SDL3MotionState motionState(SDL_JoystickID instance);
    /** Validate an actual SDL sensor event and recover its report sequence. At most
     * 256 timestamps per device are retained, with no sensor contents. Missing,
     * evicted or old-segment events return Waiting; hosts must reset, not interpolate. */
    static SDL3MotionState motionStateAt(SDL_JoystickID instance, Uint64 sensorTimestamp);
    static const char* motionStatusText(SDL3MotionStatus status);
    /** Resolve SDL instance identity to a physical controller and connection.
     * Store physical id for persistent mappings, NEVER an enumeration ordinal.
     * Return false for other SDL devices. Output pointers may be null. */
    bool identity(SDL_JoystickID instance, S2KID* physical, S2KID* connection) const;
    /** Resolve a currently connected physical controller to its SDL instance. */
    SDL_JoystickID instance(const S2KID& physical) const;
private:
    struct Impl;
    std::unique_ptr<Impl> impl;
};
}
