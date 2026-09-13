# Dolphin and Cemu

These integrations put Switch2Kit inside the emulator's SDL3 input backend. The emulator owns discovery and Bluetooth permissions. No separate Switch2Kit application, network connection, or system virtual controller is used.

## Build

Use macOS 15 or later, Xcode with Swift 6.2 or later, CMake and Ninja. Install the selected emulator's normal build dependencies first. The integration is disabled by default. Enabling it explicitly targets macOS 15; builds with it disabled retain the emulator's other platforms and deployment targets.

Use a fresh clone of the pinned revision, including its submodules:

```sh
git clone --recursive https://github.com/dolphin-emu/dolphin.git /path/to/dolphin
git -C /path/to/dolphin checkout c185d27ede09771fe93a3b520c576f646f937ed9
git -C /path/to/dolphin submodule update --init --recursive
python3 Integrations/Emulators/apply.py dolphin /path/to/dolphin
bash scripts/build-switch2kit-emulator.sh dolphin /path/to/dolphin /path/to/dolphin-build
```

For Cemu, install MoltenVK (`brew install molten-vk`) and leave the Vulkan renderer enabled.


```sh
git clone --recursive https://github.com/cemu-project/Cemu.git /path/to/cemu
git -C /path/to/cemu checkout 3310f3b8b184d64a62b89fd59088c799432badf5
git -C /path/to/cemu submodule update --init --recursive
bash /path/to/cemu/dependencies/vcpkg/bootstrap-vcpkg.sh
python3 Integrations/Emulators/apply.py cemu /path/to/cemu
bash scripts/build-switch2kit-emulator.sh cemu /path/to/cemu /path/to/cemu-build
```

`apply.py --check` validates without changing files. It refuses a different revision, modified files or untracked files. It never resets a checkout. `--verify` checks the applied source. The patches and file digests are in this directory. Extra arguments to the build script are ordinary CMake options for that emulator.

The host links its existing SDL3 target and the source-built C facade. `switch2kit_embed` places the native library and required Swift runtime libraries in the application's Frameworks directory. The emulator retains responsibility for signing the completed bundle. Each patched application supplies its own Bluetooth usage description; the embedding helper resolves that template fragment before CMake generates the bundle plist; no signing identity or permission bypass is added.

## Connect and configure

In Dolphin, open Controller Settings and select **Find Switch 2 Controllers**. In Cemu, open Input Settings, add an input API, and select **Find Switch 2 Controllers**. Allow that emulator's Bluetooth prompt, then hold Sync on the controller. Discovery lasts 60 seconds. Select the new SDL controller and configure the emulator's normal bindings.

Pro Controller, left and right Joy-Con, and NSO GameCube are separate physical devices. Joy-Con grouping is not silently imposed. Set each half's bindings in the emulator as needed. Pro/Joy-Con offer SDL rumble effects. GameCube's device-timed firmware clips remain available through the C feedback API but are not represented as cancellable SDL effects. Motion fields are raw in the C API; this integration does not expose them as calibrated SDL gyro/acceleration.

GameCube trigger travel and full-click buttons are independent. SDL exposes travel on the trigger axes and the digital clicks on Misc 3/Misc 4. Extra buttons and rail controls retain their SDL mappings. Check both travel and click bindings rather than assigning one from the other.

Dolphin records physical-to-device-number assignment in `Switch2Kit.ini` in its configuration directory. Cemu stores an opaque physical key in the existing input profile UUID field. Reconnecting two identical controllers in a different order does not intentionally redirect a saved profile to another unit. Transient SDL instance IDs and connection generations are never persisted as physical identity.

Quit the emulator to stop its manager and release its controllers. Only one process should own a controller at a time. A held input is neutralized on disconnection or overflow resynchronization. Rumble renewal comes from the emulator's live input loop, not an independent timer that could outlive a stalled host.

## Verification

`tests/emulator-host` exercises the real Swift hub, C ABI, shared adapter, and unmodified SDL together. It covers concurrent enumeration, explicit start/discovery, status, physical identity, reconnect and terminal shutdown. The underlying SDL consumer also checks every model, all 256 trigger values, button edges, overload, rumble and inactive neutral rearming.

The emulator workflow applies the exact patches, builds the full macOS application targets, and inspects their Bluetooth descriptions and embedded native library. Controller radio behavior and gameplay still require a physical-controller run of the built application.
