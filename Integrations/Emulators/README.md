# Dolphin and Cemu

These integrations put Switch2Kit inside the emulator's SDL3 input backend. The emulator owns discovery and Bluetooth permissions. No separate Switch2Kit application, network connection, or system virtual controller is used.

## Build

Use macOS 15+ with Xcode/Swift 6.2+, or experimental Linux/BlueZ with Swift 6.2+; both need CMake and Ninja. Install the selected emulator's normal platform build dependencies first. The integration is disabled by default. Apple builds explicitly target macOS 15; Linux builds do not use Xcode, macOS deployment flags or app bundles. Builds with the backend disabled retain the emulator's other platforms and deployment targets. See [Linux requirements, installation and test limits](../../docs/switch2kit/linux.md).

Use a fresh clone of the pinned revision, including its submodules:

```sh
git clone --recursive https://github.com/dolphin-emu/dolphin.git /path/to/dolphin
git -C /path/to/dolphin checkout c185d27ede09771fe93a3b520c576f646f937ed9
git -C /path/to/dolphin submodule update --init --recursive
python3 Integrations/Emulators/apply.py dolphin /path/to/dolphin
bash scripts/build-switch2kit-emulator.sh dolphin /path/to/dolphin /path/to/dolphin-build
```

For Cemu on macOS, install MoltenVK (`brew install molten-vk`) and leave the Vulkan renderer enabled. Linux uses its normal Vulkan/build dependencies, not MoltenVK.


```sh
git clone --recursive https://github.com/cemu-project/Cemu.git /path/to/cemu
git -C /path/to/cemu checkout 3310f3b8b184d64a62b89fd59088c799432badf5
git -C /path/to/cemu submodule update --init --recursive
bash /path/to/cemu/dependencies/vcpkg/bootstrap-vcpkg.sh
python3 Integrations/Emulators/apply.py cemu /path/to/cemu
bash scripts/build-switch2kit-emulator.sh cemu /path/to/cemu /path/to/cemu-build
```

`apply.py --check` validates without changing files. It refuses a different revision, modified files or untracked files. It never resets a checkout. `--verify` checks the applied source. The patches and file digests are in this directory. Extra arguments to the build script are ordinary CMake options for that emulator.

The host links its existing SDL3 target and the source-built C facade. On macOS, `switch2kit_embed` places the native library and required Swift runtime libraries in the application's Frameworks directory. The emulator retains responsibility for signing the completed bundle. Each patched application supplies its own Bluetooth usage description; the embedding helper resolves that template fragment before CMake generates the bundle plist; no signing identity or permission bypass is added.

## Connect and configure

In Dolphin, open Controller Settings and select **Find Switch 2 Controllers**. In Cemu, open Input Settings, add an input API, and select **Find Switch 2 Controllers**. Allow that emulator's macOS Bluetooth prompt, or ensure its Linux BlueZ access is permitted, then hold Sync on the controller. Discovery lasts 60 seconds. Select the new SDL controller and configure the emulator's normal bindings.

Pro Controller, left and right Joy-Con, and NSO GameCube are separate physical devices. Joy-Con grouping is not silently imposed. Set each half's bindings in the emulator as needed. Pro/Joy-Con offer amplitude-controlled SDL rumble; GameCube offers on/off SDL rumble through its dedicated motor channel. GameCube's device-timed firmware clips remain separately available through the C feedback API. Raw C telemetry remains available. A valid explicit physical-device profile enables calibrated SDL sensors; without one, basic controls work and calibrated motion is unavailable. No built-in model measurements are supplied.

GameCube trigger travel and full-click buttons are independent. SDL exposes travel on the trigger axes and the digital clicks on Misc 3/Misc 4. Extra buttons and rail controls retain their SDL mappings. Check both travel and click bindings rather than assigning one from the other.

Dolphin records physical-to-device-number assignment in `Switch2Kit.ini` in its configuration directory. Cemu stores an opaque physical key in the existing input profile UUID field. Reconnecting two identical controllers in a different order does not intentionally redirect a saved profile to another unit. Transient SDL instance IDs and connection generations are never persisted as physical identity.

