# In-process SDL3 controllers

`Switch2Kit::SDL3Adapter` attaches Switch2Kit controllers to the **host's existing SDL3 instance**. These are application-local virtual joysticks, not macOS virtual HID devices. The dashboard, UDP, Accessibility, and CoreHID are not involved.

## Build

```cmake
# Your existing SDL3 target must be defined first. Do not add a second SDL library.
find_package(SDL3 3.2 CONFIG REQUIRED)
add_subdirectory(/path/to/Switch2Kit/Integrations/SDL3 switch2kit)
target_link_libraries(your_emulator PRIVATE Switch2Kit::SDL3)
switch2kit_embed(your_emulator) # macOS application bundle; host signs it afterward
```

The source dependency builds through the [C binding](cpp.md). Enable it only for macOS 15+ hosts. The adapter itself is portable for fake-boundary tests; physical Bluetooth remains macOS-only. CI tests unmodified SDL at commit `147a8ee32dbf9ac02f3794964490687b6bbda1bc`.

## Ownership and input loop

Create `S2KContext` on the application's main thread, then start support and request a discovery window from controller settings. Initialize SDL's gamepad subsystem before constructing the adapter. Keep the main run loop active.

```cpp
#include <Switch2KitSDL3.hpp>

S2KResult error;
auto* input = s2k_create(nullptr, &error); // Main thread.
if (input && s2k_start(input) == S2K_OK) {
    Switch2Kit::SDL3Adapter adapter(input);
    s2k_discover(input, 60.0);

    // On the host's existing SDL input thread, once per update:
    adapter.pump(true);
    SDL_Event event;
    while (SDL_PollEvent(&event)) {
        // Existing emulator SDL processing.
    }

    // Keep using adapter in the input loop. Destroy it before the context and SDL.
}
s2k_destroy(input);
```

The adapter borrows the context and neither starts nor stops it. The host must destroy the adapter before the context and before SDL shutdown. All adapter methods, including destruction and identity lookup, belong to one input thread. Do not call `pump` recursively from an SDL event watch. `pump` holds SDL's joystick lock and does not run arbitrary host callbacks itself; SDL may run existing event watches during updates.

Each update drains at most 256 queued native events. Every input report crosses its own SDL update boundary, preserving a press and release that arrived within one batch. Initial discovery and overflow reconcile the authoritative controller snapshot, removing missing devices and releasing stale controls. A frame stall cannot grow the native queue indefinitely. Handle the returned error in the host UI; other SDL devices remain untouched.

Pass the host's desired input-active policy to `pump`. Inactive mode releases controls and stops effects without disconnecting Bluetooth. After reactivation, each controller must return to neutral before another held input is accepted. The host can allow background gameplay by continuing to pass true. Stop polling and destroy the adapter before teardown; no independent worker or refresh timer is created by this integration.

## Mapping

Sticks use SDL orientation, with vertical values inverted once from Switch2Kit's positive-up coordinates. GameCube travel maps to SDL trigger axes; digital L/R clicks remain independently bindable as Misc3/Misc4. Digital-only ZL/ZR also drive the corresponding trigger axis. Extra controls use SDL's Misc and paddle buttons. Missing Joy-Con sticks are not advertised.

Face buttons are positional: Pro/Joy-Con B/A/Y/X map to SDL South/East/West/North. GameCube A/X/B/Y map to South/East/West/North. Capture, C, GL and GR map to Misc1, Misc2, Misc5 and Misc6. Joy-Con SL/SR use the corresponding side's paddle buttons. Player-light callbacks map SDL's zero-based player index to indicators 1...8.

The adapter exposes `identity(SDL_JoystickID, ...)` and `instance(S2KID)` so an emulator can persist **physical identity**, rather than the discovery order of identical devices. `connection_id` changes on reconnect; it fences every rumble and indicator request. A host that still saves only SDL GUID plus ordinal must update that selection path to retain physical assignments across reversed reconnect order. The adapter does not silently pair Joy-Cons or assign logical players.

## Rumble and sensors

SDL duration-controlled rumble uses Pro/Joy-Con's continuous capability. The SDL callback starts the effect; subsequent input updates renew active intent at 200 ms intervals. SDL's own expiration is processed before renewal. Zero stops, newer effects replace older effects, and a gap of 500 ms in adapter updates cancels renewal rather than extending a stale effect. There is no timer that keeps buzzing when the host input loop is frozen.

GameCube exposes cancellable on/off SDL game rumble through its dedicated motor channel. Its separate soft/strong firmware feedback remains available through `s2k_play_feedback`; those preset clips are not used to implement SDL duration/stop. It never advertises raw counts as calibrated motion. With no valid physical-device profile, basic input remains available and no SDL motion sensors are registered. Explicit profiles, sensor delivery, clock correlation and the downstream reset contract are described in [Motion profiles](motion-profiles.md). Raw motion remains accessible through the C binding.

## Tests

```sh
S2K_SDL_SOURCE=/path/to/pinned/SDL bash tests/sdl-inprocess/verify.sh
```

A separate Swift fixture supplies fake physical controllers to the real event hub and C ABI. The C++ test uses actual SDL3 enumeration, mapping, events, duration expiry and detach behavior. It checks all four models, all 256 GameCube trigger values, button edges, overload, reconnect identity, inactivity and rumble lifetime. The fixture is not part of the adapter library. The real SDL motion consumer also checks all four models, exact SI event payloads, independent streams, enable/disable, profile replacement, 5,000 sample pairs, invalid/equal/decreasing timestamps, sequence gaps, overflow and retirement. Host tests cover bounded explicit file loading, spaces in paths, invalid-import rollback and concurrent status reads. These tests do not claim physical Bluetooth or emulator gameplay validation.
