# Controller and feature coverage

This is the implemented software contract, not a physical-controller acceptance
report. Recognition uses Nintendo manufacturer data and the four product IDs in
[`Switch2ControllerModel`](../../Sources/Switch2Kit/Public/ControllerTypes.swift).
A supported controller can have usable buttons while its motion is unavailable.

| Physical model | Product ID | Sticks and triggers | Raw optical input | Rumble contract |
| --- | --- | --- | --- | --- |
| Pro Controller 2 | `0x2069` | Two sticks; digital ZL/ZR | None exposed | Independent HD motors; sustained and duration-controlled effects |
| Joy-Con 2 (L) | `0x2067` | Left stick; digital trigger | Wrapping x/y counters, lift and surface quality | One HD motor |
| Joy-Con 2 (R) | `0x2066` | Right stick; digital trigger | Wrapping x/y counters, lift and surface quality | One HD motor |
| NSO GameCube | `0x2073` | Two sticks; analog travel separate from digital L/R clicks | None exposed | On/off motor plus separate device-timed soft/strong clips |

The [Swift and C interfaces](cpp.md) expose the understood buttons, battery
telemetry, player LEDs, and raw acceleration/gyro/magnetometer telemetry for these
models. Capability bits describe understood functions, not a sensor enablement
readback or proof of a working physical unit. Battery charge is a rough voltage
estimate; magnetic counts are not a calibrated compass or heading.

## Motion and native emulator input

The existing shared adapter places controllers in the host's own SDL3 instance.
Buttons, sticks, hotplug, physical identity and game rumble do not need a motion
profile. Pro/Joy-Con support amplitude-controlled rumble; GameCube SDL rumble uses
its dedicated on/off motor channel, including stop and duration handling. Its
separate short-feedback API selects device-timed firmware clips; those clips are
not arbitrary-duration effects and are not repeated to emulate continuous rumble.
See the [rumble contract](../rumble.md) for the distinction and validation limits.

Calibrated accelerometer/gyro sensors require a compatible user-selected
[physical profile](motion-profiles.md), explicit sensor enablement and fresh,
continuous reports. No built-in measured coefficients are supplied. The
[calibration tool](../../tools/motion-calibration/README.md) acquires six stationary
acceleration poses and gyro zero-rate bias. Gyro scale and positive-rotation axes
still require known-rate measurements or controller-specific configuration
evidence; neither follows from holding a controller still. The profile is bound
to the physical ID, model, report configuration and holding orientation, not a
player slot or transient SDL instance.

Dolphin and Cemu provide profile selection, status, persistence and actual motion
processing in their pinned integrations. These are source patches maintained in
[this repository](../../Integrations/Emulators/README.md), not upstream emulator
PRs. Independent Joy-Con halves are separate native devices and sensor streams.
The dashboard's logical pairing feature does not silently fuse their native
motion clocks or turn them into one SDL device.

Optical counters remain available to Swift/C consumers. The macOS dashboard has
an opt-in system-pointer adapter; the native Dolphin/Cemu adapter does **not**
inject system mouse movement or map optical counters to game-specific aiming.
Applications can interpret raw optical input without confusing it with calibrated
accelerometer/gyro events. No native emulator input path requires the dashboard,
Accessibility, synthetic keyboard input or system virtual HID.

## Platforms and hardware features outside this implementation

The reusable engine has live macOS/CoreBluetooth and experimental Linux/BlueZ
backends. Linux supports native Swift/C/SDL hosts, not the macOS dashboard. See
[Linux requirements and qualification limits](linux.md). Windows and Android
have no supported Switch2Kit backend. USB-driver work under
[`sdl/`](../../sdl/README.md) is separate from these Bluetooth transports; it does
not make USB a transport of the reusable Swift library.

Nintendo's [accessory descriptions](https://www.nintendo.com/us/gaming-systems/switch-2/accessories/)
include Pro Controller 2 amiibo/headset features, C-button GameChat access, and
GL/GR controls on the Joy-Con 2 charging grip. Switch2Kit exposes C and GL/GR
report bits as bindable controls; it does not provide Nintendo GameChat,
NFC/amiibo operations, a headset audio transport, console-side remapping storage,
or controller firmware updates. Those are not hidden behind a motion setting.
Charging-grip operation needs accessory-specific physical acceptance; exposing
its report bits is not an end-to-end grip qualification.

Recognition is not based on a color or marketing edition. A variant reporting a
recognized model ID uses that model's code path; unmeasured firmware, sensor
configuration or holding changes still need requalification. An unfamiliar ID is
not accepted by guessing its protocol. First-generation Switch controllers and
third-party controllers are outside this four-ID Bluetooth backend, even when
[Nintendo lists console compatibility](https://en-americas-support.nintendo.com/app/answers/detail/a_id/68426/p/897/c/182).
Their host's ordinary input backends remain available.

## What verification establishes

Automated tests cover synthetic profiles and fake controller boundaries feeding
the real Swift hub, C ABI, pinned SDL and emulator motion components. Linux tests
also exercise the real BlueZ transport through an isolated synthetic D-Bus service.
Native CI builds and inspects full Dolphin/Cemu applications on Linux and on
macOS arm64/x86_64. The macOS [fresh-runner launch suite](../../tests/emulator-launch/README.md)
observes configured onscreen GUI startup and normal quit with developer dependency
paths inaccessible. It does not complete first-use dialogs or test a stock clean
Mac, Gatekeeper/notarization, Bluetooth, or gameplay. Linux build, installation and
loader checks do not establish interactive GUI or gameplay acceptance.

No measured per-controller profiles or new physical acceptance records are supplied.
Before claiming hardware qualification, execute the existing calibration and
[physical acceptance procedure](../../tools/motion-calibration/README.md#physical-acceptance):
validate gravity/bias/positive rotations, both emulator motion paths, rapid input
edges and trigger clicks/travel, reversed identical-controller reconnects,
Bluetooth and sleep/wake transitions, shutdown, rumble and sustained latency,
drops and memory. Record only observed outcomes and explicitly chosen captures.
