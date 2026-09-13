#pragma once
#include <Switch2KitC.h>
#include <SDL3/SDL.h>
#include <memory>

namespace Switch2Kit {
/** In-process SDL3 input adapter. The host owns context and SDL initialization.
 * Construct after SDL_INIT_GAMEPAD; destroy BEFORE s2k_destroy/SDL_Quit.
 * Call pump on one host input thread, before processing its SDL events. Other
 * threads may invoke ordinary SDL rumble APIs. Do not call pump reentrantly from
 * an SDL event watch/filter or joystick callback. No controller protocol lives here.
 */
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
