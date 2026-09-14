# Explicit motion profiles

A profile binds calibration to a **physical device**, model, Bluetooth report/configuration version and holding orientation. The library neither reads application preferences nor opens or writes profile files. No built-in measured model profiles are provided. Numerical validation and synthetic tests do not establish a physical controller's scale or orientation.

## Format and selection

`Switch2MotionProfile.encoded()` exports the version-1 ASCII format; `init(encoded:)` validates it. Native hosts include `Switch2KitMotionProfile.h` and use `s2k_decode_motion_profile`. Bound file reads to 4,097 bytes and reject more than 4,096 before decoding. Unknown, duplicate or trailing records, wrong dimensions/units/range/configuration, non-finite coefficients and invalid axes fail closed. CRLF and tab-separated fields are accepted. The format contains exactly these records, in this order:

```text
Switch2KitMotionProfile 1
device <physical UUID>
model <hex model, including 0x prefix>
configuration bt-report-v1 <hex compatibility feature byte>
raw-range -32768 32767
orientation <lower-case label> <three signed axes>
acceleration m/s2
bias <three native counts>
gain <three positive m/s2-per-count gains>
axes <three signed native axes>
range-at-32768 <three gain-times-32768 values in m/s2>
angular-velocity rad/s
bias <three native counts>
gain <three positive rad/s-per-count gains>
axes <three signed native axes>
range-at-32768 <three gain-times-32768 values in rad/s>
```

This schema is not a usable calibration file: the placeholders require actual measurements. The model values are the existing C model constants. Configuration v1 identifies the existing compatibility feature setup (Pro/GameCube `0xa7`, Joy-Con halves `0xb7`) and signed-16-bit raw report layout. Range records express the gain-derived response at 32,768 counts, **not** a factory-register readback. Requalify after firmware or sensor-configuration changes.

Native sensor axis signs must be established independently for acceleration and gyro. A holding orientation is a proper rotation: only the 24 determinant-positive signed-axis permutations are admitted. The same holding rotation is composed into both calibrated sensors, using the shared Swift converter, exactly once. A reflection is not an interchangeable holding orientation. Acceleration retains gravity in m/s²; gyro is right-handed rad/s, with final axes right, up, toward the user.

On the host input thread, `SDL3Adapter::installMotionProfile(profile)` validates and selects the physical profile. `removeMotionProfile(physicalID)` removes it. At most 64 profiles are retained, including disconnected devices. Failed replacement preserves the previous profile; identical replacement is a no-op. A changed connected profile deliberately detaches and reattaches that one in-process device at the next pump, because SDL's public virtual-sensor description is fixed at attachment. Hosts must use the existing physical assignment, never the transient SDL instance or discovery ordinal.

The existing `Integrations/Emulators/SDLHost.hpp` adds `loadMotionProfile(path)`, bounded explicit file loading outside SDL/host locks, as well as in-memory installation and removal. It does not choose a path or persist it implicitly. Hosts can save user-selected paths in their own settings and explicitly reload them. Controller input and physical identity survive removing calibration. Cemu now provides selection in the chosen SDL controller's settings: **Choose Switch2Kit motion profile**, then enable **Use motion**. Import verifies that the file belongs to that physical controller. The selected path and motion policy are persisted in Cemu's existing input profile, including when disconnected. **Remove motion profile** changes sensor topology but retains basic controls and assignment. File reads reject directories, devices and FIFOs, including symlink targets; path and read sizes are bounded. Dolphin selection and downstream processing remain to be completed.

## SDL delivery and timing contract

Only a compatible profile plus a raw-motion-capable controller registers `SDL_SENSOR_ACCEL` and `SDL_SENSOR_GYRO`. Their rate is zero (unknown), not an invented hardware sampling rate. Sensors start disabled. Delivery honors SDL's per-type enable state and the existing controller compatibility policy; enabling a virtual sensor does not issue another controller protocol or change handshake ordering.

`S2KState.received_at` is host monotonic **receive** time, not a hardware sampling timestamp. Each adapter batch brackets `s2k_monotonic_time()` with `SDL_GetTicksNS()`, rejects brackets longer than 1 ms, and converts only a bounded recent receive-time delta into SDL-clock nanoseconds. The lower bracket conservatively seeds a segment; subsequent samples advance by bounded receive-time differences instead of introducing jitter by reseeding every report. Absolute uptime and Unix time are never cast to SDL nanoseconds. Backwards clock movement or disagreement between the two clock deltas breaks continuity. SDL's event `timestamp` remains delivery time; `sensor_timestamp` is the correlated receive time and must be used for this stream's integration.

