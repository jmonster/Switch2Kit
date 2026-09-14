# Explicit motion calibration

Build this small command-line host from source. It uses the existing Switch2Kit C reader for live reports and the public Swift calibration/profile implementation for fitting and validation. It does not add a Bluetooth protocol, library preferences, background logging, or another SDL instance. The emulator need not be running during calibration.

```sh
mkdir -p build
bash tools/motion-calibration/build.sh "$PWD/build/s2k-calibrate"
build/s2k-calibrate list
```

The executable is linked to this source checkout, not a redistributable app bundle. On macOS it embeds its own Bluetooth usage description; allow Bluetooth access when prompted. No Accessibility permission or CoreHID is required. Offline fitting/validation also runs on Linux. `list` is an explicit 20-second diagnostic discovery action: hold Sync; it displays locally scoped physical UUIDs and models. These IDs are not sent to a service. Close other controller hosts before capture.

## Six stationary poses and gyro bias

Establish a reference holding frame: X points right, Y up, Z toward the user when holding the controller normally. Keep those body-axis labels fixed as the controller is repositioned. Treat Joy-Con halves independently. Use a distinct holding label and profile for a different intended orientation.

Replace the UUID, model, feature byte, holding label and output path below with the chosen physical device. Model values are right Joy-Con `0x2066`, left Joy-Con `0x2067`, Pro `0x2069`, GameCube `0x2073`. Compatibility features are `0xb7` for either Joy-Con and `0xa7` for Pro/GameCube. `bt-report-v1` identifies the existing compatibility handshake and signed-16-bit report layout, **not** a readback of sensor range or sampling rate. No handshake commands are changed.

```sh
build/s2k-calibrate capture \
  --device YOUR-PHYSICAL-UUID --model 0x2069 \
  --configuration bt-report-v1 --features 0xa7 --holding pro-normal \
  --output /chosen/directory/stationary.csv
```

The tool prompts for +X, -X, +Y, -Y, +Z, -Z pointing vertically upward, then a separate completely stationary gyro-zero window. Let the controller settle and press Return. The main run loop and bounded reader stay serviced while you position it; do not touch it during a window. Each window retains 128..2048 fresh reports over 1..10 seconds, normally stopping after two seconds once enough reports exist. Repositioning is never treated as an integration interval. Connection replacement, missing motion, overflow, non-consecutive sequences, non-increasing receive time, gaps over 100 ms, stale reports and signed-report clipping abort capture. Initial/resynchronization snapshots are never samples.

The stationary capture file is raw diagnostic data, **not a usable profile**. Six acceleration poses determine native-axis bias, positive gain and axis signs. Stationary gyro sampling determines only zero-rate bias. It cannot determine gyro gain or positive-rotation axes.

## Independent gyro reference

Use either a measured rotation fixture or verified controller-specific configuration evidence. Do not substitute first-generation Switch constants, unrelated bridge constants, or a rate guessed from moving the controller by hand.

With an independently measured, steady-rate fixture, collect six positive/negative body-axis rotations:

```sh
build/s2k-calibrate capture-rate \
  --device YOUR-PHYSICAL-UUID --model 0x2069 \
  --configuration bt-report-v1 --features 0xa7 --holding pro-normal \
  --rate YOUR-MEASURED-RADIANS-PER-SECOND \
  --evidence 'Fixture identification and independently measured rate reference' \
  --output /chosen/directory/gyro-reference.csv
```

Use the right-hand rule for positive rotations. The command retains bounded report windows, rejects unstable rates/cross-axis response, and exports the six raw gyro means with the operator-supplied rate and evidence. It **does not measure or certify the fixture's true rotation rate**. Keeping the controller still is not a valid rate calibration. The fixture should rotate around the sensor to avoid excessive translational acceleration and clipping.

An externally measured reference may instead be imported as this exact ten-line CSV format. Values in angle-bracket placeholders are required measurements, not defaults:

