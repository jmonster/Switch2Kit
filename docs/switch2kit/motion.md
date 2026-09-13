# Motion calibration

`Switch2ControllerState.motion` contains signed sensor-native counts. Use an explicit `Switch2MotionCalibration` to convert measured telemetry into acceleration in m/s² and angular velocity in rad/s. The converter is stateless, immutable and safe to share across tasks. It does not change controller configuration or start Bluetooth.

## Supply measured calibration

Select bias, gain and orientation for the physical controller and its configured sensor range. Do not select a profile by player number. No built-in per-model motion profiles are supplied.

For each sensor-native axis, conversion is `(count - offset) * unitsPerCount`. The result is then reordered and signed using `xAxis`, `yAxis` and `zAxis`. Every native axis must appear once; duplicate axes, non-finite values, nonpositive gains and gains that could overflow the signed-16-bit input range are rejected with `Switch2KitError.invalidParameter`. Signs are not hidden in negative gains.

A host can construct the two sensors from its measured values:

```swift
import Switch2Kit

func makeMotionCalibration(
    accelerationBias: Switch2Vector3,
    accelerationGain: Switch2Vector3,
    gyroBias: Switch2Vector3,
    gyroGain: Switch2Vector3
) throws -> Switch2MotionCalibration {
    // This example keeps native axis order. Supply the measured axis mapping
    // when the consuming application's body frame differs from the sensor's.
    let acceleration = try Switch2SensorCalibration(
        offset: accelerationBias, unitsPerCount: accelerationGain)
    let gyro = try Switch2SensorCalibration(
        offset: gyroBias, unitsPerCount: gyroGain)
    return .init(acceleration: acceleration, angularVelocity: gyro)
}

func convert(_ state: Switch2ControllerState, with profile: Switch2MotionCalibration)
    -> Switch2CalibratedMotion? {
    state.motion.map { profile.apply(to: $0) }
}
```

Keep the original `state.receivedAt`, `state.sequence`, controller identity and connection identity alongside the result. An absent motion field is not a zero measurement.

## Reference measurements

`Switch2SensorCalibration(negativeReference:positiveReference:magnitude:)` derives bias and gain from equal negative and positive references. Each component of the reference vectors is an independent axis mean, not one three-axis pose.

For acceleration, use six stationary orientations: each sensor-native axis once at negative gravity and once at positive gravity, with the other axes perpendicular. The reference magnitude `9.80665` expresses standard gravity in m/s². Bias is the midpoint of that axis's two means; gain is the reference magnitude divided by their half-span. This removes sensor bias, **not gravity**. A stationary calibrated accelerometer still measures a vector of approximately one gravity.

A stationary gyro sample can measure zero-rate bias. It cannot establish gyro gain or prove an axis mapping. Use documented sensor configuration and verified scale, or measurements at known positive and negative angular rates. Supply gyro gains in rad/s per count, not degrees/s per count. Verify positive rotations and the intended physical holding orientation for every model.

The reference constructor checks numeric validity; it does not detect a moving calibration rig, clipping, temperature drift or poor measurements. It does not implement cross-axis matrices, automatic calibration, filtering or orientation fusion.

## C and C++ hosts

Include `<Switch2KitMotion.h>`. The additive `s2k_convert_motion` function uses the same Swift conversion implementation. It requires no `S2KContext` and works with caller-owned data on any thread. Existing `S2KState` and event layouts are unchanged.

Initialize `S2KMotionCalibration.version` to `S2K_MOTION_CALIBRATION_VERSION`, `struct_size` to `sizeof(S2KMotionCalibration)`, both sensor offsets/gains, axis selectors and zero reserved fields. Axis selectors are `1, 2, 3` for native positive X/Y/Z and their negatives for inverted axes.

```cpp
#include <Switch2KitMotion.h>

S2KResult convert_motion(const S2KState& raw, const S2KMotionCalibration& measured,
                         S2KCalibratedMotion& converted) {
    return s2k_convert_motion(&raw, &measured, &converted, sizeof(converted));
}
```

`S2K_NOT_READY` means no motion field. Invalid calibration or receive time returns `S2K_INVALID_ARGUMENT`; mismatched version/struct size returns `S2K_ABI_MISMATCH`. Output remains unchanged on every error. Successful output includes the original receive time and sequence without synthesizing timestamps.

## Emulator integration boundary

This API is the conversion stage, not automatic SDL gyro support. The SDL3 adapter still does not advertise motion sensors. Enabling those requires measured per-device/model profiles, sensor registration, timestamp and gap handling, and end-to-end verification of the target emulator's frame conventions.

SDL specifies acceleration in m/s² and gyro in rad/s with a defined body frame: see [SDL sensor types](https://wiki.libsdl.org/SDL3/SDL_SensorType). Never pass raw counts as those units. Host receive time is not hardware sample time; reset integration on reconnect, sequence discontinuities, missing telemetry and overflow rather than filling gaps with repeated samples. Do not fuse samples from different Joy-Con halves under one connection clock.