Quit the emulator to stop its manager and release its controllers. Only one process should own a controller at a time. A held input is neutralized on disconnection or overflow resynchronization. Rumble renewal comes from the emulator's live input loop, not an independent timer that could outlive a stalled host.

## Cemu motion

Open the assigned SDL controller's settings, choose **Choose Switch2Kit motion profile**, and select a profile produced for that physical controller. Enable **Use motion**. Status distinguishes unavailable/invalid calibration, disabled motion, waiting for usable samples and active delivery. The physical identity is checked before installation; an invalid selection retains the previous profile. The chosen path and motion policy are saved in the existing Cemu input profile. Removing calibration does not remove the controller assignment.

Cemu receives fresh acceleration/gyro pairs through SDL and uses its existing Wii U motion processor. Integration uses correlated host receive timestamps, not SDL event delivery time, frame time or a guessed hardware clock. Gaps and sensor-policy changes reset the actual processor; absent data is not submitted as zero measurements. Multiple controller objects sharing one SDL device share enablement requests without disabling each other on teardown.

## Dolphin motion

In Controller Settings, select **Choose Switch2Kit motion profile**. The file identifies the physical controller; the chosen path is saved in Dolphin's `Switch2Kit.ini` alongside (not instead of) existing physical assignments. **Find Switch 2 Controllers** explicitly reloads saved selections. **Remove Switch2Kit motion profile** removes only calibration. Invalid profile imports retain the preceding selection. Read failures do not overwrite the settings file.

In the emulated Wii Remote's **Configure** window, select that physical SDL device as the default device. Under **Motion Input / Gyroscope**, enable **Calibrated Switch2Kit motion**. This mode uses paired motion directly from that device rather than separate IMU axis bindings, automatic gyro recalibration or the gyro dead zone. Ordinary button/trigger bindings and other input backends are unchanged. Existing Point settings (accelerometer influence, yaw range and Recenter) remain available.

Each emulated Wii Remote consumes each new paired report at most once through Dolphin's existing cursor filter, using its receive interval. Missing motion and discontinuities reset that real processor; an event-free frame does not run it again. Multiple Wii Remotes can read one physical stream independently without stealing reports or disabling each other's sensor requests. The bounded stream refuses old events, missing reports and stalled-consumer backlogs.

Both hosts report unavailable profile, invalid calibration, disabled sensors, waiting or active motion. See [profile format, calibration limits and timing](../../docs/switch2kit/motion-profiles.md). A loaded numerical profile is not evidence of measured hardware scale or orientation.

## Verification

`tests/emulator-host` exercises the real Swift hub, C ABI, shared adapter, and unmodified SDL together. It covers concurrent enumeration, explicit start/discovery, status, physical identity, reconnect and terminal shutdown. The underlying SDL consumer also checks every model, all 256 trigger values, button edges, overload, rumble and inactive neutral rearming.

With `S2K_CEMU_SOURCE` pointing to the pinned Cemu checkout, the host suite compiles the real `WiiUMotionHandler`, Mahony and VPAD motion classes. With `S2K_DOLPHIN_SOURCE` pointing to the patched pinned Dolphin checkout, it compiles the real cursor filter, matrix math and INI parser. Both consumers exercise Swift hub → C ABI → shared adapter → real SDL → actual emulator motion processing. These component tests are distinct from full application builds.

The emulator workflow applies the exact patches, builds the full macOS application targets, and inspects their Bluetooth descriptions and embedded native library. Controller radio behavior and gameplay still require a physical-controller run of the built application.

The separate Linux workflow exercises the real BlueZ adapter on a private synthetic bus, runs native C/SDL tests, and builds and inspects both full pinned Linux applications after installation and relocation. GUI/gameplay and physical-controller qualification remain separate; enabling its source patch is not a claim of a completed gameplay test.
