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
| NSO GameCube | `0x2073` | Two sticks; analog travel separate from digital L/R clicks | None exposed | Device-timed soft/strong clips only |

The [Swift and C interfaces](cpp.md) expose the understood buttons, battery
telemetry, player LEDs, and raw acceleration/gyro/magnetometer telemetry for these
models. Capability bits describe understood functions, not a sensor enablement
readback or proof of a working physical unit. Battery charge is a rough voltage
estimate; magnetic counts are not a calibrated compass or heading.

## Motion and native emulator input

The existing shared adapter places controllers in the host's own SDL3 instance.
Buttons, sticks, hotplug, physical identity and Pro/Joy-Con game rumble do not need
a motion profile. GameCube is not advertised as an arbitrary-duration cancellable
SDL rumble device; the short-feedback API can select its firmware clips, but there
is no qualified stop command to invent or repeat into a continuous effect.

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

Optical counters remain available to Swift/C consumers. The dashboard has an
opt-in system-pointer adapter; the native Dolphin/Cemu adapter does **not** inject
system mouse movement or map optical counters to a game-specific aiming mode.
Applications can explicitly interpret raw optical input without confusing it
with calibrated accelerometer/gyro events. No native emulator input path requires
the dashboard, Accessibility, synthetic keyboard input or system virtual HID.

## Hardware features outside this implementation

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
Their host's ordinary input backends remain available. USB-driver work under
[`sdl/`](../../sdl/README.md) is separate from the CoreBluetooth engine; it does not
make USB a transport of the reusable Swift library.

## What verification establishes

Automated tests cover synthetic profiles and fake controller boundaries feeding
the real Swift hub, C ABI, pinned SDL and emulator motion components. Native CI
also builds both full applications for arm64 and x86_64 and inspects their
bundled dependencies. The [fresh-runner launch suite](../../tests/emulator-launch/README.md)
observes configured onscreen GUI startup and normal quit with developer dependency
paths inaccessible. It does not complete first-use dialogs or test a stock clean
Mac, Gatekeeper/notarization, Bluetooth, or gameplay.

No measured per-controller profiles or physical acceptance records are supplied.
Before claiming hardware qualification, execute the existing calibration and
[physical acceptance procedure](../../tools/motion-calibration/README.md#physical-acceptance):
validate gravity/bias/positive rotations, both emulator motion paths, rapid input
edges and trigger clicks/travel, reversed identical-controller reconnects,
Bluetooth and sleep/wake transitions, shutdown, rumble and sustained latency,
drops and memory. Record only observed outcomes and explicitly chosen captures.