```text
switch2kit-gyro-reference,1
<UUID>,<decimal model>,bt-report-v1,<hex feature byte>,<holding label>
known-rate,<nonempty evidence, at most 512 UTF-8 bytes>
rate-rad/s,<known positive rate>
+X,<native gyro x mean>,<native gyro y mean>,<native gyro z mean>
-X,<native gyro x mean>,<native gyro y mean>,<native gyro z mean>
+Y,<native gyro x mean>,<native gyro y mean>,<native gyro z mean>
-Y,<native gyro x mean>,<native gyro y mean>,<native gyro z mean>
+Z,<native gyro x mean>,<native gyro y mean>,<native gyro z mean>
-Z,<native gyro x mean>,<native gyro y mean>,<native gyro z mean>
```

For independently verified configuration, use five lines: the same first two lines, then `verified-configuration,<controller/configuration and scale/frame evidence>`, `gain-rad/s-per-count,<native x>,<native y>,<native z>`, and `axes,<signed x selector>,<signed y selector>,<signed z selector>`. Gains must be positive and sensor-native; each output selector is one of ±1, ±2, ±3, with each absolute axis appearing exactly once. Bias still comes from the stationary capture. The tool validates numbers and binding, not the credibility of the evidence string. Keep the reference file with your measurement records.

## Fit, validate and select

```sh
build/s2k-calibrate fit \
  --capture /chosen/directory/stationary.csv \
  --gyro-reference /chosen/directory/gyro-reference.csv \
  --output /chosen/directory/controller.s2kmotion

build/s2k-calibrate validate --profile /chosen/directory/controller.s2kmotion \
  --device YOUR-PHYSICAL-UUID --model 0x2069 \
  --configuration bt-report-v1 --features 0xa7 --holding pro-normal
```

The output is the existing version-1 `Switch2MotionProfile` format, directly usable by both emulator integrations. No second profile format or conversion library is installed. All six poses are checked through the actual shared converter. Admission limits reject axis spans below 256 counts, off-axis reference response above 3%, individual acceleration residuals above 0.5 m/s², acceleration deviation above 0.15 m/s², gyro residuals above 0.05 rad/s, or gyro deviation above 0.015 rad/s. Known-rate references must agree with stationary gyro bias. Rate capture allows at most max(0.005 rad/s, 2% of rate) deviation and max(0.01 rad/s, 5% of rate) individual residual. These are rejection thresholds, not advertised device accuracy.

Stationarity cannot be proven from these sensors alone: slow motion, uniform rotation about gravity, or incorrect reference measurements can evade rejection. Cross-axis misalignment beyond this diagonal/signed-permutation model requires better captures or a separately justified model, not silently relaxed assertions.

Input reads reject special files/FIFOs, oversized files/lines, unknown or malformed records, unsupported units/configuration, bad axes and non-finite numbers. Raw captures are limited to 4 MiB; references/profiles to 4 KiB. Outputs are explicit, new files with mode 0600. Existing files and symlinks are never overwritten. Default errors omit identifiers, sensor values and paths. No automatic telemetry or measured built-in profile is supplied.

In **Cemu**, choose the assigned SDL controller, select **Choose Switch2Kit motion profile**, then **Use motion**. In **Dolphin**, choose the profile in Controller Settings, assign the physical SDL device to the emulated Wii Remote, and enable **Calibrated Switch2Kit motion** under Motion Input / Gyroscope. Separate IMU axis bindings are not used in that mode. Each emulator owns its selected paths and persistent physical assignments. Removing a profile leaves buttons/sticks/triggers usable; it removes calibrated sensors. See [motion profiles](../../docs/switch2kit/motion-profiles.md).

## Physical acceptance

For each model/holding, check stationary gravity magnitude and direction in all six poses, near-zero stationary gyro, and positive rotations about each body axis at a measured rate. Then check actual Dolphin pointer/MotionPlus and Cemu GamePad motion, including no drift during a host stall and correct rearming after a gap. Do not infer a hardware pass from numerical fitting or synthetic fixtures.

Check rapid press/release edges, GameCube analog travel independently of clicks, extra/rail buttons, and two identical controllers reconnecting in reverse order. Exercise Bluetooth off/on, Sync and button wake, disconnect/reconnect, sleep/wake, profile replacement/removal, sensor off/on and shutdown. Confirm Pro/Joy-Con rumble duration/replacement/stops without renewal during a host stall; GameCube supports only the documented device-timed clips. During sustained play record host receive latency, observed drops and memory behavior without claiming receive time is a hardware sampling timestamp. Save raw reports only through an explicit diagnostic action.