The admission gap is 100 ms, a conservative discontinuity bound rather than a claimed sample period. Duplicates, out-of-order sequences, non-finite/equal/decreasing/future/stale timestamps, sequence gaps, missing telemetry, raw clipping, overflow snapshots, retirement, profile changes, observed sensor-disable changes, inactivity and host stalls break the segment. The first fresh report rearms; only later contiguous fresh reports deliver motion. No zero measurements are synthesized, no latest sample is replayed per emulator frame, and initial/overflow snapshots reconcile controls without creating motion samples. Both Joy-Con halves remain independent streams.

`SDL3Adapter::motionState(instance)` returns **metadata only**: ownership, status, segment epoch, current receive timestamp and the earliest valid segment timestamp. Hosts must reset/rearm their existing motion processor when the epoch changes or status is not active, reject queued sensor events older than `validSinceNS`, and avoid integration across gaps. The floor is necessary when a gap and new reports share one native batch: earlier queued events still belong to the old segment. A metadata query also reports waiting when the last measurement has aged beyond the bound, even if the input loop itself is paused.

`motionStateAt(instance, sensor_timestamp)` validates an actual SDL event and resolves its original report sequence through a 256-entry metadata-only ring. Unknown, evicted and old-segment events are unavailable. This also detects a lost complete SDL event pair, which a timestamp-gap threshold alone cannot detect. `SDLMotionPair` retains at most one acceleration/gyro pair; missing halves, duplicate events, mismatched report times and sequence loss cannot cross into another pair.

Cemu consumes only complete fresh pairs, uses their receive-time delta, and calls the pinned emulator's existing `WiiUMotionHandler`/Mahony implementation. The SDL-to-Cemu axis conversion is applied once; acceleration is converted from m/s² to standard g at that existing emulator boundary, while gyro stays rad/s. Stream breaks reset the actual handler, including its bias/orientation history. A missing stream is unavailable to VPAD/KPAD rather than a synthetic zero input sample. Ordinary controller reads return cached emulated state without integrating it again. Per-object motion enablement requests are reference-counted on the existing SDL gamepad so closing a settings/enumeration object cannot disable another user's request.

SDL's aggregate `SetSensorsEnabled` callback runs under its joystick lock for first-enable/last-disable. The adapter additionally queries per-type state on each report/pump; it cannot infer an off/on transition of one type occurring entirely between pumps while another type remains enabled. Hosts changing motion policy should disable both sensors before reenabling. Each report flushes at most two virtual-sensor records through the host's existing SDL instance; no extra worker, unbounded sensor queue, fusion framework or Bluetooth callback workload is introduced.

The pinned public API and implementation are the authority: [virtual sensor submission](https://wiki.libsdl.org/SDL3/SDL_SendJoystickVirtualSensorData), [sensor descriptor](https://wiki.libsdl.org/SDL3/SDL_VirtualJoystickSensorDesc), [sensor enablement](https://wiki.libsdl.org/SDL3/SDL_SetGamepadSensorEnabled), and [sensor event timestamps](https://wiki.libsdl.org/SDL3/SDL_GamepadSensorEvent). Tests use SDL commit `147a8ee32dbf9ac02f3794964490687b6bbda1bc`.

## Measurement status

Six stationary acceleration poses can establish independent axis bias/gain. Stationary gyro sampling establishes zero-rate bias only, not scale or orientation. Known-rate positive/negative rotations or verified sensor configuration and controller-specific evidence are required for those remaining gyro parameters.

The pinned [SDL Switch 2 driver](https://github.com/libsdl-org/SDL/blob/147a8ee32dbf9ac02f3794964490687b6bbda1bc/src/joystick/hidapi/SDL_hidapi_switch2.c) contains USB factory-flash reads and USB sensor conversion, but its Bluetooth initialization is explicitly unsupported. The USB feature setup and heuristic clock/scale selection are not proof that those coefficients apply to this Bluetooth engine. No new speculative Bluetooth factory reads, first-generation constants, or automatic model profiles are introduced here.

Current automated evidence is mathematical conversion, synthetic profiles and fake controller boundaries feeding the actual hub, C ABI and pinned SDL. The Cemu-facing consumer additionally compiles and exercises the actual pinned emulator motion classes; this is not a full GUI application build or hardware qualification. A practical capture/solve tool, the corresponding Dolphin motion path, final native application builds, measured device profiles and physical acceptance remain separately tracked; a green adapter or solver fixture is not gameplay qualification.
