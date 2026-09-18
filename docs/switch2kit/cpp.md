# C and C++ hosts

The optional `Switch2KitC` binding exposes the same controller engine through `Switch2KitC.h`. It uses caller-owned C structs and a bounded polling reader, not Objective-C objects or Swift collections. The source `Switch2Kit` product is unchanged for Swift hosts. Bluetooth requires macOS 15+ with Swift 6.2+/Xcode 26+, or the experimental [Linux/BlueZ backend](linux.md) with Swift 6.2+ and its runtime dependencies. Experimental [Windows x64/WinRT support](windows.md) uses the same engine with a native Bluetooth transport. Android remains unsupported.

## Build with CMake

```cmake
add_subdirectory(/path/to/Switch2Kit/Integrations/CMake switch2kit)
target_link_libraries(your_emulator PRIVATE Switch2Kit::C)
# Call the platform helper in the directory that creates the executable.
if(APPLE)
  switch2kit_embed(your_emulator)
elseif(WIN32)
  switch2kit_embed_windows(your_emulator)
elseif(CMAKE_SYSTEM_NAME STREQUAL "Linux")
  switch2kit_install_linux(your_emulator)
endif()
```

Use a CMake build directory owned by your project. The integration builds SwiftPM sources in that directory, respecting `CMAKE_OSX_ARCHITECTURES`. On macOS, explicitly select a deployment target of 15.0 or newer when enabling this backend. An emulator supporting older macOS versions should keep the backend optional rather than silently changing its minimum. The macOS host supplies its Bluetooth usage description and, when sandboxed, Bluetooth entitlement. Linux uses normal BlueZ/system-bus permissions and `switch2kit_install_linux` rather than macOS bundle embedding; see [Linux installation](linux.md). `switch2kit_embed` copies the binding and required Swift runtime libraries; the host's normal final signing step signs the bundle. No signing identity or application entitlements are supplied by the binding.

Windows uses a native x64 MSVC-compatible CMake build and the x64 Swift toolchain. The imported target provides both `Switch2KitC.dll` and its import library. `switch2kit_embed_windows` copies the DLL and attribution notices beside the executable; the matching Swift runtime must also be installed and available to the process. It does not copy Windows system libraries or change global `PATH`. See [Windows build and runtime instructions](windows.md).

`bash scripts/build-switch2kit-c.sh` builds and inspects a universal `build/Switch2KitC.xcframework` and compiles a fresh C++ consumer for each architecture. The C distribution has a fixed-layout C ABI. Swift consumers use the SwiftPM source package; the standalone Swift XCFramework pipeline is retired (see [Swift distribution](xcframework.md)). Do not link both implementations into one process. The C binding already includes the controller engine.

## Lifecycle and input

Create the handle on the main thread, before starting support. Do not call the creation function from an emulator's render thread. On macOS, keep the application's main run loop active. The Linux and Windows C polling APIs do not require a GUI event loop. Subsequent operations are thread-safe, except that each handle has one logical event reader and the owner must stop all API calls before destruction.

```cpp
#include <Switch2KitC.h>
#include <array>

S2KResult result;
S2KContext* input = s2k_create(nullptr, &result); // Main thread; no Bluetooth yet.
if (!input) { /* Show result and leave other input backends usable. */ }
else {
    s2k_start(input);
    s2k_discover(input, 60.0); // Connect advertising controllers during this window.
}

// Input loop: storage is entirely owned by C++.
std::array<S2KEvent, S2K_EVENT_CAPACITY> events{};
S2KSnapshot snapshot{};
uint32_t count = 0, flags = 0;
result = s2k_read(input, events.data(), events.size(), sizeof(S2KEvent),
                  &count, &snapshot, sizeof(snapshot), &flags);
if (result == S2K_OK) {
    if (flags & S2K_READ_RESYNC) {
        // Reconcile all devices and held controls against snapshot.
    } else {
        for (uint32_t i = 0; i < count; ++i) {
            // Apply each transition in order, not only the last state.
        }
    }
}
```

This reader uses the production event hub directly. It does not poll the 10 Hz presentation property or introduce another callback queue. It stores at most 256 events. The first read and overflow return an authoritative snapshot with `S2K_READ_RESYNC`; reconcile absent controllers and released buttons. A normal read preserves FIFO transitions, including a press and release in one batch. Capacity zero reads state without consuming pending events. `S2K_READ_MORE` indicates that another batch remains. Work per emulator tick should be bounded: do not loop indefinitely while a controller keeps producing input.

Snapshots accompany every read, but do not overwrite ordinary historical input with a newer snapshot before processing the events. For SDL virtual devices, commit transitions at the SDL update boundary instead of staging multiple opposing changes before one update.

Stop immediately suppresses input to the C reader and requests transport teardown. It is asynchronous: `snapshot.stopping` clears when teardown completes. Starting during that interval returns `S2K_BUSY`. Destruction cancels the reader and releases ownership; it never calls host code. There is no callback userdata to retain. Keep the loaded library resident for the process lifetime so queued Swift/Dispatch teardown can complete; do not `dlclose` it or call `FreeLibrary` on Windows.

## Mapping and control

Physical `id` persists locally, while `connection_id` changes on every reconnect. Keep both. Every device control requires both and cannot affect a replacement connection after the originating device retires. The transport repeats this check when the queued operation executes.

Sticks are normalized `-1...1`, right/up positive. GameCube trigger travel is `0...1` and independent of digital ZL/ZR clicks. Missing fields are identified by `present`; zero does not mean missing. Buttons retain Nintendo report positions, including the extra controls. Do not reinterpret them as an Xbox button layout. Raw motion is explicitly not scaled to SDL sensor units; do not advertise a calibrated sensor from these raw values.

Use `s2k_play_feedback` for a short action on every model. Use `s2k_set_rumble` for game effects (Pro/Joy-Con amplitude or GameCube motor on/off), renewing an active intent before 500 ms and sending zero on stop. `s2k_pulse_rumble` accepts 0.01...0.5 seconds. GameCube firmware clips cannot be cancelled or assigned an arbitrary duration; `S2K_CAP_RUMBLE_PRESETS` is separate from `S2K_CAP_CONTINUOUS_RUMBLE`. See [rumble](../rumble.md).

Malformed arguments return a synchronous `S2KResult`. Transport, radio and command failures arrive as `S2K_EVENT_ERROR`. Neither successful submission nor a protocol acknowledgement measures physical feedback.

## Validation

```sh
swift test -Xswiftc -warnings-as-errors
bash tests/c-consumer/run.sh # macOS and Linux
bash scripts/build-switch2kit-c.sh # macOS only
```

On Windows, use CMake directly from a native x64 developer shell: `cmake -S tests/c-consumer -B build-c -G Ninja -DCMAKE_BUILD_TYPE=Release`, `cmake --build build-c`, then `ctest --test-dir build-c --output-on-failure`.

The CMake consumer contains C11 and C++17 source. Its separately built test fixture feeds fake controller events through the real Swift event hub, C ABI and C++ program, exercising hotplug, edge order, all state fields, overflow, rumble routing and teardown. The fixture is not linked into any distribution product. Native CI also compiles the real manager creation path without starting Bluetooth. Physical controller and gameplay checks are separate from these tests.
